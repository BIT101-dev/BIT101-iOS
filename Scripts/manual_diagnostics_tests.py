"""Checks for device diagnostic evidence and report attachments."""

from contextlib import nullcontext
import copy
from io import BytesIO
import json
from pathlib import Path
from unittest.mock import patch
from manual_sample_tests import evidence_fixture


def manual_diagnostics_self_test() -> None:
    from validation_manual import (
        MANUAL_SCENARIOS,
        manual_structure,
        manual_evidence_problem,
        scenario_complete,
    )

    for check in MANUAL_SCENARIOS:
        assert set(manual_structure(check)["scenarios"]) == MANUAL_SCENARIOS[check]
    proof = json.loads(evidence_fixture("photos"))
    name = next(iter(proof["scenarios"]))
    changed = copy.deepcopy(proof)
    changed["scenarios"][name]["evidence"].pop("path")
    assert f"scenarios.{name}.evidence.path" in manual_evidence_problem(
        "photos", json.dumps(changed).encode()
    )
    changed = copy.deepcopy(proof)
    changed["application"].pop("executableUUIDs")
    assert "application.executableUUIDs" in manual_evidence_problem(
        "photos", json.dumps(changed).encode()
    )
    changed = copy.deepcopy(proof)
    changed["scenarios"][name]["outcome"] = "failed"
    with patch("validation_manual.application_identity_complete", return_value=True):
        assert f"scenarios.{name}:" in manual_evidence_problem(
            "photos", json.dumps(changed).encode()
        )
    assert "JSON" in manual_evidence_problem("photos", b"{")
    assert not scenario_complete("photos", proof | {"schemaVersion": True})


def image_resource_self_test() -> None:
    import hashlib
    from network_request_contracts import complete

    def request(url):
        from urllib.parse import urlsplit

        parts = urlsplit(url)
        endpoint = parts._replace(query="", fragment="").geturl()
        return dict(
            method="GET",
            endpoint=endpoint,
            endpointDigest=hashlib.sha256(url.encode()).hexdigest(),
            finalMethod="GET",
            finalEndpoint=endpoint,
            statusCode=200,
            query={},
            finalQuery={},
        )

    urls = ["https://cdn.example/image.png?token=first", "https://cdn.example/other.png"]
    rows = [request(url) for url in urls]
    expected = {"resourceDigests": ",".join(sorted(row["endpointDigest"] for row in rows))}
    for probe in ("gallery.image", "paper.image"):
        assert complete(probe, rows, expected)
        assert not complete(probe, rows, {})
        assert not complete(probe, rows[:1], expected)
        assert not complete(probe, [request("https://unrelated.example/wrong-image.png")], expected)
        assert not complete(probe, [request(urls[0].replace("first", "second")), rows[1]], expected)
        assert not complete(probe, rows + [request("https://cdn.example/extra.png")], expected)


def report_budget_self_test(module) -> None:
    for limit, accepted in ((16, False), (64, True)):
        stream = BytesIO()
        with (
            patch("validation_policy.MAXIMUM_REPORT_BYTES", limit),
            patch.object(Path, "open", return_value=nullcontext(stream)),
            patch.object(Path, "replace") as committed,
            patch.object(Path, "unlink") as cleanup,
        ):
            try:
                module.write_report({"evidence": "x" * 17})
            except ValueError:
                assert not accepted
            else:
                assert accepted and json.loads(stream.getvalue()) == {"evidence": "x" * 17}
            assert committed.called == accepted
            assert stream.tell() <= limit
            cleanup.assert_called_once_with(missing_ok=True)
    import shutil

    fixture = module.ROOT / ".build/static-audit/report-write-self-test"
    fixture.mkdir(parents=True, exist_ok=True)
    destination = fixture / "report.json"
    original = json.dumps({"runID": "retained-cloud-owner", "stages": []}).encode()
    try:
        for failure in ("write", "replace"):
            destination.write_bytes(original)
            original_open = Path.open

            class InterruptedStream:
                def __enter__(self):
                    self.stream = original_open(destination.with_suffix(".incoming"), "wb")
                    return self

                def write(self, data):
                    self.stream.write(data[:1])
                    raise OSError("interrupted report write")

                def __exit__(self, *args):
                    self.stream.close()

            override = (
                patch.object(Path, "open", return_value=InterruptedStream())
                if failure == "write"
                else patch.object(Path, "replace", side_effect=OSError("interrupted report commit"))
            )
            with override:
                try:
                    module.write_report({"runID": "new-owner", "stages": []}, path=destination)
                except OSError:
                    pass
                else:
                    raise AssertionError("写入故障需要保留原恢复记录")
            assert destination.read_bytes() == original
            assert json.loads(destination.read_text())["runID"] == "retained-cloud-owner"
            assert not destination.with_suffix(".incoming").exists()
        module.write_report({"runID": "new-owner", "stages": []}, path=destination)
        assert json.loads(destination.read_text())["runID"] == "new-owner"
    finally:
        shutil.rmtree(fixture)
