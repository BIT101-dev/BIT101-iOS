"""Capture structured observations and local evidence for physical-device acceptance."""
import base64
import hashlib
import json
import math
import re
import struct
import uuid
import zlib
from validation_provenance import sampling_evidence_current, utc_now
from pathlib import Path
from datetime import datetime
from validate_distribution import valid_archive_provenance
from validation_media import media_complete
from validation_policy import MAXIMUM_ATTACHMENT_BYTES, MAXIMUM_REPORT_BYTES, workflow_conditions

MANUAL_DEVICE_CHECKS = {"system-autofill", "photos", "calendar-permissions", "notifications", "external-handoff", "web-interactions", "widget", "watch", "feedback-delivery", "distribution-signing", "minimum-platforms"}
MANUAL_SCENARIOS = {
    'first-login': {'registered-account', 'new-account-registration'},
    'profile-writes': {'nickname-save', 'avatar-bind', 'restore-profile'},
    'gallery-report': {'submit-and-confirm'},
    'account-lifecycle': {'sign-in-a', 'refresh-credentials-a', 'sign-out-a', 'sign-in-b', 'restore-a'},
    'community-variants': {'course-search', 'gallery-search-filters', 'comment-sorting', 'anonymous-poster', 'anonymous-paper', 'restore-content'},
    'ipad-layout': {'portrait', 'landscape', 'split-view', 'resize'},
}
MANUAL_DEVICE_CHECKS.update(MANUAL_SCENARIOS)
BASELINE_CHECKS = {'iOS': {'cold-start-session', 'offline-persistence', 'media-and-navigation'},
    'watchOS': {'snapshot-receive', 'timeline-render', 'clear-and-retry'}}
PERFORMANCE_WORKLOADS = {
    'pagination': ('MaintenancePerformanceTests/testCommunityPaginationPerformance', {'pages': 1000, 'itemsPerPage': 100, 'passes': 2, 'states': ['MinePagedState', 'GalleryMessageListState']}),
    'image-decoding': ('MaintenancePerformanceTests/testStillImageDecodingPerformance', {'width': 1024, 'height': 1024, 'format': 'PNG'}),
    'startup': ('MaintenancePerformanceUITests/testStartupPerformance', {'operation': 'terminate-launch-schedule-ready', 'storage': 'reset'}),
    'schedule-layout': ('MaintenancePerformanceUITests/testScheduleWeekLayoutPerformance', {'weekSwitchPairs': 10, 'animations': True}),
    'long-article': ('MaintenancePerformanceTests/testLongArticleRenderingPerformance', {'paragraphs': 40, 'repetitionsPerParagraph': 64}),
    'gif-decoding': ('MaintenancePerformanceTests/testGIFDecodingPerformance', {'width': 256, 'height': 256, 'frames': 24, 'cache': 'cleared-per-sample'}),
    'widget-timeline': ('MaintenancePerformanceTests/testWidgetTimelinePerformance', {'courses': 200, 'weeks': 20, 'occurrences': 4000}),
    'response-aggregation': ('MaintenancePerformanceTests/testBoundedResponseAggregationPerformance', {'bytes': 32 * 1024 * 1024, 'chunkBytes': 64 * 1024, 'transport': 'URLSession'}),
    'local-preview': ('MaintenancePerformanceTests/testLocalPreviewFirstPagePerformance', {'pages': 64, 'width': 512, 'height': 384, 'initialIndex': 63, 'storage': 'disk'}),
}
MANUAL_SCENARIOS['performance-baseline'] = set(PERFORMANCE_WORKLOADS)
MANUAL_DEVICE_CHECKS.add('performance-baseline')


def performance_group(test: str) -> str:
    return 'ui' if test.startswith('MaintenancePerformanceUITests/') else 'all'


def capture(operation: str, result: str, evidence: Path, check: str, outcome: str, observed_at: str) -> dict:
    if not operation.strip() or not result.strip():
        raise ValueError("人工验收需要实际操作和观察结果")
    if outcome not in {"passed", "failed"} or not sampling_evidence_current({"startedAt": observed_at, "finishedAt": observed_at}):
        raise ValueError("人工验收需要明确结果状态和实际观察时间")
    with evidence.open('rb') as stream: data = stream.read(MAXIMUM_ATTACHMENT_BYTES + 1)
    if len(data) > MAXIMUM_ATTACHMENT_BYTES: raise ValueError('人工附件需要控制在 32 MiB 以内。')
    if not (failed_evidence_complete(data) if outcome == "failed" else evidence_content_complete(check, data)):
        raise ValueError("验收附件需要有效影像、PDF 或所属专项的结构化证据")
    if check == 'performance-baseline' and outcome == 'passed':
        from validation_performance import validate_capture
        validate_capture(json.loads(data))
    return {"check": check, "operation": operation.strip(), "result": result.strip(), "outcome": outcome, "capturedAt": observed_at, "registeredAt": utc_now().isoformat(),
        "evidence": {"path": str(evidence.resolve()), "sha256": hashlib.sha256(data).hexdigest(), "byteCount": len(data), "dataBase64": base64.b64encode(data).decode("ascii")}}


def failed_evidence_complete(data: bytes) -> bool:
    if not data or len(data) > MAXIMUM_ATTACHMENT_BYTES: return False
    if evidence_content_complete('photos', data): return True
    try:
        value = json.loads(data)
        return isinstance(value, dict) and bool(value)
    except (ValueError, TypeError): return False


def artifact_complete(artifact: dict, check: str) -> bool:
    try:
        if type(artifact.get('byteCount')) is not int or not 0 < artifact['byteCount'] <= MAXIMUM_ATTACHMENT_BYTES \
                or not isinstance(artifact.get('dataBase64'), str) \
                or len(artifact['dataBase64']) > 4 * ((MAXIMUM_ATTACHMENT_BYTES + 2) // 3): return False
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
    if not data or len(data) > MAXIMUM_ATTACHMENT_BYTES: return False
    if check not in MANUAL_DEVICE_CHECKS: return False
    if check in MANUAL_SCENARIOS:
        try: return scenario_complete(check, json.loads(data))
        except (ValueError, TypeError, KeyError, OSError): return False
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
            delivery = proof['storedReport']['emailDelivery']
            return proof['reportID'] == report and proof['storageKey'].startswith('report:') \
                and proof['storageKey'].endswith(':' + report) and proof['storedReport']['id'] == report \
                and isinstance(proof['storedReport']['report'], dict) \
                and isinstance(delivery, dict) and delivery.get('status') == 'sent' \
                and type(delivery.get('attempts')) is int and delivery['attempts'] > 0 \
                and isinstance(delivery.get('messageID'), str) and bool(delivery['messageID'].strip()) \
                and bool(re.fullmatch(r'[^\s@]+@[^\s@]+', proof['emailRecipient'])) \
                and bool(re.fullmatch(r'<[^\s<>@]+@[^\s<>@]+>', proof['emailMessageID'])) \
                and report in proof['emailBody']
        except (ValueError, TypeError, KeyError, AttributeError): return False
    recognized = png_complete(data) or data.startswith(b'\xff\xd8\xff') and data.endswith(b'\xff\xd9') \
        or data.startswith(b'%PDF-') and data.rstrip().endswith(b'%%EOF') \
        or len(data) >= 16 and data[4:8] == b'ftyp' and b'moov' in data
    return recognized and media_complete(data)


def scenario_complete(check: str, proof: dict) -> bool:
    if not isinstance(proof, dict) or proof.get('schemaVersion') != 1 \
            or not isinstance(proof.get('scenarios'), dict) or set(proof['scenarios']) != MANUAL_SCENARIOS[check]: return False
    if check == 'ipad-layout' and (proof.get('deviceFamily') != 'iPad' or not isinstance(proof.get('deviceIdentifier'), str)
            or not proof['deviceIdentifier'].strip()): return False
    for name, row in proof['scenarios'].items():
        if not isinstance(row, dict) or row.get('outcome') != 'passed' \
                or not all(isinstance(row.get(key), str) and row[key].strip() for key in ('operation', 'result', 'capturedAt')) \
                or not sampling_evidence_current({'startedAt': row['capturedAt'], 'finishedAt': row['capturedAt']}) \
                or not isinstance(row.get('evidence'), dict) or not artifact_complete(row['evidence'], 'photos'): return False
        if check == 'performance-baseline' and not performance_comparison_complete(name, row.get('measurement')): return False
        if check == 'ipad-layout':
            size = row.get('windowSize', {})
            if not isinstance(size, dict) or not all(type(size.get(axis)) is int and size[axis] > 0 for axis in ('width', 'height')): return False
            if name == 'portrait' and size['width'] >= size['height']: return False
            if name == 'landscape' and size['width'] <= size['height']: return False
            if name == 'split-view' and (type(row.get('screenWidth')) is not int or size['width'] >= row['screenWidth']): return False
            if name == 'resize' and (not isinstance(row.get('previousWindowSize'), dict)
                    or not all(type(row['previousWindowSize'].get(axis)) is int and row['previousWindowSize'][axis] > 0 for axis in ('width', 'height'))
                    or row['previousWindowSize'] == size): return False
    return True


def performance_comparison_complete(name: str, measurement: dict) -> bool:
    try:
        if not isinstance(measurement, dict): return False
        current, baseline = measurement['current'], measurement['baseline']
        test, workload = PERFORMANCE_WORKLOADS[name]
        for record in (current, baseline):
            if not isinstance(record, dict) or record.get('testIdentifier') != test or record.get('input') != workload \
                    or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', record.get('sourceCommit', '')): return False
            environment = record['environment']
            if not isinstance(environment, dict) or not all(isinstance(environment.get(key), str) and environment[key].strip()
                    for key in ('deviceIdentifier', 'deviceModel', 'systemVersion', 'systemBuild', 'xcodeBuild', 'configuration', 'compilerSHA256')) \
                    or environment['configuration'] != 'Release' or not re.fullmatch(r'[0-9a-f]{64}', environment['compilerSHA256']) \
                    or not isinstance(environment.get('compilationConditions'), list) \
                    or not all(isinstance(condition, str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', condition) for condition in environment['compilationConditions']) \
                    or environment['compilationConditions'] != sorted(workflow_conditions(performance_group(test))): return False
            bundle = record['resultBundle']
            if not isinstance(bundle, dict) or not isinstance(bundle.get('path'), str) or not bundle['path'].endswith('.xcresult') \
                    or not re.fullmatch(r'[0-9a-f]{64}', bundle.get('sha256', '')): return False
            if set(record['metrics']) != {'clockSeconds', 'peakPhysicalMemoryBytes'}: return False
            for metric in record['metrics'].values():
                samples, mean = metric['samples'], metric['mean']
                if not isinstance(samples, list) or not samples or not all(type(sample) in (int, float) and math.isfinite(sample) and sample >= 0 for sample in samples) \
                        or type(mean) not in (int, float) or not math.isfinite(mean) or mean <= 0 \
                        or not math.isclose(mean, sum(samples) / len(samples)): return False
        if current['environment'] != baseline['environment'] or current['resultBundle']['sha256'] == baseline['resultBundle']['sha256'] \
                or not sampling_evidence_current({'startedAt': current['capturedAt'], 'finishedAt': current['capturedAt']}) \
                or not isinstance(baseline.get('approvedBy'), str) or not baseline['approvedBy'].strip(): return False
        times = [datetime.fromisoformat(value.replace('Z', '+00:00')) for value in
            (baseline['capturedAt'], baseline['approvedAt'], current['capturedAt'])]
        if any(value.tzinfo is None for value in times) or not times[0] <= times[1] <= times[2]: return False
        for name, metric in current['metrics'].items():
            approved = baseline['metrics'][name]
            limit = approved['maximumRegressionPercent']
            maximum = approved['mean'] * (1 + limit / 100) if type(limit) in (int, float) else math.nan
            if type(limit) not in (int, float) or not math.isfinite(limit) or limit < 0 \
                    or not math.isfinite(maximum) \
                    or len(metric['samples']) != len(approved['samples']) \
                    or metric['mean'] > maximum: return False
        from validation_performance import record_complete
        return record_complete(current, current=True) and record_complete(baseline, current=False)
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        return False


def baseline_complete(proof: dict) -> bool:
    from validate_distribution import distribution_contracts, minimum_os_version
    if not isinstance(proof, dict) or proof.get('schemaVersion') != 1 or not isinstance(proof.get('platforms'), dict) \
            or set(proof['platforms']) != set(BASELINE_CHECKS): return False
    contracts = distribution_contracts()
    for platform, required in BASELINE_CHECKS.items():
        row = proof['platforms'][platform]
        minimum = max(minimum_os_version(contract['minimumOSVersion']) for contract in contracts.values() if contract['platform'] == platform)
        if not isinstance(row, dict) or not all(isinstance(row.get(key), str) and row[key].strip() for key in
                ('deviceIdentifier', 'deviceModel', 'systemVersion', 'systemBuild', 'capturedAt')) \
                or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', row['systemVersion']) \
                or minimum_os_version(row['systemVersion'])[:2] != minimum[:2] \
                or minimum_os_version(row['systemVersion']) < minimum \
                or not sampling_evidence_current({'startedAt': row['capturedAt'], 'finishedAt': row['capturedAt']}) \
                or not isinstance(row.get('checks'), dict) or set(row['checks']) != required \
                or not all(isinstance(check, dict) and check.get("outcome") == "passed" and all(isinstance(check.get(key), str) and check[key].strip()
                    for key in ('operation', 'result')) for check in row['checks'].values()) \
                or not isinstance(row.get('evidence'), dict) or not artifact_complete(row['evidence'], 'photos'): return False
    return True


def complete(checks: dict) -> bool:
    if not isinstance(checks, dict): return False
    encoded = [row.get('evidence', {}).get('dataBase64', '') for row in checks.values()
        if isinstance(row, dict) and isinstance(row.get('evidence'), dict)]
    if any(not isinstance(value, str) for value in encoded) or sum(map(len, encoded)) > MAXIMUM_REPORT_BYTES: return False
    return set(checks) == MANUAL_DEVICE_CHECKS and all(
        isinstance(row, dict) and row.get('check') == check and row.get('outcome') == 'passed'
        and all(isinstance(row.get(field), str) and row[field].strip() for field in ("operation", "result", "capturedAt"))
        and isinstance(row.get("evidence"), dict) and artifact_complete(row["evidence"], check)
        and sampling_evidence_current({"startedAt": row["capturedAt"], "finishedAt": row["capturedAt"]}) for check, row in checks.items())


def distribution_matches_archive(observation: dict, archive: dict) -> bool:
    try:
        if not artifact_complete(observation.get('evidence', {}), 'distribution-signing'): return False
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
