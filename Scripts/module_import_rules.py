"""Inspect module ownership and dependencies."""

from __future__ import annotations
import re
from pathlib import Path
from swift_source_index import (
    swift_code,
)

ROOT = Path(__file__).resolve().parents[1]


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
    "Compression",
    "CoreFoundation",
    "CoreGraphics",
    "CoreLocation",
    "CoreTransferable",
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


def imported_modules(source_root: Path) -> dict[str, set[str]]:
    imports: dict[str, set[str]] = {}
    for source in sorted(source_root.rglob("*.swift")):
        for imported in imports_in_text(source.read_text(encoding="utf-8")):
            imports.setdefault(imported, set()).add(str(source))
    return imports


def raw_imports(source: str) -> set[str]:
    pattern = (
        "(?:^|;)\\s*(?:@\\w+(?:\\([^)]*\\))?\\s+)*(?:(?:public|internal|fileprivate|private|packag"
        "e)\\s+)?import\\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\\s+)?([A-Za-z0"
        "-9_]+)"
    )
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


FOUNDATIONAL_IMPORTS = {
    "Foundation",
    "Combine",
    "Observation",
    "CryptoKit",
    "Compression",
    "OSLog",
    "os",
    "CoreFoundation",
}


PLATFORM_EXCEPTIONS = {"ScheduleActivityContracts": {"ActivityKit"}, "TransportCore": {"Network"}}


SHARED_MODULES = {"ClientCore", "StorageCore", "TransportCore", "DesignSystemKit", "MediaKit"}


CROSS_BUSINESS_CONTRACTS = {("MapFeature", "ScheduleContracts")}


def business_family(module: str) -> str:
    name = module.removesuffix(layer(module) or "")
    if name.startswith("Schedule"):
        return "Schedule"
    return "Community" if name in {"Community", "Gallery", "Course", "Paper", "Mine"} else name


def platform_errors(module: str, imports: set[str]) -> list[str]:
    if layer(module) in {
        "Core",
        "Transport",
        "Contracts",
        "Domain",
        "Ports",
        "Persistence",
        "SharedStore",
        "Infrastructure",
        "Sync",
    }:
        forbidden = (
            (imports & IGNORED_IMPORTS)
            - FOUNDATIONAL_IMPORTS
            - PLATFORM_EXCEPTIONS.get(module, set())
        )
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
        if layer(module) is None:
            errors.append(f"{module} requires a declared architectural layer suffix")
        visit(module, ())
        if layer(module) in {"Domain", "Contracts"}:
            pending, reachable = list(dependencies), set()
            while pending:
                dependency = pending.pop()
                if dependency in reachable:
                    continue
                reachable.add(dependency)
                pending.extend(manifest.get(dependency, set()) - reachable)
            for dependency in sorted(reachable & SHARED_MODULES):
                errors.append(f"pure {layer(module).lower()} boundary: {module} -> {dependency}")
        for dependency in dependencies:
            source_layer, dependency_layer = layer(module), layer(dependency)
            if dependency not in manifest:
                errors.append(f"unknown dependency: {module} -> {dependency}")
            if source_layer and dependency_layer and dependency_layer not in LAYERS[source_layer]:
                errors.append(f"{source_layer.lower()} boundary: {module} -> {dependency}")
            if (
                source_layer
                and dependency_layer
                and dependency not in SHARED_MODULES
                and business_family(module) != business_family(dependency)
                and (module, dependency) not in CROSS_BUSINESS_CONTRACTS
            ):
                errors.append(f"business domain boundary: {module} -> {dependency}")
    return errors
