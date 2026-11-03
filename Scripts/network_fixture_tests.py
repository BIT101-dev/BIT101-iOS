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


def network_trace_fixture(value: dict) -> dict:
    from network_request_contracts import community, contracts_for, SELECTORS, VISIBLE_PARAMETERS

    value["workerDeployments"] = worker_deployment_fixture(value.get("scope"))

    def example(pattern, identifier=1):
        import re

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
            for index in range(max(contract.minimum, 2 if contract.paging else 1)):
                query = {
                    key: example(pattern) if key in VISIBLE_PARAMETERS else "[REDACTED]"
                    for key, pattern in contract.query.items()
                    if pattern is not None
                }
                query.update(
                    {
                        key: item
                        for key, item in expected.items()
                        if key not in {"path", "excludedSearch"}
                        and (key != "search" or "excludedSearch" not in expected)
                        and (name != "gallery.search" or contract.query.get(key) is not None)
                    }
                )
                if contract.paging == "page":
                    query["page"] = str(index)
                if contract.paging == "last_id":
                    query["last_id"] = str(sys.maxsize) if index == 0 else "9"
                request = {
                    "method": contract.method,
                    "endpoint": "https://" + example(contract.host) + example(contract.path),
                    "statusCode": next(iter(contract.statuses)),
                    "query": query,
                    "bodyParameterNames": sorted(
                        contract.required_body_parameters
                        | (
                            contract.body_parameter_variants[0]
                            if contract.body_parameter_variants
                            else frozenset()
                        )
                    ),
                    "finalBodyParameterNames": sorted(
                        contract.required_body_parameters
                        | (
                            contract.body_parameter_variants[0]
                            if contract.body_parameter_variants
                            else frozenset()
                        )
                    ),
                }
                if contract.paging == "last_id":
                    request["responseMinimumID"] = "9" if index == 0 else "1"
                if name in {"eclass.authentication", "eclass.ddl"}:
                    query["page"] = "1"
                    request.update(responseCourseIDs=[], responseCoursePage={"page": 1, "pages": 1})
                if name == "update.emergency":
                    request["responseConfiguration"] = emergency_configuration_fixture()
                if name == "community.writes":
                    if contract.path == "/posters" and contract.method == "GET":
                        query["page"] = str(index)
                    if contract.path == "/reaction/like" and query["obj"].startswith("comment"):
                        query["obj"] = "comment" + str(index // 2 + 1)
                    if contract.method == "DELETE" and contract.path == r"/reaction/comments/\d+":
                        request["endpoint"] = (
                            "https://" + example(contract.host) + example(contract.path, index + 1)
                        )
                    if (
                        contract.method == "POST"
                        and contract.path == "/reaction/comments"
                        and query["obj"].startswith("comment")
                    ):
                        query["obj"] = "comment" + str(index // 2 + 1)
                        for field in ("bodyParameterNames", "finalBodyParameterNames"):
                            request[field] += ["reply_obj", "reply_uid"] if index % 2 else []
                request.update(
                    finalEndpoint=(
                        "https://" + example(contract.final_host) + example(contract.final_path)
                    )
                    if contract.final_host
                    else request["endpoint"],
                    finalMethod=request["method"],
                    finalQuery=dict(query),
                )
                assert contract.matches(request), (name, request)
                for key in SELECTORS.get(name, set()) - set(expected):
                    from urllib.parse import unquote, urlsplit

                    expected[key] = (
                        unquote(urlsplit(request["endpoint"]).path)
                        if key == "path"
                        else request["query"][key]
                    )
                requests.append(request)
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
