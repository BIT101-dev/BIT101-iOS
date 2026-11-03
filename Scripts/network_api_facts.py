"""Analyze network api facts."""

import re
from swift_source_index import argument_parameter_bindings, visible_variables


NETWORK_FOUNDATION_API = {
    "TransportCore.HTTPClient": {
        "send(:URLRequest,accepting:Range<Int>,alsoAccepting:Set<Int>,maximumBytes:Int?)"
    },
    "TransportCore.HTTPRequestEvidenceContext": {
        (
            "static withMutationOutcome(isTrackingRequest:@escaping@MainActor@Sendable()->Bool,ope"
            "ration:()asyncthrows->Value)"
        )
    },
    "TransportCore.HTTPBoundedTransfer": {"receive(:URLSessionDataTask)"},
    "ScorePorts.TrustedTranscriptReport": {
        "loadPages(excluding:Set<Int>,maximumBytes:Int,onPage:TrustedTranscriptPageDelivery?)"
    },
    "TransportCore.URLSessionTransport": {
        "deinit()",
        "static make(configuration:URLSessionConfiguration,followsRedirects:Bool)",
    },
    "CommunityTransport.CommunitySession": {"client(errorDomain:String)"},
    "CommunityTransport.CommunityAPIClient": {
        (
            "request(path:String,pathComponent:String?,queryItems:[URLQueryItem],method:String,bod"
            "y:Data?,contentType:String?,authentication:CommunityAuthentication,retryPolicy:Commun"
            "ityRetryPolicy,mutation:CommunityMutationKind?,validate:(@Sendable(Response)throws->V"
            "oid)?)"
        ),
        (
            "response(path:String,pathComponent:String?,queryItems:[URLQueryItem],method:String,bo"
            "dy:Data?,contentType:String?,authentication:CommunityAuthentication,retryPolicy:Commu"
            "nityRetryPolicy,mutation:CommunityMutationKind?,validate:(@Sendable(Response)throws->"
            "Void)?)"
        ),
        (
            "requestData(path:String,queryItems:[URLQueryItem],method:String,body:Data?,contentTyp"
            "e:String?,authentication:CommunityAuthentication,retryPolicy:CommunityRetryPolicy)"
        ),
        (
            "requestVoid(path:String,method:String,body:Data?,contentType:String?,authentication:C"
            "ommunityAuthentication,retryPolicy:CommunityRetryPolicy,mutation:CommunityMutationKin"
            "d?)"
        ),
    },
    "MediaKit.MediaEnvironment": {
        "retryFailedImages()",
        "static normalizedCacheLimitMB(:Int)",
        "endPreview(owner:UUID)",
        "remotePreviewFile(for:URL,owner:UUID)",
        "cachedRemotePreviewFile(for:URL,owner:UUID)",
        "usedBytes()",
        "enforceCurrentLimit()",
        "clearCaches()",
    },
    "MediaKit.RemoteAnimatedImage.Coordinator": {
        (
            "load(url:URL,into:UIImageView,media:MediaEnvironment,reduceMotion:Bool,retryGeneratio"
            "n:UInt64,budgetGeneration:UInt64,maximumPixelSize:Int?,onPhaseChange:(@MainActor(Remo"
            "teAnimatedImagePhase)->Void)?)"
        )
    },
    "MediaKit.ImageQuickLookPresenter": {
        "static dismantleUIViewController(:HostViewController,coordinator:Coordinator)"
    },
    "MediaKit.ImageQuickLookPresenter.Coordinator": {
        "receive(:ImagePreviewRequest?,from:HostViewController,media:MediaEnvironment)",
        "presentPendingIfPossible(from:HostViewController)",
        "previewControllerDidDismiss(:QLPreviewController)",
        "cancel()",
        "prepareInitialItems(for:ImagePreviewRequest,media:MediaEnvironment)",
        "retryCurrentImage()",
        "closePreview()",
    },
    "MediaKit.CachedRemoteImageLoader": {
        "load(url:URL?,fallbackURL:URL?,media:MediaEnvironment,maximumPixelSize:Int?)"
    },
    "MediaKit.CachedRemoteImageStore": {
        "data(for:URL)",
        "image(for:URL,maximumPixelSize:Int?)",
        "loadImage(for:URL,maximumPixelSize:Int?)",
    },
    "MediaKit.RemoteStillImageLoader": {
        (
            "load(thumbnailURL:URL?,originalURL:URL?,loadsOriginal:Bool,media:MediaEnvironment,pix"
            "elSize:Int,onAspectRatioResolved:((CGFloat)->Void)?)"
        )
    },
    "MediaKit.RemoteImageCache": {
        (
            "init(files:anyAppFileService,quota:ImageCacheDiskQuota,httpClient:HTTPClient,download"
            ":(@Sendable(URL)asyncthrows->HTTPResponse)?)"
        ),
        "file(for:URL)",
        "withFile(for:URL,operation:@Sendable(URL)asyncthrows->Value)",
        (
            "withSource(for:URL,download:(@Sendable(URL)asyncthrows->HTTPResponse)?,operation:@Sen"
            "dable(RemoteImageSource)asyncthrows->Value)"
        ),
    },
    "BIT101-iOS.AppScheduleSchoolSessionRestorer": {"restoreSchoolSession()"},
    "BIT101-iOS.AppNativeSchoolAuthentication": {
        "static make(state:TeachingCenterSessionState,productionPolicy:Bool)"
    },
}


NETWORK_TRANSPORT_TYPES = {
    "HTTPClient",
    "HTTPTransport",
    "URLSession",
    "CommunityAPIClient",
    "CommunitySession",
    "URLSessionTask",
    "URLSessionDataTask",
    "URLSessionUploadTask",
    "URLSessionDownloadTask",
    "URLSessionStreamTask",
    "URLSessionWebSocketTask",
    "URLSessionDataTaskPublisher",
    "NSURLConnection",
    "NWConnection",
    "NWConnectionGroup",
    "NWListener",
    "NWBrowser",
    "NetService",
    "NetServiceBrowser",
    "NSNetService",
    "NSNetServiceBrowser",
    "WKWebView",
}


NETWORK_PLATFORM_CONNECTION_TYPES = {
    name for name in NETWORK_TRANSPORT_TYPES if name.startswith("NW")
}


NETWORK_PLATFORM_TRANSPORT_TYPES = (
    NETWORK_TRANSPORT_TYPES
    - NETWORK_PLATFORM_CONNECTION_TYPES
    - {"HTTPClient", "HTTPTransport", "CommunityAPIClient", "CommunitySession"}
)


NETWORK_PLATFORM_STREAM_TYPES = {
    "Stream",
    "InputStream",
    "OutputStream",
    "NSStream",
    "NSInputStream",
    "NSOutputStream",
}


FOUNDATION_COLLECTION_TYPES = {"NSDictionary", "NSMutableDictionary", "NSArray", "NSMutableArray"}


NETWORK_SYSTEM_FUNCTIONS = frozenset(
    (
        "socket|socketpair|connect|bind|listen|accept|send|sendto|sendmsg|recv|recvfrom|recvmsg|sh"
        "utdown|setsockopt|getsockopt|getpeername|getsockname|getaddrinfo|getnameinfo|gethostbynam"
        "e|gethostbyname2|gethostbyaddr|res_query|res_search|CFReadStreamCreateForHTTPRequest|CFHT"
        "TPMessageCreateRequest"
    ).split("|")
)


NETWORK_TRANSPORT_METHODS = {
    "send",
    "receive",
    "sendPing",
    "resume",
    "start",
    "data",
    "bytes",
    "upload",
    "download",
    "receiveMessage",
    "readData",
    "write",
    "request",
    "requestData",
    "requestVoid",
    "sink",
    "subscribe",
    "sendSynchronousRequest",
    "sendAsynchronousRequest",
    "publish",
    "resolve",
    "startMonitoring",
    "stopMonitoring",
    "stop",
    "setTXTRecord",
    "searchForServices",
    "searchForBrowsableDomains",
    "searchForRegistrationDomains",
    "load",
    "loadHTMLString",
    "loadFileURL",
    "reload",
    "reloadFromOrigin",
    "goBack",
    "goForward",
}


NETWORK_HARNESS_TYPES = {
    "BIT101-iOS.ReleaseNetworkSmokeRunner": "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift",
    "BIT101-iOS.ReleaseNetworkSmokeDependencies": (
        "BIT101-iOS/Shared/Client/ReleaseNetworkSmokeModels.swift"
    ),
    "BIT101-iOS.CommunityWriteSmoke": "BIT101-iOS/Shared/Client/CommunityWriteSmoke.swift",
    "BIT101-iOS.NetworkSmokeProductionSession": (
        "BIT101-iOS/Shared/Client/NetworkSmokeProductionSession.swift"
    ),
}


def transport_method(expression: str) -> str:
    return expression.rsplit(".", 1)[-1].partition("(")[0]


def method_signature(function: dict) -> str:
    signature = (
        ("static " if function.get("isStatic") else "")
        + function["name"]
        + "("
        + ",".join(
            parameter["label"] + ":" + re.sub(r"\s+", "", parameter["type"])
            for parameter in function.get("parameters", [])
        )
        + ")"
    )
    return signature + (
        "->" + re.sub(r"\s+", "", function.get("returnType") or "Void")
        if function.get("returnOverload")
        else ""
    )


def signature_function(signature: str, scope: list[str]) -> dict:
    static = signature.startswith("static ")
    name, tail = signature.removeprefix("static ").split("(", 1)
    depth, closing = 1, 0
    for closing, character in enumerate(tail):
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        if depth == 0:
            break
    arguments, returned = tail[:closing], tail[closing + 1 :].removeprefix("->")
    values, depth, start = [], [], 0
    for position, character in enumerate(arguments):
        if character in "(<[{":
            depth.append(character)
        elif character in ")>]}" and not (
            character == ">" and position and arguments[position - 1] == "-"
        ):
            depth.pop()
        elif character == "," and not depth:
            values.append(arguments[start:position])
            start = position + 1
    values.append(arguments[start:])
    return {
        "name": name,
        "scope": scope,
        "isStatic": static,
        "returnType": returned or None,
        "returnOverload": bool(returned),
        "parameters": [
            dict(label=label, name=label, type=kind, hasDefault=False, variadic=False)
            for value in values
            if value
            for label, kind in [value.split(":", 1)]
        ],
    }


def platform_stream_request(types, path: str, call: dict, bindings=None) -> bool:
    receiver, _, method = call.get("calledExpression", "").rpartition(".")
    if method != "getStreamsToHost":
        return False
    candidates = {types.terminal_name(path, receiver, call["scope"])}
    if bindings:
        candidates |= bindings.receiver_components(call, path)
    aliases = [
        node
        for node in types.index[path].get("bindings", [])
        + visible_variables(types.index[path], call, receiver)
        if node.get("bindingName", node.get("name")) == receiver
        and node["start"] < call["start"]
        and call["scope"][: len(node["scope"])] == node["scope"]
        and call.get("lexicalScope", [])[: len(node.get("lexicalScope", []))]
        == node.get("lexicalScope", [])
    ]
    if aliases:
        alias = max(
            aliases,
            key=lambda node: (len(node["scope"]), len(node.get("lexicalScope", [])), node["start"]),
        )
        reference = alias.get("initializerReference", "")
        if reference.endswith(".self"):
            candidates.add(
                types.terminal_name(path, reference.removesuffix(".self"), alias["scope"])
            )
    if any(
        name.removeprefix("Foundation.") in NETWORK_PLATFORM_STREAM_TYPES for name in candidates
    ):
        return True
    target = types.resolve(path, receiver, call["scope"])
    return bool(
        target
        and any(
            types.terminal_name(path, base, target[1][:-1]).removeprefix("Foundation.")
            in NETWORK_PLATFORM_STREAM_TYPES
            for base in types.bases(target)
        )
    )


def api_argument_bindings(function: dict, call: dict) -> list[list[dict]]:
    labels = list(call.get("argumentLabels", []))
    trailing = [item for item in call.get("closureArguments", []) if item[0] >= len(labels)]
    if trailing:
        parameters = function.get("parameters", [])
        if len(parameters) < len(trailing):
            return []
        declared = call.get("trailingClosureLabels", [""] * len(trailing))
        result = []
        for first in {parameter["label"] for parameter in parameters}:
            for binding in argument_parameter_bindings(parameters, labels + [first, *declared[1:]]):
                if binding not in result:
                    result.append(binding)
        return result
    return argument_parameter_bindings(function.get("parameters", []), labels)


def api_invocations(facts: dict) -> list[dict]:
    return facts.get("invocations", []) + [
        dict(
            member,
            calledExpression=member["value"],
            argumentLabels=[],
            arguments=[],
            isMemberRead=True,
        )
        for member in facts.get("members", [])
        if not member.get("isAssignmentTarget")
    ]


def _is_omitted_default(parameter: dict, binding: list) -> bool:
    if not parameter.get("defaultExpressionRange"):
        return False
    return all(parameter is not supplied for supplied in binding)


def _omitted_default_parameter_starts(function: dict, invocation: dict) -> set[int]:
    omitted = set()
    parameters = function.get("parameters", [])
    for binding in api_argument_bindings(function, invocation):
        for param in parameters:
            if _is_omitted_default(param, binding):
                omitted.add(param["defaultExpressionRange"][0])
    return omitted


def matching_execution_entries(index, entries, call, declarations, invocation, *, types):
    """Select declaration bodies and omitted defaults using the shared argument contract."""
    if invocation is None:
        return [entry for entry in entries if entry[0][3] == declarations[entry[0]][1]["start"]]
    candidates = {
        id(function): (path, function)
        for key, _ in entries
        for path, function in [declarations[key]]
        if "parameters" in function
    }
    invocation = dict(invocation, path=call["path"])
    if candidates and all(function["name"] == "init" for _, function in candidates.values()):
        invocation = dict(
            invocation, calledExpression="init", receiverExpression=invocation["calledExpression"]
        )
    groups = {}
    implicit = {
        identity
        for identity, (_, function) in candidates.items()
        if function.get("isAccessor")
        or function.get("isCallableValue")
        or function["name"] == "init"
        and not function.get("isExplicitInitializer")
    }
    for path, function in candidates.values():
        if id(function) in implicit:
            continue
        groups.setdefault(types.function_scope(path, function["scope"]), []).append(
            (path, function)
        )
    matched = {
        id(function)
        for group in groups.values()
        for _, function in matching_api_calls(
            index, group, invocation, types=types, conservative=True
        )
    }
    matched.update(implicit)
    selected = []
    for entry in entries:
        key, _ = entry
        _, function = declarations[key]
        if "parameters" in function and id(function) not in matched:
            continue
        if key[3] != function["start"]:
            omitted = _omitted_default_parameter_starts(function, invocation)
            if key[3] not in omitted:
                continue
        selected.append(entry)
    return selected


def _match_argument_position(
    value: str,
    kind,
    parameter: dict,
    function: dict,
    path: str,
    position: int,
    call: dict,
    canonical_fn,
    literal_context_fn,
    types,
) -> tuple[int, int] | None:
    expected, expected_optional = canonical_fn(path, parameter["type"], function["scope"])
    context = literal_context_fn(path, function, parameter, expected, position)
    if value == "nil":
        if not expected_optional and context != "nil":
            return None
        return 0, 0
    if value.startswith("."):
        if context != "member":
            return None
        actual, actual_optional = expected, False
    elif kind is None:
        return 0, 0
    else:
        actual, actual_optional = canonical_fn(call["path"], kind, call["scope"])
    if actual_optional and not expected_optional:
        return None
    distance = 0 if actual == expected else types.inheritance_distance(actual, expected)
    if distance is None and context == "numeric":
        distance = 1
    if distance is None:
        return None
    promotions = int(expected_optional and not actual_optional)
    return distance, promotions


def _match_return_type(
    expected_return: str,
    path: str,
    function: dict,
    call: dict,
    canonical_fn,
    types,
) -> int | None:
    actual, optional = canonical_fn(path, function.get("returnType") or "Void", function["scope"])
    expected, lifted = canonical_fn(call["path"], expected_return, call["scope"])
    distance = 0 if actual == expected else types.inheritance_distance(actual, expected)
    if distance is None or (optional and not lifted):
        return None
    return distance + int(lifted and not optional)


def matching_api_calls(
    index: dict, functions: list[tuple[str, dict]], call: dict, *, types=None, conservative=False
) -> list[tuple[str, dict]]:
    name = call["calledExpression"].removeprefix("self.").rsplit(".", 1)[-1]
    candidates = [
        (path, function)
        for path, function in functions
        if function["name"] == name
        and api_argument_bindings(function, call)
        and (
            not call.get("isMemberRead")
            or function.get("isAccessor")
            and "->" not in (function.get("returnType") or "")
        )
    ]
    if not candidates:
        return []
    from swift_type_index import SwiftTypeIndex

    if types is None:
        types = SwiftTypeIndex(index)
    facts = index[call["path"]]
    receiver = call.get("receiverExpression", call["calledExpression"]).rpartition(".")[0]
    if receiver in {"self", "Self", ""}:
        containers = [
            row
            for row in facts.get("functionRanges", [])
            if row["start"] <= call["start"] < row["end"]
        ]
        static = receiver == "Self" or bool(
            containers
            and min(containers, key=lambda row: row["end"] - row["start"]).get("isStatic")
        )
    else:
        variables = visible_variables(facts, call, receiver)
        static = (
            any(
                re.sub(r"\s+", "", row.get("type") or "").endswith((".Type", ".Protocol"))
                for row in variables
            )
            or not call.get("receiverCall")
            and not variables
            and types.resolve(call["path"], receiver, call["scope"]) is not None
        )
    candidates = [
        (path, row)
        for path, row in candidates
        if not row.get("scope")
        or row.get("lexicalScope")
        or row.get("isExplicitInitializer")
        or row.get("isStatic", False) == static
    ]
    if len(candidates) <= 1:
        return candidates
    generic_candidates = [
        (path, function)
        for path, function in candidates
        if any(
            row["start"] <= function["start"] < row["end"]
            and re.search(
                r"\b" + re.escape(row["name"]) + r"\b",
                " ".join(
                    [parameter["type"] for parameter in function["parameters"]]
                    + [function.get("returnType") or ""]
                ),
            )
            for row in index[path].get("genericConstraints", [])
        )
    ]

    def canonical(path, kind, scope, seen=frozenset()):
        kind = re.sub(r"\bany\b|\s+", "", kind)
        lifted = kind.endswith(("?", "!"))
        kind = kind.rstrip("?!")
        alias = types.resolve(path, kind, scope, aliases=False)
        if alias in types.aliases and alias not in seen:
            base, inner = canonical(
                types.paths[alias], types.aliases[alias], alias[1][:-1], seen | {alias}
            )
            return base, lifted or inner
        optional = re.fullmatch(r"(?:Swift\.)?Optional<(.+)>", kind)
        if optional:
            base, _ = canonical(path, optional[1], scope, seen)
            return base, True
        return types.terminal_name(path, kind, scope).removeprefix("Swift."), lifted

    def argument_type(value):
        value = value.strip()
        if value in {"true", "false"}:
            return "Bool"
        if re.fullmatch(r"-?\d+", value):
            return "Int"
        if re.fullmatch(r"-?\d+\.\d+", value):
            return "Double"
        if value.startswith('"'):
            return "String"
        variables = visible_variables(
            facts, call, value.removeprefix("self."), value.startswith("self.")
        )
        if variables and variables[-1].get("type"):
            return re.sub(r"\s+", "", variables[-1]["type"])
        match = re.fullmatch(r"([\w.]+)\(.*\)", value, re.DOTALL)
        return (
            match[1]
            if match
            and (
                match[1].rsplit(".", 1)[-1][:1].isupper()
                or types.resolve(call["path"], match[1], call["scope"]) is not None
            )
            else None
        )

    literals = call.get("argumentTypes", [])
    arguments = [
        literals[index] if index < len(literals) and literals[index] else argument_type(value)
        for index, value in enumerate(call.get("arguments", []))
    ]

    def literal_context(path, function, parameter, expected, position):
        value = call["arguments"][position].strip()
        nominal = types.resolve(path, parameter["type"].rstrip("?!"), function["scope"])
        bases = types.bases(nominal) if nominal else set()

        def conforms(protocol):
            return bool(bases & {protocol, "Swift." + protocol})

        if value == "nil":
            return "nil" if conforms("ExpressibleByNilLiteral") else None
        if member := re.fullmatch(r"\.(\w+)(?:\(.*\))?", value, re.DOTALL):
            return "member" if member[1] in types.enum_cases.get(expected, set()) else None
        kind = literals[position] if position < len(literals) else None
        if kind not in {"Int", "Double"}:
            return None
        integer_types = {
            "Int",
            "UInt",
            *(
                prefix + width
                for prefix in ("Int", "UInt")
                for width in ("8", "16", "32", "64", "128")
            ),
        }
        floating_types = {"Float", "Float16", "Float80", "Double", "CGFloat", "Decimal"}
        standard = expected.removeprefix("CoreGraphics.").removeprefix("Foundation.")
        builtin = standard in floating_types or kind == "Int" and standard in integer_types
        protocol = "ExpressibleByIntegerLiteral" if kind == "Int" else "ExpressibleByFloatLiteral"
        return "numeric" if builtin or conforms(protocol) else None

    matches = []
    expected_return = call.get("expectedType") or next(
        (
            row.get("returnType")
            for row in facts.get("functionRanges", [])
            if row["start"] <= call["start"] < row["end"]
            and row.get("returnedCall") == call["calledExpression"]
        ),
        None,
    )
    for path, function in candidates:
        for binding in api_argument_bindings(function, call):
            promotions, conversions = 0, 0
            mismatched = False
            for position, (kind, parameter) in enumerate(zip(arguments, binding)):
                value = call["arguments"][position].strip()
                res = _match_argument_position(
                    value,
                    kind,
                    parameter,
                    function,
                    path,
                    position,
                    call,
                    canonical,
                    literal_context,
                    types,
                )
                if res is None:
                    mismatched = True
                    break
                dist, promo = res
                conversions += dist
                promotions += promo
            if mismatched:
                continue
            return_score = 0
            if expected_return:
                score_or_none = _match_return_type(
                    expected_return, path, function, call, canonical, types
                )
                if score_or_none is None:
                    continue
                return_score = score_or_none
            score = (
                conversions,
                promotions,
                return_score,
                max(0, len(function["parameters"]) - len(binding)),
            )
            matches.append((score, path, function))
    if not matches:
        return generic_candidates if conservative else []
    if conservative and (
        any(kind is None for kind in arguments) or min(score[0] for score, _, _ in matches) > 0
    ):
        return list(
            {
                (path, function["start"]): (path, function)
                for path, function in [(path, function) for _, path, function in matches]
                + generic_candidates
            }.values()
        )
    best = min(score for score, _, _ in matches)
    selected = list(
        {
            (path, function["start"]): (path, function)
            for score, path, function in matches
            if score == best
        }.values()
    )
    return selected if len(selected) == 1 else []
