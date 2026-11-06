"""Checks for redirected request identity and query validation."""

from network_fixture_tests import network_trace_fixture


def verify_final_redirect_queries(complete, login, page, transcript):
    from network_request_contracts import CONTRACTS, contracts_for
    from copy import deepcopy

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
