"""Resolve business network API signatures and calls from compiler source facts."""
import re
from pathlib import Path
from swift_source_index import matching_functions, visible_variables

NETWORK_FOUNDATION_MODULES = {'TransportCore', 'CommunityTransport', 'MediaKit'}
NETWORK_TRANSPORT_TYPES = {'HTTPClient', 'HTTPTransport', 'URLSession', 'CommunityAPIClient', 'CommunitySession'}
NETWORK_HARNESS_TYPES = {'ReleaseNetworkSmokeRunner', 'ReleaseNetworkSmokeDependencies', 'CommunityWriteSmoke',
    'NetworkSmokeProductionSession', 'ReleaseNetworkSmokeSchoolClient'}


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
    from swift_type_index import SwiftTypeIndex, compilation_unit
    types = SwiftTypeIndex(index)
    network_owners = set(NETWORK_CAPABILITIES)
    dependencies = {}
    active_sources = {path: active_swift_source(Path(path).read_text(), 'network').encode()
        if Path(path).is_file() else None for path in index}
    def owner(path, scope): return '.'.join([compilation_unit(path), *scope])
    def active(path, node):
        source = active_sources[path]
        return source is None or source[node['start']:node['start'] + 1] not in {b' ', b'\n', b'\r'}
    for path, facts in index.items():
        module = compilation_unit(path)
        if module in NETWORK_FOUNDATION_MODULES or module.endswith('Tests'): continue
        for node in facts.get('typedVariables', []):
            if not node['scope'] or node.get('lexicalScope') or not active(path, node): continue
            identity = owner(path, node['scope'])
            target = types.resolve(path, node.get('type', ''), node['scope'])
            kind = re.sub(r'\bany\b|\s+', '', node.get('type', '')).rstrip('?!')
            if kind.rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES: network_owners.add(identity)
            if target: dependencies.setdefault(identity, set()).add('.'.join([target[0], *target[1]]))
        for call in facts.get('invocations', []):
            if not call['scope'] or not active(path, call): continue
            expression = call.get('calledExpression', '')
            if expression.removesuffix('.init').rsplit('.', 1)[-1] in NETWORK_TRANSPORT_TYPES | {'URLRequest'} \
                    or expression.split('.', 1)[0] in NETWORK_TRANSPORT_TYPES:
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
        for function in facts.get('functionRanges', []):
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
    return [(path, function) for path, function in candidates if len(function['parameters']) == len(arguments)
        and all(kind is None or re.sub(r'\s+', '', parameter['type']).removeprefix('Swift.') == kind
            for kind, parameter in zip(arguments, function['parameters']))]
