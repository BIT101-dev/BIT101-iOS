"""Capture structured observations and local evidence for physical-device acceptance."""
import hashlib
import re
from pathlib import Path

MANUAL_DEVICE_CHECKS = {"system-autofill", "photos", "calendar-permissions", "notifications", "external-handoff", "web-interactions", "widget", "watch", "feedback-delivery"}


def capture(operation: str, result: str, evidence: Path) -> dict:
    if not operation.strip() or not result.strip():
        raise ValueError("人工验收需要实际操作和观察结果")
    data = evidence.read_bytes()
    if not data:
        raise ValueError("人工验收附件需要包含实际证据")
    return {"operation": operation.strip(), "result": result.strip(),
        "evidence": {"path": str(evidence.resolve()), "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data)}}


def complete(checks: dict) -> bool:
    return set(checks) == MANUAL_DEVICE_CHECKS and all(
        isinstance(row, dict) and all(isinstance(row.get(field), str) and row[field].strip() for field in ("operation", "result"))
        and isinstance(row.get("evidence"), dict) and isinstance(row["evidence"].get("path"), str)
        and bool(row["evidence"]["path"].strip()) and isinstance(row["evidence"].get("byteCount"), int)
        and row["evidence"]["byteCount"] > 0 and isinstance(row["evidence"].get("sha256"), str)
        and bool(re.fullmatch(r"[a-f0-9]{64}", row["evidence"]["sha256"])) for row in checks.values())
