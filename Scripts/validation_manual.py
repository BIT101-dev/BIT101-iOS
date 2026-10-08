"""Capture structured observations and local evidence for physical-device acceptance."""
import base64
import hashlib
import json
import re
import struct
import uuid
import zlib
from validation_provenance import sampling_evidence_current, utc_now
from pathlib import Path
from validate_distribution import valid_archive_provenance
from validation_media import media_complete

MANUAL_DEVICE_CHECKS = {"system-autofill", "photos", "calendar-permissions", "notifications", "external-handoff", "web-interactions", "widget", "watch", "feedback-delivery", "distribution-signing", "minimum-platforms"}
BASELINE_CHECKS = {'iOS': {'cold-start-session', 'offline-persistence', 'media-and-navigation'},
    'watchOS': {'snapshot-receive', 'timeline-render', 'clear-and-retry'}}


def capture(operation: str, result: str, evidence: Path, check: str, outcome: str, observed_at: str) -> dict:
    if not operation.strip() or not result.strip():
        raise ValueError("人工验收需要实际操作和观察结果")
    if outcome not in {"passed", "failed"} or not sampling_evidence_current({"startedAt": observed_at, "finishedAt": observed_at}):
        raise ValueError("人工验收需要明确结果状态和实际观察时间")
    data = evidence.read_bytes()
    if not (failed_evidence_complete(data) if outcome == "failed" else evidence_content_complete(check, data)):
        raise ValueError("验收附件需要有效影像、PDF 或所属专项的结构化证据")
    return {"check": check, "operation": operation.strip(), "result": result.strip(), "outcome": outcome, "capturedAt": observed_at, "registeredAt": utc_now().isoformat(),
        "evidence": {"path": str(evidence.resolve()), "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data), "dataBase64": base64.b64encode(data).decode("ascii")}}


def failed_evidence_complete(data: bytes) -> bool:
    if evidence_content_complete('photos', data): return True
    try:
        value = json.loads(data)
        return isinstance(value, dict) and bool(value)
    except (ValueError, TypeError): return False


def artifact_complete(artifact: dict, check: str) -> bool:
    try:
        data = base64.b64decode(artifact["dataBase64"], validate=True)
        return evidence_content_complete(check, data) and type(artifact["byteCount"]) is int and len(data) == artifact["byteCount"] \
            and hashlib.sha256(data).hexdigest() == artifact["sha256"] \
            and isinstance(artifact["path"], str) and bool(artifact["path"].strip())
    except (KeyError, TypeError, ValueError):
        return False


def png_complete(data: bytes) -> bool:
    if not data.startswith(b'\x89PNG\r\n\x1a\n'): return False
    offset, kinds = 8, []
    while offset + 12 <= len(data):
        size = int.from_bytes(data[offset:offset + 4])
        end = offset + 12 + size
        if end > len(data): return False
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:end - 4]
        if zlib.crc32(kind + payload) != int.from_bytes(data[end - 4:end]): return False
        if not kinds and (kind != b'IHDR' or size != 13 or 0 in struct.unpack('>II', payload[:8])): return False
        kinds.append(kind)
        offset = end
    return offset == len(data) and b'IDAT' in kinds and kinds[-1:] == [b'IEND']


def evidence_content_complete(check: str, data: bytes) -> bool:
    if check not in MANUAL_DEVICE_CHECKS: return False
    if check == 'minimum-platforms':
        try: return baseline_complete(json.loads(data))
        except (ValueError, TypeError, KeyError, OSError): return False
    if check == 'distribution-signing':
        from validate_distribution import distribution_complete
        try:
            proof = json.loads(data)
            return isinstance(proof, dict) and distribution_complete(proof)
        except (ValueError, TypeError, KeyError, OSError): return False
    if check == 'feedback-delivery':
        try:
            proof = json.loads(data)
            if not isinstance(proof, dict) or not all(isinstance(proof.get(field), str) for field in
                    ('reportID', 'storageKey', 'emailRecipient', 'emailMessageID', 'emailBody')): return False
            report = str(uuid.UUID(proof['reportID']))
            return proof['reportID'] == report and proof['storageKey'].startswith('report:') \
                and proof['storageKey'].endswith(':' + report) and proof['storedReport']['id'] == report \
                and isinstance(proof['storedReport']['report'], dict) \
                and bool(re.fullmatch(r'[^\s@]+@[^\s@]+', proof['emailRecipient'])) \
                and bool(re.fullmatch(r'<[^\s<>@]+@[^\s<>@]+>', proof['emailMessageID'])) \
                and report in proof['emailBody']
        except (ValueError, TypeError, KeyError, AttributeError): return False
    recognized = png_complete(data) or data.startswith(b'\xff\xd8\xff') and data.endswith(b'\xff\xd9') \
        or data.startswith(b'%PDF-') and data.rstrip().endswith(b'%%EOF') \
        or len(data) >= 16 and data[4:8] == b'ftyp' and b'moov' in data
    return recognized and media_complete(data)


def baseline_complete(proof: dict) -> bool:
    from validate_distribution import distribution_contracts
    if not isinstance(proof, dict) or proof.get('schemaVersion') != 1 or not isinstance(proof.get('platforms'), dict) \
            or set(proof['platforms']) != set(BASELINE_CHECKS): return False
    contracts = distribution_contracts()
    for platform, required in BASELINE_CHECKS.items():
        row = proof['platforms'][platform]
        minimum = min(int(contract['minimumOSVersion'].split('.')[0]) for contract in contracts.values() if contract['platform'] == platform)
        if not isinstance(row, dict) or not all(isinstance(row.get(key), str) and row[key].strip() for key in
                ('deviceIdentifier', 'deviceModel', 'systemVersion', 'systemBuild', 'capturedAt')) \
                or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', row['systemVersion']) \
                or int(row['systemVersion'].split('.')[0]) != minimum \
                or not sampling_evidence_current({'startedAt': row['capturedAt'], 'finishedAt': row['capturedAt']}) \
                or not isinstance(row.get('checks'), dict) or set(row['checks']) != required \
                or not all(isinstance(check, dict) and check.get("outcome") == "passed" and all(isinstance(check.get(key), str) and check[key].strip()
                    for key in ('operation', 'result')) for check in row['checks'].values()) \
                or not isinstance(row.get('evidence'), dict) or not artifact_complete(row['evidence'], 'photos'): return False
    return True


def complete(checks: dict) -> bool:
    return set(checks) == MANUAL_DEVICE_CHECKS and all(
        isinstance(row, dict) and row.get('check') == check and row.get('outcome') == 'passed'
        and all(isinstance(row.get(field), str) and row[field].strip() for field in ("operation", "result", "capturedAt"))
        and isinstance(row.get("evidence"), dict) and artifact_complete(row["evidence"], check)
        and sampling_evidence_current({"startedAt": row["capturedAt"], "finishedAt": row["capturedAt"]}) for check, row in checks.items())


def distribution_matches_archive(observation: dict, archive: dict) -> bool:
    try:
        proof = json.loads(base64.b64decode(observation['evidence']['dataBase64'], validate=True))
        summary = archive['summary']
        provenance = summary['archiveProvenance']
        expected = {'inputDigest': archive['inputDigest'], 'runID': archive['runID']}
        if archive.get('exitCode') != 0 or archive.get('scope') != 'full' or summary.get('passed') is not True \
                or provenance != expected or not valid_archive_provenance(provenance) or proof.get('archiveProvenance') != provenance:
            return False
        rows = proof['bundles']
        executables = summary['executables']
        if {row['identifier'] for row in rows} != set(executables): return False
        return all(row['executableUUIDs'] and all(item in executables[row['identifier']] for item in row['executableUUIDs']) for row in rows)
    except (KeyError, ValueError, TypeError, AttributeError): return False
