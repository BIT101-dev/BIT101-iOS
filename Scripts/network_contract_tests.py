"""Network evidence fixtures and request contract checks."""

from contextlib import contextmanager, nullcontext, redirect_stderr, redirect_stdout
from datetime import timedelta
from io import BytesIO, StringIO
import ast
import json
import re
import subprocess
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch
from validation_manual_tests import image_resource_self_test, report_budget_self_test
from worker_contract_tests import (
    worker_deployment_fixture,
    worker_deployment_self_test,
    emergency_configuration_fixture,
)
from validation_provenance import LIVE_GROUPS, evidence_current, sampling_evidence_current, utc_now
from network_fixture_tests import community_recovery_contract_self_test, network_trace_fixture


def verify_contract_body_parameters(contract, sample, field):
    if contract.required_body_parameters:
        assert not contract.matches(dict(sample, **{field: []}))
    for name in contract.required_body_parameters:
        assert not contract.matches(
            dict(sample, **{field: sorted(set(sample[field]) - {name})})
        )
    if (
        contract.body_parameter_variants
        and {"challenge_id", "username", "password"} <= contract.body_parameters
    ):
        for names, valid in (
            ({"challenge_id"}, True),
            ({"username", "password"}, True),
            (set(), False),
            ({"username"}, False),
            ({"password"}, False),
            ({"challenge_id", "username"}, False),
        ):
            assert (
                contract.matches(
                    dict(
                        sample,
                        **{field: sorted(contract.required_body_parameters | names)},
                    )
                )
                == valid
            )


def verify_parameter_mutation(probe, fixture, key, field, invalid):
    from copy import deepcopy
    from validation_provenance import network_requests_complete

    changed = deepcopy(fixture)
    target = next(
        row for row in changed["requestEvidence"][0]["requests"] if key in row[field]
    )
    if invalid is None:
        target[field].pop(key)
    else:
        target[field][key] = invalid
    assert not network_requests_complete({probe}, changed), (probe, key, field, invalid)


def mutate_selector_request(request: dict, key: str) -> None:
    if key == "path":
        request["endpoint"] = request["endpoint"].rsplit("/", 1)[0] + "/999"
    elif key == "uid":
        request["query"][key] = "999"
    elif key == "obj":
        request["query"][key] = re.sub(r"\d+$", "999", request["query"][key])
    else:
        request["query"][key] = "wrong"


def update_search_field(row: dict, field: str, keyword: str | None) -> None:
    if keyword is None:
        row[field].pop("search", None)
    else:
        row[field]["search"] = keyword


def gallery_search_queries(parameters: dict) -> list[dict]:
    base = {key: value for key, value in parameters.items() if key != "search"}
    return [dict(base, order=order) for order in ("new", "like")]


def network_route_identity_self_test() -> None:
    native_school_request_contracts_self_test()
    community_recovery_contract_self_test()
    image_resource_self_test()
    from copy import deepcopy
    from validation_provenance import network_requests_complete
    from network_request_contracts import CONTRACTS, contracts_for, complete

    unread = {
        "method": "GET",
        "finalMethod": "GET",
        "statusCode": 200,
        "endpoint": "https://bit101.flwfdd.xyz/messages/unread_nums",
        "finalEndpoint": "https://bit101.flwfdd.xyz/messages/unread_nums",
        "query": {},
        "finalQuery": {},
    }
    assert complete("message.unread", [unread])
    assert not complete(
        "message.unread",
        [
            dict(
                unread,
                endpoint="https://bit101.flwfdd.xyz/messages",
                finalEndpoint="https://bit101.flwfdd.xyz/messages",
                query={"type": "unread"},
                finalQuery={"type": "unread"},
            )
        ],
    )
    assert all(contracts_for(probe) == contracts for probe, contracts in CONTRACTS.items())
    for probe in CONTRACTS:
        trace = network_trace_fixture({"scope": "all", "requiredProbes": [probe]})[
            "requestEvidence"
        ][0]
        assert complete(probe, trace["requests"], trace["expectedParameters"]), probe
        for field in ("bodyParameterNames", "finalBodyParameterNames"):
            altered = deepcopy(trace["requests"])
            altered[0][field] = ["unexpected_filter"]
            assert not complete(probe, altered, trace["expectedParameters"]), (probe, field)
        for contract in contracts_for(probe):
            sample = next((row for row in trace["requests"] if contract.matches(row)), None)
            if sample is None:
                continue
            allowed = sorted(
                (contract.body_parameters | contract.required_body_parameters)
                - set().union(*contract.body_parameter_variants)
                | (
                    contract.body_parameter_variants[0]
                    if contract.body_parameter_variants
                    else set()
                )
            )
            assert contract.matches(
                dict(sample, bodyParameterNames=allowed, finalBodyParameterNames=allowed)
            )
            if allowed:
                assert not contract.matches(dict(sample, bodyParameterNames=allowed + allowed[:1]))
            for field in ("bodyParameterNames", "finalBodyParameterNames"):
                verify_contract_body_parameters(contract, sample, field)
    from network_request_contracts import complete as check_complete

    emergency = network_trace_fixture({"requiredProbes": ["update.emergency"]})["requestEvidence"][
        0
    ]["requests"]
    assert check_complete("update.emergency", emergency)
    for configuration in (
        None,
        {},
        {"content": "bad", "enabled": False},
        emergency_configuration_fixture(True),
        emergency_configuration_fixture(True, " "),
        emergency_configuration_fixture() | {"enabled": True},
    ):
        assert not check_complete(
            "update.emergency", [dict(emergency[0], responseConfiguration=configuration)]
        )
    assert check_complete(
        "update.emergency",
        [
            dict(
                emergency[0],
                responseConfiguration=emergency_configuration_fixture(True, "maintenance"),
            )
        ],
    )
    for probe, parameters in [
        ("classroom.campuses", {"dicCode": "unrelated-dictionary", "SFSY": "0"}),
        ("score.transcript", {"GPA": "0"}),
    ]:
        fixture = network_trace_fixture({"requiredProbes": [probe]})
        assert network_requests_complete({probe}, fixture)
        for key, value in parameters.items():
            for field in ("query", "finalQuery"):
                for invalid in (value, "[REDACTED]", None):
                    verify_parameter_mutation(probe, fixture, key, field, invalid)

    def complete(probe, requests, expected=None):
        return check_complete(
            probe,
            [
                dict(
                    row,
                    finalEndpoint=row.get("finalEndpoint", row["endpoint"]),
                    finalMethod=row.get("finalMethod", row["method"]),
                    finalQuery=row.get("finalQuery", dict(row.get("query", {}))),
                )
                for row in requests
            ],
            expected,
        )

    required = {"paper.comments"}
    proof = network_trace_fixture({"requiredProbes": sorted(required)})
    assert network_requests_complete(required, proof)
    for key in ("ambiguousParameters", "finalAmbiguousParameters"):
        changed = deepcopy(proof)
        row = changed["requestEvidence"][0]
        row["requests"][0][key] = ["page"]
        assert not complete(row["probe"], row["requests"], row["expectedParameters"])
        assert not network_requests_complete(required, changed)
    repeated = deepcopy(proof["requestEvidence"][0])
    repeated["requests"][-1]["statusCode"] = 500
    assert not network_requests_complete(
        required, dict(proof, requestEvidence=proof["requestEvidence"] + [repeated])
    )
    for key, value in [
        ("finalEndpoint", "https://example.invalid/reaction/comments"),
        ("finalMethod", "POST"),
        ("finalQuery", {"obj": "paper999", "order": "new", "page": "0"}),
    ]:
        changed = deepcopy(proof)
        for request in changed["requestEvidence"][0]["requests"]:
            request[key] = value
        assert not network_requests_complete(required, changed), key
    changed = deepcopy(proof)
    del changed["requestEvidence"][0]["requests"][0]["finalEndpoint"]
    assert not network_requests_complete(required, changed)
    schedule = network_trace_fixture({"requiredProbes": ["schedule.sync"]})
    for request in schedule["requestEvidence"][0]["requests"]:
        request["finalQuery"]["XNXQDM"] = "wrong-term"
    assert not network_requests_complete({"schedule.sync"}, schedule)
    for probe in ("gallery.comments", "course.comments", "paper.comments", "course.list"):
        fixture = network_trace_fixture({"requiredProbes": [probe]})
        for parameter in ("order", "search") if probe == "course.list" else ("order",):
            changed = deepcopy(fixture)
            for row in changed["requestEvidence"][0]["requests"]:
                row["query"][parameter] = row["finalQuery"][parameter] = "invalid-order"
            assert not network_requests_complete({probe}, changed), (probe, parameter)
    from network_request_contracts import SELECTORS

    for probe, selectors in SELECTORS.items():
        selected = network_trace_fixture({"requiredProbes": [probe]})
        row = selected["requestEvidence"][0]
        assert complete(probe, row["requests"], row["expectedParameters"])
        assert not complete(probe, row["requests"])
        for key in selectors:
            changed = deepcopy(selected)
            for request in changed["requestEvidence"][0]["requests"]:
                mutate_selector_request(request, key)
            assert not network_requests_complete({probe}, changed), (probe, key)
    for key, value in [
        ("endpoint", "https://example.invalid/unrelated"),
        ("method", "POST"),
        ("endpoint", "http://bit101.flwfdd.xyz/reaction/comments"),
        ("statusCode", 500),
        ("query", {"obj": "course1", "page": "0"}),
    ]:
        changed = deepcopy(proof)
        for request in changed["requestEvidence"][0]["requests"]:
            request[key] = value
        assert not network_requests_complete(required, changed)
    changed = deepcopy(proof)
    changed["requestEvidence"][0]["requests"].pop()
    assert not network_requests_complete(required, changed)
    changed = deepcopy(proof)
    changed["requestEvidence"][0]["requests"][1]["query"]["page"] = "0"
    assert not network_requests_complete(required, changed)
    changed["requestEvidence"][0]["requests"][1]["query"]["page"] = "999"
    assert not network_requests_complete(required, changed)
    original = proof["requestEvidence"][0]["requests"]
    for pages in ((0, 99, 1), (0, 1, 1), (0, 1, 3), (0, 1, 2)):
        changed = deepcopy(proof)
        rows = [deepcopy(original[0]) for _ in pages]
        for row, page in zip(rows, pages):
            row["query"]["page"] = row["finalQuery"]["page"] = str(page)
        changed["requestEvidence"][0]["requests"] = rows + [
            deepcopy(row)
            for row in original
            if row["query"].get("order") != original[0]["query"].get("order")
        ]
        assert network_requests_complete(required, changed) == (pages == (0, 1, 2)), pages
    cursors = network_trace_fixture({"requiredProbes": ["message.system"]})
    cursor_probe = cursors["requestEvidence"][0]
    assert complete(cursor_probe["probe"], cursor_probe["requests"])
    nonempty = deepcopy(cursor_probe["requests"])
    nonempty[0]["responseMinimumID"] = "9"
    nonempty[1]["query"]["last_id"] = "9"
    nonempty[1]["finalQuery"]["last_id"] = "9"
    assert complete(cursor_probe["probe"], nonempty)
    for position, invalid in ((0, None), (0, "0"), (1, "0")):
        changed = deepcopy(cursor_probe["requests"])
        if invalid is None:
            changed[position]["query"].pop("last_id")
        else:
            changed[position]["query"]["last_id"] = invalid
        assert not complete(cursor_probe["probe"], changed), (position, invalid)
    for invalid in ("0", "999", None):
        changed = deepcopy(cursor_probe["requests"])
        changed[0]["responseMinimumID"] = invalid
        assert not complete(cursor_probe["probe"], changed)
    for invalid in ("0", "9", "10", None):
        changed = deepcopy(cursor_probe["requests"])
        changed[1]["responseMinimumID"] = invalid
        assert not complete(cursor_probe["probe"], changed), invalid
    writes = network_trace_fixture({"requiredProbes": ["community.writes"]})["requestEvidence"][0][
        "requests"
    ]
    assert complete("community.writes", writes)
    assert sum(row["endpoint"].endswith("/upload/image") for row in writes) == 4
    assert (
        sum(
            row["method"] == "POST" and row["endpoint"].endswith("/reaction/comments")
            for row in writes
        )
        == 9
    )
    for endpoint, method in [("/upload/image", "POST"), ("/reaction/comments/", "DELETE")]:
        index = next(
            index
            for index, row in enumerate(writes)
            if endpoint in row["endpoint"] and row["method"] == method
        )
        assert not complete("community.writes", writes[:index] + writes[index + 1 :])
    for endpoint, method in [
        ("/upload/image", "POST"),
        ("/reaction/comments", "POST"),
        ("/reaction/comments/", "DELETE"),
        ("/reaction/like", "POST"),
        ("/user/follow/", "POST"),
        ("/posters/", "PUT"),
        ("/papers/", "PUT"),
    ]:
        changed = [
            row for row in writes if not (endpoint in row["endpoint"] and row["method"] == method)
        ]
        assert not complete("community.writes", changed), (endpoint, method)
    changed = deepcopy(writes)
    for row in changed:
        if row["method"] == "POST" and row["endpoint"].endswith("/reaction/comments"):
            row["query"]["obj"] = "poster1"
    assert not complete("community.writes", changed)
    for probe, endpoint in [
        ("eclass.authentication", "https://zy-eclass.bit.edu.cn/api/my-courses"),
        ("eclass.ddl", "https://zy-eclass.bit.edu.cn/api/my-courses"),
        ("lexue.calendar", "https://lexue.bit.edu.cn/calendar/export.php"),
    ]:
        request = network_trace_fixture({"requiredProbes": [probe]})["requestEvidence"][0][
            "requests"
        ][0]
        request.update(endpoint=endpoint, finalEndpoint=endpoint)
        assert complete(probe, [request]), probe
        assert not complete(probe, [dict(request, method="GET")]), probe
    for probe in ("eclass.authentication", "eclass.ddl"):
        page = {
            "method": "POST",
            "endpoint": "https://zy-eclass.bit.edu.cn/api/my-courses",
            "statusCode": 200,
            "query": {"page": "1", "page_size": "100", "fields": "id,name", "conditions": "{}"},
            "bodyParameterNames": ["page", "page_size", "fields", "conditions"],
            "finalBodyParameterNames": ["page", "page_size", "fields", "conditions"],
            "responseCourseIDs": ["41", "43"],
            "responseCoursePage": {"page": 1, "pages": 1},
        }
        activities = [
            dict(
                page,
                method="GET",
                query={},
                bodyParameterNames=[],
                finalBodyParameterNames=[],
                endpoint=f"https://zy-eclass.bit.edu.cn/api/courses/{value}/activities",
            )
            for value in (41, 43)
        ]
        assert complete(probe, [page] + activities)
        for key, value in (("page_size", "1"), ("fields", "id"), ("conditions", "[REDACTED]")):
            omitted = {name: val for name, val in page["query"].items() if name != key}
            for field in ("query", "finalQuery"):
                assert not complete(
                    probe, [dict(page, **{field: {**page["query"], key: value}})] + activities
                )
                assert not complete(probe, [dict(page, **{field: omitted})] + activities)
        for rows in (
            [page],
            [page, activities[0]],
            [dict(page, responseCourseIDs=None)] + activities,
            [dict(page, responseCourseIDs=["0"])] + activities,
            [page]
            + activities
            + [
                dict(
                    activities[0], endpoint="https://zy-eclass.bit.edu.cn/api/courses/45/activities"
                )
            ],
            [page, activities[0], dict(activities[1], finalEndpoint=activities[0]["endpoint"])],
        ):
            assert not complete(probe, rows), (probe, rows)
        two_pages = [
            dict(page, responseCourseIDs=["41"], responseCoursePage={"page": 1, "pages": 2}),
            dict(
                page,
                query={**page["query"], "page": "2"},
                responseCourseIDs=["43"],
                responseCoursePage={"page": 2, "pages": 2},
            ),
        ]
        assert complete(probe, two_pages + activities)
        for metadata in (
            None,
            {"page": 99, "pages": 1},
            {"page": 1, "pages": 2},
            {"page": 1, "pages": True},
        ):
            assert not complete(probe, [dict(page, responseCoursePage=metadata)] + activities)
        for rows in (two_pages[:1], two_pages[1:], two_pages[::-1], [two_pages[0], two_pages[0]]):
            assert not complete(probe, rows + activities)
        assert not complete(probe, [dict(page, query={"page": "99"})] + activities)
        assert complete(probe, [dict(page, responseCoursePage={})] + activities)
        assert not complete(
            probe,
            [
                dict(
                    page,
                    responseCourseIDs=[str(value) for value in range(1, 101)],
                    responseCoursePage={},
                )
            ]
            + activities,
        )
        assert complete(probe, [dict(page, responseCourseIDs=[])])
    building = {
        "method": "GET",
        ("endpoint"): (
            "https://jxzxehallapp.bit.edu.cn/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do"
        ),
        "statusCode": 200,
        "query": {"XXXQDM": "campus"},
    }
    assert complete("classroom.buildings", [building], {"XXXQDM": "campus"})
    assert not complete("classroom.buildings", [building])
    for query in ({}, {"XXXQDM": "other"}):
        assert not complete(
            "classroom.buildings", [dict(building, query=query)], {"XXXQDM": "campus"}
        )
        assert not complete(
            "classroom.buildings", [dict(building, finalQuery=query)], {"XXXQDM": "campus"}
        )
    for probe in ("gallery.search", "course.search", "paper.search"):
        trace = network_trace_fixture({"scope": "bit101", "requiredProbes": [probe]})[
            "requestEvidence"
        ][0]
        rows, selected = trace["requests"], trace["expectedParameters"]
        assert complete(probe, rows, selected)
        assert network_requests_complete(
            {probe}, {"requestEvidenceRequired": True, "requestEvidence": [trace]}
        )
        assert not complete(probe, rows, {})
        assert not complete(probe, rows[:1], selected)
        for keyword in selected.values():
            assert not complete(
                probe, [row for row in rows if row["query"].get("search") != keyword], selected
            )
        assert not complete(probe, rows, dict(selected, excludedSearch=selected["search"]))
        for field in ("query", "finalQuery"):
            for keyword in ("", "wrong keyword", None):
                changed = deepcopy(rows)
                for row in changed:
                    update_search_field(row, field, keyword)
                assert not complete(probe, changed, selected), (probe, field, keyword)
    variants = {
        "gallery.newest": {"mode": "search", "order": "new", "uid": "-1"},
        "gallery.following": {"mode": "follow"},
        "gallery.hot": {"mode": "hot"},
        "gallery.recommend": {},
        "gallery.bots": {"mode": "search", "order": "new", "uid": "-1"},
        "gallery.search": {"mode": "search", "order": "new", "uid": "-1", "search": "BIT101"},
        "paper.list.newest": {},
        "paper.list.like": {"order": "like"},
        "paper.list.comment": {"order": "comment"},
    }
    for probe, parameters in variants.items():
        endpoint = "https://bit101.flwfdd.xyz/" + (
            "papers" if probe.startswith("paper.") else "posters"
        )
        queries = (
            [dict(parameters, order=order) for order in ("new", "similar", "like")]
            if probe == "gallery.search"
            else [parameters]
        )
        if probe == "gallery.search":
            queries += [dict(query, search="excludedfixture") for query in queries]
        if probe == "gallery.search":
            queries += gallery_search_queries(parameters)
        requests = [
            {
                "method": "GET",
                "endpoint": endpoint,
                "statusCode": 200,
                "query": dict(query, page=str(page)),
            }
            for query in queries
            for page in (0, 1)
        ]
        assert complete(
            probe,
            requests,
            {"search": "BIT101", "excludedSearch": "excludedfixture"}
            if probe == "gallery.search"
            else None,
        ), probe
        if probe == "gallery.search":
            assert not complete(
                probe, requests[:6], {"search": "BIT101", "excludedSearch": "excludedfixture"}
            )
        for key in ("limit", "claim_id", "tags"):
            for field in ("query", "finalQuery"):
                changed = deepcopy(requests)
                for row in changed:
                    row[field] = dict(row.get(field, row["query"]), **{key: "[REDACTED]"})
                assert not complete(probe, changed), (probe, key, field)
        for extra in (
            dict(requests[-1], query=dict(parameters, page="2", order="unexpected")),
            dict(requests[-1], statusCode=500),
            dict(requests[-1], endpoint="https://example.invalid/other"),
        ):
            assert not complete(probe, requests + [extra]), (probe, extra)
        for key in (
            ("order", "search")
            if probe.startswith("paper.")
            else ("mode", "order", "uid", "search", "hide_bot")
        ):
            changed = deepcopy(requests)
            for row in changed:
                if key in row["query"]:
                    row["query"].pop(key)
                else:
                    row["query"][key] = "unexpected"
            assert not complete(probe, changed), (probe, key)
    assert not complete("paper.list.未知", requests)
    for probe, endpoint in [
        ("web.share-icon", "https://open.aihelpme.dev/share-icon.jpg"),
        ("web.association", "https://open.aihelpme.dev/.well-known/apple-app-site-association"),
        ("lexue.ddl", "https://lexue.bit.edu.cn/calendar/export_execute.php"),
    ]:
        row = {"method": "GET", "endpoint": endpoint, "statusCode": 200, "query": {}}
        assert complete(probe, [row])
        for field in ("endpoint", "finalEndpoint"):
            altered = endpoint[: endpoint.index("/", 8)] + endpoint[
                endpoint.index("/", 8) :
            ].replace(".", "X")
            assert not complete(probe, [dict(row, **{field: altered})]), (probe, field)
    for probe, parameters, selectors in [
        ("paper.list", {}, None),
        ("profile.posts", {"mode": "search", "uid": "0"}, {"uid": "0"}),
        ("user.posts", {"mode": "search", "uid": "42"}, {"uid": "42"}),
    ]:
        endpoint = "https://bit101.flwfdd.xyz/" + (
            "papers" if probe.startswith("paper.") else "posters"
        )
        rows = [
            {
                "method": "GET",
                "endpoint": endpoint,
                "statusCode": 200,
                "query": dict(parameters, page=str(page)),
            }
            for page in (0, 1)
        ]
        assert complete(probe, rows, selectors), probe
        for key, value in [("order", "hot"), ("search", "BIT101")]:
            changed = deepcopy(rows)
            for row in changed:
                row["query"][key] = value
            assert not complete(probe, changed, selectors), (probe, key)
            changed = deepcopy(rows)
            for row in changed:
                row["finalQuery"] = dict(row["query"], **{key: value})
            assert not complete(probe, changed, selectors), (probe, key, "redirect")
    for probe, paths, expected in [
        (
            "schedule.sync",
            [
                "/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do",
                "/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do",
                "/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do",
            ],
            {"XNXQDM": "2025-2026-1"},
        ),
        (
            "classroom.occupancy",
            ["/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do"],
            {
                "XNXQDM": "2025-2026-1",
                "JXLDM": "fixture-building",
                "RQ": "2026-09-07",
                "XQDM": "1",
                "XNDM": "2025-2026",
            },
        ),
    ]:
        rows = network_trace_fixture(
            {"requiredProbes": [probe], "validatedTerm": expected["XNXQDM"]}
        )["requestEvidence"][0]["requests"]
        for row, path in zip(rows, paths):
            row.update(
                endpoint="https://jxzxehallapp.bit.edu.cn" + path,
                finalEndpoint="https://jxzxehallapp.bit.edu.cn" + path,
                query=dict(expected),
                finalQuery=dict(expected),
            )
        assert complete(probe, rows, expected) and not complete(probe, rows)
        for key in expected:
            for field in ("query", "finalQuery"):
                changed = deepcopy(rows)
                changed[0][field] = dict(
                    changed[0]["query"], **{key: "2026-09-06" if key == "RQ" else "wrong-selection"}
                )
                assert not complete(probe, changed, expected)
                changed[0][field].pop(key)
                assert not complete(probe, changed, expected)
        if not (probe == "classroom.occupancy"):
            continue
        for key, value in [("RQ", "2026-02-30"), ("XQDM", "2"), ("XNDM", "2024-2025")]:
            changed = {**expected, key: value}
            assert not complete(
                probe, [dict(row, query=changed, finalQuery=changed) for row in rows], changed
            ), key
    login = {
        "method": "GET",
        "endpoint": "https://bit101.flwfdd.xyz/user/check",
        "statusCode": 200,
        "query": {},
    }
    paper = dict(login, endpoint="https://bit101.flwfdd.xyz/papers/17")
    comments = [
        dict(
            login,
            endpoint="https://bit101.flwfdd.xyz/reaction/comments",
            query={"obj": "paper17", "order": order, "page": str(page)},
        )
        for order in ("new", "old", "like")
        for page in (0, 1)
    ]
    assert not complete("paper.comments", [login] + comments[:2], {"obj": "paper17"})
    for probe, requests, selectors in [
        ("paper.detail", [login, paper], {"path": "/papers/17"}),
        ("paper.comments", [login, comments[0], login] + comments[1:], {"obj": "paper17"}),
    ]:
        assert complete(probe, requests, selectors), probe
        assert complete(probe, [row for row in requests if row is not login], selectors), probe
        assert complete(probe, [dict(login, statusCode=401)] + requests, selectors), probe
        assert not complete(probe, [login], selectors), probe
        for broken in (
            dict(login, statusCode=500),
            dict(login, statusCode=401),
            dict(login, method="POST"),
            dict(login, endpoint="https://example.invalid/user/check"),
            dict(login, endpoint="https://bit101.flwfdd.xyz/user/unrelated"),
        ):
            assert not complete(probe, requests + [broken], selectors), (probe, broken)
    write_reads = [
        login,
        dict(login, endpoint="https://bit101.flwfdd.xyz/user/info/0"),
        dict(login, endpoint="https://bit101.flwfdd.xyz/user/info/18"),
        dict(login, endpoint="https://bit101.flwfdd.xyz/courses/3"),
        dict(login, endpoint="https://bit101.flwfdd.xyz/posters/1"),
        paper,
        dict(
            login,
            endpoint="https://bit101.flwfdd.xyz/posters",
            query={"mode": "search", "uid": "0", "page": "0"},
        ),
        dict(
            login,
            endpoint="https://bit101.flwfdd.xyz/papers",
            query={"search": "功能验收", "page": "0"},
        ),
        dict(
            login,
            endpoint="https://bit101.flwfdd.xyz/reaction/comments",
            query={"obj": "paper17", "order": "old", "page": "0"},
        ),
    ]
    assert complete("community.writes", write_reads + writes)
    assert not complete("community.writes", write_reads)
    for row in write_reads:
        assert not complete("community.writes", writes + [dict(row, statusCode=500)]), row
    assert not complete(
        "community.writes",
        writes + [dict(login, endpoint="https://bit101.flwfdd.xyz/user/unrelated")],
    )
    assert complete("community.login", [dict(login, statusCode=401), login])
    assert not complete("community.login", [login, dict(login, statusCode=401)])
    assert not complete("community.login", [dict(login, statusCode=500), login])
    assert not complete(
        "community.login", [dict(login, statusCode=401, query={"order": "old"}), login]
    )
    authentication = dict(
        login,
        method="POST",
        endpoint="https://bit101.flwfdd.xyz/user/webvpn_verify",
        **{
            field: ["sid", "password", "execution", "cookie", "salt", "captcha"]
            for field in ("bodyParameterNames", "finalBodyParameterNames")
        },
    )
    assert complete("community.login", [dict(login, statusCode=401), authentication, login])
    assert not complete(
        "community.login",
        [dict(login, statusCode=401), dict(authentication, statusCode=500), login],
    )
    teaching = {
        "method": "GET",
        "endpoint": "https://jxzxehallapp.bit.edu.cn/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do",
        "statusCode": 200,
        "query": {},
    }
    preheat = dict(
        teaching,
        endpoint="https://jxzxehallapp.bit.edu.cn/jwapp/i18n.do",
        query={"appName": "wdkbby", "EMAP_LANG": "zh"},
    )
    for query in (
        {"appName": "other", "EMAP_LANG": "zh"},
        {"appName": "wdkbby", "EMAP_LANG": "en"},
        {},
    ):
        assert not complete("schedule.current-term", [dict(preheat, query=query), teaching])
    gate = dict(
        teaching,
        endpoint="https://sso.bit.edu.cn/gate/cas-success/",
        statusCode=401,
        query={"ticket": "[REDACTED]"},
    )
    assert complete(
        "eclass.authentication",
        [gate]
        + network_trace_fixture({"requiredProbes": ["eclass.authentication"]})["requestEvidence"][
            0
        ]["requests"],
    )
    lexue = network_trace_fixture({"requiredProbes": ["lexue.calendar"]})["requestEvidence"][0][
        "requests"
    ]
    vpn = dict(
        teaching,
        endpoint="https://webvpn.bit.edu.cn/https/a/",
        finalEndpoint="https://webvpn.bit.edu.cn/https/b/cas/login",
        finalQuery={"service": "[REDACTED]"},
    )
    assert complete("lexue.calendar", [vpn] + lexue)
    assert not complete(
        "lexue.calendar", [dict(vpn, finalEndpoint="https://example.invalid/cas/login")] + lexue
    )
    cookies = dict(
        authentication,
        endpoint="https://login.bit101.flwfdd.xyz/api/jxzxehall/cookies",
        **{
            field: ["username", "password"]
            for field in ("bodyParameterNames", "finalBodyParameterNames")
        },
    )
    assert complete("schedule.current-term", [cookies, preheat, teaching])
    redirected = dict(
        teaching, finalEndpoint="https://sso.bit.edu.cn/cas/login", finalMethod="GET", finalQuery={}
    )
    assert complete("schedule.current-term", [redirected, cookies, preheat, teaching])
    assert not complete("schedule.current-term", [redirected, cookies, preheat])
    assert not complete(
        "schedule.current-term",
        [dict(redirected, finalEndpoint="https://example.invalid/cas/login"), cookies, teaching],
    )
    assert not complete(
        "schedule.current-term", [dict(redirected, statusCode=500), cookies, teaching]
    )
    assert complete(
        "schedule.current-term", [dict(cookies, statusCode=503), cookies, preheat, teaching]
    )
    assert not complete("schedule.current-term", [cookies, dict(preheat, statusCode=500), teaching])
    transcript = network_trace_fixture({"requiredProbes": ["score.transcript"]})["requestEvidence"][
        0
    ]
    page = {
        "method": "GET",
        "endpoint": "https://jwb.bit.edu.cn/cjd/Temp/page.jpg",
        "statusCode": 200,
        "query": {},
    }
    assert complete("score.transcript", transcript["requests"] + [page])
    for field in ("query", "finalQuery"):
        for value in (None, "true", "0", "[REDACTED]"):
            broken = deepcopy(transcript["requests"])
            request = next(row for row in broken if row["endpoint"].endswith("/cjd/cookies"))
            query = dict(request.get(field, request["query"]))
            if value is None:
                query.pop("detailed", None)
            else:
                query["detailed"] = value
            request[field] = query
            assert not complete("score.transcript", broken)
    assert not complete("score.transcript", transcript["requests"] + [dict(page, statusCode=500)])
    assert complete(
        "community.login", [dict(login, endpoint="https://bit101.flwfdd.xyz:443/user/check")]
    )
    for port in ("0", "80", "8443", "65536", "invalid"):
        assert not complete(
            "community.login",
            [dict(login, endpoint="https://bit101.flwfdd.xyz:" + port + "/user/check")],
        )
    media = network_trace_fixture({"requiredProbes": ["gallery.image"]})["requestEvidence"][0]
    import hashlib

    resource = "https://image.invalid:8443/image.png"
    digest = hashlib.sha256(resource.encode()).hexdigest()
    assert complete(
        "gallery.image",
        [
            dict(
                media["requests"][0],
                endpoint=resource,
                finalEndpoint=resource,
                endpointDigest=digest,
            )
        ],
        {"resourceDigests": digest},
    )
    for status in (100, 302, 401, 403, 500):
        assert not complete("community.login", [dict(login, statusCode=status)])
    assert not complete(
        "community.login", [dict(login, endpoint=login["endpoint"].replace("https:", "http:"))]
    )
    account = dict(login, endpoint="https://bit101.flwfdd.xyz/user/info/0")
    phases = [account, dict(account, statusCode=401), account]
    assert complete("community.session", phases)
    for statuses in (
        (200, 200, 200),
        (401, 200, 200),
        (200, 401, 500),
        (200, 403, 200),
        (200, 401),
        (200, 401, 200, 200),
    ):
        assert not complete(
            "community.session", [dict(account, statusCode=status) for status in statuses]
        )


def native_school_request_contracts_self_test() -> None:
    from network_request_contracts import complete, auxiliary_contracts, NATIVE_CONTRACTS

    def request(path, *, host="jwms.bit.edu.cn", method="GET", status=200, body=(), query=None):
        endpoint = "https://" + host + path
        return dict(
            endpoint=endpoint,
            finalEndpoint=endpoint,
            method=method,
            finalMethod=method,
            statusCode=status,
            query=query or {},
            finalQuery=query or {},
            bodyParameterNames=list(body),
            finalBodyParameterNames=list(body),
        )

    landing = request("/jsxsd/framework/main.jsp")
    grades = request("/jsxsd/kscj/cjcx_list", method="POST", body=("kksj", "kcxz", "kcmc", "xsfs"))
    detail = request("/jsxsd/kscj/cjpm_list.do", query={"id": "[REDACTED]"})
    cas = request("/cas/login", host="sso.bit.edu.cn", status=302, query={"service": "[REDACTED]"})
    assert complete("score.authentication", [cas, landing])
    assert complete("score.brief", [grades])
    assert complete("score.detail", [grades, detail])
    session_redirect = request(
        "/http/abcdef/;jsessionid=fixture-session", host="webvpn.bit.edu.cn", status=302
    )
    assert complete("score.authentication", [session_redirect, landing])
    assert not complete("score.authentication", [session_redirect])
    analysis = request(
        "/http/abcdef/jsxsd/kscj/cjfx", host="webvpn.bit.edu.cn", query={"kch": "[REDACTED]"}
    )
    assert complete("score.detail", [grades, analysis])
    assert complete("score.detail", [analysis])
    assert not complete("score.detail", [dict(analysis, statusCode=500)])
    assert not complete(
        "score.detail", [dict(analysis, finalEndpoint="https://outside.invalid/score")]
    )
    for probe in ("school.session", "schedule.teaching-center"):
        trace = network_trace_fixture({"requiredProbes": [probe]})["requestEvidence"][0]
        callbacks = [
            request("/auth-protocol-core/loginSuccess", host="jxzxehall.bit.edu.cn", status=302),
            request(
                "/jwapp/sys/wdkbby/*default/index.do", host="jxzxehallapp.bit.edu.cn", status=302
            ),
            request("/jwapp/sys/wdkbby/*default/index.do", host="jxzxehallapp.bit.edu.cn"),
        ]
        assert complete(probe, trace["requests"] + callbacks, trace["expectedParameters"])
        assert not complete(
            probe,
            trace["requests"]
            + [dict(callbacks[0], finalEndpoint="https://outside.invalid/callback")],
            trace["expectedParameters"],
        )
    for probe in ("score.brief", "score.detail"):
        assert not complete(probe, [dict(grades, bodyParameterNames=["xsfs"])])
        assert not complete(probe, [dict(grades, finalBodyParameterNames=["xsfs"])])
        assert not complete(probe, [dict(grades, statusCode=500)])
        assert not complete(
            probe,
            [
                request(
                    "/jsxsd/kscj/cjcx_list",
                    host="outside.invalid",
                    method="POST",
                    body=("kksj", "kcxz", "kcmc", "xsfs"),
                )
            ],
        )
    assert not complete("score.detail", [detail])
    entry = request("/cjd/Account/ExternalLogin", host="jwb.bit.edu.cn", status=302)
    report = request("/cjd/ScoreReport2/Index", host="jwb.bit.edu.cn", query={"GPA": "1"})
    page = request("/cjd/Temp/page.jpg", host="jwb.bit.edu.cn")
    assert complete("score.transcript", [entry, cas, report, page])
    assert not complete("score.transcript", [entry, cas, report, dict(page, statusCode=500)])
    assert not complete("score.transcript", [entry, cas, dict(report, query={"GPA": "0"}), page])
    risk = next(
        contract
        for contract in auxiliary_contracts(
            "score.authentication", NATIVE_CONTRACTS["score.authentication"]
        )
        if contract.path == "/ustc-rba-front/fp"
    )
    fingerprint = request(
        risk.path, host="sso.bit.edu.cn", method="POST", status=404, body=risk.body_parameters
    )
    assert complete("score.authentication", [fingerprint, cas, landing])
    assert not complete("score.authentication", [dict(fingerprint, statusCode=500), cas, landing])
    assert not complete("score.authentication", [fingerprint, cas])
    courses = network_trace_fixture({"requiredProbes": ["eclass.authentication"]})[
        "requestEvidence"
    ][0]["requests"]
    index = request("/user/index", host="zy-eclass.bit.edu.cn")
    redirected = dict(
        index,
        finalEndpoint="https://sso.bit.edu.cn/cas//login",
        finalQuery={"service": "[REDACTED]"},
    )
    sms = request(
        "/cas//login",
        host="sso.bit.edu.cn",
        method="POST",
        body=("username", "password", "type", "trustDevice"),
        query={"service": "[REDACTED]", "type": "smsLogin"},
    )
    sms.update(
        finalEndpoint=index["endpoint"],
        finalMethod="GET",
        finalQuery={},
        finalBodyParameterNames=[],
    )
    recovered = [dict(courses[0], statusCode=401), redirected, sms, index] + courses
    assert complete("eclass.authentication", recovered, allow_sms=True)
    assert not complete("eclass.authentication", recovered)
    assert not complete("eclass.authentication", [redirected, sms, index], allow_sms=True)
    assert not complete(
        "eclass.authentication",
        [dict(sms, finalEndpoint="https://outside.invalid/")] + courses,
        allow_sms=True,
    )
