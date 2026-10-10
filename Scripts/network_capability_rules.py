"""Resolve business network API signatures and calls from compiler source facts."""
import re
import ast
import warnings
import math
import operator
import unicodedata
from swift_source_index import argument_parameter_bindings, matching_functions, visible_variables

NETWORK_FOUNDATION_MODULES = {'TransportCore', 'CommunityTransport', 'MediaKit'}
NETWORK_TRANSPORT_TYPES = {'HTTPClient', 'HTTPTransport', 'URLSession', 'CommunityAPIClient', 'CommunitySession'}
NETWORK_HARNESS_TYPES = {'ReleaseNetworkSmokeRunner', 'ReleaseNetworkSmokeDependencies', 'CommunityWriteSmoke',
    'NetworkSmokeProductionSession', 'ReleaseNetworkSmokeSchoolClient'}


def string_literal_value(literal):
    escapes = {'0': '\0', 't': '\t', 'n': '\n', 'r': '\r', '"': '"', "'": "'", '\\': '\\'}
    pieces = []
    for part in re.finditer(r'\\(u\{[0-9a-fA-F]{1,8}\}|.)|[^\\]+', literal[1:-1]):
        escape = part[1]
        if escape is None: pieces.append(part[0])
        elif escape in escapes: pieces.append(escapes[escape])
        elif escape.startswith('u{'):
            scalar = int(escape[2:-1], 16)
            if scalar > 0x10ffff or 0xd800 <= scalar <= 0xdfff: return None
            pieces.append(chr(scalar))
        else: return None
    return unicodedata.normalize('NFC', ''.join(pieces))


def constant_value(condition: str, resolve):
    if '"""' in condition: return None
    tokens = {'&&': ' and ', '||': ' or ', '!': ' not ', 'true': 'True', 'false': 'False'}
    def translate(match):
        if match[0].startswith('"'):
            literal = string_literal_value(match[0])
            return repr(literal) if literal is not None else 'runtime_literal()'
        return tokens[match[0]]
    expression = re.sub(r'"(?:\\.|[^"\\])*"|&&|\|\||!(?!=)|\b(?:true|false)\b',
        translate, condition).strip()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', SyntaxWarning)
            node = ast.parse(expression, mode='eval').body
    except SyntaxError: return None
    def value(node):
        if isinstance(node, ast.Constant):
            if type(node.value) in {bool, int}: return node.value
            if type(node.value) is float: return node.value if math.isfinite(node.value) else None
            if type(node.value) is str: return node.value
        if isinstance(node, ast.Name): return resolve(node.id)
        if isinstance(node, ast.UnaryOp):
            operand = value(node.operand)
            if isinstance(node.op, ast.Not): return not operand if type(operand) is bool else None
            if type(operand) in {int, float}:
                if isinstance(node.op, ast.USub): return -operand
                if isinstance(node.op, ast.UAdd): return operand
        if isinstance(node, ast.BoolOp):
            values = [value(operand) for operand in node.values]
            if isinstance(node.op, ast.And): return False if any(item is False for item in values) else True if all(item is True for item in values) else None
            if isinstance(node.op, ast.Or): return True if any(item is True for item in values) else False if all(item is False for item in values) else None
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            left, right = value(node.left), value(node.comparators[0])
            if left is None or right is None: return None
            numeric = type(left) in {int, float} and type(right) in {int, float}
            if not numeric and type(left) is not type(right): return None
            if numeric:
                if type(left) is float or type(right) is float:
                    try: left, right = float(left), float(right)
                    except OverflowError: return None
                    if not math.isfinite(left) or not math.isfinite(right): return None
            if isinstance(node.ops[0], ast.Eq): return left == right
            if isinstance(node.ops[0], ast.NotEq): return left != right
            if numeric:
                comparison = {ast.Lt: operator.lt, ast.LtE: operator.le, ast.Gt: operator.gt, ast.GtE: operator.ge}.get(type(node.ops[0]))
                if comparison: return comparison(left, right)
        return None
    return value(node)


def constant_boolean(condition: str, resolve) -> bool | None:
    result = constant_value(condition, resolve)
    return result if type(result) is bool else None


def branch_condition(facts: dict, branch: dict) -> bool | None:
    resolving = set()
    def resolve(name, location=branch):
        lexical = location.get('lexicalScope', [])
        bindings = [node for node in facts.get('bindings', []) if node.get('bindingName') == name
            and node.get('scope') == location.get('scope') and node['start'] <= location['start']
            and lexical[:len(node.get('lexicalScope', []))] == node.get('lexicalScope', [])]
        variables = visible_variables({**facts, 'typedVariables': facts.get('typedVariables', []),
            'functionRanges': facts.get('functionRanges', [])}, location, name)
        if candidates := bindings + variables:
            node = max(candidates, key=lambda item: (len(item.get('scope', [])), len(item.get('lexicalScope', [])), item['start']))
            initializer = node.get('constantInitializer')
            annotation = node.get('bindingType')
            if not initializer or node['start'] in resolving or annotation and not re.fullmatch(
                    r'(?:Swift\.)?(?:Bool|String|U?Int(?:8|16|32|64)?|Double)', annotation): return None
            resolving.add(node['start'])
            try:
                result = constant_value(initializer, lambda referenced: resolve(referenced, node))
                if annotation in {'Double', 'Swift.Double'} and type(result) is int:
                    try: return float(result)
                    except OverflowError: return None
                return result
            finally: resolving.remove(node['start'])
        return None
    return constant_boolean(branch.get('condition') or '', resolve)


def control_flow_outcomes(facts: dict, branch: dict, conditions: dict) -> set[str]:
    """Track normal continuation and explicit exits through compiler block facts."""
    rows = facts.get('controlFlow', [])
    normal = {'normal'}
    def block_outcomes(bounds, *, nested=True):
        if not bounds: return normal
        lexical = branch.get('lexicalScope', [])
        alternative = next((row for row in rows if row['start'] == bounds[0]
            and row.get('lexicalScope', []) == lexical and row.get('thenRange')), None)
        if nested and alternative: return control_flow_outcomes(facts, alternative, conditions)
        outcomes = normal
        direct = sorted((row for row in rows if bounds[0] <= row['start'] < bounds[1]
            and row.get('scope') == branch.get('scope') and row.get('lexicalScope', []) == lexical + ([bounds[0]] if nested else [])),
            key=lambda row: row['start'])
        covered_until = bounds[0]
        for row in direct:
            if row['start'] < covered_until: continue
            if 'normal' not in outcomes: break
            if row.get('deadRange'):
                following = {row['value'].split()[0]}
            elif row.get('thenRange') or row.get('elseRange') or row.get('branchRanges'):
                following = control_flow_outcomes(facts, row, conditions)
                spans = [row[key] for key in ('thenRange', 'elseRange') if row.get(key)] + row.get('branchRanges', [])
                covered_until = max([span[1] for span in spans] + [row.get('followingRange', [row['start']])[0]])
            else: continue
            outcomes = outcomes - normal | following
        return outcomes
    identity = branch['start']
    if identity not in conditions: conditions[identity] = branch_condition(facts, branch)
    value = conditions[identity]
    kind = branch['value'].split()[0]
    if kind == 'switch':
        result, following = set(), normal
        for bounds in reversed(branch.get('branchRanges', [])):
            outcome = block_outcomes(bounds, nested=False)
            following = outcome - {'fallthrough'} | (following if 'fallthrough' in outcome else set())
            result |= following
        return result - {'break'} | (normal if 'break' in result or not branch.get('branchRanges') else set())
    if kind == 'guard':
        return normal if value is True else block_outcomes(branch.get('elseRange')) | (normal if value is None else set())
    body = block_outcomes(branch.get('thenRange'))
    if kind == 'do':
        alternatives = set().union(*(block_outcomes(bounds) for bounds in branch.get('branchRanges', [])))
        return body | alternatives
    if kind in {'while', 'repeat'}:
        if kind == 'while' and value is False: return normal
        exits = 'break' in body or value is not True and bool({'normal', 'continue'} & body)
        return body - {'normal', 'break', 'continue'} | (normal if exits or kind == 'while' and value is None else set())
    alternative = block_outcomes(branch.get('elseRange'))
    return body if value is True else alternative if value is False else body | alternative


def call_can_execute(facts: dict, call: dict) -> bool:
    conditions = {}
    def hoisted(bounds, branch):
        return any(function['start'] >= bounds[0] and function['start'] <= call['start'] < function['end']
            and function.get('lexicalScope', []) == branch.get('lexicalScope', [])
            for function in facts.get('functionRanges', []))
    for branch in facts.get('controlFlow', []):
        dead = branch.get('deadRange')
        if dead and dead[0] <= call['start'] < dead[1]:
            if not hoisted(dead, branch): return False
        sequence = re.sub(r'[\s()]', '', branch.get('iterationSource') or '')
        bounds = re.fullmatch(r'([+-]?\d[\d_]*)(\.\.<|\.\.\.)([+-]?\d[\d_]*)', sequence)
        empty = sequence == '[]'
        if bounds:
            lower, upper = int(bounds[1].replace('_', '')), int(bounds[3].replace('_', ''))
            empty = lower >= upper if bounds[2] == '..<' else lower > upper
        body = branch.get('thenRange')
        if empty and body and body[0] <= call['start'] < body[1]: return False
        if branch['start'] not in conditions: conditions[branch['start']] = branch_condition(facts, branch)
        value = conditions[branch['start']]
        excluded = branch.get('elseRange') if value is True else branch.get('thenRange') if value is False and not branch['value'].startswith('repeat') else None
        if excluded and excluded[0] <= call['start'] < excluded[1]: return False
        following = branch.get('followingRange')
        if following and following[0] <= call['start'] < following[1] and not hoisted(following, branch) \
                and 'normal' not in control_flow_outcomes(facts, branch, conditions): return False
    return True


def method_signature(function: dict) -> str:
    return function['name'] + '(' + ','.join(parameter['label'] + ':' + re.sub(r'\s+', '', parameter['type'])
        for parameter in function.get('parameters', [])) + ')'


def signature_function(signature: str, scope: list[str]) -> dict:
    name, arguments = signature.removesuffix(')').split('(', 1)
    values, depth, start = [], [], 0
    for position, character in enumerate(arguments):
        if character in '(<[{': depth.append(character)
        elif character in ')>]}' and not (character == '>' and position and arguments[position - 1] == '-'):
            depth.pop()
        elif character == ',' and not depth:
            values.append(arguments[start:position])
            start = position + 1
    values.append(arguments[start:])
    return {'name': name, 'scope': scope, 'parameters': [dict(label=label, type=kind, hasDefault=False, variadic=False)
        for value in values if value for label, kind in [value.split(':', 1)]]}


def business_methods(index: dict) -> dict[str, list[tuple[str, dict]]]:
    from validation_inputs import NATIVE_PRODUCT_ROOTS
    from validation_compilation import active_network_source
    from validation_test_areas import NETWORK_CAPABILITIES
    from swift_type_index import SwiftTypeIndex, compilation_unit, receiver_resolver
    types = SwiftTypeIndex(index)
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
    def owner(path, scope): return '.'.join(types.function_scope(path, scope))
    def components(path, kind, scope, node):
        pending, seen, result = [(path, kind, scope)], set(), []
        while pending:
            source_path, value, source_scope = pending.pop()
            for name in re.findall(r'\b[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*', value):
                constraints = [item for item in index[source_path].get('genericConstraints', [])
                    if item['name'] == name and item['start'] <= node['start'] < item['end']]
                if constraints:
                    size = min(item['end'] - item['start'] for item in constraints)
                    for item in constraints:
                        key = (source_path, name, item['start'])
                        if item['end'] - item['start'] == size and item['type'] and key + (item['type'],) not in seen:
                            seen.add(key + (item['type'],))
                            pending.append((source_path, item['type'], item['scope']))
                    continue
                target = types.resolve(source_path, name, source_scope, aliases=False)
                if target in types.aliases:
                    if target not in seen:
                        seen.add(target)
                        pending.append((types.paths[target], types.aliases[target], target[1][:-1]))
                else: result.append((source_path, name, source_scope))
        return result
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
    def remote_data_request(facts, call):
        if call.get('calledExpression', '') not in {'Data', 'Foundation.Data', 'Data.init', 'Foundation.Data.init'} \
                or 'contentsOf' not in call.get('argumentLabels', []): return False
        argument = call.get('arguments', [])[call['argumentLabels'].index('contentsOf')]
        file_only = False
        if re.fullmatch(r'[A-Za-z_]\w*', argument):
            parameter = any(function['start'] <= call['start'] < function['end']
                and any(item.get('name') == argument and 'inout' not in item.get('type', '')
                    for item in function.get('parameters', [])) for function in facts.get('functionRanges', []))
            file_only = parameter and any(branch['value'].startswith('guard ')
                and re.sub(r'\s+', '', branch.get('condition') or '') == argument + '.isFileURL'
                and branch['scope'] == call['scope'] and branch.get('lexicalScope') == call.get('lexicalScope')
                and branch.get('elseRange', [0, call['start'] + 1])[1] < call['start']
                and not any(node.get('bindingName') == argument and branch['start'] < node['start'] < call['start']
                    for node in facts.get('bindings', [])) for branch in facts.get('controlFlow', []))
        return not file_only
    for path, facts in index.items():
        module = compilation_unit(path)
        if module in NETWORK_FOUNDATION_MODULES or module.endswith('Tests'): continue
        for node in facts.get('typedVariables', []):
            if not active(path, node): continue
            identity = owner(path, node['scope'])
            kind = types.terminal_name(path, node.get('type', ''), node['scope'])
            port = kind
            if 'async' in port and '->' in port and re.search(r'\b(?:URL|URLRequest)\b', port) \
                    and re.search(r'\b(?:Data|HTTPResponse|URLResponse|HTTPURLResponse)\b', port): network_owners.add(identity)
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
            if remote_data_request(facts, call): network_owners.add(owner(path, call['scope']))
            if expression.removesuffix('.init').rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES | {'URLRequest'} \
                    or expression.split('.', 1)[0] in NETWORK_TRANSPORT_TYPES and not value_utility(path, call):
                network_owners.add(owner(path, call['scope']))
    changed = True
    while changed:
        added = {identity for identity, targets in dependencies.items() if targets & network_owners} - network_owners
        changed = bool(added)
        network_owners.update(added)
    async_methods = {(owner(path, function['scope']), function['name']) for path, facts in index.items()
        for function in facts.get('functionRanges', []) if function.get('isAsync')}
    result = {}
    for path, facts in index.items():
        module = compilation_unit(path)
        if module in NETWORK_FOUNDATION_MODULES or module.endswith('Tests'): continue
        def contains_request(function):
            closures = facts.get('callableRanges', []) + facts.get('inlineClosureRanges', [])
            task_bodies = {start for invocation in facts.get('invocations', [])
                if invocation.get('calledExpression') in {'Task', 'Task.init', 'Task.detached'}
                for _, start, _ in invocation.get('closureArguments', [])}
            for call in facts.get('invocations', []):
                if not (function.get('bodyStart') or function['start']) <= call['start'] < function['end'] \
                        or not active(path, call) or not call_can_execute(facts, call): continue
                if remote_data_request(facts, call): return True
                target = resolve_receiver(dict(call, path=path))
                method = call.get('calledExpression', '').rsplit('.', 1)[-1]
                executes = all(closure['start'] in task_bodies for closure in closures
                    if function['start'] <= closure['start'] <= call['start'] < closure['end'])
                if target in network_owners and (method in {'send', 'data', 'upload', 'download'} or (target, method) in async_methods and executes):
                    return True
                receiver, _, method = call.get('calledExpression', '').rpartition('.')
                for variable in visible_variables(facts, call, receiver.removeprefix('self.'), receiver.startswith('self.')):
                    if method in {'send', 'data', 'upload', 'download'} and any(
                        types.terminal_name(source_path, name, scope).rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES
                        for source_path, name, scope in components(path, variable.get('type', ''), variable['scope'], call)):
                        return True
            return False
        accessors = [node for node in facts.get('accessorRanges', []) if node.get('isAsync') or contains_request(node)]
        constructors = [node for node in facts.get('initializers', []) if node.get('isExplicitInitializer') and contains_request(node)]
        for function in facts.get('functionRanges', []) + accessors + constructors:
            scope = function['scope']
            if function.get('lexicalScope') or not active(path, function): continue
            identity = owner(path, scope)
            if scope and scope[0] in NETWORK_HARNESS_TYPES or identity not in network_owners: continue
            target = types.resolve(path, '.'.join(scope), aliases=False)
            if target in protocols: continue
            if function.get('returnsView') or target and any(base.rsplit('.', 1)[-1] in {'View', 'ViewModifier'} for base in types.bases(target)): continue
            if target and 'HTTPTransport' in types.bases(target): continue
            if function.get('isExported') or module in NATIVE_PRODUCT_ROOTS and not function.get('isPrivate') \
                    and (function.get('isAsync') or contains_request(function)):
                result.setdefault(identity, []).append((path, function))
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


def matching_api_calls(index: dict, functions: list[tuple[str, dict]], call: dict) -> list[tuple[str, dict]]:
    name = call['calledExpression'].removeprefix('self.').rsplit('.', 1)[-1]
    candidates = [(path, function) for path, function in functions if function['name'] == name
        and api_argument_bindings(function, call) and (not call.get('isMemberRead') or function.get('isAccessor')
            and '->' not in (function.get('returnType') or ''))]
    if len(candidates) <= 1: return candidates
    from swift_type_index import SwiftTypeIndex
    types = SwiftTypeIndex(index)
    def canonical(path, kind, scope, seen=frozenset()):
        kind = re.sub(r'\s+', '', kind)
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
    literals = call.get('argumentTypes', [])
    arguments = [literals[index] if index < len(literals) and literals[index] else argument_type(value)
        for index, value in enumerate(call.get('arguments', []))]
    matches = []
    for path, function in candidates:
        for binding in api_argument_bindings(function, call):
            promotions = 0
            for kind, parameter in zip(arguments, binding):
                if kind is None: continue
                actual, actual_optional = canonical(call['path'], kind, call['scope'])
                expected, expected_optional = canonical(path, parameter['type'], function['scope'])
                if actual != expected or actual_optional and not expected_optional: break
                promotions += int(expected_optional and not actual_optional)
            else:
                score = (promotions, max(0, len(function['parameters']) - len(binding)))
                matches.append((score, path, function))
    if not matches: return []
    best = min(score for score, _, _ in matches)
    selected = [(path, function) for score, path, function in matches if score == best]
    return selected if len(selected) == 1 else []
