#!/usr/bin/env python3
"""Validate smoke request evidence and pagination."""

from dataclasses import replace
from datetime import date
import base64
import json
import re
import sys
from urllib.parse import unquote, urlsplit
from validation_policy import SCHOOL_SMS_PROBES
from request_contract_catalog import (
    API as API,
    SCHOOL as SCHOOL,
    VPN as VPN,
    VISIBLE_PARAMETERS as VISIBLE_PARAMETERS,
    SCHOOL_AUTHENTICATION_BODIES as SCHOOL_AUTHENTICATION_BODIES,
    RequestContract as RequestContract,
    community as community,
    teaching as teaching,
    CONTRACTS as CONTRACTS,
    JWB_HOST as JWB_HOST,
    JWB_VPN as JWB_VPN,
    NATIVE_SCORE_LIST as NATIVE_SCORE_LIST,
    NATIVE_SCORE_DETAIL as NATIVE_SCORE_DETAIL,
    NATIVE_JWB_LANDING as NATIVE_JWB_LANDING,
    NATIVE_TRANSCRIPT_ENTRY as NATIVE_TRANSCRIPT_ENTRY,
    NATIVE_CONTRACTS as NATIVE_CONTRACTS,
)


def expand_search_contracts(
    contracts: list[RequestContract], expected_parameters: dict
) -> list[RequestContract]:
    expanded = []
    keywords = (expected_parameters["search"], expected_parameters["excludedSearch"])
    for contract in contracts:
        if contract.query.get("search") is None:
            expanded.append(contract)
        else:
            for keyword in keywords:
                expanded.append(
                    replace(contract, query=dict(contract.query, search=re.escape(keyword)))
                )
    return expanded


def contracts_for(probe: str, expected_parameters: dict | None = None) -> list[RequestContract]:
    if probe in CONTRACTS:
        contracts = CONTRACTS[probe]
        if (
            probe in {"gallery.search", "course.search", "paper.search"}
            and expected_parameters is not None
        ):
            return expand_search_contracts(contracts, expected_parameters)
        return contracts
    if probe in {
        "message.comment",
        "message.like",
        "message.follow",
        "message.system",
        "message.subscription",
    }:
        return [
            community(
                "/messages",
                query={"type": re.escape(probe.removeprefix("message."))},
                paging="last_id",
            )
        ]
    if probe.startswith("paper.list."):
        orders = {"newest": None, "like": "like", "comment": "comment"}
        order = probe.removeprefix("paper.list.")
        return (
            [community("/papers", query={"order": orders[order], "search": None}, paging="page")]
            if order in orders
            else []
        )
    return CONTRACTS.get(probe, [])


def auxiliary_contracts(
    probe: str, contracts: list[RequestContract], *, allow_sms: bool = False
) -> list[RequestContract]:
    community_session = any(contract.host == re.escape(API) for contract in contracts)
    school_session = any(
        contract.host
        in {
            SCHOOL,
            r"zy-eclass\.bit\.edu\.cn",
            r"(?:lexue|webvpn)\.bit\.edu\.cn",
            r"login\.bit101\.flwfdd\.xyz",
            r"jwb\.bit\.edu\.cn",
            JWB_HOST,
        }
        for contract in contracts
    )
    rows = []
    if probe in {
        "paper.list",
        "paper.search",
        "paper.detail",
        "paper.comments",
        "community.writes",
    } or probe.startswith("paper.list."):
        rows.append(community("/user/check"))
    if probe == "community.writes":
        rows.extend(
            community(path)
            for path in (r"/user/info/\d+", r"/courses/\d+", r"/posters/\d+", r"/papers/\d+")
        )
        rows.extend(
            [
                community(
                    "/posters", query={"mode": "search", "uid": "0", "order": None, "search": None}
                ),
                community("/papers", query={"order": None, "search": ".+"}),
                community(
                    "/reaction/comments",
                    query={"obj": r"(?:poster|paper|course|comment)\d+", "order": "(?:old|new)"},
                ),
            ]
        )
    if community_session:
        rows.extend(
            community(path, method="POST")
            for path in ("/user/webvpn_verify_init", "/user/webvpn_verify")
        )
    if community_session or school_session:
        rows.extend(
            RequestContract(
                r"sso\.bit\.edu\.cn",
                r"/cas/{1,2}login",
                method,
                statuses=range(200, 400),
                additional_parameters=frozenset({"service", "renew", "gateway", "ticket", "type"}),
                body_parameters=frozenset(
                    {
                        "username",
                        "password",
                        "execution",
                        "croypto",
                        "captcha_payload",
                        "geolocation",
                        "captcha_code",
                        "_eventId",
                        "trustDevice",
                        "risk_payload",
                        "targetSystem",
                        "siteId",
                        "riskEngine",
                    }
                )
                if method == "POST"
                else frozenset(),
            )
            for method in ("GET", "POST")
        )
        rows.append(
            RequestContract(
                r"sso\.bit\.edu\.cn",
                r"/gate/cas-success/?",
                statuses=(200, 401),
                additional_parameters=frozenset({"ticket"}),
            )
        )
    if probe in SCHOOL_SMS_PROBES["school_sso_second_factor"]:
        rows.append(
            RequestContract(
                r"sso\.bit\.edu\.cn", "/cas/api/protected/sms/getPhoneNumberByUserId", "POST"
            )
        )
        if allow_sms:
            rows.extend(
                RequestContract(
                    r"sso\.bit\.edu\.cn",
                    "/cas/api/protected/sms/" + path,
                    "POST",
                    body_parameters=frozenset(names),
                    required_body_parameters=frozenset(names),
                )
                for path, names in (
                    ("publicNoToken/sendSmsCode", {"phone", "businessNo"}),
                    ("checkToken", {"phone", "token", "delete", "trustDevice"}),
                )
            )
    if school_session:
        rows.extend(
            [
                RequestContract(
                    r"login\.bit101\.flwfdd\.xyz",
                    "/api/jxzxehall/cookies",
                    "POST",
                    body_parameters=frozenset({"username", "password", "challenge_id"}),
                    body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES,
                ),
                RequestContract(r"login\.bit101\.flwfdd\.xyz", r"/api/auth/[^/]+"),
            ]
        )
        if allow_sms and probe in set().union(
            *(SCHOOL_SMS_PROBES[purpose] for purpose in ("webvpn", "jwb", "jwb_cjd"))
        ):
            rows.append(
                RequestContract(
                    r"login\.bit101\.flwfdd\.xyz",
                    r"/api/auth/[^/]+/sms",
                    "POST",
                    body_parameters=frozenset({"code"}),
                    required_body_parameters=frozenset({"code"}),
                )
            )
        rows.extend(CONTRACTS["schedule.teaching-center"])
        rows.extend(CONTRACTS["score.authentication"])
        rows.extend(
            [
                RequestContract(
                    r"jxzxehall\.bit\.edu\.cn",
                    "/auth-protocol-core/login",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                RequestContract(
                    r"jxzxehall\.bit\.edu\.cn",
                    "/auth-protocol-core/loginSuccess",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                RequestContract(
                    SCHOOL,
                    VPN + r"/auth-protocol-core/login",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                RequestContract(
                    SCHOOL,
                    VPN + r"/jwapp/sys/xsfacx/\*default/index\.do",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                RequestContract(
                    SCHOOL,
                    VPN + r"/jwapp/sys/wdkbby/\*default/index\.do",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                RequestContract(
                    r"login\.bit\.edu\.cn",
                    "/cas/login",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                RequestContract(
                    r"jwb\.bit\.edu\.cn",
                    r"/cjd/(?:Account/ExternalLogin(?:Callback)?|signin-cas)?",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                replace(NATIVE_JWB_LANDING, statuses=range(200, 400)),
                RequestContract(
                    r"webvpn\.bit\.edu\.cn",
                    r"/(?:set-fingerprint|fingerprint|login)",
                    statuses=range(200, 400),
                    resource_parameters=True,
                ),
                RequestContract(
                    r"sso\.bit\.edu\.cn",
                    "/ustc-rba-front/fp",
                    "POST",
                    statuses=(200, 404),
                    body_parameters=frozenset(
                        {
                            "fonts",
                            "deviceMemory",
                            "hardwareConcurrency",
                            "localgroupId",
                            "timezone",
                            "cpuClass",
                            "platform",
                            "language",
                            "screenResolution",
                            "fingerprint",
                            "cookieValue",
                            "userAgent",
                            "platformAuthenticator",
                        }
                    ),
                ),
            ]
        )
        if probe.startswith("score."):
            rows.extend(
                [
                    NATIVE_SCORE_LIST,
                    RequestContract(
                        JWB_HOST,
                        JWB_VPN + r"/jsxsd/kscj/(?:[^/]+\.do|cjfx)",
                        resource_parameters=True,
                    ),
                ]
            )
            rows.extend(contract for name in NATIVE_CONTRACTS for contract in CONTRACTS[name])
    if probe in {"eclass.authentication", "eclass.ddl"}:
        rows.extend(
            [
                RequestContract(r"zy-eclass\.bit\.edu\.cn", "/user/index"),
                RequestContract(r"zy-eclass\.bit\.edu\.cn", r"/api/courses/[1-9]\d*/activities"),
            ]
        )
    if probe in {"lexue.calendar", "lexue.ddl"}:
        rows.extend(
            [
                RequestContract(r"(?:lexue|webvpn)\.bit\.edu\.cn", VPN + "/"),
                RequestContract(
                    r"webvpn\.bit\.edu\.cn",
                    r"/https/[0-9a-f]+/",
                    final_path=r"/https/[0-9a-f]+/cas/login",
                    additional_parameters=frozenset({"service"}),
                ),
                *CONTRACTS["lexue.calendar"],
            ]
        )
    if probe == "score.transcript":
        rows.append(RequestContract(r"jwb\.bit\.edu\.cn", "/cjd/Temp/.+"))
    return rows


def contract_recovers_request(
    contract: RequestContract, row: dict, auxiliary: list[RequestContract]
) -> bool:
    statuses = (401,) if contract.host == re.escape(API) else (401, 403)
    if contract in auxiliary and contract.host == r"login\.bit101\.flwfdd\.xyz":
        statuses += (500, 502, 503, 504)
    recovered = row.get("statusCode") in statuses and replace(contract, statuses=statuses).matches(
        row
    )
    if row.get("statusCode") in range(200, 400):
        final = dict(
            row,
            endpoint=row.get("finalEndpoint"),
            method=row.get("finalMethod"),
            query=row.get("finalQuery"),
        )
        if any(auth.matches(final) for auth in auxiliary if auth.host == r"sso\.bit\.edu\.cn"):
            original = dict(
                row,
                finalEndpoint=row.get("endpoint"),
                finalMethod=row.get("method"),
                finalQuery=row.get("query"),
            )
            recovered = recovered or replace(contract, statuses=range(200, 400)).matches(original)
    return bool(recovered)


def followed_by_matching_request(
    contract: RequestContract, row: dict, later_requests: list[dict]
) -> bool:
    keys = ("endpoint", "method", "query")
    for later in later_requests:
        if contract.matches(later) and all(row.get(k) == later.get(k) for k in keys):
            return True
    return False


def requests_accounted_for(
    requests: list[dict],
    contracts: list[RequestContract],
    auxiliary: list[RequestContract],
    *,
    allow_sms: bool = False,
) -> bool:
    allowed = contracts + auxiliary
    for index, row in enumerate(requests):
        if any(contract.matches(row) for contract in allowed):
            continue
        if (
            row.get("method") == "POST"
            and row.get("finalMethod") == "GET"
            and row.get("statusCode") in range(200, 300)
            and (row.get("query", {}).get("type") != "smsLogin" or allow_sms)
        ):
            origin = dict(
                row,
                finalEndpoint=row.get("endpoint"),
                finalMethod=row.get("method"),
                finalQuery=row.get("query"),
                finalBodyParameterNames=row.get("bodyParameterNames", []),
            )
            destination = dict(
                row,
                endpoint=row.get("finalEndpoint"),
                method=row.get("finalMethod"),
                query=row.get("finalQuery"),
                bodyParameterNames=row.get("finalBodyParameterNames", []),
            )
            if any(
                contract.host == r"sso\.bit\.edu\.cn" and contract.matches(origin)
                for contract in auxiliary
            ) and any(
                contract.host != r"sso\.bit\.edu\.cn" and contract.matches(destination)
                for contract in allowed
            ):
                continue
        if row.get("responseContentMissing") is True and any(
            contract.method == "GET"
            and contract.host == re.escape(API)
            and contract.path in {r"/posters/\d+", r"/papers/\d+"}
            and replace(contract, statuses=(400, 404, 500)).matches(row)
            for contract in auxiliary
        ):
            continue
        for contract in allowed:
            if not contract_recovers_request(contract, row, auxiliary):
                continue
            if followed_by_matching_request(contract, row, requests[index + 1 :]):
                break
        else:
            return False
    return True


def cleanup_requests_complete(requests: list[dict]) -> bool:
    account = community("/user/info/0")
    optional = auxiliary_contracts("community.writes", [account])
    optional.extend(
        replace(contract, minimum=1)
        for contract in CONTRACTS["community.writes"]
        if contract.method == "DELETE" or contract.path in {"/reaction/like", r"/user/follow/\d+"}
    )
    return (
        bool(requests)
        and account.complete(requests)
        and requests_accounted_for(requests, [account], optional)
    )


SELECTORS = {
    **{
        name: {"search", "excludedSearch"}
        for name in ("gallery.search", "course.search", "paper.search")
    },
    **{name: {"obj"} for name in ("gallery.comments", "course.comments", "paper.comments")},
    **{name: {"uid"} for name in ("profile.posts", "user.posts")},
    **{
        name: {"path"}
        for name in (
            "gallery.detail",
            "course.detail",
            "course.history",
            "paper.detail",
            "user.profile",
            "gallery.web",
            "course.web",
            "paper.web",
        )
    },
    "schedule.sync": {"XNXQDM"},
    "classroom.occupancy": {"XNXQDM", "JXLDM", "RQ", "XQDM", "XNDM"},
    "classroom.buildings": {"XXXQDM"},
}


def row_matches_expected_parameters(row: dict, expected_parameters: dict) -> bool:
    for key, expected in expected_parameters.items():
        for field, query_field in (("endpoint", "query"), ("finalEndpoint", "finalQuery")):
            actual = (
                unquote(urlsplit(row[field]).path)
                if key == "path"
                else row.get(query_field, {}).get(key)
            )
            if actual != expected:
                return False
    return True


def row_matches_contract_selection(row: dict, contracts: list[RequestContract], probe: str) -> bool:
    for contract in contracts:
        if contract.matches(row):
            if probe != "gallery.search" or contract.query.get("search") is not None:
                return True
    return False


def all_matching_requests_conform(
    requests: list[dict], contracts: list[RequestContract], probe: str, expected_parameters: dict
) -> bool:
    for row in requests:
        if row_matches_contract_selection(row, contracts, probe):
            if not row_matches_expected_parameters(row, expected_parameters):
                return False
    return True


def complete(
    probe: str,
    requests: list[dict],
    expected_parameters: dict | None = None,
    *,
    allow_sms: bool = False,
) -> bool:
    selectors = SELECTORS.get(probe, set())
    if selectors and (
        not isinstance(expected_parameters, dict)
        or set(expected_parameters) != selectors
        or not all(isinstance(value, str) and value for value in expected_parameters.values())
    ):
        return False
    search_probe = "excludedSearch" in selectors
    if search_probe and expected_parameters["search"] == expected_parameters["excludedSearch"]:
        return False
    variants = [contracts_for(probe, expected_parameters)]
    if probe in NATIVE_CONTRACTS:
        variants.append(NATIVE_CONTRACTS[probe])
    if probe == "score.detail":
        variants.append([NATIVE_SCORE_DETAIL])
    contracts = next(
        (
            candidate
            for candidate in variants
            if candidate
            and requests_accounted_for(
                requests,
                candidate,
                auxiliary_contracts(probe, candidate, allow_sms=allow_sms),
                allow_sms=allow_sms,
            )
            and all(contract.complete(requests) for contract in candidate)
        ),
        [],
    )
    matched = bool(contracts)
    if matched and selectors and not search_probe:
        matched = all_matching_requests_conform(requests, contracts, probe, expected_parameters)
    if matched and probe == "community.session":
        return (
            len(requests) == 3
            and contracts[0].matches(requests[0])
            and contracts[1].matches(requests[1])
            and contracts[0].matches(requests[2])
        )
    if matched and probe == "classroom.occupancy":
        year, _, semester = expected_parameters["XNXQDM"].rpartition("-")
        if expected_parameters["XNDM"] != year or expected_parameters["XQDM"] != semester:
            return False
        try:
            date.fromisoformat(expected_parameters["RQ"])
        except ValueError:
            return False
    if matched and probe == "update.emergency":
        for row in requests:
            if not contracts[0].matches(row):
                continue
            configuration = row.get("responseConfiguration")
            if (
                not isinstance(configuration, dict)
                or type(configuration.get("enabled")) is not bool
            ):
                return False
            try:
                content = base64.b64decode(configuration.get("content", ""), validate=True)
                payload = json.loads(content)
            except (ValueError, TypeError):
                return False
            if (
                len(content) > 1_048_576
                or not isinstance(payload, dict)
                or type(payload.get("schema_version")) is not int
                or payload["schema_version"] != 1
                or type(payload.get("enabled")) is not bool
                or payload["enabled"] != configuration["enabled"]
                or payload.get("notice_id") != configuration.get("noticeID")
            ):
                return False
            notice = configuration.get("noticeID")
            if configuration["enabled"] and (not isinstance(notice, str) or not notice.strip()):
                return False
    if matched and probe in {"gallery.image", "paper.image"}:
        if not isinstance(expected_parameters, dict) or set(expected_parameters) != {
            "resourceDigests"
        }:
            return False
        value = expected_parameters["resourceDigests"]
        if not isinstance(value, str):
            return False
        expected = set(value.split(","))
        if not expected or any(not re.fullmatch(r"[0-9a-f]{64}", digest) for digest in expected):
            return False
        return {
            row.get("endpointDigest") for row in requests if contracts[0].matches(row)
        } == expected
    if matched and probe in {"eclass.authentication", "eclass.ddl"}:
        pages = [row for row in requests if contracts[0].matches(row)]
        expected = set()
        total_pages = (
            pages[0].get("responseCoursePage", {}).get("pages")
            if isinstance(pages[0].get("responseCoursePage"), dict)
            else None
        )
        for index, row in enumerate(pages, 1):
            ids, metadata = row.get("responseCourseIDs"), row.get("responseCoursePage")
            if (
                not isinstance(ids, list)
                or len(ids) > 100
                or not all(
                    isinstance(value, str) and re.fullmatch(r"[1-9]\d*", value) for value in ids
                )
                or not isinstance(metadata, dict)
            ):
                return False
            if (
                row.get("query", {}).get("page") != str(index)
                or metadata.get("pages") != total_pages
            ):
                return False
            if metadata.get("page") is not None and (
                type(metadata["page"]) is not int or metadata["page"] != index
            ):
                return False
            if ids and not set(ids) - expected:
                return False
            expected.update(ids)
            if total_pages is not None:
                if (
                    type(total_pages) is not int
                    or total_pages < 0
                    or len(pages) != max(1, total_pages)
                    or total_pages == 0
                    and ids
                    or not ids
                    and index < len(pages)
                ):
                    return False
            elif (len(ids) < 100) != (index == len(pages)):
                return False
        activity = RequestContract(r"zy-eclass\.bit\.edu\.cn", r"/api/courses/[1-9]\d*/activities")
        observed = set()
        for row in requests:
            if not (activity.matches(row)):
                continue
            path = urlsplit(row["endpoint"]).path
            if path != urlsplit(row["finalEndpoint"]).path:
                return False
            observed.add(path.split("/")[3])
        return observed == expected
    if matched and probe == "community.writes":
        comments = [
            row
            for row in requests
            if community(
                "/reaction/comments",
                method="POST",
                query={"obj": r"(?:poster|paper|course|comment)\d+"},
            ).matches(row)
        ]
        from collections import Counter

        replies = Counter(
            (
                row["query"]["obj"],
                frozenset({"reply_obj", "reply_uid"}) <= set(row.get("bodyParameterNames", [])),
            )
            for row in comments
            if row.get("query", {}).get("obj", "").startswith("comment")
            and (frozenset({"reply_obj", "reply_uid"}) <= set(row.get("bodyParameterNames", [])))
            == (
                frozenset({"reply_obj", "reply_uid"}) <= set(row.get("finalBodyParameterNames", []))
            )
        )
        deleted = {
            urlsplit(row["endpoint"]).path
            for row in requests
            if community(r"/reaction/comments/\d+", method="DELETE").matches(row)
        }
        likes = Counter(
            row.get("query", {}).get("obj")
            for row in requests
            if community(
                "/reaction/like",
                method="POST",
                query={"obj": r"(?:poster|paper|course|comment)\d+"},
            ).matches(row)
        )
        user_pages = {
            row.get("query", {}).get("page", "0")
            for row in requests
            if community(
                "/posters",
                query={"mode": "search", "uid": r"[1-9]\d*", "order": None, "search": None},
            ).matches(row)
        }
        followed = Counter(
            urlsplit(row["endpoint"]).path
            for row in requests
            if community(r"/user/follow/\d+", method="POST").matches(row)
        )
        return (
            {"0", "1"} <= user_pages
            and sum(obj.startswith("comment") and count >= 2 for obj, count in likes.items()) >= 3
            and sum(
                replies[(obj, False)] >= 1 and replies[(obj, True)] >= 1
                for obj in {obj for obj, _ in replies}
            )
            >= 3
            and len(deleted) >= 9
            and any(count >= 2 for count in followed.values())
            and all(
                any(
                    isinstance(obj, str) and re.fullmatch(kind + r"\d+", obj) and count >= 2
                    for obj, count in likes.items()
                )
                for kind in ("poster", "paper", "course")
            )
        )
    return matched


if __name__ == "__main__":
    import json

    payload = json.load(sys.stdin)
    passed = complete(payload["probe"], payload["requests"], payload.get("expectedParameters"))
    if not passed:
        print("生产请求与 Smoke 合同存在差异：" + payload["probe"], file=sys.stderr)
    raise SystemExit(0 if passed else 1)
