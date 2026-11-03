"""Exercise module ownership checks."""


def module_types_self_test(rules: dict) -> None:
    adapter_ownership_errors = rules["adapter_ownership_errors"]
    adapter_roles = rules["adapter_roles"]
    graph_errors = rules["graph_errors"]
    imports_in_text = rules["imports_in_text"]
    manifest_targets = rules["manifest_targets"]
    ownership_errors = rules["ownership_errors"]
    platform_errors = rules["platform_errors"]
    raw_imports = rules["raw_imports"]
    service_boundary_errors = rules["service_boundary_errors"]
    swift_code = rules["swift_code"]
    swift_syntax_index_sources = rules["swift_syntax_index_sources"]
    targets = manifest_targets(
        {
            "targets": [
                {
                    "name": "NewCore",
                    "path": "Modules/NewCore/Sources",
                    "type": "regular",
                    "dependencies": [],
                },
                {
                    "name": "NewFeature",
                    "path": "Modules/NewFeature/Sources",
                    "type": "regular",
                    "dependencies": [{"byName": ["NewCore", None]}],
                },
                {
                    "name": "ConsumerTests",
                    "path": "ModuleTests/Consumer",
                    "type": "test",
                    "dependencies": [{"target": ["NewFeature", {"platformNames": ["macos"]}]}],
                },
            ]
        }
    )
    assert targets["NewFeature"]["dependencies"] == {"NewCore"}
    assert targets["ConsumerTests"]["dependencies"] == {"NewFeature"}
    assert (
        graph_errors(
            {
                name: info["dependencies"]
                for name, info in targets.items()
                if info["type"] == "regular"
            }
        )
        == []
    )
    for invalid in (
        {"name": "MissingCore", "type": "regular", "dependencies": []},
        {
            "name": "ExcludedCore",
            "path": "Modules/ExcludedCore/Sources",
            "type": "regular",
            "dependencies": [],
            "exclude": ["Implementation.swift"],
        },
        {
            "name": "SelectedCore",
            "path": "Modules/SelectedCore/Sources",
            "type": "regular",
            "dependencies": [],
            "sources": ["Unused.swift"],
        },
        {
            "name": "EmptyCore",
            "path": "Modules/EmptyCore/Sources",
            "type": "regular",
            "dependencies": [],
            "sources": [],
        },
        {
            "name": "ExternalCore",
            "path": "Modules/ExternalCore/Sources",
            "type": "regular",
            "dependencies": [{"product": ["Remote", "Package", None]}],
        },
    ):
        try:
            manifest_targets({"targets": [invalid]})
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid manifest target accepted: {invalid}")
    assert imports_in_text(
        "@testable import ScoreFeature\n@preconcurrency public import TransportCore\nimport SwiftUI"
    ) == {"ScoreFeature", "TransportCore"}
    assert raw_imports("@_implementationOnly import UIKit\n@_spi(Internal) import StorageCore") == {
        "UIKit",
        "StorageCore",
    }
    for access in ("public", "internal", "fileprivate", "private", "package"):
        assert raw_imports(f"{access} import UIKit") == {"UIKit"}
        assert platform_errors(
            "ScheduleDomain", raw_imports(f"@preconcurrency {access} import struct UIKit.UIColor")
        )
    assert raw_imports("@_spi(Internal)\n@preconcurrency public import class Foundation.Date") == {
        "Foundation"
    }
    assert raw_imports("import Foundation; import UIKit; @_spi(Internal) import StorageCore") == {
        "Foundation",
        "UIKit",
        "StorageCore",
    }
    assert platform_errors(
        "ScheduleDomain", raw_imports("#if os(iOS)\nimport Foundation; import UIKit\n#endif")
    )
    assert platform_errors("ScheduleDomain", raw_imports("import `UIKit`"))
    for source in (
        "Foundation.UserDefaults.`standard`",
        "`UserDefaults`.standard",
        "let prefs: `UserDefaults` = .`standard`",
    ):
        assert ownership_errors("GalleryFeature", source) and service_boundary_errors(
            "BIT101-iOS/Example.swift", source
        )
    assert (
        graph_errors(
            {
                "ScheduleLeafCore": set(),
                "ScheduleFirstCore": {"ScheduleLeafCore"},
                "ScheduleSecondCore": {"ScheduleLeafCore"},
            }
        )
        == []
    )
    assert graph_errors(
        {
            "ScheduleDomain": {"ScheduleHelpers"},
            "ScheduleHelpers": {"ScoreFeature"},
            "ScoreFeature": set(),
        }
    ) == ["ScheduleHelpers requires a declared architectural layer suffix"]
    assert any(
        "cycle" in error for error in graph_errors({"First": {"Second"}, "Second": {"First"}})
    )
    assert any(
        "feature boundary" in error
        for error in graph_errors({"FirstFeature": {"SecondFeature"}, "SecondFeature": set()})
    )
    assert any(
        "infrastructure boundary" in error
        for error in graph_errors({"ScoreInfrastructure": {"ScoreFeature"}, "ScoreFeature": set()})
    )

    assert graph_errors({"TransportCore": {"ScoreFeature"}, "ScoreFeature": set()})
    assert ownership_errors("CommunityUI", "let screen = UIApplication . shared")
    assert ownership_errors("ScoreFeature", "let store: ScoreCacheStore")
    assert ownership_errors("GalleryFeature", "let store: ComposerDraftStore")
    for factory in (
        "URLSessionTransport.make(configuration: .ephemeral)",
        "URLSessionTransport.self.make(configuration: .ephemeral)",
        "typealias Factory = URLSessionTransport; Factory.make(configuration: .ephemeral)",
    ):
        assert ownership_errors("GalleryFeature", factory)
        assert service_boundary_errors(
            "Modules/GalleryFeature/Sources/GalleryService.swift", factory
        )
    assert ownership_errors("CommunityUI", "let store: GalleryMessageReadStore")
    assert (
        ownership_errors("ScoreFeature", '// ScoreCacheStore\nlet text = #"URLSession.shared"#')
        == []
    )
    assert ownership_errors("AppLocalDataService", "LoginStorage.shared.clearAllLocalData()")
    assert ownership_errors(
        "AppScheduleCacheEffects", "ScheduleCloudSyncManager.shared.pushLatestCache()"
    )
    renamed = swift_syntax_index_sources(
        {
            "renamed.swift": (
                "struct RenamedEffects: SchedulePlatformActions { func enable() { ScheduleCloudSyn"
                "cManager.shared.push() } }; struct RenamedCleanup { func resetAllLocalData() { Lo"
                "ginStorage.shared.clear() } }"
            )
        }
    )
    assert len(adapter_ownership_errors(renamed["renamed.swift"])) >= 2
    split = swift_syntax_index_sources(
        {
            "Types.swift": (
                "enum Namespace { struct RenamedEffects: SchedulePlatformActions {}; struct Compos"
                "ition {} }"
            ),
            "Effects.swift": (
                "extension Namespace.RenamedEffects { func enable() { ScheduleCloudSyncManager.sha"
                "red.push() } }"
            ),
            "Composition.swift": (
                "extension Namespace.Composition { func enable() { ScheduleCloudSyncManager.shared"
                ".push() } }"
            ),
        }
    )
    roles = adapter_roles(split)
    assert adapter_ownership_errors(split["Effects.swift"], roles=roles)
    assert adapter_ownership_errors(split["Composition.swift"], roles=roles) == []
    for body, expected in (
        ("loadAccountStorage()", True),
        ("let load = loadAccountStorage; load()", True),
        ("if false { loadAccountStorage() }", False),
        ("loadAccountStorage(1)", False),
    ):
        sources = {
            "BIT101-iOS/Effects.swift": "struct AppScheduleCacheEffects { func changed() { "
            + body
            + " } }",
            "BIT101-iOS/Helpers.swift": (
                "func loadAccountStorage() { indirect() }; func indirect() { AppAccountSession.sto"
                "rage }; func loadAccountStorage(_ value: Int) {}"
            ),
        }
        index = swift_syntax_index_sources(sources)
        call_roles = rules["adapter_call_roles"](index)
        errors = [
            error
            for path, facts in index.items()
            for error in adapter_ownership_errors(
                facts, path, adapter_roles(index, path), call_roles=call_roles
            )
        ]
        assert bool(errors) == expected, (body, errors)
        if expected:
            assert len(errors) == 1 and errors[0].startswith("BIT101-iOS/Helpers.swift:1:"), errors
    direct = swift_syntax_index_sources(
        {
            "Effects.swift": (
                "struct AppScheduleCacheEffects { func changed() { AppAccountSession.storage } }"
            )
        }
    )
    assert len(adapter_ownership_errors(direct["Effects.swift"], "Effects.swift")) == 1
    renamed_settings = swift_syntax_index_sources(
        {"settings.swift": "struct RenamedScreen: View { var body: some View { AppMedia.shared } }"}
    )
    assert adapter_ownership_errors(
        renamed_settings["settings.swift"], "BIT101-iOS/Settings/Renamed.swift"
    )
    assert platform_errors("ScheduleDomain", {"UIKit"})
    assert platform_errors("ScheduleDomain", {"Foundation", "Compression"}) == []
    assert platform_errors("ScheduleActivityContracts", {"Foundation", "ActivityKit"}) == []
    interpolation_sources = (
        r'let text = "\(UserDefaults.standard.string(forKey: "key"))"',
        r'let text = #"\#(UserDefaults.standard)"#',
        'let text = """\n\\(UserDefaults.standard)\n"""',
        r'let text = "\("nested \(UserDefaults.standard)")"',
    )
    for source in interpolation_sources:
        assert ownership_errors("GalleryFeature", source)
        assert len(swift_code(source)) == len(source)
    assert ownership_errors("GalleryFeature", r'let text = "\\(UserDefaults.standard)"') == []
    assert ownership_errors("GalleryFeature", r'let text = #"\(UserDefaults.standard)"#') == []
    assert (
        ownership_errors("GalleryFeature", r'let text = "\(value /* UserDefaults.standard */)"')
        == []
    )
    assert imports_in_text(
        "/* import GalleryFeature\n/* import ScoreFeature */ */\nimport TransportCore"
    ) == {"TransportCore"}
    assert imports_in_text(
        'let text = #"""\nimport GalleryFeature\n"""#\nimport struct StorageCore.AppStorageSession'
    ) == {"StorageCore"}
    service_path = "BIT101-iOS/Example.swift"
    for source in (
        "let files = AppFileSystem.files",
        "let files = LocalAppFileService()",
        'let preferences = UserDefaults(suiteName: "global")',
    ):
        assert ownership_errors("GalleryFeature", source)
    for source in (
        "LocalAppFileService.init()",
        "let files: LocalAppFileService = .init()",
        "let prefs: Swift.Optional<UserDefaults> = .standard",
        "let prefs: Swift.Array<UserDefaults> = [.standard]",
        'let prefs: Swift.Dictionary<String, UserDefaults> = ["prefs": .standard]',
    ):
        assert ownership_errors("ScheduleFeature", source) and service_boundary_errors(
            "Modules/ScheduleFeature/Sources/Example.swift", source
        ), source
    assert ownership_errors(
        "GalleryFeature", "URLSessionTransport.clearSharedCache()"
    ) and service_boundary_errors(
        "Modules/GalleryFeature/Sources/Example.swift", "URLSessionTransport.clearSharedCache()"
    )
    for source in (
        "let regex = /FileManager.default/",
        "let regex = #/UserDefaults.standard [a/b]/#",
        "let regex = flag ? /URLSession.shared/ : /safe/",
        "if /URLSession/.wholeMatch(in: input) != nil { consume() }",
        "while /UserDefaults.standard/.wholeMatch(in: input) != nil { break }",
        "guard /FileManager.default/.wholeMatch(in: input) != nil else { return }",
        'let 中文 = "文字"; if /URLSession/.wholeMatch(in: 中文) != nil { consume() }',
        "let regex = /a\\/\\/URLSession/; consume(regex)",
    ):
        assert ownership_errors("GalleryFeature", source) == []
        assert service_boundary_errors(service_path, source) == []
        assert len(swift_code(source)) == len(source)
    assert service_boundary_errors(
        service_path, "let regex = /a\\/\\/safe/; let value = URLSession.shared"
    )
    assert ownership_errors(
        "GalleryFeature", "let result = amount / UserDefaults.standard.integer(forKey: key)"
    )
