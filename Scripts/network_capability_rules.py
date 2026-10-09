"""Resolve business network API signatures and calls from compiler source facts."""
import re
from pathlib import Path
from swift_source_index import matching_functions, visible_variables

BUSINESS_NETWORK_MODULES = {'GalleryFeature', 'CourseFeature', 'PaperFeature', 'MineFeature',
    'ScheduleInfrastructure', 'ScoreInfrastructure'}
APP_NETWORK_TYPES = {'LoginService', 'AppUpdateChecker', 'EmergencyUpdateChecker', 'SettingsNetworkService'}


def method_signature(function: dict) -> str:
    return function['name'] + '(' + ','.join(parameter['label'] + ':' + re.sub(r'\s+', '', parameter['type'])
        for parameter in function.get('parameters', [])) + ')'


def signature_function(signature: str, scope: list[str]) -> dict:
    name, arguments = signature.removesuffix(')').split('(', 1)
    return {'name': name, 'scope': scope, 'parameters': [dict(label=label, type=kind, hasDefault=False, variadic=False)
        for value in arguments.split(',') if value for label, kind in [value.split(':', 1)]]}


def business_methods(index: dict) -> dict[str, list[tuple[str, dict]]]:
    from validation_evidence import active_swift_source
    result = {}
    for path, facts in index.items():
        parts = Path(path).parts
        module = parts[parts.index('Modules') + 1] if 'Modules' in parts else 'BIT101-iOS'
        active = active_swift_source(Path(path).read_text(), 'network').encode() if Path(path).is_file() else None
        for function in facts.get('functionRanges', []):
            scope = function['scope']
            if not scope or function.get('lexicalScope'): continue
            if active is not None and active[function['start']:function['start'] + 1] in {b' ', b'\n', b'\r'}: continue
            if module in BUSINESS_NETWORK_MODULES and scope[-1].endswith('Service') and function.get('isExported') \
                    or module == 'BIT101-iOS' and scope[-1] in APP_NETWORK_TYPES and function.get('isAsync') and not function.get('isPrivate'):
                result.setdefault('.'.join([module, *scope]), []).append((path, function))
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
