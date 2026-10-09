"""Resolve business network API signatures and calls from compiler source facts."""
import re
import ast
from swift_source_index import argument_parameter_bindings, matching_functions, visible_variables

NETWORK_FOUNDATION_MODULES = {'TransportCore', 'CommunityTransport', 'MediaKit'}
NETWORK_TRANSPORT_TYPES = {'HTTPClient', 'HTTPTransport', 'URLSession', 'CommunityAPIClient', 'CommunitySession'}
NETWORK_HARNESS_TYPES = {'ReleaseNetworkSmokeRunner', 'ReleaseNetworkSmokeDependencies', 'CommunityWriteSmoke',
    'NetworkSmokeProductionSession', 'ReleaseNetworkSmokeSchoolClient'}


def constant_boolean(condition: str, resolve) -> bool | None:
    expression = re.sub(r'!(?!=)', ' not ', condition.replace('&&', ' and ').replace('||', ' or '))
    expression = re.sub(r'\btrue\b', 'True', re.sub(r'\bfalse\b', 'False', expression)).strip()
    try: node = ast.parse(expression, mode='eval').body
    except SyntaxError: return None
    def value(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, bool): return node.value
        if isinstance(node, ast.Name): return resolve(node.id)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            operand = value(node.operand)
            return not operand if operand is not None else None
        if isinstance(node, ast.BoolOp):
            values = [value(operand) for operand in node.values]
            if isinstance(node.op, ast.And): return False if False in values else True if all(item is True for item in values) else None
            if isinstance(node.op, ast.Or): return True if True in values else False if all(item is False for item in values) else None
        return None
    return value(node)


def call_can_execute(facts: dict, call: dict) -> bool:
    for branch in facts.get('controlFlow', []):
        dead = branch.get('deadRange')
        if dead and dead[0] <= call['start'] < dead[1]:
            hoisted = any(function['start'] >= dead[0] and function['start'] <= call['start'] < function['end']
                and function.get('lexicalScope', []) == branch.get('lexicalScope', [])
                for function in facts.get('functionRanges', []))
            if not hoisted: return False
        sequence = re.sub(r'[\s()]', '', branch.get('iterationSource') or '')
        bounds = re.fullmatch(r'([+-]?\d[\d_]*)(\.\.<|\.\.\.)([+-]?\d[\d_]*)', sequence)
        empty = sequence == '[]'
        if bounds:
            lower, upper = int(bounds[1].replace('_', '')), int(bounds[3].replace('_', ''))
            empty = lower >= upper if bounds[2] == '..<' else lower > upper
        body = branch.get('thenRange')
        if empty and body and body[0] <= call['start'] < body[1]: return False
        def resolve(name):
            lexical = branch.get('lexicalScope', [])
            bindings = [node for node in facts.get('bindings', []) if node.get('bindingName') == name
                and node.get('scope') == branch.get('scope') and node['start'] <= branch['start']
                and lexical[:len(node.get('lexicalScope', []))] == node.get('lexicalScope', [])]
            if bindings:
                node = max(bindings, key=lambda item: (len(item.get('lexicalScope', [])), item['start']))
                return node.get('booleanValue')
            return None
        value = constant_boolean(branch.get('condition') or '', resolve)
        excluded = branch.get('elseRange') if value is True else branch.get('thenRange') if value is False else None
        if excluded and excluded[0] <= call['start'] < excluded[1]: return False
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
    def components(path, kind, scope):
        pending, seen, result = [(path, kind, scope)], set(), []
        while pending:
            source_path, value, source_scope = pending.pop()
            for name in re.findall(r'\b[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*', value):
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
    for path, facts in index.items():
        module = compilation_unit(path)
        if module in NETWORK_FOUNDATION_MODULES or module.endswith('Tests'): continue
        for node in facts.get('typedVariables', []):
            if not node['scope'] or not active(path, node): continue
            identity = owner(path, node['scope'])
            kind = types.terminal_name(path, node.get('type', ''), node['scope'])
            port = kind
            if 'async' in port and '->' in port and re.search(r'\bURLRequest\b', port) \
                    and re.search(r'\b(?:HTTPResponse|URLResponse|HTTPURLResponse)\b', port): network_owners.add(identity)
            for source_path, name, scope in components(path, node.get('type', ''), node['scope']):
                target = types.resolve(source_path, name, scope)
                if types.terminal_name(source_path, name, scope).rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES:
                    network_owners.add(identity)
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
    arguments = list(map(argument_type, call.get('arguments', [])))
    matches = []
    for path, function in candidates:
        for binding in argument_parameter_bindings(function['parameters'], call.get('argumentLabels', [])):
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
    return [(path, function) for score, path, function in matches if score == best]
