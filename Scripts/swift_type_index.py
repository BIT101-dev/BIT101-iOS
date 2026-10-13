"""Resolve nominal Swift types within their module, imports and file access scope."""
import re
import ast
import warnings
import math
import operator
import unicodedata
from pathlib import Path
from functools import cache


@cache
def package_target_paths() -> dict:
    from validation_inputs import read_manifest, manifest_targets
    return manifest_targets(read_manifest(Path(__file__).resolve().parents[1]))


def compilation_unit(path: str) -> str:
    parts = Path(path).parts
    for directory in ('Modules', 'ModuleTests'):
        if directory in parts:
            offset = parts.index(directory)
            if directory == 'Modules': return parts[offset + 1]
            relative = Path(*parts[offset:])
            for name, target in package_target_paths().items():
                if relative.is_relative_to(target['path']): return name
            raise ValueError(f'包级测试源码需要归属已声明的 SwiftPM target：{path}')
    from validation_inputs import NATIVE_PRODUCT_ROOTS, NATIVE_TEST_ROOTS
    roots = set(NATIVE_PRODUCT_ROOTS + NATIVE_TEST_ROOTS)
    return next((part for part in reversed(parts) if part in roots), 'fixture')


def canonical_type_scope(names: list[str]) -> tuple[str, ...]:
    return _canonical_type_scope(tuple(names))


@cache
def _canonical_type_scope(names: tuple[str, ...]) -> tuple[str, ...]:
    parts = []
    for name in names:
        nominal, depth = [], 0
        for index, character in enumerate(name):
            if character == "<": depth += 1
            elif character == ">" and (index == 0 or name[index - 1] != "-"): depth -= 1
            elif depth == 0 and not character.isspace(): nominal.append(character)
        parts.extend("".join(nominal).split("."))
    return tuple(parts)


def visible_variables(facts: dict, reference: dict, name: str, explicit_self: bool = False) -> list[dict]:
    lexical = reference.get("lexicalScope", [])
    candidates = [variable for variable in facts["typedVariables"] if variable["name"] == name
        and canonical_type_scope(reference["scope"])[:len(canonical_type_scope(variable["scope"]))] == canonical_type_scope(variable["scope"])
        and lexical[:len(variable.get("lexicalScope", []))] == variable.get("lexicalScope", [])
        and (not variable.get("visibilityRange") or variable["visibilityRange"][0] <= reference["start"] < variable["visibilityRange"][1])
        and (not variable.get("lexicalScope") or variable.get("start", 0) <= reference["start"])
        and not (explicit_self and any(function["scope"] == variable["scope"]
            and function["start"] <= variable.get("start", 0) < function["end"] for function in facts["functionRanges"]))]
    return sorted(candidates, key=lambda variable: (len(variable["scope"]), len(variable.get("lexicalScope", [])), variable.get("start", 0)))


def argument_parameter_bindings(parameters: list[dict], labels: list[str]) -> list[list[dict]]:
    """Align supplied arguments with parameters, including defaults and variadic arguments."""
    if not parameters: return [[]] if not labels else []
    parameter, remaining = parameters[0], parameters[1:]
    bindings = argument_parameter_bindings(remaining, labels) if parameter["hasDefault"] else []
    if parameter["variadic"]:
        for count in range(len(labels) + 1):
            if all(label == (parameter["label"] if index == 0 else "") for index, label in enumerate(labels[:count])):
                bindings.extend([parameter] * count + tail for tail in argument_parameter_bindings(remaining, labels[count:]))
    elif labels and labels[0] == parameter["label"]:
        bindings.extend([parameter] + tail for tail in argument_parameter_bindings(remaining, labels[1:]))
    return bindings


class SwiftTypeIndex:
    def __init__(self, index: dict):
        self.index = index
        self.units = {path: compilation_unit(path) for path in index}
        self.module_names = set(self.units.values())
        self.imports = {path: set(facts.get('imports', [])) for path, facts in index.items()}
        self.records = {}
        self.paths = {}
        self.inheritance_paths = {}
        self.exported = set()
        self.aliases = {}
        for path, facts in index.items():
            private = {canonical_type_scope(node['scope'] + [node['name']]) for node in facts.get('declarations', [])
                if node.get('isFilePrivate') and node['kind'] != 'extension'}
            for node in facts.get('declarations', []) + facts.get('typeAliases', []):
                if node.get('kind') == 'extension': continue
                owner = canonical_type_scope(node.get('scope', []) + [node['name']])
                hidden = node.get('isFilePrivate') or any(owner[:len(parent)] == parent for parent in private)
                namespace = self.units[path] + ('@' + path if hidden else '')
                key = (namespace, owner)
                bases = [node['type']] if 'type' in node else node.get('inheritedTypes', [])
                self.records.setdefault(key, set()).update(re.sub(r'\s+', '', base) for base in bases)
                for base in bases: self.inheritance_paths[key, re.sub(r'\s+', '', base)] = path
                self.paths.setdefault(key, path)
                if node.get('isExported') and not hidden: self.exported.add(key)
                if 'type' in node: self.aliases[key] = node['type']
        self.exported_by_owner = {}
        for key in self.exported:
            self.exported_by_owner.setdefault(key[1], []).append(key)
        self.nominal_records = frozenset(self.records)
        self._resolutions = None
        for path, facts in index.items():
            for node in facts.get('declarations', []):
                if node.get('kind') != 'extension': continue
                key = self.resolve(path, node['name'], node['scope'], aliases=False) or (self.units[path], canonical_type_scope(node['scope'] + [node['name']]))
                self.records.setdefault(key, set()).update(re.sub(r'\s+', '', base) for base in node['inheritedTypes'])
                for base in node['inheritedTypes']: self.inheritance_paths[key, re.sub(r'\s+', '', base)] = path
                self.paths.setdefault(key, path)
        self._bases = {}
        self._resolutions = {}
        self.enum_cases = {}
        for path, facts in index.items():
            for case in facts.get('enumCases', []):
                owner = self.terminal_name(path, '.'.join(case['scope']))
                self.enum_cases.setdefault(owner, set()).add(case['name'])

    def resolve(self, path: str, name: str, scope=(), *, aliases=True):
        key = (path, name, tuple(scope), aliases)
        if self._resolutions is None: return self._resolve(*key)
        if key not in self._resolutions: self._resolutions[key] = self._resolve(*key)
        return self._resolutions[key]

    def _resolve(self, path, name, scope, aliases):
        name = re.sub(r'\s+|\bany\b', '', name).rstrip('?!')
        parts = canonical_type_scope([name])
        if not parts: return None
        if parts[0] == 'Self': parts = canonical_type_scope([part for part in scope if isinstance(part, str)]) + parts[1:]
        if not parts: return None
        module = self.units[path]
        if parts[0] in self.module_names:
            candidates = [(parts[0], parts[1:])]
        else:
            candidates = [(namespace, tuple(scope[:depth]) + parts) for depth in range(len(scope), -1, -1)
                for namespace in (module + '@' + path, module)]
        key = next((key for key in candidates if key in self.records and
            (key[0].split('@', 1)[0] == module or key in self.exported)), None)
        if key is None:
            candidates = [key for key in self.exported_by_owner.get(parts, []) if key[0] in self.imports[path]]
            if len(candidates) == 1: key = candidates[0]
        if key is not None and aliases:
            seen = set()
            while key in self.aliases and key not in seen:
                seen.add(key)
                target = self.resolve(self.paths[key], self.aliases[key], key[1][:-1], aliases=False)
                if target is None: break
                key = target
        return key

    def bases(self, key, visiting=frozenset()):
        if key in self._bases: return self._bases[key]
        if key in visiting: return set()
        result = set(self.records[key])
        for base in self.records[key]:
            parent = self.resolve(self.inheritance_paths[key, base], base, key[1][:-1])
            if parent is not None: result.update(self.bases(parent, visiting | {key}))
        self._bases[key] = result
        return result

    def conformances(self, path: str):
        module = self.units[path]
        result = {}
        for key in self.records:
            namespace, owner = key
            if namespace in {module, module + '@' + path} and self.resolve(path, '.'.join(owner), aliases=False) == key:
                result[owner] = self.bases(key)
        imported = set(self.index[path].get('imports', []))
        candidates = {}
        for key in self.exported:
            if key[0] not in imported: continue
            result[(key[0],) + key[1]] = self.bases(key)
            candidates.setdefault(key[1], []).append(key)
        for owner, keys in candidates.items():
            if owner not in result and len(keys) == 1: result[owner] = self.bases(keys[0])
        return result

    def inheritance_distance(self, actual: str, expected: str):
        identities = {'.'.join([namespace, *owner]): (namespace, owner) for namespace, owner in self.records}
        source, target = identities.get(actual), identities.get(expected)
        if source is None or target is None: return None
        pending, seen = [(source, 0)], set()
        for key, distance in pending:
            if key == target: return distance
            if key in seen: continue
            seen.add(key)
            for base in self.records[key]:
                path = self.inheritance_paths[key, base]
                parent = self.resolve(path, base, key[1][:-1])
                if parent is not None: pending.append((parent, distance + 1))
        return None

    def all_conformances(self):
        return {(namespace,) + owner: self.bases((namespace, owner)) for namespace, owner in self.records}

    def function_scope(self, path: str, scope):
        key = self.resolve(path, '.'.join(scope), aliases=False) if scope else None
        return (key[0],) + key[1] if key else (self.units[path],) + canonical_type_scope(scope)

    def terminal_name(self, path: str, name: str, scope=(), seen=frozenset()) -> str:
        name = re.sub(r'\bany\b|\s+', '', name).rstrip('?!')
        key = self.resolve(path, name, scope, aliases=False)
        if key in self.aliases and key not in seen:
            return self.terminal_name(self.paths[key], self.aliases[key], key[1][:-1], seen | {key})
        return '.'.join([key[0], *key[1]]) if key else name

    def components(self, path, kind, scope, reference):
        pending, seen, result = [(path, kind, scope)], set(), []
        while pending:
            source_path, value, source_scope = pending.pop()
            for name in re.findall(r'\b[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*', value):
                constraints = [item for item in self.index[source_path].get('genericConstraints', [])
                    if item['name'] == name and item['start'] <= reference['start'] < item['end']]
                if constraints:
                    size = min(item['end'] - item['start'] for item in constraints)
                    for item in constraints:
                        key = (source_path, name, item['start'], item['type'])
                        if item['end'] - item['start'] == size and item['type'] and key not in seen:
                            seen.add(key)
                            pending.append((source_path, item['type'], item['scope']))
                    continue
                target = self.resolve(source_path, name, source_scope, aliases=False)
                if target in self.aliases:
                    if target not in seen:
                        seen.add(target)
                        pending.append((self.paths[target], self.aliases[target], target[1][:-1]))
                else: result.append((source_path, name, source_scope))
        return result


class SwiftBindingTypes:
    """Share declaration, variable and factory types used by semantic call audits."""
    def __init__(self, index: dict, types: SwiftTypeIndex | None = None):
        self.index = index
        self.types = types or SwiftTypeIndex(index)
        self.type_ids = {namespace + "." + ".".join(owner): (namespace, owner) for namespace, owner in self.types.records}
        self.accessors = {(self.types.function_scope(path, node['scope']), node['name'])
            for path, facts in index.items() for node in facts.get('accessorRanges', [])}
        self.return_types = {}
        for path, facts in index.items():
            for function in facts.get('functionRanges', []):
                if function.get('returnType'):
                    key = (self.types.function_scope(path, function['scope']), function['name'])
                    self.return_types.setdefault(key, []).append((function, path))
        self.reference_paths = {id(node): path for path, facts in index.items()
            for node in facts.get("calls", []) + facts.get("members", []) + facts.get("scopedIdentifiers", [])}
        self.aliases = [(path, alias, self.variable_scope(path, alias)) for path, facts in index.items()
            for alias in facts.get("typeAliases", [])]
        self.variable_types = {}
        for path, facts in index.items():
            for variable in facts.get("typedVariables", []):
                self.variable_types[(self.variable_scope(path, variable), variable["name"])] = variable["type"]
            for binding in facts.get("bindings", []):
                scope = self.variable_scope(path, binding)
                initializer = re.match(r"(\w+)\s*=\s*(?:try\??\s+)?(?:await\s+)?([A-Z]\w*)[.(]", binding["value"])
                if initializer: self.variable_types[(scope, initializer[1])] = initializer[2]
                returned = re.match(r"(\w+)\s*=\s*(?:try\??\s+)?(?:await\s+)?(\w+)\.(\w+)\(", binding["value"])
                if returned and (returned_type := self.method_return(path, (returned[2],), returned[3],
                        self.factory_invocation(path, binding, returned[2] + '.' + returned[3]))):
                    self.variable_types[(scope, returned[1])] = returned_type
                decoded = re.match(r"(\w+)\s*=.*?\.decode\(\s*(\w+)\.self", binding["value"])
                if decoded: self.variable_types[(scope, decoded[1])] = decoded[2]
        for path, facts in index.items():
            for binding in facts.get('bindings', []):
                key = (self.variable_scope(path, binding), binding.get('bindingName'))
                reference = binding.get('initializerReference')
                if reference and key[1] and key not in self.variable_types:
                    kind = self.receiver_type(dict(binding, calledExpression=reference + '.type'), path)
                    if kind: self.variable_types[key] = kind

    def variable_scope(self, path, node):
        owner = (node["ownerNamespace"],) + tuple(node["scope"]) if node.get("ownerNamespace") else self.types.function_scope(path, node["scope"])
        return owner + tuple(f"@{path}:{start}" for start in node.get("lexicalScope", []))

    def replacing_source(self, path, facts):
        return SwiftBindingTypes({**self.index, path: facts}, self.types)

    def canonical_type(self, value, scope, path):
        if value in self.type_ids: return value
        owner_scope = tuple(part for part in scope[1:] if not part.startswith("@"))
        key = self.types.resolve(path, value, owner_scope)
        return key[0] + "." + ".".join(key[1]) if key else value.rsplit(".", 1)[-1].rstrip("?!")

    def factory_invocation(self, path, reference, expression):
        end = reference['start'] + len(reference.get('value', '').encode())
        return next((call for call in self.index[path].get('invocations', [])
            if call['calledExpression'] == expression and reference['start'] <= call['start'] < end), None)

    def method_return(self, path, owner, name, invocation=None):
        key = self.types.resolve(path, ".".join(owner)) if owner else None
        scope = (key[0],) + key[1] if key else self.types.function_scope(path, owner)
        candidates = self.return_types.get((scope, name), [])
        if invocation:
            candidates = [(function, source) for function, source in candidates
                if argument_parameter_bindings(function['parameters'], invocation.get('argumentLabels', []))]
            if len(candidates) > 1:
                def argument_type(argument):
                    if re.fullmatch(r'".*"', argument, re.DOTALL): return 'String'
                    if re.fullmatch(r'[+-]?\d[\d_]*', argument): return 'Int'
                    if argument in {'true', 'false'}: return 'Bool'
                    variable_scope = self.variable_scope(path, invocation)
                    return next((self.variable_types[(owner, argument)] for length in range(len(variable_scope), 0, -1)
                        if (owner := variable_scope[:length], argument) in self.variable_types), None)
                argument_types = [argument_type(argument) for argument in invocation.get('arguments', [])]
                candidates = [(function, source) for function, source in candidates if any(
                    all(actual is None or self.canonical_type(parameter['type'].rstrip('?!'), scope, source)
                        == self.canonical_type(actual, self.variable_scope(path, invocation), path)
                        for actual, parameter in zip(argument_types, parameters))
                    for parameters in argument_parameter_bindings(function['parameters'], invocation.get('argumentLabels', [])))]
        results = {self.canonical_type(function['returnType'], scope, source) for function, source in candidates}
        if not results and key is None and invocation and self.receiver_type(invocation, path) == 'URLSession':
            return {'dataTask': 'URLSessionDataTask', 'uploadTask': 'URLSessionUploadTask',
                'downloadTask': 'URLSessionDownloadTask', 'streamTask': 'URLSessionStreamTask',
                'webSocketTask': 'URLSessionWebSocketTask', 'dataTaskPublisher': 'URLSessionDataTaskPublisher'}.get(name)
        return next(iter(results)) if len(results) == 1 else None

    def receiver_type(self, call, path=None):
        path = path or self.reference_paths.get(id(call), "")
        scope = self.variable_scope(path, call)
        if constructor := call.get("receiverCall"):
            constructor = constructor.removesuffix(".init")
            if constructor.rsplit(".", 1)[-1][:1].isupper():
                return self.canonical_type(constructor, scope, path)
            owner, _, method = constructor.rpartition(".")
            owners = [tuple(owner.split("."))] if owner else [tuple(call["scope"][:length]) for length in range(len(call["scope"]), -1, -1)]
            invocation = self.factory_invocation(path, call, call['receiverCall'])
            return next((returned for owner in owners if (returned := self.method_return(path, owner, method or constructor, invocation))), None)
        parts = call.get("calledExpression", call.get("value", "")).replace("?", "").split(".")[:-1]
        if parts and parts[0] == "self":
            parts.pop(0)
            scope = self.types.function_scope(path, call["scope"])
            if not parts:
                for length in range(len(call["scope"]), 0, -1):
                    owner = self.types.resolve(path, ".".join(call["scope"][:length]), aliases=False)
                    if owner: return ".".join((owner[0],) + owner[1])
        resolved = None
        for length in range(len(parts), 0, -1):
            if self.types.resolve(path, ".".join(parts[:length])) is not None:
                resolved = self.canonical_type(".".join(parts[:length]), scope, path)
                parts = parts[length:]
                break
        for part in parts:
            if part == "shared" and resolved: continue
            if resolved is None and part[:1].isupper():
                resolved = self.canonical_type(part, scope, path)
                continue
            identity = self.type_ids.get(resolved)
            owned_type = (identity[0],) + identity[1] if identity else None
            lookup_scopes = [scope[:length] for length in range(len(scope), 0, -1)] if resolved is None \
                else [owner for owner, field in self.variable_types if owner == owned_type and field == part]
            if resolved is None:
                facts = self.index[path]
                bindings = [dict(node, name=node['bindingName']) for node in facts.get('bindings', []) if node.get('bindingName')]
                visible = visible_variables(dict(facts, typedVariables=facts.get('typedVariables', []) + bindings),
                    call, part, call.get('calledExpression', '').startswith('self.'))
                if visible: lookup_scopes = [self.variable_scope(path, visible[-1])]
            resolved = next((self.variable_types[(owner, part)] for owner in lookup_scopes if (owner, part) in self.variable_types), None)
            if resolved is None: return None
            resolved = self.canonical_type(resolved, scope, path)
        return resolved

    def receiver_components(self, call, path=None):
        path = path or self.reference_paths.get(id(call), '')
        kind = self.receiver_type(call, path)
        if kind in self.type_ids: return {kind}
        return {self.types.terminal_name(source, name, scope) for source, name, scope
            in self.types.components(path, kind or '', call['scope'], call)}

    def is_accessor_reference(self, call, path=None):
        path = path or self.reference_paths.get(id(call), '')
        identity = self.type_ids.get(self.receiver_type(call, path))
        if identity is None: return False
        name = call.get('calledExpression', call.get('value', '')).rsplit('.', 1)[-1]
        owners = {identity} | {self.types.resolve(self.types.paths[identity], base, identity[1]) for base in self.types.bases(identity)}
        return any(((owner[0],) + owner[1], name) in self.accessors for owner in owners if owner)


def receiver_resolver(index: dict):
    types = SwiftTypeIndex(index)
    binding_types = SwiftBindingTypes(index, types)
    variables, factories = {}, {}
    for path, facts in index.items():
        bindings = [dict(binding, name=binding['bindingName'], type=binding.get('bindingType', ''))
            for binding in facts.get('bindings', []) if binding.get('bindingName')]
        variables[path] = dict(facts, typedVariables=facts.get('typedVariables', []) + bindings,
            functionRanges=facts.get('functionRanges', []))
        for function in facts.get('functionRanges', []) + facts.get('callableRanges', []):
            owner = types.resolve(path, '.'.join(function['scope']), aliases=False)
            if owner:
                factories.setdefault((owner, function['name']), []).append((path, function))

    @cache
    def candidates_for(path, scope, lexical, start, name, explicit_self):
        reference = {'scope': list(scope), 'lexicalScope': list(lexical), 'start': start}
        return visible_variables(variables[path], reference, name, explicit_self)

    def resolve(path, expression, reference, seen=frozenset()):
        key = (path, expression, reference['start'])
        if key in seen: return None
        seen = seen | {key}
        nominal = types.resolve(path, expression, reference['scope'])
        if nominal: return nominal
        explicit_self = expression.startswith('self.')
        name = expression.removeprefix('self.')
        candidates = candidates_for(path, tuple(reference['scope']), tuple(reference.get('lexicalScope', [])),
            reference['start'], name, explicit_self)
        if candidates:
            variable = candidates[-1]
            if initializer := variable.get('initializerCall') or variable.get('initializerReference'):
                position = dict(variable, start=variable['start'] - 1) if initializer == variable['name'] \
                    and variable.get('lexicalScope') else variable
                target = resolve(path, initializer, position, seen)
                if target: return target
            variable_owner = types.resolve(path, '.'.join(variable['scope']), aliases=False)
            assigned = {target for factory_path, factory in factories.get((variable_owner, variable['name']), [])
                if factory.get('referenceTarget') and (factory.get('isPropertyAssignment') and not variable.get('lexicalScope')
                    or not factory.get('isAssignment') and factory.get('lexicalScope', []) == variable.get('lexicalScope', [])
                    or factory.get('isUnqualifiedAssignment')
                        and (visible := candidates_for(factory_path, tuple(factory['scope']), tuple(factory.get('lexicalScope', [])),
                            factory['start'], variable['name'], False)) and visible[-1]['start'] == variable['start'])
                and (target := resolve(factory_path, factory['referenceTarget'], factory, seen))}
            if len(assigned) == 1: return next(iter(assigned))
            return types.resolve(path, variable.get('type', ''), variable['scope'])
        receiver, _, method = expression.rpartition('.')
        owner = types.resolve(path, '.'.join(reference['scope']), aliases=False) if receiver in {'self', 'Self', ''} \
            else resolve(path, receiver, reference, seen)
        targets = set()
        for factory_path, factory in factories.get((owner, method), []):
            target = resolve(factory_path, factory.get('returnedCall') or factory.get('referenceTarget') or '', factory, seen)
            if not target: target = types.resolve(factory_path, factory.get('returnType') or '', factory['scope'])
            if target: targets.add(target)
        return next(iter(targets)) if len(targets) == 1 else None

    def owner(call):
        expression = call.get('calledExpression', '')
        receiver = call.get('receiverCall') or (expression.rsplit('.', 1)[0] if '.' in expression else '')
        target = resolve(call['path'], receiver, call)
        if target is None:
            targets = {identity for declared in binding_types.receiver_components(call, call['path'])
                if (identity := types.resolve(call['path'], declared, call['scope']))}
            target = next(iter(targets)) if len(targets) == 1 else None
        return '.'.join([target[0], *target[1]]) if target else None
    return owner
def callable_effect_index(index: dict[str, dict]) -> dict[str, dict]:
    """函数值与闭包共享已有调用图事实；引用的效果由实际调用传播。"""
    output = {}
    for path, facts in collection_callable_index(index).items():
        aliases = facts.get('callableRanges', [])
        invocations = list(facts.get('invocations', []))
        for alias in aliases:
            target = alias.get('referenceTarget')
            if not target: continue
            labels = re.search(r'\(([^()]*)\)$', target)
            labels = labels[1].split(':')[:-1] if labels else []
            invocations.append(dict(alias, calledExpression=re.sub(r'\([^()]*\)$', '', target),
                argumentLabels=labels, arguments=['_'] * len(labels)))
        output[path] = dict(facts, callableRanges=aliases, invocations=invocations, functionRanges=facts.get('functionRanges', []) + aliases)
    return implicit_callable_index(output)


def collection_callable_index(index: dict) -> dict:
    return {path: dict(facts, callableRanges=facts.get('callableRanges', []) + collection_callable_ranges(facts))
        for path, facts in index.items()}


def collection_callable_ranges(facts: dict) -> list[dict]:
    """Connect literal closure collections to the visible for-in element binding."""
    variables = dict(facts, typedVariables=[dict(row, name=row['bindingName'])
        for row in facts.get('bindings', []) if row.get('bindingName')])
    def elements(value, reference, bounds, seen=frozenset()):
        if re.fullmatch(r'(?:self\.)?\w+', value):
            visible = visible_variables(variables, reference, value.removeprefix('self.'), value.startswith('self.'))
            if not visible or visible[-1]['start'] in seen: return []
            binding = visible[-1]
            return elements(binding.get('initializerReference') or binding.get('constantInitializer') or '', binding,
                (binding['start'], binding['start'] + len(binding['value'].encode())), seen | {binding['start']})
        if not value.startswith('[') or not value.endswith(']'): return []
        closures = [row for row in facts.get('inlineClosureRanges', []) if bounds[0] <= row['start'] < bounds[1]]
        return [row for row in closures if not any(parent['start'] < row['start'] < parent['end'] for parent in closures)]
    result = []
    existing = {(row.get('collectionBindingStart'), row['start']) for row in facts.get('callableRanges', [])}
    for binding in facts.get('bindings', []):
        if not binding.get('bindingName') or not binding.get('iterationSourceRange'): continue
        reference = dict(binding, lexicalScope=binding['lexicalScope'][:-1])
        for closure in elements(binding['iterationSource'], reference, binding['iterationSourceRange']):
            if (binding['start'], closure['start']) in existing: continue
            result.append(dict(closure, name=binding['bindingName'], scope=binding['scope'],
                lexicalScope=binding['lexicalScope'], collectionBindingStart=binding['start']))
    return result


def visible_callable_ranges(facts: dict, name: str, call: dict) -> list[dict]:
    variables = dict(facts, typedVariables=[dict(row, name=row['bindingName'])
        for row in facts.get('bindings', []) if row.get('bindingName')])
    visible = visible_variables(variables, call, name)
    return [alias for alias in facts.get('callableRanges', []) if alias['name'] == name
        and call['scope'][:len(alias['scope'])] == alias['scope']
        and call.get('lexicalScope', [])[:len(alias['lexicalScope'])] == alias['lexicalScope']
        and (not alias['lexicalScope'] or alias['start'] <= call['start'])
        and (not alias.get('collectionBindingStart') or visible and visible[-1]['start'] == alias['collectionBindingStart'])]


def implicit_callable_index(index: dict[str, dict]) -> dict[str, dict]:
    """把函数式对象的调用连接到其 callAsFunction 方法。"""
    types = SwiftTypeIndex(index)
    owners = {'.'.join(types.function_scope(path, function['scope']))
        for path, facts in index.items() for function in facts.get('functionRanges', [])
        if function['name'] == 'callAsFunction' and not function.get('lexicalScope')}
    if not owners: return index
    resolve, result = receiver_resolver(index), {}
    for path, facts in index.items():
        calls = []
        for call in facts.get('invocations', []):
            expression = call['calledExpression']
            named = any(function['name'] == expression
                and call['scope'][:len(function['scope'])] == function['scope']
                and call.get('lexicalScope', [])[:len(function.get('lexicalScope', []))] == function.get('lexicalScope', [])
                and argument_parameter_bindings(function.get('parameters', []), call.get('argumentLabels', []))
                for function in facts.get('functionRanges', [])) if '.' not in expression else False
            candidate = dict(call, path=path, calledExpression=expression + '.callAsFunction')
            if not named and not expression.endswith(('.callAsFunction', '.init')) \
                    and types.resolve(path, expression, call['scope']) is None and resolve(candidate) in owners:
                call = dict(call, calledExpression=candidate['calledExpression'])
            calls.append(call)
        result[path] = dict(facts, invocations=calls)
    return result


def custom_constant_symbols(facts: dict) -> bool:
    return _custom_constant_symbols(facts.get('source', ''),
        tuple(function.get('name') for function in facts.get('functionRanges', [])),
        tuple(node['name'] for node in facts.get('declarations', []) + facts.get('typeAliases', [])))


@cache
def _custom_constant_symbols(source: str, functions: tuple, declarations: tuple) -> bool:
    scalar = r'(?:Bool|String|Character|Float|Double|U?Int(?:8|16|32|64)?|Array|ArraySlice|\w*LiteralType)'
    operators = {'==', '!=', '<', '>', '<=', '>=', '+', '-', '*', '/', '%', '!', '&&', '||', '~=', '...', '..<',
        'prefix', 'suffix', 'dropFirst', 'dropLast'}
    if any(name in operators for name in functions): return True
    if any(re.fullmatch(scalar, name) for name in declarations): return True
    return any(re.fullmatch(scalar, parameter.split(':', 1)[0].strip())
        for match in re.finditer(r'\b(?:func|struct|class|enum|typealias)\s+\w+\s*<([^>{}]*)', source)
        for parameter in match[1].split(','))


def execution_index(index: dict) -> dict:
    """Keep custom scalar and operator paths reachable across module imports."""
    index = collection_callable_index(index)
    units = {path: compilation_unit(path) for path in index}
    imports = {}
    for path, facts in index.items(): imports.setdefault(units[path], set()).update(facts.get('imports', []))
    custom = {units[path] for path, facts in index.items() if custom_constant_symbols(facts)}
    while imported := {unit for unit, dependencies in imports.items() if unit not in custom and dependencies & custom}:
        custom.update(imported)
    return implicit_callable_index({path: dict(facts, constantFoldingAllowed=units[path] not in custom) for path, facts in index.items()})


def constant_folding_allowed(facts: dict) -> bool:
    if 'constantFoldingAllowed' in facts: return facts['constantFoldingAllowed']
    return not custom_constant_symbols(facts)


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


def constant_value(condition: str, resolve, *, floating=False):
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
    def value(node, floating=False):
        if isinstance(node, ast.Constant):
            if type(node.value) is bool: return node.value
            if type(node.value) is int:
                if floating:
                    try: return float(node.value)
                    except OverflowError: return None
                return node.value
            if type(node.value) is float: return node.value if math.isfinite(node.value) else None
            if type(node.value) is str: return node.value
        if isinstance(node, ast.Name): return resolve(node.id)
        if isinstance(node, ast.UnaryOp):
            operand = value(node.operand, floating)
            if isinstance(node.op, ast.Not): return not operand if type(operand) is bool else None
            if type(operand) in {int, float}:
                if isinstance(node.op, ast.USub): return -operand
                if isinstance(node.op, ast.UAdd): return operand
        if isinstance(node, ast.BinOp):
            left, right = value(node.left, floating), value(node.right, floating)
            if isinstance(node.op, ast.Add) and type(left) is str and type(right) is str:
                return unicodedata.normalize('NFC', left + right)
            if type(left) is float or type(right) is float:
                left, right = value(node.left, True), value(node.right, True)
            if type(left) not in {int, float} or type(right) not in {int, float}: return None
            if type(left) is int and type(right) is int and not all(-(1 << 63) <= item < (1 << 63) for item in (left, right)): return None
            operation = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
                ast.Div: operator.truediv}.get(type(node.op))
            try:
                if type(left) is int and type(right) is int and isinstance(node.op, (ast.Div, ast.Mod)):
                    if right == 0 or left == -(1 << 63) and right == -1: return None
                    quotient = abs(left) // abs(right) * (-1 if (left < 0) != (right < 0) else 1)
                    result = quotient if isinstance(node.op, ast.Div) else left - quotient * right
                elif operation: result = operation(left, right)
                else: return None
            except (OverflowError, ZeroDivisionError): return None
            return result if (math.isfinite(result) if type(result) is float else -(1 << 63) <= result < (1 << 63)) else None
        if isinstance(node, ast.BoolOp):
            values = [value(operand) for operand in node.values]
            if isinstance(node.op, ast.And): return False if any(item is False for item in values) else True if all(item is True for item in values) else None
            if isinstance(node.op, ast.Or): return True if any(item is True for item in values) else False if all(item is False for item in values) else None
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            left, right = value(node.left), value(node.comparators[0])
            if type(left) is float or type(right) is float:
                left, right = value(node.left, True), value(node.comparators[0], True)
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
    return value(node, floating)


def constant_boolean(condition: str, resolve) -> bool | None:
    result = constant_value(condition, resolve)
    return result if type(result) is bool else None


def branch_value(facts: dict, branch: dict, expression: str):
    literal = expression.strip(' \t\r\n()')
    if literal in {'true', 'false'}: return literal == 'true'
    if not constant_folding_allowed(facts): return None
    bound_scope = facts.get('smokeScope')
    scope_bindings = facts.get('smokeScopeBindings', {})
    smoke_context = bound_scope is not None or 'smokeScopeBindings' in facts
    def enum_literals(value):
        return re.sub(r'(?<![\w.])(?:NetworkSmokeScope)?\.(all|communityWrites|communityCleanup)\b',
            lambda match: '"' + match[1] + '"', value) if smoke_context else value
    expression = enum_literals(expression)
    def parameter_value(name, location, node=None):
        functions = [function for function in facts.get('functionRanges', [])
            if function['start'] <= location['start'] < function['end']
            and (node is None or function['start'] <= node['start'] < function.get('bodyStart', function['start']))
            and any(parameter.get('name') == name
                for parameter in function.get('parameters', []))]
        if not functions: return None
        function = min(functions, key=lambda item: item['end'] - item['start'])
        root_scope = bound_scope if function.get('scope') == ['ReleaseNetworkSmokeRunner'] \
            and function['name'] == 'run' and name == 'scope' else None
        return scope_bindings.get((function['start'], name), root_scope)
    resolving = set()
    def resolve(name, location=branch):
        lexical = location.get('lexicalScope', [])
        bindings = [node for node in facts.get('bindings', []) if node.get('bindingName') == name
            and node.get('scope') == location.get('scope') and node['start'] <= location['start']
            and (not node.get('visibilityRange') or node['visibilityRange'][0] <= location['start'] < node['visibilityRange'][1])
            and lexical[:len(node.get('lexicalScope', []))] == node.get('lexicalScope', [])]
        variables = visible_variables({**facts, 'typedVariables': facts.get('typedVariables', []),
            'functionRanges': facts.get('functionRanges', [])}, location, name)
        if smoke_context and not bindings and not variables: return parameter_value(name, location)
        if candidates := bindings + variables:
            node = max(candidates, key=lambda item: (len(item.get('scope', [])), len(item.get('lexicalScope', [])), item['start']))
            initializer = node.get('constantInitializer')
            annotation = node.get('bindingType')
            if smoke_context and not initializer:
                return parameter_value(name, location, node)
            if not initializer or node['start'] in resolving or annotation and not re.fullmatch(
                    r'(?:Swift\.)?(?:Bool|String|U?Int(?:8|16|32|64)?|Double)' +
                    (r'|NetworkSmokeScope' if smoke_context else ''), annotation): return None
            resolving.add(node['start'])
            try:
                result = constant_value(enum_literals(initializer), lambda referenced: resolve(referenced, node),
                    floating=annotation in {'Double', 'Swift.Double'})
                if annotation in {'Double', 'Swift.Double'} and type(result) is int:
                    try: return float(result)
                    except OverflowError: return None
                return result
            finally: resolving.remove(node['start'])
        return None
    return constant_value(expression, resolve)


def branch_condition(facts: dict, branch: dict) -> bool | None:
    values = [branch_value(facts, branch, condition) for condition in
        branch.get('conditionElements') or [branch.get('condition') or '']]
    return False if any(value is False for value in values) else True if all(value is True for value in values) else None


def switch_entries(facts: dict, branch: dict) -> set[int]:
    """Select possible entry cases from constant subjects, patterns and guards."""
    cases = branch.get('switchCases')
    if cases is None: return set(range(len(branch.get('branchRanges', []))))
    subject = branch_value(facts, branch, branch.get('switchSubject') or '')
    entries = set()
    for index, case in enumerate(cases):
        matches = [True] if case['isDefault'] else []
        for pattern in case['patterns']:
            value = branch_value(facts, branch, pattern['value'])
            if pattern['value'] == '_': match = True
            elif value is None:
                guard = branch_value(facts, branch, pattern.get('condition') or 'true')
                matches.append(False if guard is False else None)
                continue
            elif subject is None: match = None
            else:
                numeric = type(subject) in {int, float} and type(value) in {int, float}
                if numeric and (type(subject) is float or type(value) is float):
                    try: match = float(subject) == float(value)
                    except OverflowError: match = None
                else: match = subject == value if numeric or type(subject) is type(value) else None
            guard = branch_value(facts, branch, pattern['condition']) if pattern.get('condition') else True
            matches.append(False if match is False or guard is False else True if match is True and guard is True else None)
        if any(match is not False for match in matches): entries.add(index)
        if any(match is True for match in matches): break
    return entries


def block_outcomes(facts: dict, branch: dict, conditions: dict, bounds, *, nested=True) -> set[str]:
    normal = {'normal'}
    if not bounds: return normal
    rows = facts.get('controlFlow', [])
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
            jump = row['value'].split(maxsplit=1)
            following = {'labeled-jump' if len(jump) > 1 and jump[0] in {'break', 'continue'} else jump[0]}
        elif row.get('thenRange') or row.get('elseRange') or row.get('branchRanges'):
            following = control_flow_outcomes(facts, row, conditions)
            spans = [row[key] for key in ('thenRange', 'elseRange') if row.get(key)] + row.get('branchRanges', [])
            covered_until = max([span[1] for span in spans] + [row.get('followingRange', [row['start']])[0]])
        else: continue
        outcomes = outcomes - normal | following
    return outcomes


def control_flow_outcomes(facts: dict, branch: dict, conditions: dict) -> set[str]:
    """Track normal continuation and explicit exits through compiler block facts."""
    normal = {'normal'}
    def outcomes(bounds, *, nested=True): return block_outcomes(facts, branch, conditions, bounds, nested=nested)
    identity = branch['start']
    if identity not in conditions: conditions[identity] = branch_condition(facts, branch)
    value = conditions[identity]
    kind = branch['value'].split()[0]
    if kind == 'switch':
        result, following = set(), normal
        entries = switch_entries(facts, branch)
        for index, bounds in reversed(list(enumerate(branch.get('branchRanges', [])))):
            outcome = outcomes(bounds, nested=False)
            following = outcome - {'fallthrough'} | (following if 'fallthrough' in outcome else set())
            if index in entries: result |= following
        return result - {'break'} | (normal if 'break' in result or not entries else set())
    if kind == 'guard':
        return normal if value is True else outcomes(branch.get('elseRange')) | (normal if value is None else set())
    body = outcomes(branch.get('thenRange'))
    if kind == 'do':
        alternatives = set().union(*(outcomes(bounds) for bounds in branch.get('branchRanges', [])))
        return body | alternatives
    if kind in {'while', 'repeat'}:
        if kind == 'while' and value is False: return normal
        exits = 'break' in body or value is not True and bool({'normal', 'continue'} & body)
        return body - {'normal', 'break', 'continue'} | (normal if exits or kind == 'while' and value is None else set())
    alternative = outcomes(branch.get('elseRange'))
    return body if value is True else alternative if value is False else body | alternative


def collection_count(facts: dict, location: dict, source=None, seen=frozenset()):
    if location.get('collectionElementCount') is not None: return location['collectionElementCount']
    name = (source if source is not None else location.get('iterationSource') or '').strip(' \t\r\n()')
    if not re.fullmatch(r'[A-Za-z_]\w*', name): return None
    lexical = location.get('lexicalScope', [])
    candidates = [node for node in facts.get('bindings', []) if node.get('bindingName') == name
        and node.get('scope') == location.get('scope') and node['start'] < location['start']
        and (not node.get('visibilityRange') or node['visibilityRange'][0] <= location['start'] < node['visibilityRange'][1])
        and lexical[:len(node.get('lexicalScope', []))] == node.get('lexicalScope', [])]
    candidates += visible_variables(facts, location, name)
    if not candidates: return None
    node = max(candidates, key=lambda item: (len(item.get('lexicalScope', [])), item['start']))
    annotation = re.sub(r'\s+', '', node.get('bindingType') or '')
    if not node.get('constantInitializer') or node['start'] in seen or annotation and not (
            annotation.startswith('[') or re.match(r'(?:Swift\.)?(?:Array|ArraySlice)<', annotation)): return None
    return collection_count(facts, node, node['constantInitializer'], seen | {node['start']})


def call_can_execute(facts: dict, call: dict) -> bool:
    conditions = {}
    folding = constant_folding_allowed(facts)
    for branch in facts.get('expressionFlow', []):
        if not any(bounds and bounds[0] <= call['start'] < bounds[1]
                for bounds in (branch.get('thenRange'), branch.get('elseRange'))): continue
        value = branch_condition(facts, branch)
        excluded = branch.get('elseRange') if value is True else branch.get('thenRange') if value is False else None
        if excluded and excluded[0] <= call['start'] < excluded[1]: return False
    def hoisted(bounds, branch):
        return any(function['start'] >= bounds[0] and function['start'] <= call['start'] < function['end']
            and function.get('lexicalScope', []) == branch.get('lexicalScope', [])
            for function in facts.get('functionRanges', []))
    for branch in facts.get('controlFlow', []):
        dead = branch.get('deadRange')
        if dead and dead[0] <= call['start'] < dead[1]:
            if not hoisted(dead, branch): return False
        body = branch.get('thenRange')
        if body and body[0] <= call['start'] < body[1]:
            sequence = re.sub(r'[\s()]', '', branch.get('iterationSource') or '')
            bounds = branch.get('iterationBounds')
            if not bounds:
                literal = re.fullmatch(r'([+-]?\d[\d_]*)(\.\.<|\.\.\.)([+-]?\d[\d_]*)', sequence)
                bounds = list(literal.groups()) if literal else None
            empty = folding and (sequence == '[]' or collection_count(facts, branch) == 0)
            if bounds and folding:
                lower, upper = (branch_value(facts, branch, bounds[position]) for position in (0, 2))
                if type(lower) is int and type(upper) is int: empty = lower >= upper if bounds[1] == '..<' else lower > upper
            if empty: return False
        if branch.get('switchSubject') is not None and any(
                bounds[0] <= call['start'] < bounds[1] for bounds in branch.get('branchRanges', [])):
            reachable = switch_entries(facts, branch)
            for index, bounds in enumerate(branch.get('branchRanges', [])):
                if index in reachable and 'fallthrough' in block_outcomes(facts, branch, conditions, bounds, nested=False):
                    reachable.add(index + 1)
                if bounds[0] <= call['start'] < bounds[1] and index not in reachable: return False
        if not any(bounds and bounds[0] <= call['start'] < bounds[1]
                for bounds in (body, branch.get('elseRange'), branch.get('followingRange'))): continue
        if branch['start'] not in conditions: conditions[branch['start']] = branch_condition(facts, branch)
        value = conditions[branch['start']]
        excluded = branch.get('elseRange') if value is True else branch.get('thenRange') if value is False and not branch['value'].startswith('repeat') else None
        if excluded and excluded[0] <= call['start'] < excluded[1]: return False
        following = branch.get('followingRange')
        if following and following[0] <= call['start'] < following[1] and not hoisted(following, branch) \
                and not {'normal', 'labeled-jump'} & control_flow_outcomes(facts, branch, conditions): return False
    return True
