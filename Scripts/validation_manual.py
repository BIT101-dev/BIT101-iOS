"""Capture structured observations and local evidence for physical-device acceptance."""
import base64
import hashlib
from validation_provenance import sampling_evidence_current, utc_now
from pathlib import Path

MANUAL_DEVICE_CHECKS = {"system-autofill", "photos", "calendar-permissions", "notifications", "external-handoff", "web-interactions", "widget", "watch", "feedback-delivery"}


def capture(operation: str, result: str, evidence: Path) -> dict:
    if not operation.strip() or not result.strip():
        raise ValueError("人工验收需要实际操作和观察结果")
    data = evidence.read_bytes()
    if not data:
        raise ValueError("人工验收附件需要包含实际证据")
    return {"operation": operation.strip(), "result": result.strip(), "capturedAt": utc_now().isoformat(),
        "evidence": {"path": str(evidence.resolve()), "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data), "dataBase64": base64.b64encode(data).decode("ascii")}}


def artifact_complete(artifact: dict) -> bool:
    try:
        data = base64.b64decode(artifact["dataBase64"], validate=True)
        return bool(data) and type(artifact["byteCount"]) is int and len(data) == artifact["byteCount"] \
            and hashlib.sha256(data).hexdigest() == artifact["sha256"] \
            and isinstance(artifact["path"], str) and bool(artifact["path"].strip())
    except (KeyError, TypeError, ValueError):
        return False


def complete(checks: dict) -> bool:
    return set(checks) == MANUAL_DEVICE_CHECKS and all(
        isinstance(row, dict) and all(isinstance(row.get(field), str) and row[field].strip() for field in ("operation", "result", "capturedAt"))
        and isinstance(row.get("evidence"), dict) and artifact_complete(row["evidence"])
        and sampling_evidence_current({"startedAt": row["capturedAt"], "finishedAt": row["capturedAt"]}) for row in checks.values())
