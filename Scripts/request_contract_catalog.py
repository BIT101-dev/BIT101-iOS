#!/usr/bin/env python3
"""Declare smoke request routes and parameter rules."""

from dataclasses import dataclass, field
import re
import sys
from urllib.parse import urlsplit

API = "bit101.flwfdd.xyz"
SCHOOL = r"(?:jxzxehallapp|webvpn)\.bit\.edu\.cn"
VPN = r"(?:/https/[0-9a-f]+)?"
VISIBLE_PARAMETERS = frozenset(
    {
        "page",
        "last_id",
        "obj",
        "order",
        "mode",
        "type",
        "uid",
        "detail",
        "detailed",
        "search",
        "hide_bot",
        "XNXQDM",
        "JXLDM",
        "XXXQDM",
        "dicCode",
        "SFSY",
        "RQ",
        "XQDM",
        "XNDM",
        "GPA",
        "page_size",
        "fields",
        "conditions",
        "appName",
        "EMAP_LANG",
    }
)
SCHOOL_AUTHENTICATION_BODIES = (frozenset({"challenge_id"}), frozenset({"username", "password"}))


@dataclass(frozen=True)
class RequestContract:
    host: str
    path: str
    method: str = "GET"
    query: dict = field(default_factory=dict)
    minimum: int = 1
    paging: str = ""
    scheme: str = "https"
    statuses: range | tuple[int, ...] = range(200, 300)
    port: int | None = 443
    final_host: str = ""
    final_path: str = ""
    additional_parameters: frozenset[str] = frozenset()
    resource_parameters: bool = False
    body_parameters: frozenset[str] = frozenset()
    required_body_parameters: frozenset[str] = frozenset()
    body_parameter_variants: tuple[frozenset[str], ...] = ()

    def matches(self, request: dict) -> bool:
        if any(
            request.get(key) is not None
            for key in ("ambiguousParameters", "finalAmbiguousParameters")
        ):
            return False
        try:
            endpoint = urlsplit(request["endpoint"])
            declared_port = endpoint.port
            port = (
                declared_port
                if declared_port is not None
                else (443 if endpoint.scheme == "https" else 80)
            )
            final = urlsplit(request.get("finalEndpoint", ""))
            final_port = (
                final.port if final.port is not None else (443 if final.scheme == "https" else 80)
            )
        except ValueError:
            return False
        query = request.get("query", {})
        final_query = request.get("finalQuery", {})
        allowed = {
            key for key, pattern in self.query.items() if pattern is not None
        } | self.additional_parameters
        if self.paging:
            allowed.add(self.paging)
        if not self.resource_parameters and (set(query) - allowed or set(final_query) - allowed):
            return False
        body_allowed = self.body_parameters | (
            allowed if self.method in {"POST", "PUT"} else frozenset()
        )
        for key in ("bodyParameterNames", "finalBodyParameterNames"):
            names = request.get(key, [])
            if (
                not isinstance(names, list)
                or not all(isinstance(name, str) for name in names)
                or len(set(names)) != len(names)
                or set(names) - body_allowed
                or self.required_body_parameters - set(names)
            ):
                return False
            if (
                self.body_parameter_variants
                and set(names) & set().union(*self.body_parameter_variants)
                not in self.body_parameter_variants
            ):
                return False
        return (
            endpoint.scheme == self.scheme
            and final.scheme == self.scheme
            and request["statusCode"] in self.statuses
            and (self.port is None or port == self.port)
            and (self.port is None or final_port == self.port)
            and request.get("finalMethod") == self.method
            and re.fullmatch(self.final_host or self.host, final.hostname or "") is not None
            and re.fullmatch(self.final_path or self.path, final.path) is not None
            and request["method"] == self.method
            and re.fullmatch(self.host, endpoint.hostname or "") is not None
            and re.fullmatch(self.path, endpoint.path) is not None
            and all(
                key not in query
                if pattern is None
                else re.fullmatch(pattern, query.get(key, "")) is not None
                for key, pattern in self.query.items()
            )
            and all(
                key not in final_query
                if pattern is None
                else re.fullmatch(pattern, final_query.get(key, "")) is not None
                for key, pattern in self.query.items()
            )
            and all(query.get(key) == final_query.get(key) for key in ("page", "last_id"))
        )

    def complete(self, requests: list[dict]) -> bool:
        rows = [request for request in requests if self.matches(request)]
        if len(rows) < self.minimum:
            return False
        if not self.paging:
            return True
        values = [row.get("query", {}).get(self.paging) for row in rows]
        initial = str(sys.maxsize) if self.paging == "last_id" else "0"
        normalized = [
            initial if value is None and self.paging == "page" else value for value in values
        ]
        if len(rows) < 2 or normalized[0] != initial:
            return False
        if self.paging == "page":
            return normalized == [str(page) for page in range(len(rows))]
        return all(
            isinstance(cursor, str)
            and re.fullmatch(r"[1-9]\d*", cursor)
            and isinstance(minimum := previous.get("responseMinimumID"), str)
            and re.fullmatch(r"[1-9]\d*", minimum)
            and minimum == cursor
            for previous, cursor in zip(rows, normalized[1:])
        ) and all(
            isinstance(minimum := row.get("responseMinimumID"), str)
            and re.fullmatch(r"[1-9]\d*", minimum)
            and int(minimum) < int(cursor)
            for row, cursor in zip(rows[1:], normalized[1:])
        )


def community(
    path: str,
    *,
    query: dict | None = None,
    minimum: int = 1,
    paging: str = "",
    method: str = "GET",
    statuses: range | tuple[int, ...] = range(200, 300),
) -> RequestContract:
    parameters = (
        frozenset({"page"})
        if method == "GET" and path in {"/posters", "/papers", "/reaction/comments"}
        else frozenset()
    )
    body = set()
    if method in {"POST", "PUT"}:
        if path.startswith("/posters"):
            body = {
                "title",
                "text",
                "image_mids",
                "plugins",
                "anonymous",
                "tags",
                "claim_id",
                "public",
            }
        elif path.startswith("/papers"):
            body = {"title", "intro", "content", "anonymous", "public_edit", "last_time"}
        elif path == "/reaction/comments":
            body = {"obj", "text", "reply_obj", "reply_uid", "anonymous", "rate", "image_mids"}
        elif path == "/reaction/like":
            body = {"obj"}
        elif path == "/subscriptions":
            body = {"obj", "level"}
        elif path == "/user/webvpn_verify_init":
            body = {"sid"}
        elif path == "/user/webvpn_verify":
            body = {"sid", "password", "execution", "cookie", "salt", "captcha"}
    required = body if path.startswith(("/posters", "/papers")) else set()
    if path.startswith("/papers") and method == "POST":
        required = body - {"last_time"}
    if path == "/reaction/comments" and method == "POST":
        required = {"obj", "text", "anonymous", "image_mids"}
        if (query or {}).get("obj", "").startswith("course"):
            required.add("rate")
    if path in {
        "/reaction/like",
        "/subscriptions",
        "/user/webvpn_verify_init",
        "/user/webvpn_verify",
    }:
        required = body
    variants = (
        (frozenset(), frozenset({"reply_obj", "reply_uid"}))
        if path == "/reaction/comments" and method == "POST"
        else ()
    )
    return RequestContract(
        re.escape(API),
        path,
        method,
        query or {},
        minimum,
        paging,
        statuses=statuses,
        additional_parameters=parameters,
        body_parameters=frozenset(body),
        required_body_parameters=frozenset(required),
        body_parameter_variants=variants,
    )


def teaching(path: str, method: str = "GET", *, query: dict | None = None) -> RequestContract:
    body = (
        {"*order"}
        if path.endswith("/cxxsksap.do")
        else {"requestParamStr", "requestParamStr.XNXQDM", "requestParamStr.ZC"}
        if path.endswith("/cxzkbrq.do")
        else set()
    )
    required = body | (
        {name for name, pattern in (query or {}).items() if pattern is not None}
        if method == "POST" and "requestParamStr" not in body
        else set()
    )
    return RequestContract(
        SCHOOL,
        VPN + re.escape(path),
        method,
        query or {},
        body_parameters=frozenset(body),
        required_body_parameters=frozenset(required),
    )


CONTRACTS = {
    "community.login": [community("/user/check")],
    "gallery.newest": [
        community(
            "/posters",
            query={"mode": "search", "order": "new", "uid": "-1", "search": None, "hide_bot": None},
            paging="page",
        )
    ],
    "gallery.following": [
        community(
            "/posters",
            query={"mode": "follow", "order": None, "uid": None, "search": None, "hide_bot": None},
            paging="page",
        )
    ],
    "gallery.hot": [
        community(
            "/posters",
            query={"mode": "hot", "order": None, "uid": None, "search": None, "hide_bot": None},
            paging="page",
        )
    ],
    "gallery.recommend": [
        community(
            "/posters",
            query={"mode": None, "order": None, "uid": None, "search": None, "hide_bot": None},
            paging="page",
        )
    ],
    "gallery.bots": [
        community(
            "/posters",
            query={"mode": "search", "order": "new", "uid": "-1", "search": None, "hide_bot": None},
            paging="page",
        )
    ],
    "gallery.search": [
        community(
            "/posters",
            query={
                "mode": "search",
                "order": order,
                "uid": "-1",
                "search": search,
                "hide_bot": None,
            },
            paging="page",
        )
        for search, orders in ((".+", ("similar", "like", "new")), (None, ("like", "new")))
        for order in orders
    ],
    "gallery.detail": [community(r"/posters/\d+")],
    "gallery.comments": [
        community("/reaction/comments", query={"obj": r"poster\d+", "order": order}, paging="page")
        for order in ("new", "old", "like")
    ],
    "gallery.claims": [community("/posters/claims")],
    "community.report-types": [community("/manage/report_types")],
    "message.unread": [community("/messages/unread_nums")],
    "course.list": [community("/courses", query={"order": "new", "search": None}, paging="page")],
    "course.search": [community("/courses", query={"order": "new", "search": ".+"}, paging="page")],
    "course.detail": [community(r"/courses/\d+")],
    "course.comments": [
        community("/reaction/comments", query={"obj": r"course\d+", "order": "new"}, paging="page")
    ],
    "course.history": [community("/courses/histories/.+")],
    "paper.list": [community("/papers", query={"order": None, "search": None}, paging="page")],
    "paper.search": [community("/papers", query={"order": None, "search": ".+"}, paging="page")],
    "paper.detail": [community(r"/papers/\d+")],
    "paper.image": [RequestContract(r".+", "/.+", port=None, resource_parameters=True)],
    "paper.comments": [
        community("/reaction/comments", query={"obj": r"paper\d+", "order": order}, paging="page")
        for order in ("new", "old", "like")
    ],
    "profile.mine": [community("/user/info/0")],
    "community.session": [
        community("/user/info/0", minimum=2),
        community("/user/info/0", statuses=(401,)),
    ],
    "profile.following": [community("/user/followings", paging="page")],
    "profile.followers": [community("/user/followers", paging="page")],
    "profile.posts": [
        community(
            "/posters",
            query={"mode": "search", "uid": "0", "order": None, "search": None},
            paging="page",
        )
    ],
    "user.posts": [
        community(
            "/posters",
            query={"mode": "search", "uid": r"[1-9]\d*", "order": None, "search": None},
            paging="page",
        )
    ],
    "user.profile": [community(r"/user/info/\d+")],
    "schedule.current-term": [teaching("/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do")],
    "school.session": [teaching("/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do")],
    "schedule.teaching-center": [
        teaching("/jwapp/sys/funauthapp/api/getAppConfig/wdkbby-5959167891382285.do"),
        teaching("/jwapp/i18n.do", query={"appName": "wdkbby", "EMAP_LANG": "zh"}),
    ],
    "schedule.terms": [teaching("/jwapp/sys/wdkbby/modules/jshkcb/xnxqcx.do")],
    "schedule.sync": [
        teaching(path, "POST", query={"XNXQDM": ".+"})
        for path in (
            "/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do",
            "/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do",
            "/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do",
        )
    ],
    "classroom.campuses": [
        teaching(
            "/jwapp/sys/kxjasbyMobile/modules/jxllb/ggzdpx.do",
            query={"dicCode": "48682", "SFSY": "1", "order": r"\+DM"},
        )
    ],
    "classroom.buildings": [
        teaching("/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do", query={"XXXQDM": ".+"})
    ],
    "classroom.occupancy": [
        teaching(
            "/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do",
            "POST",
            query={
                "XNXQDM": ".+",
                "JXLDM": ".+",
                "RQ": r"\d{4}-\d{2}-\d{2}",
                "XQDM": ".+",
                "XNDM": ".+",
            },
        )
    ],
    "eclass.authentication": [
        RequestContract(
            r"zy-eclass\.bit\.edu\.cn",
            "/api/my-courses",
            "POST",
            additional_parameters=frozenset({"page"}),
            query={"page_size": "100", "fields": "id,name", "conditions": r"\{\}"},
            body_parameters=frozenset({"page_size", "fields", "conditions"}),
            required_body_parameters=frozenset({"page", "page_size", "fields", "conditions"}),
        )
    ],
    "eclass.ddl": [
        RequestContract(
            r"zy-eclass\.bit\.edu\.cn",
            "/api/my-courses",
            "POST",
            additional_parameters=frozenset({"page"}),
            query={"page_size": "100", "fields": "id,name", "conditions": r"\{\}"},
            body_parameters=frozenset({"page_size", "fields", "conditions"}),
            required_body_parameters=frozenset({"page", "page_size", "fields", "conditions"}),
        )
    ],
    "lexue.calendar": [
        RequestContract(
            r"(?:lexue|webvpn)\.bit\.edu\.cn",
            VPN + re.escape("/calendar/export.php"),
            "POST",
            body_parameters=frozenset(
                {
                    "sesskey",
                    "_qf__core_calendar_export_form",
                    "events[exportevents]",
                    "period[timeperiod]",
                    "generateurl",
                }
            ),
            required_body_parameters=frozenset(
                {
                    "sesskey",
                    "_qf__core_calendar_export_form",
                    "events[exportevents]",
                    "period[timeperiod]",
                    "generateurl",
                }
            ),
        )
    ],
    "lexue.ddl": [
        RequestContract(
            r"(?:lexue|webvpn)\.bit\.edu\.cn",
            VPN + re.escape("/calendar/export_execute.php"),
            additional_parameters=frozenset({"userid", "authtoken", "preset_what", "preset_time"}),
        )
    ],
    "score.authentication": [
        RequestContract(
            r"login\.bit101\.flwfdd\.xyz",
            "/api/auth/start",
            "POST",
            body_parameters=frozenset({"username", "password", "services", "wait_seconds"}),
            required_body_parameters=frozenset(
                {"username", "password", "services", "wait_seconds"}
            ),
        )
    ],
    "score.brief": [
        RequestContract(
            r"login\.bit101\.flwfdd\.xyz",
            "/api/jwb/bit101/score",
            "POST",
            {"detail": "false"},
            body_parameters=frozenset({"username", "password", "challenge_id"}),
            required_body_parameters=frozenset({"detail"}),
            body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES,
        )
    ],
    "score.detail": [
        RequestContract(
            r"login\.bit101\.flwfdd\.xyz",
            "/api/jwb/bit101/score",
            "POST",
            {"detail": "true"},
            body_parameters=frozenset({"username", "password", "challenge_id"}),
            required_body_parameters=frozenset({"detail"}),
            body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES,
        )
    ],
    "score.transcript": [
        RequestContract(
            r"login\.bit101\.flwfdd\.xyz",
            "/api/jwb/cjd/cookies",
            "POST",
            {"detailed": "false"},
            body_parameters=frozenset({"username", "password", "challenge_id", "detailed"}),
            required_body_parameters=frozenset({"detailed"}),
            body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES,
        ),
        RequestContract(r"jwb\.bit\.edu\.cn", "/cjd/ScoreReport2/Index", query={"GPA": "1"}),
    ],
    "web.association": [
        RequestContract(
            r"open\.aihelpme\.dev", re.escape("/.well-known/apple-app-site-association")
        )
    ],
    "web.share-icon": [RequestContract(r"open\.aihelpme\.dev", re.escape("/share-icon.jpg"))],
    "web.home": [
        RequestContract(
            r"open\.aihelpme\.dev", "/?", final_host=r"bit101\.cn", final_path="/gallery/"
        )
    ],
    "gallery.web": [RequestContract(r"open\.aihelpme\.dev", r"/gallery/\d+")],
    "course.web": [RequestContract(r"open\.aihelpme\.dev", r"/course/\d+")],
    "paper.web": [RequestContract(r"open\.aihelpme\.dev", r"/paper/\d+")],
    "gallery.image": [RequestContract(r".+", "/.+", port=None, resource_parameters=True)],
    "feedback.preflight": [
        RequestContract(r"feedback\.aihelpme\.dev", "/api/error-reports", "OPTIONS")
    ],
    "feedback.recovery": [
        RequestContract(
            r"feedback\.aihelpme\.dev",
            "/api/error-reports",
            "POST",
            {"mode": "network-smoke"},
            body_parameters=frozenset({"mode", "runID"}),
            required_body_parameters=frozenset({"mode", "runID"}),
        )
    ],
    "update.app-store": [
        RequestContract(
            r"(?:itunes|apps)\.apple\.com",
            "/lookup",
            query={"id": ".+", "country": ".+", "requestTime": ".+"},
        )
    ],
    "update.emergency": [RequestContract(r"update\.aihelpme\.dev", "/emergency-update.json")],
    "gallery.subscriptions": [community("/subscriptions", paging="page")],
    "community.writes": [
        community("/subscriptions", method="POST", query={"obj": r"poster\d+"}, minimum=4),
        community("/posters", method="POST"),
        community(r"/posters/\d+", method="DELETE"),
        community(r"/posters/\d+", method="PUT"),
        community("/papers", method="POST"),
        community(r"/papers/\d+", method="DELETE"),
        community(r"/papers/\d+", method="PUT"),
        community("/upload/image", method="POST", minimum=4),
        *[
            community(
                "/reaction/comments", method="POST", query={"obj": kind + r"\d+"}, minimum=minimum
            )
            for kind, minimum in (("poster", 1), ("paper", 1), ("course", 1), ("comment", 6))
        ],
        community(r"/reaction/comments/\d+", method="DELETE", minimum=9),
        *[
            community("/reaction/like", method="POST", query={"obj": kind + r"\d+"}, minimum=2)
            for kind in ("poster", "paper", "course")
        ],
        community("/reaction/like", method="POST", query={"obj": r"comment\d+"}, minimum=6),
        community(
            "/posters",
            query={"mode": "search", "uid": r"[1-9]\d*", "order": None, "search": None},
            minimum=2,
        ),
        community(r"/user/follow/\d+", method="POST", minimum=2),
    ],
}


JWB_HOST = r"(?:jwms|webvpn)\.bit\.edu\.cn"
JWB_VPN = r"(?:/https?/[0-9a-f]+)?"
NATIVE_SCORE_LIST = RequestContract(
    JWB_HOST,
    JWB_VPN + "/jsxsd/kscj/cjcx_list",
    "POST",
    body_parameters=frozenset({"kksj", "kcxz", "kcmc", "xsfs"}),
    required_body_parameters=frozenset({"kksj", "kcxz", "kcmc", "xsfs"}),
)
NATIVE_SCORE_DETAIL = RequestContract(
    JWB_HOST, JWB_VPN + "/jsxsd/kscj/cjfx", resource_parameters=True
)
NATIVE_JWB_LANDING = RequestContract(
    JWB_HOST,
    JWB_VPN + r"/(?:;jsessionid=[A-Za-z0-9_-]+|jsxsd/(?:framework/main\.jsp|xk/LoginToXk))?",
    resource_parameters=True,
)
NATIVE_TRANSCRIPT_ENTRY = RequestContract(
    r"jwb\.bit\.edu\.cn",
    "/cjd/Account/ExternalLogin",
    statuses=range(200, 400),
    resource_parameters=True,
)
NATIVE_CONTRACTS = {
    "score.authentication": [NATIVE_JWB_LANDING],
    "score.brief": [NATIVE_SCORE_LIST],
    "score.detail": [NATIVE_SCORE_LIST],
    "score.transcript": [NATIVE_TRANSCRIPT_ENTRY, CONTRACTS["score.transcript"][-1]],
}
