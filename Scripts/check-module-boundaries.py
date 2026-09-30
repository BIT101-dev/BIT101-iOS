#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EXPECTED = {
    "MediaKit": {"DesignSystemKit", "StorageCore", "TransportCore"},
    "ScheduleDomain": {"ClientCore", "ScheduleContracts", "StorageCore"},
    "ScheduleInfrastructure": {"ClientCore", "ScheduleDomain", "TransportCore"},
    "ScheduleFeature": {"ClientCore", "DesignSystemKit", "ScheduleDomain", "ScheduleContracts", "StorageCore", "TransportCore"},
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
    "ScoreFeature": {"ClientCore", "DesignSystemKit", "StorageCore", "TransportCore"},
    "StorageCore": set(),
    "TransportCore": set(),
    "MapFeature": {"DesignSystemKit", "ScheduleContracts"},
}

IGNORED_IMPORTS = {
    "Foundation",
    "SwiftUI",
    "Combine",
    "CryptoKit",
    "CoreFoundation",
    "CoreGraphics",
    "CoreLocation",
    "ImageIO",
    "MapKit",
    "OSLog",
    "PhotosUI",
    "QuickLook",
    "Security",
    "UIKit",
    "UniformTypeIdentifiers",
    "WatchConnectivity",
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
        for line in source.read_text(encoding="utf-8").splitlines():
            match = re.match(r"\s*(?:@_exported\s+)?import\s+([A-Za-z0-9_]+)", line)
            if match and match.group(1) not in IGNORED_IMPORTS:
                imports.setdefault(match.group(1), set()).add(str(source))
    return imports


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    try:
        manifest = manifest_dependencies((root / "Package.swift").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    errors: list[str] = []
    if set(manifest) != set(EXPECTED):
        errors.append(f"target set mismatch: {sorted(manifest)}")

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
        for imported, files in imported_modules(source_root).items():
            if imported in EXPECTED and imported not in expected_dependencies:
                errors.append(
                    f"{module} imports undeclared {imported}: {', '.join(sorted(files))}"
                )

    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(EXPECTED)} module source roots and direct dependencies pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
