"""Resolve business network API signatures and calls from compiler source facts."""
import re
from swift_source_index import argument_parameter_bindings, matching_functions, visible_variables

NETWORK_FOUNDATION_MODULES = {'TransportCore', 'CommunityTransport', 'MediaKit'}
NETWORK_TRANSPORT_TYPES = {'HTTPClient', 'HTTPTransport', 'URLSession', 'CommunityAPIClient', 'CommunitySession'}
NETWORK_HARNESS_TYPES = {'ReleaseNetworkSmokeRunner', 'ReleaseNetworkSmokeDependencies', 'CommunityWriteSmoke',
    'NetworkSmokeProductionSession', 'ReleaseNetworkSmokeSchoolClient'}


def call_can_execute(facts: dict, call: dict) -> bool:
    for branch in facts.get('controlFlow', []):
        dead = branch.get('deadRange')
        if dead and dead[0] <= call['start'] < dead[1]:
            hoisted = any(function['start'] >= dead[0] and function['start'] <= call['start'] < function['end']
                and function.get('lexicalScope', []) == branch.get('lexicalScope', [])
                for function in facts.get('functionRanges', []))
            if not hoisted: return False
        condition = re.sub(r'[\s()]', '', branch.get('condition') or '')
        value = {'true': True, 'false': False, '!true': False, '!false': True}.get(condition)
        if value is None and re.fullmatch(r'!?[A-Za-z_]\w*', condition):
            name = condition.removeprefix('!')
            lexical = branch.get('lexicalScope', [])
            bindings = [node for node in facts.get('bindings', []) if node.get('bindingName') == name
                and node.get('scope') == branch.get('scope') and node['start'] <= branch['start']
                and lexical[:len(node.get('lexicalScope', []))] == node.get('lexicalScope', [])]
            if bindings:
                node = max(bindings, key=lambda item: (len(item.get('lexicalScope', [])), item['start']))
                value = node.get('booleanValue')
                if value is not None and condition.startswith('!'): value = not value
        excluded = branch.get('elseRange') if value is True else branch.get('thenRange') if value is False else None
        if excluded and excluded[0] <= call['start'] < excluded[1]: return False
    return True


def method_signature(function: dict) -> str:
    return function['name'] + '(' + ','.join(parameter['label'] + ':' + re.sub(r'\s+', '', parameter['type'])
        for parameter in function.get('parameters', [])) + ')'


def signature_function(signature: str, scope: list[str]) -> dict:
    name, arguments = signature.removesuffix(')').split('(', 1)
    return {'name': name, 'scope': scope, 'parameters': [dict(label=label, type=kind, hasDefault=False, variadic=False)
        for value in arguments.split(',') if value for label, kind in [value.split(':', 1)]]}


def business_methods(index: dict) -> dict[str, list[tuple[str, dict]]]:
    from validation_evidence import active_swift_source
    from validation_test_areas import NETWORK_CAPABILITIES
    from swift_type_index import SwiftTypeIndex, compilation_unit, receiver_resolver
    types = SwiftTypeIndex(index)
    resolve_receiver = receiver_resolver(index)
    network_owners = set(NETWORK_CAPABILITIES)
    dependencies = {}
    for target, bases in types.records.items():
        identity = '.'.join([target[0], *target[1]])
        if target[1][-1] not in NETWORK_TRANSPORT_TYPES and 'HTTPTransport' not in types.bases(target): continue
        network_owners.add(identity)
        for base in bases:
            if inherited := types.resolve(types.paths[target], base):
                network_owners.add('.'.join([inherited[0], *inherited[1]]))
    active_sources = {path: active_swift_source(facts['source'], 'network').encode()
        if 'source' in facts else None for path, facts in index.items()}
    def owner(path, scope): return '.'.join([compilation_unit(path), *scope])
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
    for path, facts in index.items():
        module = compilation_unit(path)
        if module in NETWORK_FOUNDATION_MODULES or module.endswith('Tests'): continue
        for node in facts.get('typedVariables', []):
            if not node['scope'] or not active(path, node): continue
            identity = owner(path, node['scope'])
            target = types.resolve(path, node.get('type', ''), node['scope'])
            kind = types.terminal_name(path, node.get('type', ''), node['scope'])
            if kind.rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES: network_owners.add(identity)
            port = kind
            if 'async' in port and '->' in port and re.search(r'\bURLRequest\b', port) \
                    and re.search(r'\b(?:HTTPResponse|URLResponse|HTTPURLResponse)\b', port): network_owners.add(identity)
            if target: dependencies.setdefault(identity, set()).add('.'.join([target[0], *target[1]]))
        for node in facts.get('bindings', []):
            if not node['scope'] or node.get('lexicalScope') or not active(path, node): continue
            if target := resolve_receiver(dict(node, path=path, calledExpression=node['bindingName'] + '.__propertyType')):
                dependencies.setdefault(owner(path, node['scope']), set()).add(target)
        for call in facts.get('invocations', []):
            if not call['scope'] or not active(path, call): continue
            expression = call.get('calledExpression', '')
            if expression.removesuffix('.init').rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES | {'URLRequest'} \
                    or expression.split('.', 1)[0] in NETWORK_TRANSPORT_TYPES and not value_utility(path, call):
                network_owners.add(owner(path, call['scope']))
    changed = True
    while changed:
        added = {identity for identity, targets in dependencies.items() if targets & network_owners} - network_owners
        changed = bool(added)
        network_owners.update(added)
    result = {}
    for path, facts in index.items():
        module = compilation_unit(path)
        if module in NETWORK_FOUNDATION_MODULES or module.endswith('Tests'): continue
        for function in facts.get('functionRanges', []) + [accessor for accessor in facts.get('accessorRanges', []) if accessor.get('isAsync')]:
            scope = function['scope']
            if not scope or function.get('lexicalScope') or not active(path, function): continue
            identity = owner(path, scope)
            if scope[0] in NETWORK_HARNESS_TYPES or identity not in network_owners: continue
            target = types.resolve(path, '.'.join(scope), aliases=False)
            if target and 'HTTPTransport' in types.bases(target): continue
            if function.get('isExported') or module == 'BIT101-iOS' and function.get('isAsync') and not function.get('isPrivate'):
                result.setdefault(identity, []).append((path, function))
    return result


def matching_api_calls(index: dict, functions: list[tuple[str, dict]], call: dict) -> list[tuple[str, dict]]:
    name = call['calledExpression'].removeprefix('self.').rsplit('.', 1)[-1]
    candidates = [(path, function) for path, function in functions if matching_functions({'functionRanges': [dict(function, parameters=function.get('parameters', []), lexicalScope=function.get('lexicalScope', []))]}, name,
        dict(call, scope=function['scope'], lexicalScope=function.get('lexicalScope', [])))]
    if len(candidates) <= 1: return candidates
    facts = index[call['path']]
    def argument_type(value):
        value = value.strip()
        if value in {'true', 'false'}: return 'Bool'
        if re.fullmatch(r'-?\d+', value): return 'Int'
        if re.fullmatch(r'-?\d+\.\d+', value): return 'Double'
        if value.startswith('"'): return 'String'
        variables = visible_variables(facts, call, value.removeprefix('self.'), value.startswith('self.'))
        if variables and variables[-1].get('type'): return re.sub(r'\s+', '', variables[-1]['type'])
        match = re.fullmatch(r'([\w.]+)\(.*\)', value, re.DOTALL)
        return match[1] if match else None
    arguments = list(map(argument_type, call.get('arguments', [])))
    return [(path, function) for path, function in candidates if any(
        all(kind is None or re.sub(r'\s+', '', parameter['type']).removeprefix('Swift.') == kind
            for kind, parameter in zip(arguments, binding))
        for binding in argument_parameter_bindings(function['parameters'], call.get('argumentLabels', [])))]
