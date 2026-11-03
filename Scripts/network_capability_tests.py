"""Regression contracts for network capability discovery and reachable smoke calls."""

from validation_test_areas import (
    MANUAL_CAPABILITY_SCENARIOS,
    NETWORK_CAPABILITIES,
    network_capability_findings,
    smoke_receiver_resolver,
)

from network_discovery_tests import network_discovery_self_test as network_discovery_self_test
from network_execution_tests import smoke_execution_self_test


def network_capability_self_test() -> None:
    from swift_type_index_tests import (
        stored_network_callback_self_test,
        dynamic_network_callback_self_test,
        callable_object_network_self_test,
        recursive_network_reachability_self_test,
    )

    for check in (
        stored_network_callback_self_test,
        dynamic_network_callback_self_test,
        callable_object_network_self_test,
        recursive_network_reachability_self_test,
    ):
        check()
    from unittest.mock import patch
    from validation_compilation import compilation_condition

    assert compilation_condition("RELEASE_NETWORK_SMOKE", "network")
    assert not compilation_condition("DEBUG", "network")
    from network_capability_rules import signature_function, method_signature

    for signature in (
        "fetch(values:Dictionary<String,Int>)",
        "fetch(context:(Int,String))",
        "fetch(callback:(Int,String)->Void)",
        "fetch(values:Dictionary<String,(Int,String)>,callback:(Int,String)->Void)",
        "static fetch()",
        "fetch()->Int",
        "static fetch(callback:()->Void)->(Int,String)",
    ):
        assert method_signature(signature_function(signature, ["Service"])) == signature
    index = {
        f"Modules/{name.split('.')[0]}/Sources/{name.split('.')[1]}.swift": {
            "declarations": [
                {
                    "kind": "struct",
                    "name": part,
                    "scope": name.split(".")[1:position],
                    "inheritedTypes": [],
                    "isExported": True,
                }
                for position, part in enumerate(name.split(".")[1:], 1)
            ],
            "typedVariables": [],
            "functionRanges": [
                {
                    **signature_function(method, name.split(".")[1:]),
                    "isExported": True,
                    "isAsync": True,
                    "start": 0,
                    "end": 1,
                }
                for method in methods
            ],
        }
        for name, methods in NETWORK_CAPABILITIES.items()
    }
    bindings = {
        owner.split(".")[1]: owner.split(".")[1].removesuffix("Service").lower()
        for owner in NETWORK_CAPABILITIES
    }
    bindings["GalleryService"] = "gallery"
    entries = (
        (
            "network",
            "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift",
            ["ReleaseNetworkSmokeRunner"],
            "run",
        ),
        (
            "community-writes",
            "BIT101-iOS/Shared/Client/CommunityWriteSmoke.swift",
            ["CommunityWriteSmoke", "Operations"],
            "production",
        ),
    )
    guard = "#if RELEASE_NETWORK_SMOKE\n"
    offset = len(guard)
    for route, file, scope, entry in entries:
        selected = [
            (owner, method)
            for owner, methods in NETWORK_CAPABILITIES.items()
            for method, target in methods.items()
            if target == route
        ]
        calls = [
            {
                "calledExpression": (
                    owner.split(".")[1]
                    if signature_function(method, [])["isStatic"]
                    else bindings[owner.split(".")[1]]
                )
                + "."
                + signature_function(method, [])["name"],
                "argumentLabels": [
                    p["label"] for p in signature_function(method, [])["parameters"]
                ],
                "arguments": [
                    p["type"] + "()" for p in signature_function(method, [])["parameters"]
                ],
                "start": offset + 10 + position,
                "scope": scope,
            }
            for position, (owner, method) in enumerate(selected)
        ]
        length = max(100, len(calls) + 20)
        index[file] = {
            "declarations": [
                {"kind": "struct", "name": name, "scope": scope[:position]}
                for position, name in enumerate(scope)
            ],
            "source": guard + "f" * length + "\n#endif",
            "functionRanges": [
                {
                    "name": entry,
                    "scope": scope,
                    "start": offset,
                    "end": offset + length,
                    "isStatic": entry == "production",
                }
            ],
            "invocations": calls,
            "typedVariables": [
                {
                    "name": bindings[owner.split(".")[1]],
                    "type": owner,
                    "scope": scope,
                    "start": offset,
                }
                for owner in NETWORK_CAPABILITIES
            ],
        }
    index["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"]["invocations"].append(
        {
            "calledExpression": "CommunityWriteSmoke.Operations.production",
            "start": offset + 10,
            "scope": ["ReleaseNetworkSmokeRunner"],
        }
    )
    assert network_capability_findings(index) == [], network_capability_findings(index)
    with patch.dict(
        MANUAL_CAPABILITY_SCENARIOS["BIT101-iOS.NetworkDiagnosisRunner"], {}, clear=True
    ):
        assert any("逐方法登记" in error for error in network_capability_findings(index))
    with patch.dict(
        MANUAL_CAPABILITY_SCENARIOS["BIT101-iOS.NetworkDiagnosisRunner"], {"run()": "unknown-scene"}
    ):
        assert any("有效验收场景" in error for error in network_capability_findings(index))
    from copy import deepcopy

    unbound = deepcopy(index)
    unbound["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"]["typedVariables"] = []
    assert any("静态可达服务调用" in error for error in network_capability_findings(unbound))
    renamed = deepcopy(index)
    for facts in (
        renamed["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"],
        renamed["BIT101-iOS/Shared/Client/CommunityWriteSmoke.swift"],
    ):
        for variable in facts["typedVariables"]:
            if variable["name"] == "gallery":
                variable["name"] = "feedClient"
        for call in facts["invocations"]:
            call["calledExpression"] = call["calledExpression"].replace("gallery.", "feedClient.")
    assert not network_capability_findings(renamed)
    unused = deepcopy(index)
    unused["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"]["functionRanges"][0]["scope"] = [
        "UnusedHelper"
    ]
    assert any("静态可达服务调用" in error for error in network_capability_findings(unused))
    nested = deepcopy(index)
    nested["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"]["functionRanges"].append(
        {
            "name": "unused",
            "scope": ["ReleaseNetworkSmokeRunner"],
            "start": offset + 5,
            "end": offset + 20,
        }
    )
    assert any("静态可达服务调用" in error for error in network_capability_findings(nested))
    queued = deepcopy(index)
    queued["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"]["callableRanges"] = [
        {
            "name": "queued",
            "scope": ["ReleaseNetworkSmokeRunner"],
            "start": offset + 5,
            "end": offset + 20,
        }
    ]
    assert any("静态可达服务调用" in error for error in network_capability_findings(queued))
    invocation = {
        "calledExpression": "runInParallel",
        "start": offset + 30,
        "arguments": ["queued"],
        "scope": ["ReleaseNetworkSmokeRunner"],
    }
    queued["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"]["invocations"].append(invocation)
    assert not network_capability_findings(queued)
    invocation["calledExpression"] = "storeCallback"
    assert any("静态可达服务调用" in error for error in network_capability_findings(queued))
    from swift_source_index import swift_syntax_index_sources

    receiver_sources = {
        "Modules/GalleryFeature/Sources/Service.swift": "public struct GalleryService {}",
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift": (
            "import GalleryFeature; struct Dependencies { var makeFeed: () -> GalleryService = { G"
            "alleryService() } }"
        ),
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift": """import GalleryFeature
            struct Dummy {}; struct ReleaseNetworkSmokeRunner { let dependencies: Dependencies
                func run() { let feedClient = dependencies.makeFeed(); feedClient.fetchFeed()
                    let alias = feedClient; alias.fetchFeed()
                    do { let feedClient = Dummy(); feedClient.fetchFeed() }
                    unknown.fetchFeed(); GalleryFeature.GalleryService().fetchFeed()
                }
            }""",
    }
    receiver_index = swift_syntax_index_sources(receiver_sources)
    receiver_owner = smoke_receiver_resolver(receiver_index)
    receiver_path = "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"
    owners = [
        receiver_owner(dict(call, path=receiver_path))
        for call in receiver_index[receiver_path]["invocations"]
        if call["calledExpression"].endswith(".fetchFeed")
    ]
    assert owners == [
        "GalleryFeature.GalleryService",
        "GalleryFeature.GalleryService",
        "BIT101-iOS.Dummy",
        None,
        "GalleryFeature.GalleryService",
    ]
    overload_sources = {
        "Modules/GalleryFeature/Sources/Service.swift": (
            "public struct GalleryService { public func fetchFeed(id: Int) {}; public func fetchFe"
            "ed(id: String) {} }"
        ),
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift": guard
        + (
            "import GalleryFeature; struct ReleaseNetworkSmokeRunner { func run() { let service = "
            'GalleryService(); service.fetchFeed(id: 1); service.fetchFeed(id: "one") } }\n#endif'
        ),
    }
    with (
        patch.dict(
            NETWORK_CAPABILITIES,
            {
                "GalleryFeature.GalleryService": {
                    "fetchFeed(id:Int)": "network",
                    "fetchFeed(id:String)": "network",
                }
            },
            clear=True,
        ),
        patch.dict(MANUAL_CAPABILITY_SCENARIOS, {}, clear=True),
    ):
        assert not network_capability_findings(swift_syntax_index_sources(overload_sources))
        overload_sources["BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"] = overload_sources[
            "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"
        ].replace('service.fetchFeed(id: "one")', "")
        assert any(
            "fetchFeed(id:String)" in error
            for error in network_capability_findings(swift_syntax_index_sources(overload_sources))
        )
    smoke_execution_self_test()

    def request_call(start, scope):
        return {
            "calledExpression": "URLSession.shared.data",
            "start": start,
            "scope": [scope],
            "arguments": ["request"],
            "argumentLabels": ["for"],
        }

    course_facts = index["Modules/CourseFeature/Sources/CourseService.swift"]
    courses = course_facts["functionRanges"]
    courses.append(
        {
            "name": "newEndpoint",
            "scope": ["CourseService"],
            "isExported": True,
            "isAsync": True,
            "start": 0,
            "end": 1,
        }
    )
    course_facts.setdefault("invocations", []).append(request_call(0, "CourseService"))
    assert network_capability_findings(index)
    from validation_policy import NETWORK_GROUPS

    for route in NETWORK_GROUPS:
        with patch.dict(
            NETWORK_CAPABILITIES["CourseFeature.CourseService"], **{"newEndpoint()": route}
        ):
            expected = (
                "静态可达服务调用" if route in {"network", "community-writes"} else "有效验收入口"
            )
            assert any(expected in error for error in network_capability_findings(index)), route
    courses.pop()
    course_facts["invocations"].pop()
    courses.append(
        {
            "name": "fetchComments",
            "scope": ["CourseService"],
            "isExported": True,
            "isAsync": True,
            "start": 2,
            "end": 3,
            "parameters": [
                {"label": "includeReplies", "type": "Bool", "hasDefault": False, "variadic": False}
            ],
        }
    )
    course_facts["invocations"].append(request_call(2, "CourseService"))
    assert any(
        "fetchComments(includeReplies:Bool)" in error
        for error in network_capability_findings(index)
    )
    with patch.dict(
        NETWORK_CAPABILITIES["CourseFeature.CourseService"],
        **{"fetchComments(includeReplies:Bool)": "gallery-report"},
    ):
        assert any("逐方法登记" in error for error in network_capability_findings(index))
        with patch.dict(
            MANUAL_CAPABILITY_SCENARIOS,
            {
                "CourseFeature.CourseService": {
                    "fetchComments(includeReplies:Bool)": "submit-and-confirm"
                }
            },
        ):
            assert not network_capability_findings(index)
    courses.pop()
    course_facts["invocations"].pop()
    course_facts["typedVariables"] = [
        {"name": "client", "type": "HTTPClient", "scope": ["NewService"], "start": 0}
    ]
    courses.append(
        {
            "name": "fetchCourse",
            "scope": ["NewService"],
            "isExported": True,
            "isAsync": True,
            "start": 0,
            "end": 1,
        }
    )
    course_facts["invocations"].append(request_call(0, "NewService"))
    assert any("新增生产服务" in error for error in network_capability_findings(index))
    courses.pop()
    course_facts["invocations"].pop()
    course_facts["typedVariables"] = []
    network_discovery_self_test()
    scores = index["Modules/ScoreInfrastructure/Sources/ScoreService.swift"]["functionRanges"]
    scores.append(
        {
            "name": "newEndpoint",
            "scope": ["ScoreService"],
            "isExported": True,
            "isAsync": True,
            "start": 0,
            "end": 1,
        }
    )
    index["Modules/ScoreInfrastructure/Sources/ScoreService.swift"].setdefault(
        "invocations", []
    ).append(request_call(0, "ScoreService"))
    assert any(
        "ScoreService" in error and "newEndpoint()" in error
        for error in network_capability_findings(index)
    )
    scores.pop()
    index["Modules/ScoreInfrastructure/Sources/ScoreService.swift"]["invocations"].pop()
    with patch.dict(
        NETWORK_CAPABILITIES, {"CourseFeature.CourseService": {"fetchCourses": "missing-check"}}
    ):
        assert network_capability_findings(index)
