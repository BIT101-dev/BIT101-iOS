"""Resolve business network API signatures and calls from compiler source facts."""
import re
from pathlib import Path
from swift_source_index import argument_parameter_bindings, matching_functions, visible_variables
from swift_type_index import (
    custom_constant_symbols, execution_index as scalar_execution_index, constant_folding_allowed, string_literal_value, constant_value,
    constant_boolean, branch_value, branch_condition, switch_entries, block_outcomes,
    control_flow_outcomes, collection_count, call_can_execute, visible_callable_ranges,
)

NETWORK_FOUNDATION_API = {
    'TransportCore.HTTPClient': {'send(:URLRequest,accepting:Range<Int>,alsoAccepting:Set<Int>,maximumBytes:Int?)'},
    'TransportCore.HTTPBoundedTransfer': {'receive(:URLSessionDataTask)'},
    'ScorePorts.TrustedTranscriptReport': {'loadPages(excluding:Set<Int>,maximumBytes:Int,onPage:TrustedTranscriptPageDelivery?)'},
    'TransportCore.URLSessionTransport': {'deinit()', 'static make(configuration:URLSessionConfiguration,followsRedirects:Bool)'},
    'CommunityTransport.CommunitySession': {'client(errorDomain:String)'},
    'CommunityTransport.CommunityAPIClient': {
        'request(path:String,pathComponent:String?,queryItems:[URLQueryItem],method:String,body:Data?,contentType:String?,authentication:CommunityAuthentication,retryPolicy:CommunityRetryPolicy,validate:(@Sendable(Response)throws->Void)?)',
        'response(path:String,pathComponent:String?,queryItems:[URLQueryItem],method:String,body:Data?,contentType:String?,authentication:CommunityAuthentication,retryPolicy:CommunityRetryPolicy,validate:(@Sendable(Response)throws->Void)?)',
        'requestData(path:String,queryItems:[URLQueryItem],method:String,body:Data?,contentType:String?,authentication:CommunityAuthentication,retryPolicy:CommunityRetryPolicy)',
        'requestVoid(path:String,method:String,body:Data?,contentType:String?,authentication:CommunityAuthentication,retryPolicy:CommunityRetryPolicy)'},
    'MediaKit.MediaEnvironment': {'retryFailedImages()', 'static normalizedCacheLimitMB(:Int)', 'endPreview(owner:UUID)',
        'remotePreviewFile(for:URL,owner:UUID)', 'cachedRemotePreviewFile(for:URL,owner:UUID)',
        'usedBytes()', 'enforceCurrentLimit()', 'clearCaches()'},
    'MediaKit.RemoteAnimatedImage.Coordinator': {'load(url:URL,into:UIImageView,media:MediaEnvironment,reduceMotion:Bool,retryGeneration:UInt64,budgetGeneration:UInt64,maximumPixelSize:Int?,onPhaseChange:(@MainActor(RemoteAnimatedImagePhase)->Void)?)'},
    'MediaKit.ImageQuickLookPresenter': {'static dismantleUIViewController(:HostViewController,coordinator:Coordinator)'},
    'MediaKit.ImageQuickLookPresenter.Coordinator': {'receive(:ImagePreviewRequest?,from:HostViewController,media:MediaEnvironment)',
        'presentPendingIfPossible(from:HostViewController)', 'previewControllerDidDismiss(:QLPreviewController)', 'cancel()',
        'prepareInitialItems(for:ImagePreviewRequest,media:MediaEnvironment)', 'retryCurrentImage()', 'closePreview()'},
    'MediaKit.CachedRemoteImageLoader': {'load(url:URL?,fallbackURL:URL?,media:MediaEnvironment,maximumPixelSize:Int?)'},
    'MediaKit.CachedRemoteImageStore': {'data(for:URL)', 'image(for:URL,maximumPixelSize:Int?)',
        'loadImage(for:URL,maximumPixelSize:Int?)'},
    'MediaKit.RemoteStillImageLoader': {'load(thumbnailURL:URL?,originalURL:URL?,loadsOriginal:Bool,media:MediaEnvironment,pixelSize:Int,onAspectRatioResolved:((CGFloat)->Void)?)'},
    'MediaKit.RemoteImageCache': {'init(files:anyAppFileService,quota:ImageCacheDiskQuota,httpClient:HTTPClient,download:(@Sendable(URL)asyncthrows->HTTPResponse)?)',
        'file(for:URL)', 'withFile(for:URL,operation:@Sendable(URL)asyncthrows->Value)',
        'withSource(for:URL,download:(@Sendable(URL)asyncthrows->HTTPResponse)?,operation:@Sendable(RemoteImageSource)asyncthrows->Value)'},
    'BIT101-iOS.AppScheduleSchoolSessionRestorer': {'restoreSchoolSessionIfNeeded()'},
    'BIT101-iOS.AppNativeSchoolAuthentication': {'static make(state:TeachingCenterSessionState,productionPolicy:Bool)'},
}
NETWORK_TRANSPORT_TYPES = {'HTTPClient', 'HTTPTransport', 'URLSession', 'CommunityAPIClient', 'CommunitySession',
    'URLSessionTask', 'URLSessionDataTask', 'URLSessionUploadTask', 'URLSessionDownloadTask', 'URLSessionStreamTask',
    'URLSessionWebSocketTask', 'URLSessionDataTaskPublisher', 'NSURLConnection', 'NWConnection', 'NWConnectionGroup', 'NWListener', 'NWBrowser',
    'NetService', 'NetServiceBrowser', 'NSNetService', 'NSNetServiceBrowser', 'WKWebView'}
NETWORK_PLATFORM_CONNECTION_TYPES = {name for name in NETWORK_TRANSPORT_TYPES if name.startswith('NW')}
NETWORK_PLATFORM_TRANSPORT_TYPES = NETWORK_TRANSPORT_TYPES - NETWORK_PLATFORM_CONNECTION_TYPES - {'HTTPClient', 'HTTPTransport', 'CommunityAPIClient', 'CommunitySession'}
NETWORK_PLATFORM_STREAM_TYPES = {'Stream', 'InputStream', 'OutputStream', 'NSStream', 'NSInputStream', 'NSOutputStream'}
FOUNDATION_COLLECTION_TYPES = {'NSDictionary', 'NSMutableDictionary', 'NSArray', 'NSMutableArray'}
NETWORK_SYSTEM_FUNCTIONS = frozenset('socket|socketpair|connect|bind|listen|accept|send|sendto|sendmsg|recv|recvfrom|recvmsg|shutdown|setsockopt|getsockopt|getpeername|getsockname|getaddrinfo|getnameinfo|gethostbyname|gethostbyname2|gethostbyaddr|res_query|res_search|CFReadStreamCreateForHTTPRequest|CFHTTPMessageCreateRequest'.split('|'))
NETWORK_SYSTEM_FUNCTIONS |= frozenset({
    'connectx', 'disconnectx', 'sendfile', 'sockatmark',
    'CFSocketCreate', 'CFSocketCreateWithNative', 'CFSocketCreateWithSocketSignature',
    'CFSocketCreateConnectedToSocketSignature', 'CFSocketSetAddress', 'CFSocketConnectToAddress', 'CFSocketSendData',
    'CFStreamCreatePairWithSocket', 'CFStreamCreatePairWithSocketToHost', 'CFStreamCreatePairWithPeerSocketSignature',
    'CFStreamCreatePairWithSocketToCFHost', 'CFStreamCreatePairWithSocketToNetService',
})
NETWORK_TRANSPORT_METHODS = {'send', 'receive', 'sendPing', 'resume', 'start', 'data', 'bytes', 'upload', 'download',
    'receiveMessage', 'readData', 'write', 'request', 'requestData', 'requestVoid', 'sink', 'subscribe',
    'sendSynchronousRequest', 'sendAsynchronousRequest',
    'publish', 'resolve', 'startMonitoring', 'stopMonitoring', 'stop', 'setTXTRecord',
    'searchForServices', 'searchForBrowsableDomains', 'searchForRegistrationDomains',
    'load', 'loadHTMLString', 'loadFileURL', 'reload', 'reloadFromOrigin', 'goBack', 'goForward'}
NETWORK_HARNESS_TYPES = {
    'BIT101-iOS.ReleaseNetworkSmokeRunner': 'BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift',
    'BIT101-iOS.ReleaseNetworkSmokeDependencies': 'BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift',
    'BIT101-iOS.CommunityWriteSmoke': 'BIT101-iOS/Shared/Client/CommunityWriteSmoke.swift',
    'BIT101-iOS.NetworkSmokeProductionSession': 'BIT101-iOS/Shared/Client/NetworkSmokeProductionSession.swift',
}


def transport_method(expression: str) -> str:
    return expression.rsplit('.', 1)[-1].partition('(')[0]


def executed_callback_positions(call: dict, *, project_call: bool = False, potential: bool = False) -> set[int]:
    """Resolve system execution callbacks, including cancellation paths for production capabilities."""
    if project_call: return set()
    from swift_type_index import canonical_type_scope
    expression = '.'.join(canonical_type_scope([call.get('calledExpression', '').removeprefix('self.')])).removeprefix('_Concurrency.')
    if expression == 'withTaskCancellationHandler': return {0, 1} if potential else {0}
    if expression == 'withExtendedLifetime' or expression.endswith('.withValue') and '.$' in expression: return {1}
    if expression in {'AsyncStream', 'AsyncStream.init', 'AsyncThrowingStream', 'AsyncThrowingStream.init'} \
            and 'unfolding' in call.get('argumentLabels', []) and not potential: return set()
    functions = {'Task', 'Task.init', 'Task.detached', 'withTaskGroup', 'withThrowingTaskGroup',
        'withDiscardingTaskGroup', 'withThrowingDiscardingTaskGroup', 'withCheckedContinuation', 'withCheckedThrowingContinuation',
        'withUnsafeContinuation', 'withUnsafeThrowingContinuation', 'autoreleasepool',
        'withUnsafePointer', 'withUnsafeMutablePointer', 'withUnsafeTemporaryAllocation',
        'AsyncStream', 'AsyncStream.init', 'AsyncThrowingStream', 'AsyncThrowingStream.init'}
    methods = {'addTask', 'addTaskUnlessCancelled', 'forEach', 'map', 'compactMap', 'flatMap', 'filter', 'reduce',
        'async', 'asyncAfter', 'sync', 'scheduledTimer', 'sink', 'addOperation', 'addObserver', 'addBarrierBlock', 'concurrentPerform',
        'withUnsafeBytes', 'withUnsafeMutableBytes', 'withUnsafeBufferPointer', 'withUnsafeMutableBufferPointer'}
    receiver, _, method = expression.rpartition('.')
    if not potential:
        if method in {'asyncAfter', 'scheduledTimer'}: return set()
        if method == 'addObserver': return set()
        if method == 'sink' and not re.fullmatch(r'(?:Combine\.)?Just\([\s\S]*\)', receiver): return set()
        if method in {'forEach', 'map', 'compactMap', 'flatMap', 'filter', 'reduce'} \
                and not (call.get('receiverElementCount') or 0) > 0: return set()
        if method == 'concurrentPerform':
            labels, arguments = call.get('argumentLabels', []), call.get('arguments', [])
            iterations = arguments[labels.index('iterations')] if 'iterations' in labels else ''
            if not re.fullmatch(r'[0-9][0-9_]*', iterations) or int(iterations.replace('_', '')) <= 0: return set()
    if expression.removeprefix('Dispatch.') in {'DispatchWorkItem', 'DispatchWorkItem.init'}: return set()
    if not potential and expression not in functions and expression.rsplit('.', 1)[-1] not in methods: return set()
    return set(range(len(call.get('arguments', [])))) | {position for position, _, _ in call.get('closureArguments', [])}


def snapshot_execution_checker():
    """复用固定语法快照中每处引用的可达性结果。"""
    states = {}
    def check(facts, call):
        key = (id(facts), id(call))
        if key not in states: states[key] = (facts, call, call_can_execute(facts, call))
        return states[key][2]
    return check


def execution_index(index: dict) -> dict:
    return autoclosure_index(scalar_execution_index(index))


def autoclosure_index(index: dict) -> dict:
    """Represent known project autoclosure arguments with the existing callback graph."""
    from swift_type_index import SwiftTypeIndex, compilation_unit, receiver_resolver
    functions = [(path, function) for path, facts in index.items() for function in facts.get('functionRanges', [])]
    names = {function['name'] for _, function in functions
        if any('@autoclosure' in parameter['type'] for parameter in function.get('parameters', []))}
    if not names: return index
    types, receiver = SwiftTypeIndex(index), receiver_resolver(index)
    result = {}
    for path, facts in index.items():
        calls, closures = [], list(facts.get('inlineClosureRanges', []))
        for call in facts.get('invocations', []):
            expression = call['calledExpression']
            prefix, _, name = expression.rpartition('.')
            if name not in names: calls.append(call); continue
            target = receiver(dict(call, path=path)) if prefix not in {'', 'self', 'Self'} else None
            candidates = [(source, function) for source, function in functions if function['name'] == name and (
                target and '.'.join(types.function_scope(source, function['scope'])) == target or not target
                and prefix in {'', 'self', 'Self'} and compilation_unit(source) == compilation_unit(path)
                and call['scope'][:len(function['scope'])] == function['scope']) and (
                not function.get('lexicalScope') or source == path
                and call.get('lexicalScope', [])[:len(function['lexicalScope'])] == function['lexicalScope'])]
            matches = matching_api_calls(index, candidates, dict(call, path=path), types=types, conservative=True)
            bindings = [binding for _, function in matches for binding in api_argument_bindings(function, call)]
            ranges = call.get('argumentRanges', [])
            lazy = [(position, start, end) for position, (start, end) in enumerate(ranges) if bindings
                and all(position < len(binding) and '@autoclosure' in binding[position]['type'] for binding in bindings)]
            calls.append(dict(call, autoclosureArguments=lazy))
            for position, start, end in lazy:
                if any(node['start'] == start and node['end'] == end for node in closures): continue
                closures.append(dict(call, start=start, end=end, bodyStart=start,
                    name=f'autoclosure_{call["start"]}_{position}', parameters=[]))
        result[path] = dict(facts, invocations=calls, inlineClosureRanges=closures)
    return result


def callback_body_ranges(facts: dict, call: dict, positions: set[int], *, references: set[str] | None = None) -> set[tuple[int, int]]:
    """Resolve consumed closures and work items through their visible local bindings."""
    if not positions and not call.get('calledExpression', '').endswith('.perform') \
            and not re.fullmatch(r'\w+', call.get('calledExpression', '')): return set()
    variables = dict(facts, typedVariables=[dict(node, name=node['bindingName'])
        for node in facts.get('bindings', []) if node.get('bindingName')] + facts.get('callableRanges', []))
    work_items = {'DispatchWorkItem', 'DispatchWorkItem.init', 'Dispatch.DispatchWorkItem', 'Dispatch.DispatchWorkItem.init'}
    if any(node['name'] == 'DispatchWorkItem' for node in facts.get('declarations', [])):
        work_items -= {'DispatchWorkItem', 'DispatchWorkItem.init'}
    def resolve(value, reference, bounds=None, seen=frozenset()):
        name = value.removeprefix('self.')
        if re.fullmatch(r'\w+', name):
            if references is not None and not value.startswith('self.'): references.add(name)
            visible = visible_variables(variables, reference, name, value.startswith('self.'))
            if not visible: return set()
            binding = visible[-1]
            binding = next((node for node in visible if node['start'] == binding['start']
                and node.get('iterationSource')), binding)
            if binding['start'] in seen: return set()
            seen = seen | {binding['start']}
            result = {(node['start'], node['end']) for node in facts.get('callableRanges', [])
                if node['start'] == binding['start'] and node['name'] == name}
            target = binding.get('referenceTarget') or binding.get('initializerReference')
            if target: result.update(resolve(target, binding, seen=seen))
            if binding.get('iterationSource'):
                result.update(resolve(binding['iterationSource'], dict(binding,
                    lexicalScope=binding.get('lexicalScope', [])[:-1]), seen=seen))
            initializer = binding.get('constantInitializer', binding.get('value', '').partition('=')[2]).strip()
            if initializer.startswith('[') and initializer.endswith(']'):
                end = binding['start'] + len(binding['value'].encode())
                closures = [node for node in facts.get('inlineClosureRanges', [])
                    if binding['start'] <= node['start'] < node['end'] <= end]
                result.update((node['start'], node['end']) for node in closures if not any(
                    parent['start'] < node['start'] and node['end'] <= parent['end'] for parent in closures))
                for mutation in facts.get('invocations', []):
                    if mutation['calledExpression'] != name + '.append' or mutation['start'] >= reference['start'] \
                            or not call_can_execute(facts, mutation): continue
                    owners = visible_variables(variables, mutation, name)
                    if owners and owners[-1]['start'] == binding['start']:
                        result.update(callback_body_ranges(facts, mutation, {0}, references=references))
            if binding.get('initializerCall') in work_items:
                end = binding['start'] + len(binding['value'].encode())
                result.update(resolve(binding.get('constantInitializer', ''), binding, (binding['start'], end), seen))
            return result
        if bounds is None: return set()
        constructors = [node for node in facts.get('invocations', []) if node['calledExpression'] in work_items
            and bounds[0] <= node['start'] < bounds[1]]
        if not constructors: return set()
        constructor = min(constructors, key=lambda node: node['start'])
        result = {(start, end) for _, start, end in constructor.get('closureArguments', [])}
        for position, argument in enumerate(constructor.get('arguments', [])):
            ranges = constructor.get('argumentRanges', [])
            result.update(resolve(argument, constructor, ranges[position] if position < len(ranges) else None, seen))
        return result
    result = {(start, end) for position, start, end in call.get('closureArguments', []) + call.get('autoclosureArguments', [])
        if position in positions}
    for position, argument in enumerate(call.get('arguments', [])):
        if position in positions:
            ranges = call.get('argumentRanges', [])
            result.update(resolve(argument, call, ranges[position] if position < len(ranges) else None))
    if call.get('calledExpression', '').endswith('.perform'):
        result.update(resolve(call['calledExpression'].removesuffix('.perform'), call))
    expression = call.get('calledExpression', '')
    if re.fullmatch(r'\w+', expression):
        result.update(resolve(expression, call))
    return result


def method_signature(function: dict) -> str:
    signature = ('static ' if function.get('isStatic') else '') + function['name'] + '(' + ','.join(
        parameter['label'] + ':' + re.sub(r'\s+', '', parameter['type']) for parameter in function.get('parameters', [])) + ')'
    return signature + ('->' + re.sub(r'\s+', '', function.get('returnType') or 'Void') if function.get('returnOverload') else '')


def signature_function(signature: str, scope: list[str]) -> dict:
    static = signature.startswith('static ')
    name, tail = signature.removeprefix('static ').split('(', 1)
    depth, closing = 1, 0
    for closing, character in enumerate(tail):
        if character == '(': depth += 1
        elif character == ')': depth -= 1
        if depth == 0: break
    arguments, returned = tail[:closing], tail[closing + 1:].removeprefix('->')
    values, depth, start = [], [], 0
    for position, character in enumerate(arguments):
        if character in '(<[{': depth.append(character)
        elif character in ')>]}' and not (character == '>' and position and arguments[position - 1] == '-'):
            depth.pop()
        elif character == ',' and not depth:
            values.append(arguments[start:position])
            start = position + 1
    values.append(arguments[start:])
    return {'name': name, 'scope': scope, 'isStatic': static, 'returnType': returned or None, 'returnOverload': bool(returned),
        'parameters': [dict(label=label, name=label, type=kind, hasDefault=False, variadic=False)
        for value in values if value for label, kind in [value.split(':', 1)]]}


def platform_stream_request(types, path: str, call: dict, bindings=None) -> bool:
    receiver, _, method = call.get('calledExpression', '').rpartition('.')
    if method != 'getStreamsToHost': return False
    candidates = {types.terminal_name(path, receiver, call['scope'])}
    if bindings: candidates |= bindings.receiver_components(call, path)
    aliases = [node for node in types.index[path].get('bindings', []) + visible_variables(types.index[path], call, receiver)
        if node.get('bindingName', node.get('name')) == receiver
        and node['start'] < call['start'] and call['scope'][:len(node['scope'])] == node['scope']
        and call.get('lexicalScope', [])[:len(node.get('lexicalScope', []))] == node.get('lexicalScope', [])]
    if aliases:
        alias = max(aliases, key=lambda node: (len(node['scope']), len(node.get('lexicalScope', [])), node['start']))
        reference = alias.get('initializerReference', '')
        if reference.endswith('.self'): candidates.add(types.terminal_name(path, reference.removesuffix('.self'), alias['scope']))
    if any(name.removeprefix('Foundation.') in NETWORK_PLATFORM_STREAM_TYPES for name in candidates): return True
    target = types.resolve(path, receiver, call['scope'])
    return bool(target and any(types.terminal_name(path, base, target[1][:-1]).removeprefix('Foundation.')
        in NETWORK_PLATFORM_STREAM_TYPES for base in types.bases(target)))


def stored_callback_bindings(index: dict, types) -> dict:
    """连接构造参数、闭包属性与所属源码中的可调用体。"""
    properties, initializers, result = {}, {}, {}
    for path, facts in index.items():
        for node in facts.get('typedVariables', []):
            if not node.get('lexicalScope') and '->' in node.get('type', ''):
                target = types.resolve(path, '.'.join(node['scope']), aliases=False)
                if target: properties.setdefault(target, set()).add(node['name'])
        for node in facts.get('initializers', []):
            if node.get('isExplicitInitializer'):
                target = types.resolve(path, '.'.join(node['scope']), aliases=False)
                if target: initializers.setdefault(target, []).append((path, node))
    for path, facts in index.items():
        closures = facts.get('callableRanges', []) + facts.get('inlineClosureRanges', [])
        for call in facts.get('invocations', []):
            expression = call['calledExpression'].removesuffix('.init')
            target = types.resolve(path, '.'.join(call['scope']) if expression == 'Self' else expression, call['scope'])
            if target not in properties: continue
            positions = set(range(len(call.get('arguments', [])))) | {row[0] for row in call.get('closureArguments', [])}
            for position in positions:
                labels = call.get('argumentLabels', [])
                names = {labels[position]} & properties[target] if position < len(labels) and target not in initializers else set()
                for source_path, function in initializers.get(target, []):
                    for binding in api_argument_bindings(function, call):
                        if position >= len(binding): continue
                        parameter = binding[position].get('name', '')
                        for assignment in index[source_path].get('expressions', []):
                            if function['start'] <= assignment['start'] < function['end']:
                                if match := re.fullmatch(r'self\.(\w+)\s*=\s*' + re.escape(parameter), assignment['value']):
                                    names.update({match[1]} & properties[target])
                ranges = callback_body_ranges(facts, call, {position})
                for closure in closures:
                    if (closure['start'], closure['end']) in ranges:
                        for name in names:
                            result.setdefault(('.'.join([target[0], *target[1]]), name), []).append((path, closure, call))
    return result


def business_methods(index: dict) -> dict[str, list[tuple[str, dict]]]:
    from swift_type_index import callable_effect_index
    index = execution_index(callable_effect_index(index))
    can_execute = snapshot_execution_checker()
    from validation_inputs import NATIVE_PRODUCT_ROOTS, NATIVE_TEST_ROOTS
    test_roots = {'ModuleTests', *NATIVE_TEST_ROOTS}
    from validation_compilation import active_network_source, active_swift_source
    from validation_policy import NETWORK_CAPABILITIES
    from swift_type_index import SwiftTypeIndex, SwiftBindingTypes, compilation_unit, receiver_resolver
    types = SwiftTypeIndex(index)
    binding_types = SwiftBindingTypes(index, types)
    resolve_receiver = receiver_resolver(index)
    network_owners = set(NETWORK_CAPABILITIES)
    dependencies = {}
    protocols = {types.resolve(path, '.'.join(node['scope'] + [node['name']]), aliases=False)
        for path, facts in index.items() for node in facts.get('declarations', []) if node['kind'] == 'protocol'}
    for target, bases in types.records.items():
        identity = '.'.join([target[0], *target[1]])
        for base in bases:
            inherited = types.resolve(types.paths[target], base, target[1][:-1])
            if inherited in protocols and identity not in NETWORK_CAPABILITIES:
                dependencies.setdefault('.'.join([inherited[0], *inherited[1]]), set()).add(identity)
        if target[1][-1] not in NETWORK_TRANSPORT_TYPES and 'HTTPTransport' not in types.bases(target): continue
        network_owners.add(identity)
        for base in bases:
            if inherited := types.resolve(types.paths[target], base):
                network_owners.add('.'.join([inherited[0], *inherited[1]]))
    active_sources = {path: active_network_source(facts['source'], path).encode()
        if 'source' in facts else None for path, facts in index.items()}
    regular_sources = {path: active_swift_source(facts['source'], 'restore', path=path).encode()
        for path, facts in index.items() if 'source' in facts and any(path == known or path.endswith('/' + known)
            for known in NETWORK_HARNESS_TYPES.values())}
    def owner(path, scope): return '.'.join(types.function_scope(path, scope))
    components = types.components
    def active(path, node):
        source = active_sources[path]
        return source is None or source[node['start']:node['start'] + 1] not in {b' ', b'\n', b'\r'}
    def value_utility(path, call):
        expression = call.get('calledExpression', '')
        receiver, _, name = expression.rpartition('.')
        target = types.resolve(path, receiver, call['scope'])
        if not target: return False
        scope = (target[0], *target[1])
        definitions = [(source_path, function) for source_path, facts in index.items()
            for function in facts.get('functionRanges', []) if function['name'] == name
            and types.function_scope(source_path, function['scope']) == scope
            and matching_functions({'functionRanges': [function]}, name, dict(call, scope=function['scope']))]
        return bool(definitions) and all(not function.get('isAsync') and not any(
            types.terminal_name(source_path, kind, function['scope']).rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES | {'URLRequest'}
            for kind in [function.get('returnType') or '', *[parameter['type'] for parameter in function.get('parameters', [])]])
            for source_path, function in definitions)
    def network_port(kind):
        return 'async' in kind and '->' in kind and re.search(r'\b(?:URL|URLRequest)\b', kind) \
            and re.search(r'\b(?:Data|HTTPResponse|URLResponse|HTTPURLResponse)\b', kind)
    def remote_data_request(facts, call, source_path):
        readers = FOUNDATION_COLLECTION_TYPES | {'Data', 'NSData', 'NSMutableData', 'String', 'NSString', 'NSMutableString', 'XMLParser'}
        expression = call.get('calledExpression', '').removesuffix('.init').removesuffix('.self') or call.get('expectedType', '')
        expression = types.terminal_name(source_path, expression, call['scope']).removeprefix('Foundation.').removeprefix('Swift.')
        labels = call.get('argumentLabels', [])
        label = next((value for value in labels if value in {'contentsOf', 'contentsOfURL'}), None)
        if expression not in readers or label is None: return False
        position = labels.index(label)
        def file_only_argument(argument, invocation):
            if not re.fullmatch(r'[A-Za-z_]\w*', argument): return False
            parameter = any(function['start'] <= invocation['start'] < function['end']
                and any(item.get('name') == argument and 'inout' not in item.get('type', '')
                    for item in function.get('parameters', [])) for function in facts.get('functionRanges', []))
            return parameter and any(branch['value'].startswith('guard ')
                and re.sub(r'\s+', '', branch.get('condition') or '') == argument + '.isFileURL'
                and branch['scope'] == invocation['scope'] and branch.get('lexicalScope') == invocation.get('lexicalScope')
                and branch.get('elseRange', [0, invocation['start'] + 1])[1] < invocation['start']
                and not any(node.get('bindingName') == argument and branch['start'] < node['start'] < invocation['start']
                    for node in facts.get('bindings', [])) for branch in facts.get('controlFlow', []))
        if call.get('referenceTarget'):
            uses = [invocation for invocation in facts.get('invocations', [])
                if active(source_path, invocation) and can_execute(facts, invocation)
                and any(node['start'] == call['start'] for node in visible_callable_ranges(
                    facts, invocation.get('calledExpression', ''), invocation))]
            return not uses or any(position >= len(invocation.get('arguments', []))
                or not file_only_argument(invocation['arguments'][position], invocation) for invocation in uses)
        return not file_only_argument(call.get('arguments', [])[position], call)
    def system_request(facts, call, source_path):
        expression = call.get('calledExpression', '')
        if platform_stream_request(types, source_path, call, binding_types): return True
        if expression in {module + '.' + name for module in ('Darwin', 'Glibc', 'CFNetwork', 'CoreFoundation') for name in NETWORK_SYSTEM_FUNCTIONS}:
            return True
        return expression in NETWORK_SYSTEM_FUNCTIONS and not visible_variables(facts, call, expression) \
            and not matching_functions(facts, expression, call)
    for path, facts in index.items():
        if test_roots.intersection(Path(path).parts): continue
        for node in facts.get('typedVariables', []):
            if not active(path, node): continue
            identity = owner(path, node['scope'])
            kind = types.terminal_name(path, node.get('type', ''), node['scope'])
            if network_port(kind): network_owners.add(identity)
            for source_path, name, scope in components(path, node.get('type', ''), node['scope'], node):
                target = types.resolve(source_path, name, scope)
                if types.terminal_name(source_path, name, scope).rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES:
                    network_owners.add(identity)
                if target: dependencies.setdefault(identity, set()).add('.'.join([target[0], *target[1]]))
        for node in facts.get('bindings', []):
            if node.get('lexicalScope') or not active(path, node): continue
            if target := resolve_receiver(dict(node, path=path, calledExpression=node['bindingName'] + '.__propertyType')):
                dependencies.setdefault(owner(path, node['scope']), set()).add(target)
        for call in facts.get('invocations', []):
            if not active(path, call): continue
            expression = call.get('calledExpression', '')
            if remote_data_request(facts, call, path) or system_request(facts, call, path): network_owners.add(owner(path, call['scope']))
            if expression.removesuffix('.init').rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES | {'URLRequest'} \
                    or expression.split('.', 1)[0] in NETWORK_TRANSPORT_TYPES and not value_utility(path, call):
                network_owners.add(owner(path, call['scope']))
    changed = True
    while changed:
        added = {identity for identity, targets in dependencies.items() if targets & network_owners} - network_owners
        changed = bool(added)
        network_owners.update(added)
    registered_methods = {identity: {signature.split('(', 1)[0].removeprefix('static ') for signature in signatures}
        for identity, signatures in NETWORK_CAPABILITIES.items()}
    helper_functions = {}
    for source_path, source_facts in index.items():
        for function in source_facts.get('functionRanges', []) + [node for node in source_facts.get('initializers', [])
                if node.get('isExplicitInitializer')]:
            if active(source_path, function):
                helper_functions.setdefault(owner(source_path, function['scope']), []).append((source_path, function))
    protocol_helpers = {}
    for identity in dependencies.keys() & network_owners:
        waiting, visited = list(dependencies[identity]), set()
        while waiting:
            implementation = waiting.pop()
            if implementation in visited: continue
            visited.add(implementation)
            protocol_helpers.setdefault(identity, []).extend(helper_functions.get(implementation, []))
            waiting.extend(dependencies.get(implementation, set()) - visited)
    def transport_calls(facts):
        return facts.get('invocations', []) + [dict(member, calledExpression=member['value'], arguments=[], argumentLabels=[], isMemberRead=True)
            for member in facts.get('members', []) if not member.get('isAssignmentTarget')
            and transport_method(member['value']) in NETWORK_TRANSPORT_METHODS] + [
            dict(node, calledExpression=node['referenceTarget'], arguments=[], argumentLabels=[])
            for node in facts.get('callableRanges', []) if node.get('referenceTarget')]
    executed_bodies = {}
    eager_parameters = set()
    callback_functions = [(source_path, function) for entries in helper_functions.values()
        for source_path, function in entries if any('->' in parameter['type'] for parameter in function.get('parameters', []))]
    def executes(source_path, function, call):
        facts = index[source_path]
        return all(closure['start'] in executed_bodies[source_path]
            for closure in facts.get('callableRanges', []) + facts.get('inlineClosureRanges', [])
            if function['start'] <= closure['start'] <= call['start'] < closure['end'])
    def callback_targets(source_path, call):
        receiver, _, name = call.get('calledExpression', '').rpartition('.')
        constructor = types.resolve(source_path, call.get('calledExpression', '').removesuffix('.init'), call['scope'])
        if constructor:
            candidates = helper_functions.get('.'.join([constructor[0], *constructor[1]]), [])
            return matching_api_calls(index, candidates, dict(call, path=source_path, calledExpression='init',
                receiverExpression=call['calledExpression']), types=types, conservative=True)
        target = owner(source_path, call['scope']) if receiver in {'', 'self', 'Self'} \
            else resolve_receiver(dict(call, path=source_path))
        candidates = helper_functions.get(target, [])
        if not receiver: candidates = candidates + helper_functions.get(owner(source_path, []), [])
        return matching_api_calls(index, candidates, dict(call, path=source_path), types=types, conservative=True)
    def standard_callbacks(source_path, call):
        constructor = types.resolve(source_path, call.get('calledExpression', '').removesuffix('.init'), call['scope'])
        return executed_callback_positions(call, project_call=constructor is not None or bool(callback_targets(source_path, call)), potential=True)
    def selector_targets(source_path, call):
        if callback_targets(source_path, call): return
        facts = index[source_path]
        variables = dict(facts, typedVariables=[dict(node, name=node['bindingName'])
            for node in facts.get('bindings', []) if node.get('bindingName')])
        def reference(value, position, seen=frozenset()):
            matches = visible_variables(variables, position, value)
            if not matches or matches[-1]['start'] in seen: return None
            binding = matches[-1]
            return binding.get('selectorTarget') or reference(binding.get('initializerReference', ''), binding,
                seen | {binding['start']})
        selectors = list(call.get('selectorArguments', []))
        selectors.extend([None] * (len(call.get('arguments', [])) - len(selectors)))
        for position, argument in enumerate(call.get('arguments', [])):
            selector = selectors[position] or reference(argument, call)
            if not selector: continue
            match = re.fullmatch(r'(?:(.+)\.)?(\w+)(?:\(([^()]*)\))?', selector)
            if not match: continue
            receiver, name, signature = match.groups()
            resolved = types.resolve(source_path, receiver, call['scope']) if receiver else None
            target = '.'.join([resolved[0], *resolved[1]]) if resolved else owner(source_path, call['scope'])
            labels = [label.replace('_', '') for label in signature.split(':')[:-1]] if signature is not None else None
            for target_path, function in helper_functions.get(target, []):
                if function['name'] == name and (labels is None or labels == [
                        parameter['label'] for parameter in function.get('parameters', [])]):
                    yield target_path, function
    stored_callbacks = stored_callback_bindings(index, types)
    stored_callback_names = {name for _, name in stored_callbacks}
    def stored_targets(source_path, call):
        receiver, _, name = call.get('calledExpression', '').rpartition('.')
        if name not in stored_callback_names: return []
        if receiver in {'', 'self', 'Self'}:
            facts = index[source_path]
            variables = visible_variables(dict(facts, typedVariables=facts.get('typedVariables', []) + [
                dict(node, name=node['bindingName']) for node in facts.get('bindings', []) if node.get('bindingName')]), call, name)
            if not receiver and variables and (variables[-1].get('lexicalScope') or variables[-1].get('visibilityRange')): return []
            target = owner(source_path, call['scope'])
        else: target = resolve_receiver(dict(call, path=source_path))
        return [(path, closure) for path, closure, constructor in stored_callbacks.get((target, name), [])
            if active(path, constructor) and can_execute(index[path], constructor)]
    for source_path, source_facts in index.items():
        executed_bodies[source_path] = set()
    while True:
        previous = (len(eager_parameters), sum(map(len, executed_bodies.values())))
        for source_path, function in callback_functions:
            names = {parameter['name'] for parameter in function['parameters'] if '->' in parameter['type']}
            for call in index[source_path].get('invocations', []):
                if not function.get('bodyStart', function['start']) <= call['start'] < function['end'] \
                        or not active(source_path, call) or not can_execute(index[source_path], call) \
                        or not executes(source_path, function, call): continue
                expression = call.get('calledExpression', '')
                if expression in names:
                    eager_parameters.add((source_path, function['start'], expression))
                references = set()
                callback_body_ranges(index[source_path], call, standard_callbacks(source_path, call), references=references)
                eager_parameters.update((source_path, function['start'], name) for name in references & names)
                for target_path, target_function in callback_targets(source_path, call):
                    for binding in api_argument_bindings(target_function, call):
                        positions = {position for position, parameter in enumerate(binding)
                            if (target_path, target_function['start'], parameter.get('name')) in eager_parameters}
                        references = set()
                        callback_body_ranges(index[source_path], call, positions, references=references)
                        eager_parameters.update((source_path, function['start'], name) for name in references & names)
        for source_path, source_facts in index.items():
            for call in source_facts.get('invocations', []):
                if active(source_path, call) and can_execute(source_facts, call) and all(
                        closure['start'] in executed_bodies[source_path] for closure in source_facts.get('callableRanges', []) + source_facts.get('inlineClosureRanges', [])
                        if closure['start'] <= call['start'] < closure['end']):
                    executed_bodies[source_path].update(start for start, _ in callback_body_ranges(
                        source_facts, call, standard_callbacks(source_path, call)))
                    executed_bodies[source_path].update(closure['start'] for closure in
                        visible_callable_ranges(source_facts, call['calledExpression'], call))
                if not active(source_path, call) or not can_execute(source_facts, call) or not all(
                        closure['start'] in executed_bodies[source_path] for closure in source_facts.get('callableRanges', []) + source_facts.get('inlineClosureRanges', [])
                        if closure['start'] <= call['start'] < closure['end']): continue
                if can_execute(source_facts, call):
                    for target_path, closure in stored_targets(source_path, call):
                        executed_bodies[target_path].add(closure['start'])
                for target_path, function in callback_targets(source_path, call):
                    for binding in api_argument_bindings(function, call):
                        positions = {position for position, parameter in enumerate(binding)
                            if (target_path, function['start'], parameter.get('name')) in eager_parameters}
                        executed_bodies[source_path].update(start for start, _ in callback_body_ranges(source_facts, call, positions))
        if previous == (len(eager_parameters), sum(map(len, executed_bodies.values()))): break
    result, request_results = {}, {}
    for path, facts in index.items():
        module = compilation_unit(path)
        if test_roots.intersection(Path(path).parts): continue
        def contains_request(function, source_path=path, seen=None):
            key = (source_path, function['start'], function['end'], function.get('bodyStart'),
                function.get('isExplicitInitializer'), tuple(function.get('scope', [])))
            if key in request_results: return request_results[key]
            found = scan_requests(function, source_path, seen)
            if found or seen is None: request_results[key] = found
            return found
        def scan_requests(function, source_path, seen):
            if seen is None: seen = set()
            key = (source_path, function['start'])
            if key in seen: return False
            seen.add(key)
            source_facts = index[source_path]
            if function.get('isExplicitInitializer') and any(contains_request(node, source_path, seen)
                    for node in source_facts.get('initializers', [])
                    if not node.get('isExplicitInitializer') and node['scope'] == function['scope']): return True
            closures = source_facts.get('callableRanges', []) + source_facts.get('inlineClosureRanges', [])
            task_bodies = executed_bodies[source_path]
            for call in transport_calls(source_facts):
                if not (function.get('bodyStart') or function['start']) <= call['start'] < function['end'] \
                        or not active(source_path, call) or not can_execute(source_facts, call): continue
                target = resolve_receiver(dict(call, path=source_path))
                method = transport_method(call.get('calledExpression', ''))
                executes = all(closure['start'] in task_bodies for closure in closures
                    if function['start'] <= closure['start'] <= call['start'] < closure['end'])
                if not executes: continue
                if any(contains_request(closure, target_path, seen)
                        for target_path, closure in stored_targets(source_path, call)): return True
                if any(contains_request(callback, target_path, seen)
                        for target_path, callback in selector_targets(source_path, call)): return True
                callback_ranges = callback_body_ranges(source_facts, call, standard_callbacks(source_path, call))
                if any(contains_request(closure, source_path, seen) for closure in closures
                        if (closure['start'], closure['end']) in callback_ranges): return True
                if remote_data_request(source_facts, call, source_path): return True
                if executes and system_request(source_facts, call, source_path): return True
                expression = call.get('calledExpression', '')
                constructor = types.resolve(source_path, expression.removesuffix('.init'), call['scope'])
                invocation = dict(call, calledExpression='init', receiverExpression=expression) if constructor else call
                if constructor: target = '.'.join([constructor[0], *constructor[1]])
                definitions = matching_api_calls(index, helper_functions.get(target, []),
                    dict(invocation, path=source_path), types=types, conservative=True)
                if (target and target.rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES
                        or expression.removesuffix('.init').rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES) \
                        and not value_utility(source_path, call) and (not definitions or any(
                            function.get('isAsync') for _, function in definitions)) \
                        and expression.removesuffix('.init') not in NETWORK_PLATFORM_TRANSPORT_TYPES: return True
                if target in network_owners and (method in NETWORK_TRANSPORT_METHODS or method in registered_methods.get(target, set())):
                    return True
                expression = call.get('calledExpression', '').removeprefix('self.')
                if any(network_port(types.terminal_name(source_path, variable.get('type', ''), variable['scope']))
                        for variable in visible_variables(source_facts, call, expression)):
                    return True
                if method in NETWORK_TRANSPORT_METHODS and any(kind.rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES
                        or kind in NETWORK_PLATFORM_TRANSPORT_TYPES for kind in binding_types.receiver_components(call, source_path)):
                    return True
                receiver, _, method = call.get('calledExpression', '').rpartition('.')
                receiver_name = re.split(r'[.\[]', receiver.removeprefix('self.'), maxsplit=1)[0]
                for variable in visible_variables(source_facts, call, receiver_name, receiver.startswith('self.')):
                    if method in NETWORK_TRANSPORT_METHODS and any(
                        types.terminal_name(component_path, name, scope).rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES
                        for component_path, name, scope in components(source_path, variable.get('type', ''), variable['scope'], call)):
                        return True
                if not executes: continue
                if constructor:
                    matches = definitions
                    if any(contains_request(helper, candidate_path, seen) for candidate_path, helper in matches): return True
                    continue
                if not receiver or receiver in {'self', 'Self'}:
                    if not receiver and visible_variables(source_facts, call, method): continue
                    target = owner(source_path, call['scope'])
                available = helper_functions.get(target, []) + protocol_helpers.get(target, [])
                if not receiver: available = available + helper_functions.get(owner(source_path, []), [])
                candidates = [(candidate_path, helper) for candidate_path, helper in available
                    if (not helper.get('isPrivate') or candidate_path == source_path)
                    and call.get('lexicalScope', [])[:len(helper.get('lexicalScope', []))] == helper.get('lexicalScope', [])]
                groups = {None: candidates}
                if target in protocol_helpers:
                    groups = {}
                    for candidate_path, helper in candidates:
                        groups.setdefault(owner(candidate_path, helper['scope']), []).append((candidate_path, helper))
                matches = [match for group in groups.values() for match in matching_api_calls(
                    index, group, dict(call, path=source_path), types=types, conservative=True)]
                if any(contains_request(helper, candidate_path, seen) for candidate_path, helper in matches): return True
            return False
        accessors = [node for node in facts.get('accessorRanges', []) if node.get('isAsync') or contains_request(node)]
        explicit_scopes = {tuple(node['scope']) for node in facts.get('initializers', []) if node.get('isExplicitInitializer')}
        constructors = [node for node in facts.get('initializers', [])
            if (node.get('isExplicitInitializer') or tuple(node['scope']) not in explicit_scopes) and contains_request(node)]
        callable_apis = []
        for declaration in facts.get('functionRanges', []) + facts.get('accessorRanges', []):
            if not declaration.get('isExported') or '->' not in (declaration.get('returnType') or ''): continue
            if any(contains_request(dict(node, start=node['start'] + 1, end=node['end'] - 1))
                    for node in facts.get('inlineClosureRanges', [])
                    if declaration['start'] <= node['start'] < node['end'] <= declaration['end']):
                callable_apis.append(dict(declaration, isAsync=True))
        for declaration in facts.get('callableRanges', []):
            if declaration.get('lexicalScope') or not declaration.get('isExported'): continue
            bodies = [node for node in facts.get('callableRanges', [])
                if node['name'] == declaration['name'] and node['scope'] == declaration['scope']]
            for body in bodies:
                if body is not declaration and any(binding.get('bindingName') == body['name']
                        and binding.get('lexicalScope') and binding['start'] <= body['start']
                        and body.get('lexicalScope', [])[:len(binding['lexicalScope'])] == binding['lexicalScope']
                        for binding in facts.get('bindings', [])): continue
                closures = [node for node in facts.get('inlineClosureRanges', [])
                    if body['start'] <= node['start'] < node['end'] <= body['end']]
                outer = [node for node in closures if not any(parent['start'] < node['start']
                    and node['end'] <= parent['end'] for parent in closures)]
                if body.get('bodyStart') and contains_request(dict(body, start=body['bodyStart'])) \
                        or any(contains_request(dict(node, start=node['start'] + 1, end=node['end'] - 1)) for node in outer):
                    callable_apis.append(dict(declaration, isAsync=True)); break
        for function in facts.get('functionRanges', []) + accessors + constructors + callable_apis:
            scope = function['scope']
            if function.get('lexicalScope') or not active(path, function): continue
            identity = owner(path, scope)
            if method_signature(function) in NETWORK_FOUNDATION_API.get(identity, set()): continue
            harness_path = NETWORK_HARNESS_TYPES.get(owner(path, scope[:1]))
            if harness_path and (path == harness_path or path.endswith('/' + harness_path)) \
                    and path in regular_sources and regular_sources[path][function['start']:function['start'] + 1] in {b' ', b'\n', b'\r'}: continue
            if identity not in network_owners and function not in callable_apis and not contains_request(function): continue
            target = types.resolve(path, '.'.join(scope), aliases=False)
            if target in protocols: continue
            if types.returns_view(path, function) or target and any(base.rsplit('.', 1)[-1] in {'View', 'ViewModifier', 'App', 'Scene'}
                    and types.resolve(path, base, target[1][:-1]) not in types.nominal_records for base in types.bases(target)): continue
            parameters = function.get('parameters', [])
            if target and 'HTTPTransport' in types.bases(target) and function['name'] == 'data' \
                    and not function.get('isStatic') and len(parameters) in {1, 2} and parameters[0]['label'] == 'for' \
                    and (len(parameters) == 1 or parameters[1]['label'] == 'maximumBytes'
                        and re.sub(r'\s+', '', parameters[1]['type']) in {'Int?', 'Swift.Int?'}) \
                    and types.terminal_name(path, parameters[0]['type'], scope).rsplit('.', 1)[-1] == 'URLRequest': continue
            if function.get('isDeinitializer') and contains_request(function) \
                    or function.get('isExported') and (function in callable_apis or contains_request(function)
                    or method_signature(function) in NETWORK_CAPABILITIES.get(identity, {})) \
                    or module in NATIVE_PRODUCT_ROOTS and not function.get('isPrivate') \
                    and (contains_request(function) or method_signature(function) in NETWORK_CAPABILITIES.get(identity, {})) \
                    or not function.get('isPrivate') and method_signature(function) in NETWORK_CAPABILITIES.get(identity, {}) and contains_request(function) \
                    or identity not in NETWORK_CAPABILITIES and not function.get('isPrivate') and contains_request(function):
                result.setdefault(identity, []).append((path, function))
    for functions in result.values():
        groups = {}
        for _, function in functions: groups.setdefault(method_signature(function), []).append(function)
        for group in groups.values():
            if len({row.get('returnType') or 'Void' for row in group}) > 1:
                for function in group: function['returnOverload'] = True
    return result


def api_argument_bindings(function: dict, call: dict) -> list[list[dict]]:
    labels = list(call.get('argumentLabels', []))
    trailing = [item for item in call.get('closureArguments', []) if item[0] >= len(labels)]
    if trailing:
        parameters = function.get('parameters', [])
        if len(parameters) < len(trailing): return []
        declared = call.get('trailingClosureLabels', [''] * len(trailing))
        result = []
        for first in {parameter['label'] for parameter in parameters}:
            for binding in argument_parameter_bindings(parameters, labels + [first, *declared[1:]]):
                if binding not in result: result.append(binding)
        return result
    return argument_parameter_bindings(function.get('parameters', []), labels)


def api_invocations(facts: dict) -> list[dict]:
    return facts.get('invocations', []) + [dict(member, calledExpression=member['value'],
        argumentLabels=[], arguments=[], isMemberRead=True) for member in facts.get('members', [])
        if not member.get('isAssignmentTarget')]


def matching_execution_entries(index, entries, call, declarations, invocation, *, types):
    """Select declaration bodies and omitted defaults using the shared argument contract."""
    if invocation is None:
        return [entry for entry in entries if entry[0][3] == declarations[entry[0]][1]['start']]
    candidates = {id(function): (path, function) for key, _ in entries
        for path, function in [declarations[key]] if 'parameters' in function}
    invocation = dict(invocation, path=call['path'])
    if candidates and all(function['name'] == 'init' for _, function in candidates.values()):
        invocation = dict(invocation, calledExpression='init', receiverExpression=invocation['calledExpression'])
    groups = {}
    implicit = {identity for identity, (_, function) in candidates.items()
        if function.get('isAccessor') or function.get('isCallableValue') or function['name'] == 'init' and not function.get('isExplicitInitializer')}
    for path, function in candidates.values():
        if id(function) in implicit: continue
        groups.setdefault(types.function_scope(path, function['scope']), []).append((path, function))
    matched = {id(function) for group in groups.values()
        for _, function in matching_api_calls(index, group, invocation, types=types, conservative=True)}
    matched.update(implicit)
    selected = []
    for entry in entries:
        key, _ = entry
        _, function = declarations[key]
        if 'parameters' in function and id(function) not in matched: continue
        if key[3] != function['start']:
            omitted = {parameter['defaultExpressionRange'][0] for binding in api_argument_bindings(function, invocation)
                for parameter in function.get('parameters', []) if parameter.get('defaultExpressionRange')
                and all(parameter is not supplied for supplied in binding)}
            if key[3] not in omitted: continue
        selected.append(entry)
    return selected


def matching_api_calls(index: dict, functions: list[tuple[str, dict]], call: dict, *, types=None, conservative=False) -> list[tuple[str, dict]]:
    name = call['calledExpression'].removeprefix('self.').rsplit('.', 1)[-1]
    candidates = [(path, function) for path, function in functions if function['name'] == name
        and api_argument_bindings(function, call) and (not call.get('isMemberRead') or function.get('isAccessor')
            and '->' not in (function.get('returnType') or ''))]
    if not candidates: return []
    from swift_type_index import SwiftTypeIndex
    if types is None: types = SwiftTypeIndex(index)
    facts = index[call['path']]
    receiver = call.get('receiverExpression', call['calledExpression']).rpartition('.')[0]
    if receiver in {'self', 'Self', ''}:
        containers = [row for row in facts.get('functionRanges', []) if row['start'] <= call['start'] < row['end']]
        static = receiver == 'Self' or bool(containers and min(containers, key=lambda row: row['end'] - row['start']).get('isStatic'))
    else:
        variables = visible_variables(facts, call, receiver)
        static = any(re.sub(r'\s+', '', row.get('type') or '').endswith(('.Type', '.Protocol')) for row in variables) \
            or not call.get('receiverCall') and not variables and types.resolve(call['path'], receiver, call['scope']) is not None
    candidates = [(path, row) for path, row in candidates if not row.get('scope') or row.get('lexicalScope')
        or row.get('isExplicitInitializer') or row.get('isStatic', False) == static]
    if len(candidates) <= 1: return candidates
    generic_candidates = [(path, function) for path, function in candidates if any(
        row['start'] <= function['start'] < row['end'] and re.search(r'\b' + re.escape(row['name']) + r'\b',
            ' '.join([parameter['type'] for parameter in function['parameters']] + [function.get('returnType') or '']))
        for row in index[path].get('genericConstraints', []))]
    def canonical(path, kind, scope, seen=frozenset()):
        kind = re.sub(r'\bany\b|\s+', '', kind)
        lifted = kind.endswith(('?', '!'))
        kind = kind.rstrip('?!')
        alias = types.resolve(path, kind, scope, aliases=False)
        if alias in types.aliases and alias not in seen:
            base, inner = canonical(types.paths[alias], types.aliases[alias], alias[1][:-1], seen | {alias})
            return base, lifted or inner
        optional = re.fullmatch(r'(?:Swift\.)?Optional<(.+)>', kind)
        if optional:
            base, _ = canonical(path, optional[1], scope, seen)
            return base, True
        return types.terminal_name(path, kind, scope).removeprefix('Swift.'), lifted
    def argument_type(value):
        value = value.strip()
        if value in {'true', 'false'}: return 'Bool'
        if re.fullmatch(r'-?\d+', value): return 'Int'
        if re.fullmatch(r'-?\d+\.\d+', value): return 'Double'
        if value.startswith('"'): return 'String'
        variables = visible_variables(facts, call, value.removeprefix('self.'), value.startswith('self.'))
        if variables and variables[-1].get('type'): return re.sub(r'\s+', '', variables[-1]['type'])
        match = re.fullmatch(r'([\w.]+)\(.*\)', value, re.DOTALL)
        return match[1] if match and (match[1].rsplit('.', 1)[-1][:1].isupper()
            or types.resolve(call['path'], match[1], call['scope']) is not None) else None
    literals = call.get('argumentTypes', [])
    arguments = [literals[index] if index < len(literals) and literals[index] else argument_type(value)
        for index, value in enumerate(call.get('arguments', []))]
    def literal_context(path, function, parameter, expected, position):
        value = call['arguments'][position].strip()
        nominal = types.resolve(path, parameter['type'].rstrip('?!'), function['scope'])
        bases = types.bases(nominal) if nominal else set()
        def conforms(protocol): return bool(bases & {protocol, 'Swift.' + protocol})
        if value == 'nil': return 'nil' if conforms('ExpressibleByNilLiteral') else None
        if member := re.fullmatch(r'\.(\w+)(?:\(.*\))?', value, re.DOTALL):
            return 'member' if member[1] in types.enum_cases.get(expected, set()) else None
        kind = literals[position] if position < len(literals) else None
        if kind not in {'Int', 'Double'}: return None
        integer_types = {'Int', 'UInt', *(prefix + width for prefix in ('Int', 'UInt') for width in ('8', '16', '32', '64', '128'))}
        floating_types = {'Float', 'Float16', 'Float80', 'Double', 'CGFloat', 'Decimal'}
        standard = expected.removeprefix('CoreGraphics.').removeprefix('Foundation.')
        builtin = standard in floating_types or kind == 'Int' and standard in integer_types
        protocol = 'ExpressibleByIntegerLiteral' if kind == 'Int' else 'ExpressibleByFloatLiteral'
        return 'numeric' if builtin or conforms(protocol) else None
    matches = []
    expected_return = call.get('expectedType') or next((row.get('returnType') for row in facts.get('functionRanges', [])
        if row['start'] <= call['start'] < row['end'] and row.get('returnedCall') == call['calledExpression']), None)
    for path, function in candidates:
        for binding in api_argument_bindings(function, call):
            promotions, conversions = 0, 0
            for position, (kind, parameter) in enumerate(zip(arguments, binding)):
                expected, expected_optional = canonical(path, parameter['type'], function['scope'])
                value = call['arguments'][position].strip()
                context = literal_context(path, function, parameter, expected, position)
                if value == 'nil':
                    if not expected_optional and context != 'nil': break
                    continue
                if value.startswith('.'):
                    if context != 'member': break
                    actual, actual_optional = expected, False
                elif kind is None: continue
                else: actual, actual_optional = canonical(call['path'], kind, call['scope'])
                if actual_optional and not expected_optional: break
                distance = 0 if actual == expected else types.inheritance_distance(actual, expected)
                if distance is None and context == 'numeric': distance = 1
                if distance is None: break
                conversions += distance
                promotions += int(expected_optional and not actual_optional)
            else:
                return_score = 0
                if expected_return:
                    actual, optional = canonical(path, function.get('returnType') or 'Void', function['scope'])
                    expected, lifted = canonical(call['path'], expected_return, call['scope'])
                    distance = 0 if actual == expected else types.inheritance_distance(actual, expected)
                    if distance is None or optional and not lifted: continue
                    return_score = distance + int(lifted and not optional)
                score = (conversions, promotions, return_score, max(0, len(function['parameters']) - len(binding)))
                matches.append((score, path, function))
    if not matches: return generic_candidates if conservative else []
    if conservative and (any(kind is None for kind in arguments) or min(score[0] for score, _, _ in matches) > 0):
        return list({(path, function['start']): (path, function)
            for path, function in [(path, function) for _, path, function in matches] + generic_candidates}.values())
    best = min(score for score, _, _ in matches)
    selected = list({(path, function['start']): (path, function)
        for score, path, function in matches if score == best}.values())
    return selected if len(selected) == 1 else []
