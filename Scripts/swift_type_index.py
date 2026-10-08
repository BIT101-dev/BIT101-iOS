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
