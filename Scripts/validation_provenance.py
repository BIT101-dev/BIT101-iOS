"""Associate workflow results with their producing run and network sampling interval."""
from datetime import datetime, timedelta, timezone
import re

NETWORK_GROUPS = {"network", "ddl", "school-sms", "community-writes", "community-cleanup"}
NETWORK_EVIDENCE_LIFETIME = timedelta(days=1)


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def producing_run_matches(value: str | dict, input_digest: str, run_id: str) -> bool:
    if not input_digest or not run_id:
        return False
    if isinstance(value, dict):
        return value.get("runID") == run_id
    return re.findall(r"^验证输入：(\S+)$", value, re.MULTILINE) == [input_digest] \
        and re.findall(r"^验证运行：(\S+)$", value, re.MULTILINE) == [run_id]


def network_evidence_current(summary: dict, now: datetime | None = None) -> bool:
    try:
        start, finish = (datetime.fromisoformat(summary[key].replace("Z", "+00:00"))
                         for key in ("startedAt", "finishedAt"))
        return start <= finish and timedelta() <= (now or utc_now()) - finish <= NETWORK_EVIDENCE_LIFETIME
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


def evidence_current(group: str, summary: dict) -> bool:
    return group not in NETWORK_GROUPS or network_evidence_current(summary)
