#!/usr/bin/env python3
"""Match smoke responses to business routes and explicit pagination requests."""
from dataclasses import dataclass, field, replace
from datetime import date
import re
import sys
from urllib.parse import unquote, urlsplit
from validation_policy import SCHOOL_SMS_PROBES

API = 'bit101.flwfdd.xyz'
SCHOOL = r'(?:jxzxehallapp|webvpn)\.bit\.edu\.cn'
VPN = r'(?:/https/[0-9a-f]+)?'
VISIBLE_PARAMETERS = frozenset({'page', 'last_id', 'obj', 'order', 'mode', 'type', 'uid', 'detail', 'detailed', 'search', 'hide_bot',
    'XNXQDM', 'JXLDM', 'XXXQDM', 'dicCode', 'SFSY', 'RQ', 'XQDM', 'XNDM', 'GPA', 'page_size', 'fields', 'conditions', 'appName', 'EMAP_LANG'})
SCHOOL_AUTHENTICATION_BODIES = (frozenset({'challenge_id'}), frozenset({'username', 'password'}))


@dataclass(frozen=True)
class RequestContract:
    host: str
    path: str
    method: str = 'GET'
    query: dict = field(default_factory=dict)
    minimum: int = 1
    paging: str = ''
    scheme: str = 'https'
    statuses: range | tuple[int, ...] = range(200, 300)
    port: int | None = 443
    final_host: str = ''
    final_path: str = ''
    additional_parameters: frozenset[str] = frozenset()
    resource_parameters: bool = False
    body_parameters: frozenset[str] = frozenset()
    required_body_parameters: frozenset[str] = frozenset()
    body_parameter_variants: tuple[frozenset[str], ...] = ()

    def matches(self, request: dict) -> bool:
        if any(request.get(key) is not None for key in ('ambiguousParameters', 'finalAmbiguousParameters')): return False
        try:
            endpoint = urlsplit(request['endpoint'])
            declared_port = endpoint.port
            port = declared_port if declared_port is not None else (443 if endpoint.scheme == 'https' else 80)
            final = urlsplit(request.get('finalEndpoint', ''))
            final_port = final.port if final.port is not None else (443 if final.scheme == 'https' else 80)
        except ValueError: return False
        query = request.get('query', {})
        final_query = request.get('finalQuery', {})
        allowed = {key for key, pattern in self.query.items() if pattern is not None} | self.additional_parameters
        if self.paging: allowed.add(self.paging)
        if not self.resource_parameters and (set(query) - allowed or set(final_query) - allowed): return False
        body_allowed = self.body_parameters | (allowed if self.method in {'POST', 'PUT'} else frozenset())
        for key in ('bodyParameterNames', 'finalBodyParameterNames'):
            names = request.get(key, [])
            if not isinstance(names, list) or not all(isinstance(name, str) for name in names) \
                    or len(set(names)) != len(names) or set(names) - body_allowed \
                    or self.required_body_parameters - set(names): return False
            if self.body_parameter_variants and set(names) & set().union(*self.body_parameter_variants) not in self.body_parameter_variants:
                return False
        return endpoint.scheme == self.scheme and final.scheme == self.scheme and request['statusCode'] in self.statuses \
            and (self.port is None or port == self.port) \
            and (self.port is None or final_port == self.port) \
            and request.get('finalMethod') == self.method \
            and re.fullmatch(self.final_host or self.host, final.hostname or '') is not None \
            and re.fullmatch(self.final_path or self.path, final.path) is not None \
            and request['method'] == self.method and re.fullmatch(self.host, endpoint.hostname or '') is not None \
            and re.fullmatch(self.path, endpoint.path) is not None \
            and all(key not in query if pattern is None else re.fullmatch(pattern, query.get(key, '')) is not None
                for key, pattern in self.query.items()) \
            and all(key not in final_query if pattern is None else re.fullmatch(pattern, final_query.get(key, '')) is not None
                for key, pattern in self.query.items()) \
            and all(query.get(key) == final_query.get(key) for key in ('page', 'last_id'))

    def complete(self, requests: list[dict]) -> bool:
        rows = [request for request in requests if self.matches(request)]
        if len(rows) < self.minimum: return False
        if not self.paging: return True
        values = [row.get('query', {}).get(self.paging) for row in rows]
        initial = str(sys.maxsize) if self.paging == 'last_id' else '0'
        normalized = [initial if value is None and self.paging == 'page' else value for value in values]
        if len(rows) < 2 or normalized[0] != initial: return False
        if self.paging == 'page': return normalized == [str(page) for page in range(len(rows))]
        return all(isinstance(cursor, str) and re.fullmatch(r'[1-9]\d*', cursor)
            and isinstance(minimum := previous.get('responseMinimumID'), str) and re.fullmatch(r'[1-9]\d*', minimum)
            and minimum == cursor for previous, cursor in zip(rows, normalized[1:])) \
            and all(isinstance(minimum := row.get('responseMinimumID'), str) and re.fullmatch(r'[1-9]\d*', minimum)
                and int(minimum) < int(cursor) for row, cursor in zip(rows[1:], normalized[1:]))


def community(path: str, *, query: dict | None = None, minimum: int = 1, paging: str = '', method: str = 'GET',
              statuses: range | tuple[int, ...] = range(200, 300)) -> RequestContract:
    parameters = frozenset({'page'}) if method == 'GET' and path in {'/posters', '/papers', '/reaction/comments'} else frozenset()
    body = set()
    if method in {'POST', 'PUT'}:
        if path.startswith('/posters'): body = {'title', 'text', 'image_mids', 'plugins', 'anonymous', 'tags', 'claim_id', 'public'}
        elif path.startswith('/papers'): body = {'title', 'intro', 'content', 'anonymous', 'public_edit', 'last_time'}
        elif path == '/reaction/comments': body = {'obj', 'text', 'reply_obj', 'reply_uid', 'anonymous', 'rate', 'image_mids'}
        elif path == '/reaction/like': body = {'obj'}
        elif path == '/subscriptions': body = {'obj', 'level'}
        elif path == '/user/webvpn_verify_init': body = {'sid'}
        elif path == '/user/webvpn_verify': body = {'sid', 'password', 'execution', 'cookie', 'salt', 'captcha'}
    required = body if path.startswith(('/posters', '/papers')) else set()
    if path.startswith('/papers') and method == 'POST': required = body - {'last_time'}
    if path == '/reaction/comments' and method == 'POST':
        required = {'obj', 'text', 'anonymous', 'image_mids'}
        if (query or {}).get('obj', '').startswith('course'): required.add('rate')
    if path in {'/reaction/like', '/subscriptions', '/user/webvpn_verify_init', '/user/webvpn_verify'}: required = body
    variants = (frozenset(), frozenset({'reply_obj', 'reply_uid'})) if path == '/reaction/comments' and method == 'POST' else ()
    return RequestContract(re.escape(API), path, method, query or {}, minimum, paging, statuses=statuses,
        additional_parameters=parameters, body_parameters=frozenset(body), required_body_parameters=frozenset(required), body_parameter_variants=variants)


def teaching(path: str, method: str = 'GET', *, query: dict | None = None) -> RequestContract:
    body = {'*order'} if path.endswith('/cxxsksap.do') else \
        {'requestParamStr', 'requestParamStr.XNXQDM', 'requestParamStr.ZC'} if path.endswith('/cxzkbrq.do') else set()
    required = body | ({name for name, pattern in (query or {}).items() if pattern is not None}
        if method == 'POST' and 'requestParamStr' not in body else set())
    return RequestContract(SCHOOL, VPN + re.escape(path), method, query or {}, body_parameters=frozenset(body),
        required_body_parameters=frozenset(required))


CONTRACTS = {
    'community.login': [community('/user/check')],
    'gallery.newest': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.following': [community('/posters', query={'mode': 'follow', 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.hot': [community('/posters', query={'mode': 'hot', 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.recommend': [community('/posters', query={'mode': None, 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.bots': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.search': [community('/posters', query={'mode': 'search', 'order': order, 'uid': '-1', 'search': search, 'hide_bot': None}, paging='page')
        for search, orders in (('.+', ('similar', 'like', 'new')), (None, ('like', 'new'))) for order in orders],
    'gallery.detail': [community(r'/posters/\d+')],
    'gallery.comments': [community('/reaction/comments', query={'obj': r'poster\d+', 'order': order}, paging='page') for order in ('new', 'old', 'like')],
    'gallery.claims': [community('/posters/claims')],
    'community.report-types': [community('/manage/report_types')],
    'message.unread': [community('/messages/unread_nums')],
    'course.list': [community('/courses', query={'order': 'new', 'search': None}, paging='page')],
    'course.search': [community('/courses', query={'order': 'new', 'search': '.+'}, paging='page')],
    'course.detail': [community(r'/courses/\d+')],
    'course.comments': [community('/reaction/comments', query={'obj': r'course\d+', 'order': 'new'}, paging='page')],
    'course.history': [community('/courses/histories/.+')],
    'paper.list': [community('/papers', query={'order': None, 'search': None}, paging='page')],
    'paper.search': [community('/papers', query={'order': None, 'search': '.+'}, paging='page')],
    'paper.detail': [community(r'/papers/\d+')],
    'paper.image': [RequestContract(r'.+', '/.+', port=None, resource_parameters=True)],
    'paper.comments': [community('/reaction/comments', query={'obj': r'paper\d+', 'order': order}, paging='page') for order in ('new', 'old', 'like')],
    'profile.mine': [community('/user/info/0')],
    'community.session': [community('/user/info/0', minimum=2), community('/user/info/0', statuses=(401,))],
    'profile.following': [community('/user/followings', paging='page')],
    'profile.followers': [community('/user/followers', paging='page')],
    'profile.posts': [community('/posters', query={'mode': 'search', 'uid': '0', 'order': None, 'search': None}, paging='page')],
    'user.posts': [community('/posters', query={'mode': 'search', 'uid': r'[1-9]\d*', 'order': None, 'search': None}, paging='page')],
    'user.profile': [community(r'/user/info/\d+')],
    'schedule.current-term': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do')],
    'school.session': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do')],
    'schedule.teaching-center': [teaching('/jwapp/sys/funauthapp/api/getAppConfig/wdkbby-5959167891382285.do'), teaching('/jwapp/i18n.do', query={'appName': 'wdkbby', 'EMAP_LANG': 'zh'})],
    'schedule.terms': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/xnxqcx.do')],
    'schedule.sync': [teaching(path, 'POST', query={'XNXQDM': '.+'}) for path in (
        '/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do', '/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do',
        '/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do')],
    'classroom.campuses': [teaching('/jwapp/sys/kxjasbyMobile/modules/jxllb/ggzdpx.do', query={'dicCode': '48682', 'SFSY': '1', 'order': r'\+DM'})],
    'classroom.buildings': [teaching('/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do', query={'XXXQDM': '.+'})],
    'classroom.occupancy': [teaching('/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do', 'POST',
        query={'XNXQDM': '.+', 'JXLDM': '.+', 'RQ': r'\d{4}-\d{2}-\d{2}', 'XQDM': '.+', 'XNDM': '.+'})],
    'eclass.authentication': [RequestContract(r'zy-eclass\.bit\.edu\.cn', '/api/my-courses', 'POST', additional_parameters=frozenset({'page'}),
        query={'page_size': '100', 'fields': 'id,name', 'conditions': r'\{\}'},
        body_parameters=frozenset({'page_size', 'fields', 'conditions'}), required_body_parameters=frozenset({'page', 'page_size', 'fields', 'conditions'}))],
    'eclass.ddl': [RequestContract(r'zy-eclass\.bit\.edu\.cn', '/api/my-courses', 'POST', additional_parameters=frozenset({'page'}),
        query={'page_size': '100', 'fields': 'id,name', 'conditions': r'\{\}'},
        body_parameters=frozenset({'page_size', 'fields', 'conditions'}), required_body_parameters=frozenset({'page', 'page_size', 'fields', 'conditions'}))],
    'lexue.calendar': [RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + re.escape('/calendar/export.php'), 'POST',
        body_parameters=frozenset({'sesskey', '_qf__core_calendar_export_form', 'events[exportevents]', 'period[timeperiod]', 'generateurl'}),
        required_body_parameters=frozenset({'sesskey', '_qf__core_calendar_export_form', 'events[exportevents]', 'period[timeperiod]', 'generateurl'}))],
    'lexue.ddl': [RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + re.escape('/calendar/export_execute.php'),
        additional_parameters=frozenset({'userid', 'authtoken', 'preset_what', 'preset_time'}))],
    'score.authentication': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/auth/start', 'POST',
        body_parameters=frozenset({'username', 'password', 'services', 'wait_seconds'}),
        required_body_parameters=frozenset({'username', 'password', 'services', 'wait_seconds'}))],
    'score.brief': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/bit101/score', 'POST', {'detail': 'false'},
        body_parameters=frozenset({'username', 'password', 'challenge_id'}), required_body_parameters=frozenset({'detail'}), body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES)],
    'score.detail': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/bit101/score', 'POST', {'detail': 'true'},
        body_parameters=frozenset({'username', 'password', 'challenge_id'}), required_body_parameters=frozenset({'detail'}), body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES)],
    'score.transcript': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/cjd/cookies', 'POST', {'detailed': 'false'},
        body_parameters=frozenset({'username', 'password', 'challenge_id', 'detailed'}), required_body_parameters=frozenset({'detailed'}), body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES),
        RequestContract(r'jwb\.bit\.edu\.cn', '/cjd/ScoreReport2/Index', query={'GPA': '1'})],
    'web.association': [RequestContract(r'open\.aihelpme\.dev', re.escape('/.well-known/apple-app-site-association'))],
    'web.share-icon': [RequestContract(r'open\.aihelpme\.dev', re.escape('/share-icon.jpg'))],
    'web.home': [RequestContract(r'open\.aihelpme\.dev', '/?', final_host=r'bit101\.cn', final_path='/gallery/')],
    'gallery.web': [RequestContract(r'open\.aihelpme\.dev', r'/gallery/\d+')],
    'course.web': [RequestContract(r'open\.aihelpme\.dev', r'/course/\d+')],
    'paper.web': [RequestContract(r'open\.aihelpme\.dev', r'/paper/\d+')],
    'gallery.image': [RequestContract(r'.+', '/.+', port=None, resource_parameters=True)],
    'feedback.preflight': [RequestContract(r'feedback\.aihelpme\.dev', '/api/error-reports', 'OPTIONS')],
    'feedback.recovery': [RequestContract(r'feedback\.aihelpme\.dev', '/api/error-reports', 'POST', {'mode': 'network-smoke'},
        body_parameters=frozenset({'mode', 'runID'}), required_body_parameters=frozenset({'mode', 'runID'}))],
    'update.app-store': [RequestContract(r'(?:itunes|apps)\.apple\.com', '/lookup', query={'id': '.+', 'country': '.+', 'requestTime': '.+'})],
    'update.emergency': [RequestContract(r'update\.aihelpme\.dev', '/emergency-update.json')],
    'gallery.subscriptions': [community('/subscriptions', paging='page')],
    'community.writes': [community('/subscriptions', method='POST', query={'obj': r'poster\d+'}, minimum=4),
        community('/posters', method='POST'), community(r'/posters/\d+', method='DELETE'),
        community(r'/posters/\d+', method='PUT'), community('/papers', method='POST'),
        community(r'/papers/\d+', method='DELETE'), community(r'/papers/\d+', method='PUT'),
        community('/upload/image', method='POST', minimum=4),
        *[community('/reaction/comments', method='POST', query={'obj': kind + r'\d+'}, minimum=minimum)
            for kind, minimum in (('poster', 1), ('paper', 1), ('course', 1), ('comment', 6))],
        community(r'/reaction/comments/\d+', method='DELETE', minimum=9),
        *[community('/reaction/like', method='POST', query={'obj': kind + r'\d+'}, minimum=2)
            for kind in ('poster', 'paper', 'course')],
        community('/reaction/like', method='POST', query={'obj': r'comment\d+'}, minimum=6),
        community('/posters', query={'mode': 'search', 'uid': r'[1-9]\d*', 'order': None, 'search': None}, minimum=2),
        community(r'/user/follow/\d+', method='POST', minimum=2)],
}


def contracts_for(probe: str, expected_parameters: dict | None = None) -> list[RequestContract]:
    if probe in CONTRACTS:
        contracts = CONTRACTS[probe]
        if probe in {'gallery.search', 'course.search', 'paper.search'} and expected_parameters is not None:
            expanded = []
            for contract in contracts:
                if contract.query.get('search') is None:
                    expanded.append(contract)
                else:
                    expanded.extend(replace(contract, query=dict(contract.query, search=re.escape(keyword)))
                        for keyword in (expected_parameters['search'], expected_parameters['excludedSearch']))
            return expanded
        return contracts
    if probe in {'message.comment', 'message.like', 'message.follow', 'message.system', 'message.subscription'}:
        return [community('/messages', query={'type': re.escape(probe.removeprefix('message.'))}, paging='last_id')]
    if probe.startswith('paper.list.'):
        orders = {'newest': None, 'like': 'like', 'comment': 'comment'}
        order = probe.removeprefix('paper.list.')
        return [community('/papers', query={'order': orders[order], 'search': None}, paging='page')] if order in orders else []
    return CONTRACTS.get(probe, [])


def auxiliary_contracts(probe: str, contracts: list[RequestContract], *, allow_sms: bool = False) -> list[RequestContract]:
    community_session = any(contract.host == re.escape(API) for contract in contracts)
    school_session = any(contract.host in {SCHOOL, r'zy-eclass\.bit\.edu\.cn', r'(?:lexue|webvpn)\.bit\.edu\.cn',
        r'login\.bit101\.flwfdd\.xyz', r'jwb\.bit\.edu\.cn'} for contract in contracts)
    rows = []
    if probe in {'paper.list', 'paper.search', 'paper.detail', 'paper.comments', 'community.writes'} or probe.startswith('paper.list.'):
        rows.append(community('/user/check'))
    if probe == 'community.writes':
        rows.extend(community(path) for path in (r'/user/info/\d+', r'/courses/\d+', r'/posters/\d+', r'/papers/\d+'))
        rows.extend([
            community('/posters', query={'mode': 'search', 'uid': '0', 'order': None, 'search': None}),
            community('/papers', query={'order': None, 'search': '.+'}),
            community('/reaction/comments', query={'obj': r'(?:poster|paper|course|comment)\d+', 'order': '(?:old|new)'}),
        ])
    if community_session:
        rows.extend(community(path, method='POST') for path in ('/user/webvpn_verify_init', '/user/webvpn_verify'))
    if community_session or school_session:
        rows.extend(RequestContract(r'sso\.bit\.edu\.cn', '/cas/login', method, statuses=range(200, 400),
            additional_parameters=frozenset({'service', 'renew', 'gateway', 'ticket', 'type'}),
            body_parameters=frozenset({'username', 'password', 'execution', 'croypto', 'captcha_payload',
                'geolocation', 'captcha_code', '_eventId', 'trustDevice'}) if method == 'POST' else frozenset()) for method in ('GET', 'POST'))
        rows.append(RequestContract(r'sso\.bit\.edu\.cn', r'/gate/cas-success/?', statuses=(200, 401), additional_parameters=frozenset({'ticket'})))
    if probe in SCHOOL_SMS_PROBES['school_sso_second_factor']:
        rows.append(RequestContract(r'sso\.bit\.edu\.cn', '/cas/api/protected/sms/getPhoneNumberByUserId', 'POST'))
        if allow_sms:
            rows.extend(RequestContract(r'sso\.bit\.edu\.cn', '/cas/api/protected/sms/' + path, 'POST',
                body_parameters=frozenset(names), required_body_parameters=frozenset(names))
                for path, names in (('publicNoToken/sendSmsCode', {'phone', 'businessNo'}),
                                    ('checkToken', {'phone', 'token', 'delete', 'trustDevice'})))
    if school_session:
        rows.extend([RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jxzxehall/cookies', 'POST',
            body_parameters=frozenset({'username', 'password', 'challenge_id'}), body_parameter_variants=SCHOOL_AUTHENTICATION_BODIES),
            RequestContract(r'login\.bit101\.flwfdd\.xyz', r'/api/auth/[^/]+')])
        if allow_sms and probe in set().union(*(SCHOOL_SMS_PROBES[purpose] for purpose in ('webvpn', 'jwb', 'jwb_cjd'))):
            rows.append(RequestContract(r'login\.bit101\.flwfdd\.xyz', r'/api/auth/[^/]+/sms', 'POST',
                body_parameters=frozenset({'code'}), required_body_parameters=frozenset({'code'})))
        rows.extend(CONTRACTS['schedule.teaching-center'])
        rows.extend(CONTRACTS['score.authentication'])
    if probe in {'eclass.authentication', 'eclass.ddl'}:
        rows.extend([RequestContract(r'zy-eclass\.bit\.edu\.cn', '/user/index'),
            RequestContract(r'zy-eclass\.bit\.edu\.cn', r'/api/courses/[1-9]\d*/activities')])
    if probe in {'lexue.calendar', 'lexue.ddl'}:
        rows.extend([RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + '/'),
            RequestContract(r'webvpn\.bit\.edu\.cn', r'/https/[0-9a-f]+/', final_path=r'/https/[0-9a-f]+/cas/login', additional_parameters=frozenset({'service'})),
            *CONTRACTS['lexue.calendar']])
    if probe == 'score.transcript':
        rows.append(RequestContract(r'jwb\.bit\.edu\.cn', '/cjd/Temp/.+'))
    return rows


def requests_accounted_for(requests: list[dict], contracts: list[RequestContract], auxiliary: list[RequestContract]) -> bool:
    allowed = contracts + auxiliary
    for index, row in enumerate(requests):
        if any(contract.matches(row) for contract in allowed): continue
        if row.get('responseContentMissing') is True and any(contract.method == 'GET'
                and contract.host == re.escape(API) and contract.path in {r'/posters/\d+', r'/papers/\d+'}
                and replace(contract, statuses=(400, 404, 500)).matches(row) for contract in auxiliary): continue
        for contract in allowed:
            statuses = (401,) if contract.host == re.escape(API) else (401, 403)
            if contract in auxiliary and contract.host == r'login\.bit101\.flwfdd\.xyz': statuses += (500, 502, 503, 504)
            recovered = row.get('statusCode') in statuses and replace(contract, statuses=statuses).matches(row)
            final = dict(row, endpoint=row.get('finalEndpoint'), method=row.get('finalMethod'), query=row.get('finalQuery'))
            if row.get('statusCode') in range(200, 400) and any(auth.matches(final) for auth in auxiliary if auth.host == r'sso\.bit\.edu\.cn'):
                original = dict(row, finalEndpoint=row.get('endpoint'), finalMethod=row.get('method'), finalQuery=row.get('query'))
                recovered = recovered or replace(contract, statuses=range(200, 400)).matches(original)
            if not recovered: continue
            if any(contract.matches(later) and all(row.get(key) == later.get(key) for key in ('endpoint', 'method', 'query'))
                   for later in requests[index + 1:]): break
        else: return False
    return True


def cleanup_requests_complete(requests: list[dict]) -> bool:
    account = community('/user/info/0')
    optional = auxiliary_contracts('community.writes', [account])
    optional.extend(replace(contract, minimum=1) for contract in CONTRACTS['community.writes']
        if contract.method == 'DELETE' or contract.path in {'/reaction/like', r'/user/follow/\d+'})
    return bool(requests) and account.complete(requests) and requests_accounted_for(requests, [account], optional)


SELECTORS = {
    **{name: {'search', 'excludedSearch'} for name in ('gallery.search', 'course.search', 'paper.search')},
    **{name: {'obj'} for name in ('gallery.comments', 'course.comments', 'paper.comments')},
    **{name: {'uid'} for name in ('profile.posts', 'user.posts')},
    **{name: {'path'} for name in ('gallery.detail', 'course.detail', 'course.history', 'paper.detail',
        'user.profile', 'gallery.web', 'course.web', 'paper.web')},
    'schedule.sync': {'XNXQDM'}, 'classroom.occupancy': {'XNXQDM', 'JXLDM', 'RQ', 'XQDM', 'XNDM'}, 'classroom.buildings': {'XXXQDM'},
}


def complete(probe: str, requests: list[dict], expected_parameters: dict | None = None, *, allow_sms: bool = False) -> bool:
    selectors = SELECTORS.get(probe, set())
    if selectors and (not isinstance(expected_parameters, dict) or set(expected_parameters) != selectors
            or not all(isinstance(value, str) and value for value in expected_parameters.values())): return False
    search_probe = 'excludedSearch' in selectors
    if search_probe and expected_parameters['search'] == expected_parameters['excludedSearch']: return False
    contracts = contracts_for(probe, expected_parameters)
    matched = bool(contracts) and requests_accounted_for(requests, contracts, auxiliary_contracts(probe, contracts, allow_sms=allow_sms)) \
        and all(contract.complete(requests) for contract in contracts)
    if matched and selectors and not search_probe:
        matched = all(all((unquote(urlsplit(row[field]).path) if key == 'path' else row.get(query_field, {}).get(key)) == expected
            for key, expected in expected_parameters.items() for field, query_field in (('endpoint', 'query'), ('finalEndpoint', 'finalQuery')))
            for row in requests if any(contract.matches(row) and (probe != 'gallery.search' or contract.query.get('search') is not None) for contract in contracts))
    if matched and probe == 'community.session':
        return len(requests) == 3 and contracts[0].matches(requests[0]) \
            and contracts[1].matches(requests[1]) and contracts[0].matches(requests[2])
    if matched and probe == 'classroom.occupancy':
        year, _, semester = expected_parameters['XNXQDM'].rpartition('-')
        if expected_parameters['XNDM'] != year or expected_parameters['XQDM'] != semester: return False
        try: date.fromisoformat(expected_parameters['RQ'])
        except ValueError: return False
    if matched and probe == 'update.emergency':
        for row in requests:
            if not contracts[0].matches(row): continue
            configuration = row.get('responseConfiguration')
            if not isinstance(configuration, dict) or not re.fullmatch(r'[0-9a-f]{64}', configuration.get('digest', '')) \
                    or type(configuration.get('enabled')) is not bool: return False
            notice = configuration.get('noticeID')
            if configuration['enabled'] and (not isinstance(notice, str) or not notice.strip()): return False
    if matched and probe in {'gallery.image', 'paper.image'}:
        if not isinstance(expected_parameters, dict) or set(expected_parameters) != {'resourceDigests'}: return False
        value = expected_parameters['resourceDigests']
        if not isinstance(value, str): return False
        expected = set(value.split(','))
        if not expected or any(not re.fullmatch(r'[0-9a-f]{64}', digest) for digest in expected): return False
        return {row.get('endpointDigest') for row in requests if contracts[0].matches(row)} == expected
    if matched and probe in {'eclass.authentication', 'eclass.ddl'}:
        pages = [row for row in requests if contracts[0].matches(row)]
        expected = set()
        total_pages = pages[0].get('responseCoursePage', {}).get('pages') if isinstance(pages[0].get('responseCoursePage'), dict) else None
        for index, row in enumerate(pages, 1):
            ids, metadata = row.get('responseCourseIDs'), row.get('responseCoursePage')
            if not isinstance(ids, list) or len(ids) > 100 or not all(isinstance(value, str)
                and re.fullmatch(r'[1-9]\d*', value) for value in ids) or not isinstance(metadata, dict): return False
            if row.get('query', {}).get('page') != str(index) or metadata.get('pages') != total_pages: return False
            if metadata.get('page') is not None and (type(metadata['page']) is not int or metadata['page'] != index): return False
            if ids and not set(ids) - expected: return False
            expected.update(ids)
            if total_pages is not None:
                if type(total_pages) is not int or total_pages < 0 or len(pages) != max(1, total_pages) \
                    or total_pages == 0 and ids or not ids and index < len(pages): return False
            elif (len(ids) < 100) != (index == len(pages)): return False
        activity = RequestContract(r'zy-eclass\.bit\.edu\.cn', r'/api/courses/[1-9]\d*/activities')
        observed = set()
        for row in requests:
            if activity.matches(row):
                path = urlsplit(row['endpoint']).path
                if path != urlsplit(row['finalEndpoint']).path: return False
                observed.add(path.split('/')[3])
        return observed == expected
    if matched and probe == 'community.writes':
        comments = [row for row in requests if community('/reaction/comments', method='POST', query={'obj': r'(?:poster|paper|course|comment)\d+'}).matches(row)]
        from collections import Counter
        replies = Counter((row['query']['obj'], frozenset({'reply_obj', 'reply_uid'}) <= set(row.get('bodyParameterNames', [])))
            for row in comments if row.get('query', {}).get('obj', '').startswith('comment')
            and (frozenset({'reply_obj', 'reply_uid'}) <= set(row.get('bodyParameterNames', [])))
                == (frozenset({'reply_obj', 'reply_uid'}) <= set(row.get('finalBodyParameterNames', []))))
        deleted = {urlsplit(row['endpoint']).path for row in requests if community(r'/reaction/comments/\d+', method='DELETE').matches(row)}
        likes = Counter(row.get('query', {}).get('obj') for row in requests if community('/reaction/like', method='POST', query={'obj': r'(?:poster|paper|course|comment)\d+'}).matches(row))
        user_pages = {row.get('query', {}).get('page', '0') for row in requests if
            community('/posters', query={'mode': 'search', 'uid': r'[1-9]\d*', 'order': None, 'search': None}).matches(row)}
        followed = Counter(urlsplit(row['endpoint']).path for row in requests if community(r'/user/follow/\d+', method='POST').matches(row))
        return {'0', '1'} <= user_pages and sum(obj.startswith('comment') and count >= 2 for obj, count in likes.items()) >= 3 \
            and sum(replies[(obj, False)] >= 1 and replies[(obj, True)] >= 1 for obj in {obj for obj, _ in replies}) >= 3 \
            and len(deleted) >= 9 and any(count >= 2 for count in followed.values()) \
            and all(any(isinstance(obj, str) and re.fullmatch(kind + r'\d+', obj) and count >= 2
                for obj, count in likes.items()) for kind in ('poster', 'paper', 'course'))
    return matched


if __name__ == '__main__':
    import json
    payload = json.load(sys.stdin)
    passed = complete(payload['probe'], payload['requests'], payload.get('expectedParameters'))
    if not passed: print('生产请求与 Smoke 合同存在差异：' + payload['probe'], file=sys.stderr)
    raise SystemExit(0 if passed else 1)
