"""Associate workflow results with their producing run and network sampling interval."""
from datetime import datetime, timedelta, timezone
import re
from urllib.parse import urlsplit
from validation_policy import NETWORK_GROUPS

LIVE_GROUPS = NETWORK_GROUPS | {"audit", "icloud", "icloud-cleanup", "manual-device"}
LIVE_EVIDENCE_LIFETIME = timedelta(days=1)


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def producing_run_matches(value: str | dict, input_digest: str, run_id: str) -> bool:
    if not input_digest or not run_id:
        return False
    if isinstance(value, dict):
        return value.get("runID") == run_id
    return re.findall(r"^验证输入：(\S+)$", value, re.MULTILINE) == [input_digest] \
        and re.findall(r"^验证运行：(\S+)$", value, re.MULTILINE) == [run_id]


def sampling_evidence_current(summary: dict, now: datetime | None = None) -> bool:
    try:
        start, finish = (datetime.fromisoformat(summary[key].replace("Z", "+00:00"))
                         for key in ("startedAt", "finishedAt"))
        instant = now or utc_now()
        return start <= finish <= instant and timedelta() <= instant - start <= LIVE_EVIDENCE_LIFETIME
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


def evidence_current(group: str, summary: dict) -> bool:
    return group not in LIVE_GROUPS or sampling_evidence_current(summary)


def complete_group_row(row: dict) -> dict:
    from validation_environment import exchange_identity
    full = row.get('lastFullRun', {})
    if row.get('scope') == 'selected' and row.get('exitCode') == 0 and row.get('summary', {}).get('passed') is True \
            and full.get('scope') == 'full' and full.get('exitCode') == 0 \
            and full.get('summary', {}).get('passed') is True \
            and row.get('inputDigest') and row['inputDigest'] == full.get('inputDigest') \
            and exchange_identity(row.get('environment')) == exchange_identity(full.get('environment')):
        return full
    return row


def network_requests_complete(required: set[str], value: dict) -> bool:
    from network_request_contracts import complete
    if value.get('requestEvidenceRequired') is not True: return False
    if value.get('scope') == 'community-cleanup': required = required - {'社区写入与清理'}
    rows = value.get('requestEvidence', [])
    if not isinstance(rows, list): return False
    observed = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('probe'), str) or not isinstance(row.get('requests'), list): return False
        if not row['requests']: continue
        for request in row['requests']:
            if not isinstance(request, dict): return False
            try: final = urlsplit(request.get('finalEndpoint', ''))
            except (TypeError, ValueError): return False
            if not final.hostname or final.scheme not in {'http', 'https'} or final.username or final.password \
                    or final.query or final.fragment or request.get('finalMethod') not in {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'}: return False
            try: endpoint = urlsplit(request.get('endpoint', ''))
            except (TypeError, ValueError): return False
            if not endpoint.hostname or endpoint.scheme not in {'http', 'https'} or endpoint.username or endpoint.password \
                    or endpoint.query or endpoint.fragment or request.get('method') not in {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'} \
                    or type(request.get('statusCode')) is not int or not 100 <= request['statusCode'] < 600: return False
            query = request.get('query', {})
            cursor = request.get('responseMinimumID')
            if cursor is not None and (not isinstance(cursor, str) or re.fullmatch(r'\d+', cursor) is None): return False
            if not isinstance(query, dict) or not set(query) <= {'page', 'last_id', 'obj', 'order', 'mode', 'type', 'uid', 'detail', 'search', 'hide_bot', 'XNXQDM', 'JXLDM'} \
                    or not all(isinstance(key, str) and isinstance(item, str) for key, item in query.items()): return False
            final_query = request.get('finalQuery')
            if not isinstance(final_query, dict) or not set(final_query) <= {'page', 'last_id', 'obj', 'order', 'mode', 'type', 'uid', 'detail', 'search', 'hide_bot', 'XNXQDM', 'JXLDM'} \
                    or not all(isinstance(key, str) and isinstance(item, str) for key, item in final_query.items()): return False
        expected = row.get('expectedParameters', {})
        if not isinstance(expected, dict) or not set(expected) <= {'XNXQDM', 'JXLDM', 'obj', 'uid', 'path'} \
                or not all(isinstance(item, str) for item in expected.values()): return False
        if value.get('validatedTerm') and expected.get('XNXQDM') != value['validatedTerm'] and 'XNXQDM' in expected: return False
        if complete(row['probe'], row['requests'], expected): observed.add(row['probe'])
        elif row['probe'] in required: return False
    return bool(required) and required <= observed
