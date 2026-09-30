#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EXPECTED = {
    "MediaKit": {"DesignSystemKit", "StorageCore", "TransportCore"},
    "ScheduleSync": {"ScheduleDomain", "SchedulePersistence", "StorageCore"},
    "SchedulePersistence": {"ScheduleDomain", "StorageCore"},
    "ScheduleDomain": {"ScheduleContracts"},
    "SchedulePorts": {"ClientCore", "ScheduleDomain", "StorageCore"},
    "ScoreDomain": {"ClientCore"},
    "ScheduleInfrastructure": {"SchedulePorts", "ClientCore", "ScheduleDomain", "TransportCore"},
    "ScheduleFeature": {"SchedulePorts", "ClientCore", "DesignSystemKit", "ScheduleDomain", "ScheduleContracts", "StorageCore", "TransportCore"},
    "ScheduleSharedStore": {"ScheduleContracts", "StorageCore"},
    "CommunityCore": set(),
    "CommunityTransport": {"TransportCore"},
    "GalleryFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "StorageCore", "TransportCore"},
    "CourseFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "TransportCore"},
    "PaperFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "TransportCore"},
    "MineFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "TransportCore"},
    "CommunityUI": {"CommunityCore", "DesignSystemKit", "MediaKit"},
    "ClientCore": set(),
    "DesignSystemKit": set(),
    "ScheduleContracts": set(),
    "ScheduleActivityContracts": set(),
    "ScoreInfrastructure": {"ClientCore", "ScoreDomain", "TransportCore"},
    "ScoreFeature": {"ScoreDomain", "ClientCore", "DesignSystemKit", "StorageCore", "TransportCore"},
    "StorageCore": set(),
    "TransportCore": set(),
    "MapFeature": {"DesignSystemKit", "ScheduleContracts"},
}

IGNORED_IMPORTS = {
    "Foundation",
    "Observation",
    "ActivityKit",
    "os",
    "Testing",
    "SwiftUI",
    "Combine",
    "Charts",
    "CryptoKit",
    "CoreFoundation",
    "CoreGraphics",
    "CoreLocation",
    "ImageIO",
    "MapKit",
    "Network",
    "OSLog",
    "PhotosUI",
    "QuickLook",
    "Security",
    "UIKit",
    "UniformTypeIdentifiers",
    "WatchConnectivity",
    "WebKit",
    "WidgetKit",
}


def manifest_dependencies(manifest: str) -> dict[str, set[str]]:
    pattern = re.compile(r'\.target\(name:\s*"(?P<name>[^"]+)"(?P<body>.*)\),')
    result: dict[str, set[str]] = {}
    for line in manifest.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        name = match.group("name")
        body = match.group("body")
        dependencies_match = re.search(r'dependencies:\s*\[([^\]]*)\]', body)
        dependencies = set(
            re.findall(r'"([A-Za-z0-9]+)"', dependencies_match.group(1))
        ) if dependencies_match else set()
        path_match = re.search(r'path:\s*"([^"]+)"', body)
        if not path_match:
            raise ValueError(f"{name} has no explicit source path")
        if name == "BIT101TestSupport" and path_match.group(1) == "ModuleTests/Support":
            continue
        expected_path = f"Modules/{name}/Sources"
        if path_match.group(1) != expected_path:
            raise ValueError(f"{name} uses {path_match.group(1)}, expected {expected_path}")
        result[name] = dependencies
    return result


def imported_modules(source_root: Path) -> dict[str, set[str]]:
    imports: dict[str, set[str]] = {}
    for source in sorted(source_root.rglob("*.swift")):
        for imported in imports_in_text(source.read_text(encoding="utf-8")):
            imports.setdefault(imported, set()).add(str(source))
    return imports


def swift_code(source: str) -> str:
    """Mask nested comments and Swift strings while retaining line positions."""
    result = list(source)
    i = 0
    while i < len(source):
        start = i
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = len(source) if end < 0 else end
        elif source.startswith("/*", i):
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
        else:
            match = re.match(r'(#{0,})(' + '\"\"\"|\"' + r')', source[i:])
            if match:
                hashes, quotes = match.groups()
                i += len(match[0])
                closing = quotes + hashes
                escape = "\\" + hashes
                while i < len(source):
                    if source.startswith(escape, i):
                        i += len(escape) + 1
                    elif source.startswith(closing, i):
                        i += len(closing)
                        break
                    else:
                        i += 1
            else:
                i += 1
                continue
        for index in range(start, min(i, len(source))):
            if source[index] != "\n":
                result[index] = " "
    return "".join(result)


def raw_imports(source: str) -> set[str]:
    pattern = r"^\s*(?:(?:@_exported|@testable|@preconcurrency)\s+)*(?:(?:public|internal|private|package)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z0-9_]+)"
    return set(re.findall(pattern, swift_code(source), re.MULTILINE))


def imports_in_text(source: str) -> set[str]:
    return raw_imports(source) - IGNORED_IMPORTS


LAYERS = {
    "Core": {"Core"},
    "Transport": {"Core", "Transport"},
    "Kit": {"Core", "Kit"},
    "UI": {"Core", "Kit", "UI"},
    "Contracts": {"Core", "Contracts"},
    "Domain": {"Core", "Contracts", "Domain"},
    "Ports": {"Core", "Contracts", "Domain", "Ports"},
    "Persistence": {"Core", "Contracts", "Domain", "Persistence"},
    "SharedStore": {"Core", "Contracts"},
    "Infrastructure": {"Core", "Transport", "Contracts", "Domain", "Ports", "Infrastructure"},
    "Sync": {"Core", "Contracts", "Domain", "Persistence", "Ports"},
    "Feature": {"Core", "Transport", "Kit", "UI", "Contracts", "Domain", "Ports"},
}


def layer(module: str) -> str | None:
    return next((name for name in LAYERS if module.endswith(name)), None)


FOUNDATIONAL_IMPORTS = {"Foundation", "Combine", "Observation", "CryptoKit", "OSLog", "os", "CoreFoundation"}
PLATFORM_EXCEPTIONS = {"ScheduleActivityContracts": {"ActivityKit"}}


def platform_errors(module: str, imports: set[str]) -> list[str]:
    if layer(module) in {"Core", "Transport", "Contracts", "Domain", "Ports", "Persistence", "SharedStore", "Infrastructure", "Sync"}:
        forbidden = (imports & IGNORED_IMPORTS) - FOUNDATIONAL_IMPORTS - PLATFORM_EXCEPTIONS.get(module, set())
        return [f"platform boundary: {module} imports {name}" for name in sorted(forbidden)]
    return []


def graph_errors(manifest: dict[str, set[str]]) -> list[str]:
    errors: list[str] = []
    visited: set[str] = set()

    def visit(module: str, path: tuple[str, ...]) -> None:
        if module in path:
            errors.append(f"dependency cycle: {' -> '.join((*path, module))}")
            return
        if module in visited:
            return
        for dependency in sorted(manifest.get(module, set())):
            visit(dependency, (*path, module))
        visited.add(module)

    for module, dependencies in manifest.items():
        visit(module, ())
        for dependency in dependencies:
            source_layer, dependency_layer = layer(module), layer(dependency)
            if dependency not in manifest:
                errors.append(f"unknown dependency: {module} -> {dependency}")
            if source_layer and dependency_layer and dependency_layer not in LAYERS[source_layer]:
                errors.append(f"{source_layer.lower()} boundary: {module} -> {dependency}")
    return errors


def self_test() -> None:
    assert imports_in_text("@testable import ScoreFeature\n@preconcurrency public import TransportCore\nimport SwiftUI") == {"ScoreFeature", "TransportCore"}
    assert graph_errors({"Leaf": set(), "First": {"Leaf"}, "Second": {"Leaf"}}) == []
    assert any("cycle" in error for error in graph_errors({"First": {"Second"}, "Second": {"First"}}))
    assert any("feature boundary" in error for error in graph_errors({"FirstFeature": {"SecondFeature"}, "SecondFeature": set()}))
    assert any("infrastructure boundary" in error for error in graph_errors({"ScoreInfrastructure": {"ScoreFeature"}, "ScoreFeature": set()}))


    assert graph_errors({"TransportCore": {"ScoreFeature"}, "ScoreFeature": set()})
    assert platform_errors("ScheduleDomain", {"UIKit"})
    assert platform_errors("ScheduleActivityContracts", {"Foundation", "ActivityKit"}) == []
    assert imports_in_text('/* import GalleryFeature\n/* import ScoreFeature */ */\nimport TransportCore') == {"TransportCore"}
    assert imports_in_text('let text = #"""\nimport GalleryFeature\n"""#\nimport struct StorageCore.AppStorageSession') == {"StorageCore"}


def native_target_errors(root: Path) -> list[str]:
    project = (root / "BIT101-iOS.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    errors: list[str] = []
    pattern = r"\t\t[A-F0-9]+ /\* ([^*]+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};"
    targets = dict(re.findall(pattern, project, re.DOTALL))
    for name in ("BIT101-iOS", "BIT101-iOSTests", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"):
        body = targets.get(name, "")
        products = re.search(r"packageProductDependencies = \((.*?)\);", body, re.DOTALL)
        declared = set(re.findall(r"/\* ([A-Za-z0-9]+) \*/", products[1])) if products else set()
        actual = imported_modules(root / name)
        if name == "BIT101Watch":
            for module in imports_in_text((root / "BIT101-iOS/WatchSync/WatchScheduleSyncManager.swift").read_text(encoding="utf-8")):
                actual.setdefault(module, set())
        for module in actual.keys() & EXPECTED.keys() - declared:
            errors.append(f"native target {name} imports undeclared product {module}")
    return errors


def main() -> int:
    self_test()
    root = Path(__file__).resolve().parents[1]
    try:
        manifest = manifest_dependencies((root / "Package.swift").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    errors: list[str] = []
    if set(manifest) != set(EXPECTED):
        errors.append(f"target set mismatch: {sorted(manifest)}")

    errors.extend(graph_errors(manifest))

    for module, expected_dependencies in EXPECTED.items():
        if manifest.get(module) != expected_dependencies:
            errors.append(
                f"{module} dependencies: expected {sorted(expected_dependencies)}, "
                f"found {sorted(manifest.get(module, set()))}"
            )
        source_root = root / "Modules" / module / "Sources"
        if not source_root.is_dir():
            errors.append(f"{module} source root missing: {source_root}")
            continue
        for source in source_root.rglob("*.swift"):
            errors.extend(platform_errors(module, raw_imports(source.read_text(encoding="utf-8"))))
        actual_imports = imported_modules(source_root)
        for dependency in expected_dependencies - actual_imports.keys():
            errors.append(f"{module} declares unused {dependency}")
        for imported, files in actual_imports.items():
            if imported not in EXPECTED:
                errors.append(f"{module} imports unknown module {imported}: {', '.join(sorted(files))}")
            if imported in EXPECTED and imported not in expected_dependencies:
                errors.append(
                    f"{module} imports undeclared {imported}: {', '.join(sorted(files))}"
                )

    test_targets = re.findall(r'\.testTarget\(name:\s*"([^\"]+)",\s*dependencies:\s*\[([^\]]*)\],\s*path:\s*"([^\"]+)"', (root / "Package.swift").read_text(encoding="utf-8"))
    for name, dependencies, path in test_targets:
        declared = set(re.findall(r'"([A-Za-z0-9]+)"', dependencies))
        actual = imported_modules(root / path).keys() & (EXPECTED.keys() | {"BIT101TestSupport"})
        if actual != declared:
            errors.append(f"test consumer {name}: declared {sorted(declared)}, imports {sorted(actual)}")
    if len(test_targets) < 2:
        errors.append("test consumers require independent source roots")

    errors.extend(native_target_errors(root))

    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(EXPECTED)} module source roots and direct dependencies pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
