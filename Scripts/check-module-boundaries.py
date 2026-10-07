#!/usr/bin/env python3
"""Validate the local Swift Package source roots and direct dependency graph."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from functools import cache
from pathlib import Path


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


def manifest_targets(package: dict) -> dict[str, dict]:
    """Consume SwiftPM's evaluated manifest, including computed and conditional declarations."""
    targets = {}
    for target in package["targets"]:
        name = target["name"]
        path = target.get("path")
        if not isinstance(path, str):
            raise ValueError(f"{name} requires an explicit source path")
        dependencies = set()
        for dependency in target["dependencies"]:
            value = dependency.get("byName") or dependency.get("target")
            if not value or not isinstance(value[0], str):
                raise ValueError(f"{name} requires local target dependencies: {dependency}")
            dependencies.add(value[0])
        if name in targets:
            raise ValueError(f"duplicate target: {name}")
        targets[name] = {"path": path, "type": target["type"], "dependencies": dependencies}
    return targets


def read_manifest(root: Path) -> dict:
    environment = dict(os.environ)
    environment["CLANG_MODULE_CACHE_PATH"] = str(root / ".build/compiler-cache/ModuleCache.noindex")
    result = subprocess.run([
        "xcrun", "swift", "package", "--package-path", str(root),
        "--scratch-path", str(root / ".build/extended-automation"), "dump-package",
    ], capture_output=True, text=True, env=environment)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "SwiftPM manifest evaluation failed")
    return json.loads(result.stdout)


def imported_modules(source_root: Path) -> dict[str, set[str]]:
    imports: dict[str, set[str]] = {}
    for source in sorted(source_root.rglob("*.swift")):
        for imported in imports_in_text(source.read_text(encoding="utf-8")):
            imports.setdefault(imported, set()).add(str(source))
    return imports


@cache
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
    if path not in {"Modules/TransportCore/Sources/NetworkPathState.swift", "BIT101-iOS/Login/AppUITestBootstrap.swift"}:
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
    if layer(scope) is not None:
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
    targets = manifest_targets({"targets": [
        {"name": "NewCore", "path": "Modules/NewCore/Sources", "type": "regular", "dependencies": []},
        {"name": "NewFeature", "path": "Modules/NewFeature/Sources", "type": "regular",
         "dependencies": [{"byName": ["NewCore", None]}]},
        {"name": "ConsumerTests", "path": "ModuleTests/Consumer", "type": "test",
         "dependencies": [{"target": ["NewFeature", {"platformNames": ["macos"]}]}]},
    ]})
    assert targets["NewFeature"]["dependencies"] == {"NewCore"}
    assert targets["ConsumerTests"]["dependencies"] == {"NewFeature"}
    assert graph_errors({name: info["dependencies"] for name, info in targets.items() if info["type"] == "regular"}) == []
    for invalid in (
        {"name": "MissingCore", "type": "regular", "dependencies": []},
        {"name": "ExternalCore", "path": "Modules/ExternalCore/Sources", "type": "regular",
         "dependencies": [{"product": ["Remote", "Package", None]}]},
    ):
        try:
            manifest_targets({"targets": [invalid]})
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid manifest target accepted: {invalid}")
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


def native_target_errors(root: Path, package: dict, modules: set[str]) -> list[str]:
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
        exported = {module for product in package["products"] if product["name"] in declared for module in product["targets"]}
        for module in actual.keys() & modules - exported:
            errors.append(f"native target {name} imports undeclared product for {module}")
    return errors


def main() -> int:
    self_test()
    root = Path(__file__).resolve().parents[1]
    try:
        package = read_manifest(root)
        targets = manifest_targets(package)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    modules = {name: info for name, info in targets.items() if info["path"].startswith("Modules/")}
    support = {name: info for name, info in targets.items()
               if info["type"] == "regular" and info["path"].startswith("ModuleTests/")}
    tests = {name: info for name, info in targets.items() if info["type"] == "test"}
    errors: list[str] = []
    unknown = targets.keys() - modules.keys() - support.keys() - tests.keys()
    if unknown:
        errors.append(f"unclassified source targets: {sorted(unknown)}")
    roots = {path.name for path in (root / "Modules").iterdir() if path.is_dir()}
    if modules.keys() != roots:
        errors.append(f"module source roots differ from manifest: {sorted(modules.keys() ^ roots)}")
    graph = {name: info["dependencies"] for name, info in modules.items()}
    errors.extend(graph_errors(graph))

    for module, info in modules.items():
        source_root = root / info["path"]
        if info["type"] != "regular" or info["path"] != f"Modules/{module}/Sources":
            errors.append(f"{module} requires a regular target at Modules/{module}/Sources")
        if layer(module) is None:
            errors.append(f"{module} requires a declared architectural layer suffix")
        if not source_root.is_dir():
            errors.append(f"{module} source root missing: {source_root}")
            continue
        for path in source_root.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            errors.extend(platform_errors(module, raw_imports(text)))
            errors.extend(ownership_errors(module, text, path.relative_to(root).as_posix()))
            errors.extend(service_boundary_errors(path.relative_to(root).as_posix(), text))
        actual = imported_modules(source_root)
        for dependency in info["dependencies"] - actual.keys():
            errors.append(f"{module} declares unused {dependency}")
        for imported, files in actual.items():
            if imported not in modules:
                errors.append(f"{module} imports unknown module {imported}: {', '.join(sorted(files))}")
            elif imported not in info["dependencies"]:
                errors.append(f"{module} imports undeclared {imported}: {', '.join(sorted(files))}")

    for name, info in (support | tests).items():
        source_root = root / info["path"]
        if not source_root.is_dir() or not info["path"].startswith("ModuleTests/"):
            errors.append(f"test source root requires ModuleTests ownership: {name}")
        actual = imported_modules(source_root).keys() & (modules.keys() | support.keys())
        if actual != info["dependencies"]:
            errors.append(f"test consumer {name}: declared {sorted(info['dependencies'])}, imports {sorted(actual)}")
    if len(tests) < 2:
        errors.append("test consumers require independent source roots")

    for name in ("AppLocalDataService.swift", "SettingsRootView.swift", "SettingsCommunityViews.swift", "SettingsAccountViews.swift", "SettingsServices.swift"):
        for source in (root / "BIT101-iOS").rglob(name):
            errors.extend(ownership_errors(name, source.read_text(encoding="utf-8")))

    errors.extend(native_target_errors(root, package, set(modules)))

    for name in ("BIT101-iOS", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"):
        for source in (root / name).rglob("*.swift"):
            errors.extend(service_boundary_errors(source.relative_to(root).as_posix(), source.read_text(encoding="utf-8")))

    if errors:
        for error in errors:
            print(f"module-boundary: {error}", file=sys.stderr)
        return 1

    print(f"module-boundary: {len(modules)} module source roots and direct dependencies pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
