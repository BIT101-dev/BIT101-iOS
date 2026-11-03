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


def community_recovery_contract_self_test() -> None:
    from copy import deepcopy
    from network_request_contracts import cleanup_requests_complete, complete

    source = (
        Path(__file__).resolve().parents[1] / "BIT101-iOSTests/NetworkSessionIsolationTests.swift"
    ).read_text()
    from swift_source_index import swift_syntax_index_sources

    facts = swift_syntax_index_sources({"fixture.swift": source})["fixture.swift"]
    declaration = re.search(r"static\s+let\s+recovery\s*=", source)
    start = len(source[: declaration.end()].encode())
    literal = next(row for row in facts["styleLiterals"] if row["start"] >= start)
    fixture = json.loads(literal["value"])

    def evidence(row):
        value = {key: item for key, item in row.items() if key != "responseBody"}
        value.update(
            finalMethod=row["method"], finalEndpoint=row["endpoint"], finalQuery=dict(row["query"])
        )
        return value

    accepted = [evidence(row) for row in fixture["accepted"]]
    assert cleanup_requests_complete(accepted)
    from validation_provenance import network_requests_complete

    cleanup = network_trace_fixture(
        {"scope": "community-cleanup", "requiredProbes": ["community.login", "community.writes"]}
    )
    assert network_requests_complete(
        set(cleanup["requiredProbes"]), cleanup | {"requestEvidenceRequired": True}
    )
    missing = dict(
        cleanup, requestEvidence=cleanup["requestEvidence"][:1], requestEvidenceRequired=True
    )
    assert not network_requests_complete(set(cleanup["requiredProbes"]), missing)
    assert not cleanup_requests_complete(accepted[1:])
    writes = network_trace_fixture({"requiredProbes": ["community.writes"]})["requestEvidence"][0][
        "requests"
    ]
    assert complete("community.writes", writes + accepted)
    assert not cleanup_requests_complete(accepted + writes)
    for row in fixture["rejected"]:
        assert not cleanup_requests_complete(accepted + [evidence(row)])
        assert not complete("community.writes", writes + [evidence(row)])
    for index, row in enumerate(accepted):
        if row.get("responseContentMissing") is not True:
            continue
        altered = deepcopy(accepted)
        altered[index].pop("responseContentMissing")
        assert not cleanup_requests_complete(altered)
        assert not complete("community.writes", writes + [altered[index]])


def _pattern_example(pattern: str, identifier: int = 1) -> str:
    pattern = re.sub(r"\(\?:([^()]*)\)", lambda match: match[1].split("|")[0], pattern)
    return (
        pattern.replace("[0-9a-f]+", "a")
        .replace(r"[1-9]\d*", str(identifier))
        .replace(r"\d+", str(identifier))
        .replace(r"\.", ".")
        .replace(r"\-", "-")
        .replace(r"\+", "+")
        .replace(r"\{", "{")
        .replace(r"\}", "}")
        .replace(".+", "fixture")
        .replace("?", "")
    )


def _build_initial_query(contract, expected, name, visible_params):
    query = {}
    for key, pattern in contract.query.items():
        if pattern is not None:
            query[key] = _pattern_example(pattern) if key in visible_params else "[REDACTED]"
    for key, item in expected.items():
        if (
            key not in {"path", "excludedSearch"}
            and (key != "search" or "excludedSearch" not in expected)
            and (name != "gallery.search" or contract.query.get(key) is not None)
        ):
            query[key] = item
    return query


def _adjust_community_writes(contract, index, query, request):
    if contract.path == "/posters" and contract.method == "GET":
        query["page"] = str(index)
    if contract.path == "/reaction/like" and query["obj"].startswith("comment"):
        query["obj"] = "comment" + str(index // 2 + 1)
    if contract.method == "DELETE" and contract.path == r"/reaction/comments/\d+":
        path = _pattern_example(contract.path, index + 1)
        request["endpoint"] = "https://" + _pattern_example(contract.host) + path
    if (
        contract.method == "POST"
        and contract.path == "/reaction/comments"
        and query["obj"].startswith("comment")
    ):
        query["obj"] = "comment" + str(index // 2 + 1)
        suffix = ["reply_obj", "reply_uid"] if index % 2 else []
        request["bodyParameterNames"] += suffix
        request["finalBodyParameterNames"] += suffix


def _record_expected_selectors(name, expected, request, selectors_map):
    from urllib.parse import unquote, urlsplit

    for key in selectors_map.get(name, set()) - set(expected):
        if key == "path":
            expected[key] = unquote(urlsplit(request["endpoint"]).path)
        else:
            expected[key] = request["query"][key]


def _build_fixture_request(name, contract, index, expected, visible_params, selectors_map):
    query = _build_initial_query(contract, expected, name, visible_params)
    if contract.paging == "page":
        query["page"] = str(index)
    elif contract.paging == "last_id":
        query["last_id"] = str(sys.maxsize) if index == 0 else "9"
    body_variants = (
        contract.body_parameter_variants[0]
        if contract.body_parameter_variants
        else frozenset()
    )
    body_params = sorted(contract.required_body_parameters | body_variants)
    host = _pattern_example(contract.host)
    path = _pattern_example(contract.path)
    request = {
        "method": contract.method,
        "endpoint": f"https://{host}{path}",
        "statusCode": next(iter(contract.statuses)),
        "query": query,
        "bodyParameterNames": list(body_params),
        "finalBodyParameterNames": list(body_params),
    }
    if contract.paging == "last_id":
        request["responseMinimumID"] = "9" if index == 0 else "1"
    if name in {"eclass.authentication", "eclass.ddl"}:
        query["page"] = "1"
        request.update(responseCourseIDs=[], responseCoursePage={"page": 1, "pages": 1})
    if name == "update.emergency":
        request["responseConfiguration"] = emergency_configuration_fixture()
    if name == "community.writes":
        _adjust_community_writes(contract, index, query, request)
    final_endpoint = (
        f"https://{_pattern_example(contract.final_host)}{_pattern_example(contract.final_path)}"
        if contract.final_host
        else request["endpoint"]
    )
    request.update(
        finalEndpoint=final_endpoint,
        finalMethod=request["method"],
        finalQuery=dict(query),
    )
    assert contract.matches(request), (name, request)
    _record_expected_selectors(name, expected, request, selectors_map)
    return request


def network_trace_fixture(value: dict) -> dict:
    from network_request_contracts import community, contracts_for, SELECTORS, VISIBLE_PARAMETERS

    value["workerDeployments"] = worker_deployment_fixture(value.get("scope"))

    rows = []
    for name in value.get("requiredProbes", []):
        requests = []
        expected = (
            {"XNXQDM": value.get("validatedTerm", "fixture-current")}
            if name in {"schedule.sync", "classroom.occupancy"}
            else {}
        )
        if name in {"gallery.search", "course.search", "paper.search"}:
            expected = {"search": "fixture", "excludedSearch": "excludedfixture"}
        contracts = (
            [community("/user/info/0"), community(r"/posters/\d+", method="DELETE")]
            if value.get("scope") == "community-cleanup" and name == "community.writes"
            else contracts_for(name, expected)
        )
        assert contracts, name
        if name == "classroom.occupancy":
            year, _, semester = expected["XNXQDM"].rpartition("-")
            expected.update(JXLDM="fixture-building", RQ="2026-09-07", XQDM=semester, XNDM=year)
        for contract in contracts:
            repeat = max(contract.minimum, 2 if contract.paging else 1)
            for index in range(repeat):
                req = _build_fixture_request(
                    name, contract, index, expected, VISIBLE_PARAMETERS, SELECTORS
                )
                requests.append(req)
        if name == "community.session":
            requests.insert(1, requests.pop())
        if name in {"gallery.image", "paper.image"}:
            import hashlib

            for request in requests:
                request["endpointDigest"] = hashlib.sha256(request["endpoint"].encode()).hexdigest()
            expected["resourceDigests"] = ",".join(
                sorted({request["endpointDigest"] for request in requests})
            )
        rows.append({"probe": name, "requests": requests, "expectedParameters": expected})
    value["requestEvidenceRequired"] = True
    value["requestEvidence"] = rows
    return value
