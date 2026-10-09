"""Resolve nominal Swift types within their module, imports and file access scope."""
import re
from pathlib import Path
from swift_source_index import canonical_type_scope


def compilation_unit(path: str) -> str:
    parts = Path(path).parts
    for directory in ('Modules', 'ModuleTests'):
        if directory in parts:
            offset = parts.index(directory)
            return parts[offset + 1] + ('Tests' if directory == 'ModuleTests' else '')
    roots = {'BIT101-iOS', 'BIT101-iOSTests', 'BIT101-iOSUITests', 'BIT101ScheduleWidgets', 'BIT101Watch', 'BIT101WatchWidgets'}
    return next((part for part in parts if part in roots), 'fixture')


class SwiftTypeIndex:
    def __init__(self, index: dict):
        self.index = index
        self.units = {path: compilation_unit(path) for path in index}
        self.module_names = set(self.units.values())
        self.imports = {path: set(facts.get('imports', [])) for path, facts in index.items()}
        self.records = {}
        self.paths = {}
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
                self.paths.setdefault(key, path)
                if node.get('isExported') and not hidden: self.exported.add(key)
                if 'type' in node: self.aliases[key] = node['type']
        self.exported_by_owner = {}
        for key in self.exported:
            self.exported_by_owner.setdefault(key[1], []).append(key)
        self._resolutions = None
        for path, facts in index.items():
            for node in facts.get('declarations', []):
                if node.get('kind') != 'extension': continue
                key = self.resolve(path, node['name'], node['scope'], aliases=False) or (self.units[path], canonical_type_scope(node['scope'] + [node['name']]))
                self.records.setdefault(key, set()).update(re.sub(r'\s+', '', base) for base in node['inheritedTypes'])
                self.paths.setdefault(key, path)
        self._bases = {}
        self._resolutions = {}

    def resolve(self, path: str, name: str, scope=(), *, aliases=True):
        key = (path, name, tuple(scope), aliases)
        if self._resolutions is None: return self._resolve(*key)
        if key not in self._resolutions: self._resolutions[key] = self._resolve(*key)
        return self._resolutions[key]

    def _resolve(self, path, name, scope, aliases):
        name = re.sub(r'\s+|\bany\b', '', name).rstrip('?!')
        parts = canonical_type_scope([name])
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
            parent = self.resolve(self.paths[key], base, key[1][:-1])
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

    def all_conformances(self):
        return {(namespace,) + owner: self.bases((namespace, owner)) for namespace, owner in self.records}

    def function_scope(self, path: str, scope):
        key = self.resolve(path, '.'.join(scope), aliases=False) if scope else None
        return (key[0],) + key[1] if key else (self.units[path],) + canonical_type_scope(scope)


class SwiftBindingTypes:
    """Share declaration, variable and factory types used by semantic call audits."""
    def __init__(self, index: dict, types: SwiftTypeIndex | None = None):
        self.index = index
        self.types = types or SwiftTypeIndex(index)
        self.type_ids = {namespace + "." + ".".join(owner): (namespace, owner) for namespace, owner in self.types.records}
        self.return_types = {(self.types.function_scope(path, function["scope"]), function["name"]): (function["returnType"], path)
            for path, facts in index.items() for function in facts.get("functionRanges", []) if function.get("returnType")}
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
                if returned and (returned_type := self.method_return(path, (returned[2],), returned[3])):
                    self.variable_types[(scope, returned[1])] = returned_type
                decoded = re.match(r"(\w+)\s*=.*?\.decode\(\s*(\w+)\.self", binding["value"])
                if decoded: self.variable_types[(scope, decoded[1])] = decoded[2]

    def variable_scope(self, path, node):
        owner = (node["ownerNamespace"],) + tuple(node["scope"]) if node.get("ownerNamespace") else self.types.function_scope(path, node["scope"])
        return owner + tuple(f"@{path}:{start}" for start in node.get("lexicalScope", []))

    def canonical_type(self, value, scope, path):
        if value in self.type_ids: return value
        owner_scope = tuple(part for part in scope[1:] if not part.startswith("@"))
        key = self.types.resolve(path, value, owner_scope)
        return key[0] + "." + ".".join(key[1]) if key else value.rsplit(".", 1)[-1].rstrip("?!")

    def method_return(self, path, owner, name):
        key = self.types.resolve(path, ".".join(owner)) if owner else None
        scope = (key[0],) + key[1] if key else self.types.function_scope(path, owner)
        result = self.return_types.get((scope, name))
        return self.canonical_type(result[0], scope, result[1]) if result else None

    def receiver_type(self, call, path=None):
        path = path or self.reference_paths.get(id(call), "")
        scope = self.variable_scope(path, call)
        if constructor := call.get("receiverCall"):
            constructor = constructor.removesuffix(".init")
            if constructor.rsplit(".", 1)[-1][:1].isupper():
                return self.canonical_type(constructor, scope, path)
            owner, _, method = constructor.rpartition(".")
            owners = [tuple(owner.split("."))] if owner else [tuple(call["scope"][:length]) for length in range(len(call["scope"]), -1, -1)]
            return next((returned for owner in owners if (returned := self.method_return(path, owner, method or constructor))), None)
        parts = call.get("calledExpression", call.get("value", "")).replace("?", "").split(".")[:-1]
        if parts and parts[0] == "self":
            parts.pop(0)
            scope = self.types.function_scope(path, call["scope"])
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
            resolved = next((self.variable_types[(owner, part)] for owner in lookup_scopes if (owner, part) in self.variable_types), None)
            if resolved is None: return None
            resolved = self.canonical_type(resolved, scope, path)
        return resolved


def receiver_resolver(index: dict):
    from swift_source_index import visible_variables
    from swift_type_index import SwiftTypeIndex, SwiftBindingTypes
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

    def resolve(path, expression, reference, seen=frozenset()):
        key = (path, expression, reference['start'])
        if key in seen: return None
        seen = seen | {key}
        nominal = types.resolve(path, expression, reference['scope'])
        if nominal: return nominal
        explicit_self = expression.startswith('self.')
        name = expression.removeprefix('self.')
        candidates = visible_variables(variables[path], reference, name, explicit_self)
        if candidates:
            variable = candidates[-1]
            if initializer := variable.get('initializerCall') or variable.get('initializerReference'):
                target = resolve(path, initializer, variable, seen)
                if target: return target
            variable_owner = types.resolve(path, '.'.join(variable['scope']), aliases=False)
            assigned = {target for factory_path, factory in factories.get((variable_owner, variable['name']), [])
                if factory.get('referenceTarget') and (target := resolve(factory_path, factory['referenceTarget'], factory, seen))}
            if len(assigned) == 1: return next(iter(assigned))
            return types.resolve(path, variable.get('type', ''), variable['scope'])
        if '.' not in expression: return None
        receiver, method = expression.rsplit('.', 1)
        owner = types.resolve(path, '.'.join(reference['scope']), aliases=False) if receiver in {'self', 'Self'} \
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
            declared = binding_types.receiver_type(call, call['path'])
            target = types.resolve(call['path'], declared or '', call['scope'])
        return '.'.join([target[0], *target[1]]) if target else None
    return owner
