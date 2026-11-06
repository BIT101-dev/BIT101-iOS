"""Focused checks for validation batch tests."""

from copy import deepcopy
import json
from pathlib import Path
import shutil
import subprocess
from unittest.mock import patch
import validation_performance as subject


def batch_fault_expected_bytes(fault: str) -> bytes:
    if fault == "current-only":
        return b"previouscurrent"
    merged_faults = {
        "current",
        "merged",
        "current-merged",
        "published-current",
        "published-missing",
    }
    if fault in merged_faults:
        return b"merged"
    return b"previous"


def setup_batch_fault_fixture(bundle, retained, incoming, fault, create):
    for path in (bundle, retained, incoming):
        shutil.rmtree(path, ignore_errors=True)
    create(retained, b"previous")
    create(incoming, b"merged")
    if fault.startswith("current") or fault == "published-current":
        create(bundle, b"current")
        if fault in {"current-partial", "current-merged"}:
            (bundle / "Staging").mkdir()
        if fault == "current-missing":
            (bundle / "database.sqlite3").unlink()
    if fault in {"retained", "current-only"}:
        shutil.rmtree(incoming)
    if fault.startswith("published"):
        shutil.rmtree(retained)
    if fault in {"partial", "current-partial", "current-missing"}:
        (incoming / "Staging").mkdir()


def verify_retain_failure_recovery(
    subject,
    failure,
    bundle,
    retained,
    incoming,
    create,
    report_path,
    writer,
    merge,
    exported,
):
    for path in (bundle, retained, incoming):
        shutil.rmtree(path, ignore_errors=True)
    create(retained, b"previous")
    create(bundle, b"failed")
    writer.reset_mock()

    def failing_merge(command, **kwargs):
        if failure != "summary":
            create(incoming, b"partial")
            if failure == "interrupt":
                raise KeyboardInterrupt()
            raise subprocess.CalledProcessError(1, command)
        merge(command, **kwargs)

    def failing_export(command, **kwargs):
        if failure == "summary" and str(incoming) in command:
            raise subprocess.CalledProcessError(1, command)
        return exported(command, **kwargs)

    with (
        patch.object(subject.subprocess, "run", side_effect=failing_merge),
        patch.object(subject.subprocess, "check_output", side_effect=failing_export),
    ):
        try:
            subject.retain_result_step(["all", "ui"])
        except (subprocess.CalledProcessError, KeyboardInterrupt):
            pass
        else:
            raise AssertionError("结果合并失败与中断需要传播")
    assert json.loads(report_path.read_text())["resultMerge"]["groups"] == ["all", "ui"]
    assert bundle.is_dir() and retained.is_dir() and not incoming.exists()
    assert (bundle / "database.sqlite3").read_bytes() == b"failed"
    assert (retained / "database.sqlite3").read_bytes() == b"previous"
    subject.recover_result_step()
    assert (bundle / "database.sqlite3").read_bytes() == b"previousfailed"
    subject.recover_result_step()
    assert (bundle / "database.sqlite3").read_bytes() == b"previousfailed"


def verify_retain_interrupted_recovery(
    subject,
    interrupted,
    bundle,
    retained,
    incoming,
    create,
    remove,
    move,
    report_path,
    writer,
):
    for path in (bundle, retained, incoming):
        remove(path, ignore_errors=True)
    create(retained, b"previous")
    create(bundle, b"current")
    writer.reset_mock()

    def interrupted_remove(path, **kwargs):
        if path == (retained if interrupted == "retained" else bundle) and interrupted in {
            "retained",
            "current",
        }:
            (path / "database.sqlite3").unlink()
            raise KeyboardInterrupt()
        return remove(path, **kwargs)

    def interrupted_move(source, destination, **kwargs):
        if interrupted == "publish-before":
            raise KeyboardInterrupt()
        result = move(source, destination, **kwargs)
        if interrupted == "publish-after":
            raise KeyboardInterrupt()
        return result

    with (
        patch.object(subject.shutil, "rmtree", side_effect=interrupted_remove),
        patch.object(subject.shutil, "move", side_effect=interrupted_move),
    ):
        try:
            subject.retain_result_step(["all", "ui"])
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("结果包提交中断需要传播")
    assert json.loads(report_path.read_text())["resultMerge"]["groups"] == ["all", "ui"]
    with patch.object(subject.subprocess, "run") as repeated_merge:
        subject.recover_result_step()
        subject.recover_result_step()
        repeated_merge.assert_not_called()
    assert (bundle / "database.sqlite3").read_bytes() == b"previouscurrent"
    assert not retained.exists() and not incoming.exists()
    recovered = json.loads(report_path.read_text())
    assert "resultMerge" not in recovered
    assert recovered["groups"]["all"]["resultBundleIdentity"] == subject.bundle_identity(bundle)


def batch_retention_self_test(raw: list, test: str) -> None:
    import json
    import shutil
    import subprocess
    import sys
    from contextlib import nullcontext, redirect_stderr
    from io import StringIO
    import validation_provenance

    fixture = subject.ROOT / ".build/static-audit/performance-results-self-test"
    bundle = fixture / ".build/extended-automation/test-results.xcresult"
    retained = bundle.with_suffix(".retained.xcresult")
    incoming = bundle.with_suffix(".incoming.xcresult")
    report_path = fixture / "report.json"
    audit_run = subprocess.run

    def artifact_status():
        return audit_run(
            [
                sys.executable,
                "-B",
                str(subject.ROOT / "Scripts/validation_artifacts.py"),
                str(fixture),
            ],
            capture_output=True,
            text=True,
        ).returncode

    record = {
        "testIdentifier": test,
        "xcresultMetrics": raw,
        "execution": {
            "environment": {"device": {"identifier": "phone"}},
            "bundleIdentity": "original",
            "runID": "run",
        },
        "resultBundle": {"identity": "original"},
    }
    report = {
        "groups": {
            "all": {
                "resultBundleIdentity": "original",
                "performance": {"records": {"sample": record}},
            },
            "ui": {"runID": "ui"},
        },
        "performanceBaseline": deepcopy(record),
    }
    foreign = deepcopy(raw[0]["testRuns"][0])
    foreign["device"]["deviceId"] = "mac"
    combined = deepcopy(raw)
    combined[0]["testRuns"].append(foreign)
    assert subject.normalize_metrics(combined, test, "phone") == subject.normalize_metrics(
        raw, test, "phone"
    )
    duplicate = deepcopy(raw)
    duplicate[0]["testRuns"] += deepcopy(raw[0]["testRuns"])
    try:
        subject.normalize_metrics(duplicate, test, "phone")
    except ValueError:
        pass
    else:
        raise AssertionError("所属设备需要唯一的性能运行")
    with (
        patch.object(subject.subprocess, "check_output", return_value=json.dumps(combined)),
        patch.object(subject, "bundle_identity", return_value="aggregate") as digest,
    ):
        updated = subject.rebind_result_records(report, ["all", "ui"])
        digest.assert_called_once_with(subject.BUNDLE)
    assert report["groups"]["all"]["resultBundleIdentity"] == "original"
    assert updated["groups"]["all"]["runResultBundleIdentity"] == "original"
    assert (
        updated["groups"]["all"]["performance"]["records"]["sample"]["execution"]["bundleIdentity"]
        == "aggregate"
    )
    assert (
        updated["groups"]["all"]["performance"]["records"]["sample"]["resultBundle"]["identity"]
        == "aggregate"
    )
    assert updated["performanceBaseline"] == report["performanceBaseline"]
    selected = deepcopy(report)
    selected["groups"]["all"]["lastFullRun"] = deepcopy(report["groups"]["all"])
    selected["groups"]["all"].pop("performance")
    repeated = deepcopy(raw)
    repeated[0]["testRuns"].append(deepcopy(raw[0]["testRuns"][0]))
    repeated[0]["testRuns"][-1]["metrics"][0]["measurements"] = [99]
    with (
        patch.object(subject.subprocess, "check_output", return_value=json.dumps(repeated)),
        patch.object(subject, "bundle_identity", return_value="aggregate"),
    ):
        rebound = subject.rebind_result_records(selected, ["all"])
    assert rebound["groups"]["all"]["lastFullRun"]["resultBundleIdentity"] == "aggregate"
    assert rebound["groups"]["all"]["lastFullRun"]["runResultBundleIdentity"] == "original"
    altered = deepcopy(raw)
    altered[0]["testRuns"][0]["metrics"][0]["measurements"] = [99]
    with (
        patch.object(subject.subprocess, "check_output", return_value=json.dumps(duplicate)),
        patch.object(subject, "bundle_identity", return_value="aggregate"),
    ):
        equivalent = subject.rebind_result_records(report, ["all"])
        assert equivalent["groups"]["all"]["runResultBundleIdentity"] == "original"
    for value in (altered,):
        with patch.object(subject.subprocess, "check_output", return_value=json.dumps(value)):
            try:
                subject.rebind_result_records(report, ["all"])
            except ValueError:
                pass
            else:
                raise AssertionError("合并结果包需要保留所属运行的原始采样")
        assert report["groups"]["all"]["resultBundleIdentity"] == "original"

    def create(path, data):
        path.mkdir(parents=True)
        (path / "database.sqlite3").write_bytes(data)

    def merge(command, **kwargs):
        assert command[:3] == ["xcrun", "xcresulttool", "merge"]
        assert command[3:5] == ["--output-path", str(incoming)]
        assert command[5:] == [str(retained), str(bundle)]
        create(
            incoming,
            (retained / "database.sqlite3").read_bytes()
            + (bundle / "database.sqlite3").read_bytes(),
        )
        (incoming / "database.sqlite3").rename(incoming / "Info.plist")

    def exported(command, **kwargs):
        candidate = Path(command[command.index("--path") + 1]) if "--path" in command else bundle
        if (
            "summary" in command
            and (candidate / "Info.plist").exists()
            and not (candidate / "database.sqlite3").exists()
        ):
            (candidate / "database.sqlite3").write_bytes((candidate / "Info.plist").read_bytes())
        if "summary" in command:
            return json.dumps(
                {
                    "result": "Passed",
                    "execution": (candidate / "database.sqlite3").read_bytes().decode(),
                }
            )
        if "tests" in command:
            return json.dumps({"testNodes": [{"name": test, "result": "Passed"}]})
        return json.dumps(combined)

    try:
        shutil.rmtree(fixture, ignore_errors=True)
        create(bundle, b"first")
        (bundle / "database.sqlite3").rename(bundle / "Info.plist")
        assert subject.bundle_identity(bundle)
        (bundle / "Staging").mkdir()
        try:
            subject.bundle_identity(bundle)
        except ValueError:
            pass
        else:
            raise AssertionError("结果包完成写入后提供采样摘要")
        (bundle / "Staging").rmdir()
        (bundle / "Info.plist").rename(bundle / "database.sqlite3")
        verify_batch_result_retention(
            artifact_status,
            bundle,
            create,
            exported,
            incoming,
            merge,
            report,
            report_path,
            retained,
        )
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(subject.ROOT / "Scripts/validation_performance.py"),
                "invalid",
            ],
            text=True,
            capture_output=True,
        )
        assert result.returncode == 1 and "性能命令" in result.stderr
    finally:
        shutil.rmtree(fixture, ignore_errors=True)


def merge_regression_self_test() -> None:
    import json
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO
    import validation_provenance
    from validation_manual_tests import evidence_fixture

    measurements = json.loads(evidence_fixture("performance-baseline"))["scenarios"]
    report = {"groups": {}, "performanceBaseline": {"schemaVersion": 1, "records": {}}}
    for name, scenario in measurements.items():
        current, baseline = scenario["measurement"]["current"], scenario["measurement"]["baseline"]
        execution = current["execution"]
        row = report["groups"].setdefault(
            execution["group"],
            dict(
                execution,
                recordedAt=current["capturedAt"],
                resultBundleIdentity=execution["bundleIdentity"],
                performance={"schemaVersion": 1, "records": {}},
            ),
        )
        current["capturedAt"] = row["recordedAt"]
        row["performance"]["records"][name] = current
        report["performanceBaseline"]["records"][name] = baseline
    assert not subject.merge_findings(report)
    with patch.object(subject, "current_commit", return_value="0" * 40):
        assert not subject.merge_findings(report)
        with patch(
            "validation_provenance.input_identity",
            side_effect=lambda group, **kwargs: report["groups"][group]["inputDigest"],
        ):
            for row in report["groups"].values():
                assert all(
                    subject.record_complete(record, current=True)
                    for record in row["performance"]["records"].values()
                )
        with patch("validation_provenance.input_identity", return_value="changed input"):
            assert not subject.record_complete(
                report["groups"]["all"]["performance"]["records"]["pagination"], current=True
            )
    from validation_environment import exchange_identity

    shared = exchange_identity(report)
    assert not subject.merge_findings(shared)
    assert not subject.merge_findings(
        report | {"performanceBaseline": shared["performanceBaseline"]}
    )
    assert (
        shared["groups"]["all"]["performance"]["records"]["pagination"]["execution"]["inputDigest"]
        == report["groups"]["all"]["performance"]["records"]["pagination"]["execution"][
            "inputDigest"
        ]
    )
    for fault in (
        "missing-baseline",
        "missing-current",
        "run",
        "clock-regression",
        "memory-regression",
        "clock-tail",
        "memory-tail",
        "approver",
        "environment",
        "raw-metrics",
        "commit",
    ):
        changed = deepcopy(report)
        current = changed["groups"]["all"]["performance"]["records"]["pagination"]
        baseline = changed["performanceBaseline"]["records"]["pagination"]
        if fault == "missing-baseline":
            changed.pop("performanceBaseline")
        if fault == "missing-current":
            changed["groups"]["ui"]["performance"]["records"].pop("startup")
        if fault == "run":
            current["execution"]["runID"] = "other"
        if fault in {"clock-regression", "memory-regression", "clock-tail", "memory-tail"}:
            metric_name = "clockSeconds" if fault.startswith("clock") else "peakPhysicalMemoryBytes"
            identifier, _, factor = subject.METRICS[metric_name]
            samples = [sample * 4 for sample in current["metrics"][metric_name]["samples"]]
            if fault.endswith("tail"):
                approved = baseline["metrics"][metric_name]["samples"]
                samples = [min(approved) * 0.1] * (len(approved) - 1) + [max(approved) * 2]
            current["metrics"][metric_name].update(
                samples=samples, mean=sum(samples) / len(samples)
            )
            raw = current["xcresultMetrics"][0]["testRuns"][0]["metrics"]
            next(metric for metric in raw if metric["identifier"] == identifier)["measurements"] = [
                sample / factor for sample in samples
            ]
            assert subject.record_complete(current, current=True)
            assert subject.record_complete(baseline, current=False)
            assert not subject.performance_comparison_complete(
                "pagination", dict(current=current, baseline=baseline)
            ), fault
        if fault == "approver":
            baseline["approvedBy"] = ""
        if fault == "environment":
            baseline["environment"]["systemBuild"] = "other"
        if fault == "raw-metrics":
            current["xcresultMetrics"][0]["testRuns"][0]["metrics"][0]["measurements"] = [0.01] * 10
        if fault == "commit":
            current["sourceCommit"] = "0" * 40
        assert subject.merge_findings(changed), fault
    approved = deepcopy(report["performanceBaseline"])
    for record in approved["records"].values():
        for metric in record["xcresultMetrics"][0]["testRuns"][0]["metrics"]:
            metric["maxPercentRegression"] = 10
    with (
        patch.object(subject, "capture_current", return_value=approved),
        patch.object(Path, "is_file", return_value=True),
        patch.object(Path, "read_text", return_value='{"mergeCommit":"old","groups":{}}'),
        patch.object(Path, "write_text"),
        patch.object(validation_provenance, "report_lock", side_effect=nullcontext),
        patch.object(validation_provenance, "write_report") as writer,
        redirect_stdout(StringIO()),
    ):
        assert subject.main(["baseline", "maintainer"]) == 0
        assert writer.call_args_list[0].kwargs == {"path": subject.MEASUREMENTS}
        saved = writer.call_args.args[0]
        assert "mergeCommit" not in saved and set(saved["performanceBaseline"]["records"]) == set(
            measurements
        )
        assert all(
            record["approvedBy"] == "maintainer"
            for record in saved["performanceBaseline"]["records"].values()
        )


def verify_batch_result_retention(
    artifact_status, bundle, create, exported, incoming, merge, report, report_path, retained
):
    from io import StringIO
    import json
    from contextlib import nullcontext, redirect_stderr
    import shutil
    import validation_provenance

    with (
        patch.object(subject, "BUNDLE", bundle),
        patch.object(validation_provenance, "REPORT", report_path),
        patch.object(validation_provenance, "report_lock", side_effect=nullcontext),
        patch.object(
            validation_provenance,
            "write_report",
            side_effect=lambda value: report_path.write_text(json.dumps(value)),
        ) as writer,
        patch.object(subject.subprocess, "run", side_effect=merge),
        patch.object(subject.subprocess, "check_output", side_effect=exported),
        redirect_stderr(StringIO()),
    ):
        first_sha = subject.bundle_identity(bundle)
        report["groups"]["all"]["resultBundleIdentity"] = first_sha
        report_path.write_text(json.dumps(report))
        assert subject.main(["begin-batch", "append"]) == 0
        assert retained.is_dir() and not bundle.exists()
        assert subject.main(["reset-results"]) == 0
        writer.assert_not_called()
        create(bundle, b"second")
        second_sha = subject.bundle_identity(bundle)
        assert subject.main(["retain-batch", "all", "ui"]) == 0
        saved = writer.call_args.args[0]
        assert (bundle / "database.sqlite3").read_bytes() == b"firstsecond"
        assert not retained.exists() and not incoming.exists()
        assert saved["groups"]["all"]["runResultBundleIdentity"] == first_sha
        assert saved["groups"]["ui"]["runResultBundleIdentity"] == second_sha
        assert all(
            row["resultBundleIdentity"] == subject.bundle_identity(bundle)
            for row in saved["groups"].values()
        )
        assert (bundle / "Info.plist").is_file() and (bundle / "database.sqlite3").is_file()
        writer.reset_mock()
        assert subject.main(["begin-batch", "append"]) == 0
        assert subject.main(["retain-batch", "all", "ui", "release-runtime"]) == 0
        assert (
            bundle / "database.sqlite3"
        ).read_bytes() == b"firstsecond" and not retained.exists()
        report_path.write_text(json.dumps({"groups": {"catalyst": {"runID": "catalyst"}}}))
        assert subject.main(["begin-batch", "append"]) == 0
        create(bundle, b"catalyst")
        assert subject.main(["retain-batch", "catalyst"]) == 0
        assert writer.call_args.args[0]["groups"]["catalyst"][
            "resultBundleIdentity"
        ] == subject.bundle_identity(bundle)
        assert (bundle / "database.sqlite3").is_file()
        assert subject.main(["begin-batch", "append"]) == 0
        create(bundle, b"failed")
        report_path.write_text(json.dumps(report))
        for failure in ("merge", "summary", "interrupt"):
            verify_retain_failure_recovery(
                subject,
                failure,
                bundle,
                retained,
                incoming,
                create,
                report_path,
                writer,
                merge,
                exported,
            )
        remove = shutil.rmtree
        move = shutil.move
        for interrupted in ("retained", "current", "publish-before", "publish-after"):
            verify_retain_interrupted_recovery(
                subject,
                interrupted,
                bundle,
                retained,
                incoming,
                create,
                remove,
                move,
                report_path,
                writer,
            )
        for path in (bundle, retained, incoming):
            remove(path, ignore_errors=True)
        create(retained, b"previous")
        create(bundle, b"current")

        def fail_report_publish(value):
            if "resultMerge" not in value:
                raise OSError("report publish failure")
            report_path.write_text(json.dumps(value))

        writer.side_effect = fail_report_publish
        try:
            subject.merge_result_step(["all", "ui"])
        except OSError:
            pass
        else:
            raise AssertionError("报告发布失败需要保留待恢复合并身份")
        assert (bundle / "database.sqlite3").read_bytes() == b"previouscurrent"
        assert "resultMerge" in json.loads(report_path.read_text())
        writer.side_effect = lambda value: report_path.write_text(json.dumps(value))
        subject.recover_result_step()
        recovered = json.loads(report_path.read_text())
        assert "resultMerge" not in recovered
        assert recovered["groups"]["all"]["resultBundleIdentity"] == subject.bundle_identity(bundle)
        for publication in (2, 3):
            for path in (bundle, retained, incoming):
                remove(path, ignore_errors=True)
            create(bundle, b"first")
            receipt = deepcopy(report)
            identity = subject.bundle_identity(bundle)
            receipt["groups"]["all"].update(
                resultBundleIdentity=identity, runResultBundleIdentity=identity
            )
            report_path.write_text(json.dumps(receipt))
            writes = 0

            def fail_first_publication(value):
                nonlocal writes
                writes += 1
                if writes == publication:
                    raise OSError("first bundle publication failure")
                report_path.write_text(json.dumps(value))

            writer.side_effect = fail_first_publication
            try:
                subject.merge_result_step(["all"])
            except OSError:
                pass
            else:
                raise AssertionError("首包推广登记与报告发布中断需要传播")
            writer.side_effect = lambda value: report_path.write_text(json.dumps(value))
            subject.recover_result_step()
            recovered = json.loads(report_path.read_text())
            assert "resultMerge" not in recovered
            assert recovered["groups"]["all"]["resultBundleIdentity"] == subject.bundle_identity(
                bundle
            )
            assert recovered["groups"]["all"]["runResultBundleIdentity"] == subject.bundle_identity(
                bundle
            )
        for fault in (
            "current",
            "current-only",
            "published-current",
            "published-missing",
            "retained",
            "merged",
            "partial",
            "unreadable",
            "current-partial",
            "current-missing",
            "current-unreadable",
            "current-merged",
        ):
            setup_batch_fault_fixture(bundle, retained, incoming, fault, create)
            assert artifact_status() == 1, fault

            def recover_export(command, **kwargs):
                assert "--path" in command and command[-1] in {str(bundle), str(incoming)}
                if fault in {"unreadable", "current-unreadable"}:
                    raise subprocess.CalledProcessError(1, command)
                return exported(command, **kwargs)

            with patch.object(subject.subprocess, "check_output", side_effect=recover_export):
                assert subject.main(["recover-batch"]) == 0
            expected = batch_fault_expected_bytes(fault)
            assert (bundle / "database.sqlite3").read_bytes() == expected, fault
            assert not retained.exists() and not incoming.exists(), fault
            assert artifact_status() == 0, fault
            subject.recover_result_step()
            assert (bundle / "database.sqlite3").read_bytes() == expected, fault
        assert subject.main(["begin-batch", "first"]) == 0
        assert not any(path.exists() for path in (bundle, retained, incoming))
