#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EXPECTED = {
    "MediaKit": {"DesignSystemKit", "StorageCore", "TransportCore"},
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


def imports_in_text(source: str) -> set[str]:
    pattern = r"^\s*(?:(?:@_exported|@testable|@preconcurrency)\s+)*(?:(?:public|internal|private|package)\s+)?import\s+([A-Za-z0-9_]+)"
    return set(re.findall(pattern, source, re.MULTILINE)) - IGNORED_IMPORTS


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
            if module.endswith("Feature") and dependency.endswith(("Feature", "Infrastructure", "Persistence")):
                errors.append(f"feature boundary: {module} -> {dependency}")
            if module.endswith(("Infrastructure", "Persistence", "Domain", "Ports")) and dependency.endswith(("Feature", "UI", "Kit")):
                errors.append(f"implementation boundary: {module} -> {dependency}")
    return errors


def self_test() -> None:
    assert imports_in_text("@testable import ScoreFeature\n@preconcurrency public import TransportCore\nimport SwiftUI") == {"ScoreFeature", "TransportCore"}
    assert graph_errors({"Leaf": set(), "First": {"Leaf"}, "Second": {"Leaf"}}) == []
    assert any("cycle" in error for error in graph_errors({"First": {"Second"}, "Second": {"First"}}))
    assert any("feature boundary" in error for error in graph_errors({"FirstFeature": {"SecondFeature"}, "SecondFeature": set()}))
    assert any("implementation boundary" in error for error in graph_errors({"ScoreInfrastructure": {"ScoreFeature"}, "ScoreFeature": set()}))


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

    test_target = re.search(r'\.testTarget\(name:\s*"BIT101ModulesTests",\s*dependencies:\s*\[([^\]]*)\]', (root / "Package.swift").read_text(encoding="utf-8"))
    test_dependencies = set(re.findall(r'"([A-Za-z0-9]+)"', test_target[1])) if test_target else set()
    for imported in imported_modules(root / "ModuleTests"):
        if imported in EXPECTED and imported not in test_dependencies:
            errors.append(f"module tests import undeclared {imported}")

    errors.extend(native_target_errors(root))

    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(EXPECTED)} module source roots and direct dependencies pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
