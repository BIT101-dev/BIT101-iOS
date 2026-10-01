#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EXPECTED = {
    "MediaKit": {"DesignSystemKit", "StorageCore", "TransportCore"},
    "ScheduleSync": {"ScheduleDomain", "StorageCore"},
    "SchedulePersistence": {"ScheduleDomain", "StorageCore"},
    "ScheduleDomain": {"ScheduleContracts"},
    "SchedulePorts": {"ClientCore", "ScheduleDomain", "StorageCore"},
    "ScoreDomain": {"ClientCore", "StorageCore"},
    "ScheduleInfrastructure": {"SchedulePorts", "ClientCore", "ScheduleDomain", "TransportCore"},
    "ScheduleFeature": {"SchedulePorts", "ClientCore", "DesignSystemKit", "ScheduleDomain", "ScheduleContracts", "StorageCore", "TransportCore"},
    "ScheduleSharedStore": {"ScheduleContracts", "StorageCore"},
    "CommunityCore": {"StorageCore"},
    "CommunityPersistence": {"CommunityCore", "StorageCore"},
    "CommunityTransport": {"TransportCore"},
    "GalleryFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "TransportCore"},
    "CourseFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "TransportCore"},
    "PaperFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "TransportCore"},
    "MineFeature": {"CommunityCore", "CommunityTransport", "CommunityUI", "DesignSystemKit", "MediaKit", "TransportCore"},
    "CommunityUI": {"CommunityCore", "DesignSystemKit", "MediaKit"},
    "ClientCore": set(),
    "DesignSystemKit": set(),
    "ScheduleContracts": set(),
    "ScheduleActivityContracts": set(),
    "ScoreInfrastructure": {"ClientCore", "ScoreDomain", "StorageCore", "TransportCore"},
    "ScoreFeature": {"ScoreDomain", "ClientCore", "DesignSystemKit", "StorageCore", "TransportCore"},
    "StorageCore": set(),
    "TransportCore": set(),
    "MapFeature": {"DesignSystemKit", "ScheduleContracts", "TransportCore"},
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
    """Retain executable Swift, including interpolation, with stable positions."""
    result = ["\n" if char == "\n" else " " for char in source]
    string_start = re.compile(r'(#{0,})("""|")')

    def code(index: int, interpolation: bool = False) -> int:
        depth = 1
        while index < len(source):
            if source.startswith("//", index):
                end = source.find("\n", index)
                index = len(source) if end < 0 else end
                continue
            if source.startswith("/*", index):
                nesting = 1
                index += 2
                while index < len(source) and nesting:
                    if source.startswith("/*", index):
                        nesting += 1
                        index += 2
                    elif source.startswith("*/", index):
                        nesting -= 1
                        index += 2
                    else:
                        index += 1
                continue
            match = string_start.match(source, index)
            if match:
                hashes, quotes = match.groups()
                index += len(match[0])
                closing = quotes + hashes
                escape = "\\" + hashes
                while index < len(source):
                    if source.startswith(escape + "(", index):
                        index = code(index + len(escape) + 1, interpolation=True)
                    elif source.startswith(escape, index):
                        index += len(escape) + 1
                    elif source.startswith(closing, index):
                        index += len(closing)
                        break
                    else:
                        index += 1
                continue
            if interpolation:
                if source[index] == "(":
                    depth += 1
                elif source[index] == ")":
                    depth -= 1
                    if depth == 0:
                        return index + 1
            result[index] = source[index]
            index += 1
        return index

    code(0)
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
PLATFORM_EXCEPTIONS = {"ScheduleActivityContracts": {"ActivityKit"}, "TransportCore": {"Network"}}


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


GLOBAL_RESOURCE_PATTERN = r"\b(?:UserDefaults\s*\.\s*standard|URLSession\s*\.\s*shared|URLCache\s*\.\s*shared|HTTPCookieStorage\s*\.\s*shared|FileManager\s*\.\s*default|UIApplication\s*\.\s*shared|UIScreen\s*\.\s*main)\b"


def service_boundary_errors(path: str, source: str) -> list[str]:
    """Enforce service ownership across production modules, app, and extensions."""
    code = swift_code(source)
    patterns: list[tuple[str, str]] = []
    transport_sources = {
        "Modules/TransportCore/Sources/HTTPClient.swift",
        "Modules/TransportCore/Sources/SecureURLTransport.swift",
    }
    if path not in transport_sources:
        patterns.append((r"\b(?:URLSession|URLCache)\b", "use TransportCore transport and cache services"))
    if path != "Modules/TransportCore/Sources/HTTPClient.swift":
        patterns.append((r"\.\s*(?:data|download|upload|bytes)\s*\(\s*for\s*:", "send requests through HTTPClient"))
        patterns.append((r"\.\s*(?:dataTask|downloadTask|uploadTask|webSocketTask)\s*\(", "send requests through HTTPClient"))
    if path != "Modules/TransportCore/Sources/NetworkPathState.swift":
        patterns.append((r"\b(?:NWPathMonitor|NWConnection|NWListener)\b", "use TransportCore network services"))
    if path != "Modules/TransportCore/Sources/TaskCancellation.swift":
        patterns.append((r"\.\s*userInfo\s*\[\s*NSUnderlyingErrorKey\s*\]", "traverse underlying errors through ErrorChain"))
    if path != "Modules/TransportCore/Sources/AppURL.swift":
        patterns.append((r"\bCharacterSet\s*\.\s*urlQueryAllowed\b", "encode form fields through HTTPFormEncoding"))
    if path.startswith("Modules/ScheduleFeature/"):
        patterns.append((r"\bDateFormatter\s*\(", "format schedule dates through ScheduleDateCodec"))
    if path != "Modules/StorageCore/Sources/AppFileService.swift":
        patterns.extend((
            (r"\bFileManager\b(?!\s*\.\s*(?:SearchPathDirectory|DirectoryEnumerationOptions)\b)", "use AppFileService"),
            (r"\b(?:Data|NSData|String|NSString)\s*(?:\.\s*init\s*)?\(\s*(?:contentsOf|contentsOfFile|contentsOfURL)\s*:", "read files through AppFileService"),
            (r"\.\s*write\s*\(\s*(?:to|toFile)\s*:", "write files through AppFileService"),
            (r"\.\s*(?:resourceValues|setResourceValues|resolvingSymlinksInPath|checkResourceIsReachable)\s*\(", "access file metadata through AppFileService"),
            (r"\b(?:FileHandle|NSFileHandle|NSFileCoordinator|CGImageSourceCreateWithURL|CGImageDestinationCreateWithURL)\b", "access files through AppFileService"),
            (r"\b(?:UIImage|NSImage|InputStream|OutputStream)\s*\(\s*(?:contentsOfFile|contentsOf|url|fileAtPath|toFileAtPath)\s*:", "access files through AppFileService"),
            (r"(?<![.\w])(?:fopen|freopen|fread|fwrite|fclose|creat|unlink|mkdir|rmdir)\s*\(", "access files through AppFileService"),
        ))
    if path != "BIT101-iOS/Shared/Client/AppFileDirectories.swift":
        patterns.append((r"\bUserDefaults\s*\.\s*standard\b|\bUserDefaults\s*=\s*\.\s*standard\b", "select preferences through the host storage entry"))
    errors = []
    for pattern, rule in patterns:
        for match in re.finditer(pattern, code):
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"service boundary: {path}:{line}: {rule}: {match[0].strip()}")
    return errors


def ownership_errors(scope: str, source: str, path: str = "") -> list[str]:
    code = swift_code(source)
    patterns = []
    if scope in EXPECTED:
        patterns.append(GLOBAL_RESOURCE_PATTERN)
    if scope in {"GalleryFeature", "CommunityUI"}:
        patterns.append(r"\b(?:ComposerDraftStore|GalleryMessageReadStore)\b")
    if scope == "ScoreFeature":
        patterns.append(r"\b(?:ScoreCacheStore|ScoreFilterPreferenceStore)\b")
    if scope == "AppLocalDataService.swift":
        patterns.extend((GLOBAL_RESOURCE_PATTERN, r"\b(?:LoginStorage|ScheduleCacheStore|ScheduleWidgetExporter|AppMedia|AppSettingsStore|WKWebsiteDataStore)\b"))
    if scope in {"SettingsRootView.swift", "SettingsCommunityViews.swift", "SettingsAccountViews.swift", "SettingsServices.swift"}:
        patterns.append(r"\b(?:AppMedia|LoginStorage)\s*\.")
    return [
        f"resource ownership: {scope} uses {match[0].strip()}"
        for pattern in patterns
        for match in re.finditer(pattern, code)
        if not (path == "Modules/TransportCore/Sources/SecureURLTransport.swift"
                and re.fullmatch(r"URLCache\s*\.\s*shared", match[0]))
    ]


def self_test() -> None:
    assert imports_in_text("@testable import ScoreFeature\n@preconcurrency public import TransportCore\nimport SwiftUI") == {"ScoreFeature", "TransportCore"}
    assert graph_errors({"Leaf": set(), "First": {"Leaf"}, "Second": {"Leaf"}}) == []
    assert any("cycle" in error for error in graph_errors({"First": {"Second"}, "Second": {"First"}}))
    assert any("feature boundary" in error for error in graph_errors({"FirstFeature": {"SecondFeature"}, "SecondFeature": set()}))
    assert any("infrastructure boundary" in error for error in graph_errors({"ScoreInfrastructure": {"ScoreFeature"}, "ScoreFeature": set()}))


    assert graph_errors({"TransportCore": {"ScoreFeature"}, "ScoreFeature": set()})
    assert ownership_errors("CommunityUI", "let screen = UIApplication . shared")
    assert ownership_errors("ScoreFeature", "let store: ScoreCacheStore")
    assert ownership_errors("GalleryFeature", "let store: ComposerDraftStore")
    assert ownership_errors("CommunityUI", "let store: GalleryMessageReadStore")
    assert ownership_errors("ScoreFeature", "// ScoreCacheStore\nlet text = #\"URLSession.shared\"#") == []
    assert ownership_errors("AppLocalDataService.swift", "LoginStorage.shared.clearAllLocalData()")
    assert platform_errors("ScheduleDomain", {"UIKit"})
    assert platform_errors("ScheduleActivityContracts", {"Foundation", "ActivityKit"}) == []
    interpolation_sources = (
        r'let text = "\(UserDefaults.standard.string(forKey: "key"))"',
        r'let text = #"\#(UserDefaults.standard)"#',
        r'let text = """\(UserDefaults.standard)"""',
        r'let text = "\("nested \(UserDefaults.standard)")"',
    )
    for source in interpolation_sources:
        assert ownership_errors("GalleryFeature", source)
        assert len(swift_code(source)) == len(source)
    assert ownership_errors("GalleryFeature", r'let text = "\\(UserDefaults.standard)"') == []
    assert ownership_errors("GalleryFeature", r'let text = #"\(UserDefaults.standard)"#') == []
    assert ownership_errors("GalleryFeature", r'let text = "\(value /* UserDefaults.standard */)"') == []
    assert imports_in_text('/* import GalleryFeature\n/* import ScoreFeature */ */\nimport TransportCore') == {"TransportCore"}
    assert imports_in_text('let text = #"""\nimport GalleryFeature\n"""#\nimport struct StorageCore.AppStorageSession') == {"StorageCore"}
    service_path = "BIT101-iOS/Example.swift"
    for source in (
        "let session = URLSession(configuration: configuration)",
        "try await transport.data(for: request)",
        "session.dataTask(with: request)",
        "let manager: FileManager = .default",
        "try Data(contentsOf: url)",
        "try String.init(contentsOf: url, encoding: .utf8)",
        "try data.write(to: url)",
        "try url.resourceValues(forKeys: [.fileSizeKey])",
        "url.resolvingSymlinksInPath()",
        "let image = UIImage(contentsOfFile: path)",
        "let monitor = NWPathMonitor()",
        "let defaults: UserDefaults = .standard",
        "let underlying = error.userInfo[NSUnderlyingErrorKey]",
        "let allowed = CharacterSet.urlQueryAllowed",
        r'let text = "\(try Data(contentsOf: url))"',
    ):
        assert service_boundary_errors(service_path, source), source
    for source in (
        "// URLSession.shared\nlet text = #\"Data(contentsOf: url)\"#",
        "try files.writeData(data, to: url, options: [.atomic])",
        "try await client.send(request)",
        "defaults.data(forKey: key)",
        "let directory: FileManager.SearchPathDirectory = .cachesDirectory",
        "let options: FileManager.DirectoryEnumerationOptions = []",
    ):
        assert service_boundary_errors(service_path, source) == [], source
    assert service_boundary_errors("Modules/StorageCore/Sources/AppFileService.swift", "try data.write(to: url)") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/HTTPClient.swift", "try await transport.data(for: request)") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/SecureURLTransport.swift", "URLSession(configuration: configuration)") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/NetworkPathState.swift", "NWPathMonitor()") == []
    assert service_boundary_errors("Modules/ScheduleFeature/Sources/Example.swift", "DateFormatter()")
    assert service_boundary_errors("Modules/TransportCore/Sources/TaskCancellation.swift", "error.userInfo[NSUnderlyingErrorKey]") == []
    assert service_boundary_errors("Modules/TransportCore/Sources/AppURL.swift", "CharacterSet.urlQueryAllowed") == []
    assert ownership_errors("TransportCore", "URLCache.shared", "Modules/TransportCore/Sources/SecureURLTransport.swift") == []
    assert ownership_errors("TransportCore", "URLCache.shared", "Modules/TransportCore/Sources/HTTPClient.swift")


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
            source_text = source.read_text(encoding="utf-8")
            errors.extend(platform_errors(module, raw_imports(source_text)))
            errors.extend(ownership_errors(module, source_text, source.relative_to(root).as_posix()))
            errors.extend(service_boundary_errors(source.relative_to(root).as_posix(), source_text))
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

    for name in ("AppLocalDataService.swift", "SettingsRootView.swift", "SettingsCommunityViews.swift", "SettingsAccountViews.swift", "SettingsServices.swift"):
        for source in (root / "BIT101-iOS").rglob(name):
            errors.extend(ownership_errors(name, source.read_text(encoding="utf-8")))

    errors.extend(native_target_errors(root))

    for name in ("BIT101-iOS", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"):
        for source in (root / name).rglob("*.swift"):
            errors.extend(service_boundary_errors(source.relative_to(root).as_posix(), source.read_text(encoding="utf-8")))

    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(EXPECTED)} module source roots and direct dependencies pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
