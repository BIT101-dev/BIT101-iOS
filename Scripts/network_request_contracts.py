#!/usr/bin/env python3
"""Match smoke responses to business routes and explicit pagination requests."""
from dataclasses import dataclass, field, replace
import re
import sys
from urllib.parse import unquote, urlsplit

API = 'bit101.flwfdd.xyz'
SCHOOL = r'(?:jxzxehallapp|webvpn)\.bit\.edu\.cn'
VPN = r'(?:/https/[0-9a-f]+)?'


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
            and isinstance(minimum := previous.get('responseMinimumID'), str) and re.fullmatch(r'\d+', minimum)
            and str(max(1, int(minimum))) == cursor for previous, cursor in zip(rows, normalized[1:]))


def community(path: str, *, query: dict | None = None, minimum: int = 1, paging: str = '', method: str = 'GET',
              statuses: range | tuple[int, ...] = range(200, 300)) -> RequestContract:
    return RequestContract(re.escape(API), path, method, query or {}, minimum, paging, statuses=statuses)


def teaching(path: str, method: str = 'GET', *, query: dict | None = None) -> RequestContract:
    return RequestContract(SCHOOL, VPN + re.escape(path), method, query or {})


CONTRACTS = {
    'community.login': [community('/user/check')],
    'gallery.newest': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.following': [community('/posters', query={'mode': 'follow', 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.hot': [community('/posters', query={'mode': 'hot', 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.recommend': [community('/posters', query={'mode': None, 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.bots': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': None, 'hide_bot': None}, paging='page')],
    'gallery.search': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': 'BIT101', 'hide_bot': None}, paging='page')],
    'gallery.detail': [community(r'/posters/\d+')],
    'gallery.comments': [community('/reaction/comments', query={'obj': r'poster\d+', 'order': 'new'}, paging='page')],
    'gallery.claims': [community('/posters/claims')],
    'community.report-types': [community('/manage/report_types')],
    'message.unread': [community('/messages/unread_nums')],
    'course.list': [community('/courses', query={'order': 'new', 'search': None}, paging='page')],
    'course.detail': [community(r'/courses/\d+')],
    'course.comments': [community('/reaction/comments', query={'obj': r'course\d+', 'order': 'new'}, paging='page')],
    'course.history': [community('/courses/histories/.+')],
    'paper.list': [community('/papers', query={'order': None, 'search': None}, paging='page')],
    'paper.detail': [community(r'/papers/\d+')],
    'paper.image': [RequestContract(r'.+', '/.+', port=None)],
    'paper.comments': [community('/reaction/comments', query={'obj': r'paper\d+', 'order': 'new'}, paging='page')],
    'profile.mine': [community('/user/info/0')],
    'community.session': [community('/user/info/0', minimum=2), community('/user/info/0', statuses=(401,))],
    'profile.following': [community('/user/followings', paging='page')],
    'profile.followers': [community('/user/followers', paging='page')],
    'profile.posts': [community('/posters', query={'mode': 'search', 'uid': '0', 'order': None, 'search': None}, paging='page')],
    'user.posts': [community('/posters', query={'mode': 'search', 'uid': r'[1-9]\d*', 'order': None, 'search': None}, paging='page')],
    'user.profile': [community(r'/user/info/\d+')],
    'schedule.current-term': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do')],
    'school.session': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do')],
    'schedule.teaching-center': [teaching('/jwapp/sys/funauthapp/api/getAppConfig/wdkbby-5959167891382285.do'), teaching('/jwapp/i18n.do')],
    'schedule.terms': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/xnxqcx.do')],
    'schedule.sync': [teaching(path, 'POST', query={'XNXQDM': '.+'}) for path in (
        '/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do', '/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do',
        '/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do')],
    'classroom.campuses': [teaching('/jwapp/sys/kxjasbyMobile/modules/jxllb/ggzdpx.do')],
    'classroom.buildings': [teaching('/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do', query={'XXXQDM': '.+'})],
    'classroom.occupancy': [teaching('/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do', 'POST', query={'XNXQDM': '.+', 'JXLDM': '.+'})],
    'eclass.authentication': [RequestContract(r'zy-eclass\.bit\.edu\.cn', '/api/my-courses', 'POST')],
    'eclass.ddl': [RequestContract(r'zy-eclass\.bit\.edu\.cn', '/api/my-courses', 'POST')],
    'lexue.calendar': [RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + '/calendar/export.php', 'POST')],
    'lexue.ddl': [RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + '/calendar/export_execute.php')],
    'score.authentication': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/auth/start', 'POST')],
    'score.brief': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/bit101/score', 'POST', {'detail': 'false'})],
    'score.detail': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/bit101/score', 'POST', {'detail': 'true'})],
    'score.transcript': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/cjd/cookies', 'POST'),
        RequestContract(r'jwb\.bit\.edu\.cn', '/cjd/ScoreReport2/Index')],
    'web.association': [RequestContract(r'open\.aihelpme\.dev', '/.well-known/apple-app-site-association')],
    'web.share-icon': [RequestContract(r'open\.aihelpme\.dev', '/share-icon.jpg')],
    'web.home': [RequestContract(r'open\.aihelpme\.dev', '/?', final_host=r'bit101\.cn', final_path='/gallery/')],
    'gallery.web': [RequestContract(r'open\.aihelpme\.dev', r'/gallery/\d+')],
    'course.web': [RequestContract(r'open\.aihelpme\.dev', r'/course/\d+')],
    'paper.web': [RequestContract(r'open\.aihelpme\.dev', r'/paper/\d+')],
    'gallery.image': [RequestContract(r'.+', '/.+', port=None)],
    'feedback.preflight': [RequestContract(r'feedback\.aihelpme\.dev', '/api/error-reports', 'OPTIONS')],
    'feedback.recovery': [RequestContract(r'feedback\.aihelpme\.dev', '/api/error-reports', 'POST')],
    'update.app-store': [RequestContract(r'(?:itunes|apps)\.apple\.com', '/lookup')],
    'update.emergency': [RequestContract(r'update\.aihelpme\.dev', '/emergency-update.json')],
    'community.writes': [community('/posters', method='POST'), community(r'/posters/\d+', method='DELETE'),
        community(r'/posters/\d+', method='PUT'), community('/papers', method='POST'),
        community(r'/papers/\d+', method='DELETE'), community(r'/papers/\d+', method='PUT'),
        community('/upload/image', method='POST', minimum=4),
        *[community('/reaction/comments', method='POST', query={'obj': kind + r'\d+'}, minimum=minimum)
            for kind, minimum in (('poster', 1), ('paper', 1), ('course', 1), ('comment', 6))],
        community(r'/reaction/comments/\d+', method='DELETE', minimum=9),
        *[community('/reaction/like', method='POST', query={'obj': kind + r'\d+'}, minimum=2)
            for kind in ('poster', 'paper', 'course')],
        community(r'/user/follow/\d+', method='POST', minimum=2)],
}


def contracts_for(probe: str) -> list[RequestContract]:
    if probe.startswith('message.'):
        return [community('/messages', query={'type': re.escape(probe.removeprefix('message.'))}, paging='last_id')]
    if probe.startswith('paper.list.'):
        orders = {'newest': None, 'like': 'like', 'comment': 'comment'}
        order = probe.removeprefix('paper.list.')
        return [community('/papers', query={'order': orders[order], 'search': 'BIT101'}, paging='page')] if order in orders else []
    return CONTRACTS.get(probe, [])


def auxiliary_contracts(probe: str, contracts: list[RequestContract]) -> list[RequestContract]:
    community_session = any(contract.host == re.escape(API) for contract in contracts)
    school_session = any(contract.host in {SCHOOL, r'zy-eclass\.bit\.edu\.cn', r'(?:lexue|webvpn)\.bit\.edu\.cn',
        r'login\.bit101\.flwfdd\.xyz', r'jwb\.bit\.edu\.cn'} for contract in contracts)
    rows = []
    if probe in {'paper.detail', 'paper.comments', 'community.writes'}:
        rows.append(community('/user/check'))
    if probe == 'community.writes':
        rows.extend(community(path) for path in (r'/user/info/\d+', r'/courses/\d+', r'/posters/\d+', r'/papers/\d+'))
        rows.extend([
            community('/posters', query={'mode': 'search', 'uid': '0', 'order': None, 'search': None}),
            community('/papers', query={'order': None, 'search': '.+'}),
            community('/reaction/comments', query={'obj': r'(?:poster|paper|course|comment)\d+', 'order': 'old'}),
        ])
    if community_session:
        rows.extend(community(path, method='POST') for path in ('/user/webvpn_verify_init', '/user/webvpn_verify'))
    if community_session or school_session:
        rows.extend(RequestContract(r'sso\.bit\.edu\.cn', '/cas/login', method, statuses=range(200, 400)) for method in ('GET', 'POST'))
        rows.append(RequestContract(r'sso\.bit\.edu\.cn', '/gate/cas-success', statuses=(200, 401)))
        rows.extend(RequestContract(r'sso\.bit\.edu\.cn', '/cas/api/protected/sms/' + path, method) for path, method in (
            ('getPhoneNumberByUserId', 'GET'), ('publicNoToken/sendSmsCode', 'POST'), ('checkToken', 'POST')))
    if school_session:
        rows.extend([RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jxzxehall/cookies', 'POST'),
            RequestContract(r'login\.bit101\.flwfdd\.xyz', r'/api/auth/[^/]+'),
            RequestContract(r'login\.bit101\.flwfdd\.xyz', r'/api/auth/[^/]+/sms', 'POST')])
        rows.extend(CONTRACTS['schedule.teaching-center'])
        rows.extend(CONTRACTS['score.authentication'])
    if probe in {'eclass.authentication', 'eclass.ddl'}:
        rows.extend([RequestContract(r'zy-eclass\.bit\.edu\.cn', '/user/index'),
            RequestContract(r'zy-eclass\.bit\.edu\.cn', r'/api/courses/[1-9]\d*/activities')])
    if probe in {'lexue.calendar', 'lexue.ddl'}:
        rows.extend([RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + '/'),
            RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + '/calendar/export.php', 'POST')])
    if probe == 'score.transcript':
        rows.append(RequestContract(r'jwb\.bit\.edu\.cn', '/cjd/Temp/.+'))
    return rows


def requests_accounted_for(requests: list[dict], contracts: list[RequestContract], auxiliary: list[RequestContract]) -> bool:
    allowed = contracts + auxiliary
    for index, row in enumerate(requests):
        if any(contract.matches(row) for contract in allowed): continue
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


SELECTORS = {
    **{name: {'obj'} for name in ('gallery.comments', 'course.comments', 'paper.comments')},
    **{name: {'uid'} for name in ('profile.posts', 'user.posts')},
    **{name: {'path'} for name in ('gallery.detail', 'course.detail', 'course.history', 'paper.detail',
        'user.profile', 'gallery.web', 'course.web', 'paper.web')},
    'schedule.sync': {'XNXQDM'}, 'classroom.occupancy': {'XNXQDM', 'JXLDM'}, 'classroom.buildings': {'XXXQDM'},
}


def complete(probe: str, requests: list[dict], expected_parameters: dict | None = None) -> bool:
    contracts = contracts_for(probe)
    matched = bool(contracts) and requests_accounted_for(requests, contracts, auxiliary_contracts(probe, contracts)) \
        and all(contract.complete(requests) for contract in contracts)
    selectors = SELECTORS.get(probe, set())
    if matched and selectors:
        if not isinstance(expected_parameters, dict) or set(expected_parameters) != selectors \
                or not all(isinstance(value, str) and value for value in expected_parameters.values()): return False
        matched = all(all((unquote(urlsplit(row[field]).path) if key == 'path' else row.get(query_field, {}).get(key)) == expected
            for key, expected in expected_parameters.items() for field, query_field in (('endpoint', 'query'), ('finalEndpoint', 'finalQuery')))
            for row in requests if any(contract.matches(row) for contract in contracts))
    if matched and probe == 'community.session':
        return len(requests) == 3 and contracts[0].matches(requests[0]) \
            and contracts[1].matches(requests[1]) and contracts[0].matches(requests[2])
    if matched and probe in {'gallery.image', 'paper.image'}:
        if not isinstance(expected_parameters, dict) or set(expected_parameters) != {'resourceDigests'}: return False
        value = expected_parameters['resourceDigests']
        if not isinstance(value, str): return False
        expected = set(value.split(','))
        if not expected or any(not re.fullmatch(r'[0-9a-f]{64}', digest) for digest in expected): return False
        return {row.get('endpointDigest') for row in requests if contracts[0].matches(row)} == expected
    if matched and probe in {'eclass.authentication', 'eclass.ddl'}:
        pages = [row.get('responseCourseIDs') for row in requests if contracts[0].matches(row)]
        if not all(isinstance(ids, list) and all(isinstance(value, str) and re.fullmatch(r'[1-9]\d*', value)
            for value in ids) for ids in pages): return False
        expected = {value for ids in pages for value in ids}
        activity = RequestContract(r'zy-eclass\.bit\.edu\.cn', r'/api/courses/[1-9]\d*/activities')
        observed = set()
        for row in requests:
            if activity.matches(row):
                path = urlsplit(row['endpoint']).path
                if path != urlsplit(row['finalEndpoint']).path: return False
                observed.add(path.split('/')[3])
        return observed == expected
    if matched and probe == 'community.writes':
        comments = [row for row in requests if community('/reaction/comments', method='POST').matches(row)]
        from collections import Counter
        replies = Counter(row.get('query', {}).get('obj') for row in comments if row.get('query', {}).get('obj', '').startswith('comment'))
        deleted = {urlsplit(row['endpoint']).path for row in requests if community(r'/reaction/comments/\d+', method='DELETE').matches(row)}
        likes = Counter(row.get('query', {}).get('obj') for row in requests if community('/reaction/like', method='POST').matches(row))
        followed = Counter(urlsplit(row['endpoint']).path for row in requests if community(r'/user/follow/\d+', method='POST').matches(row))
        return sum(count >= 2 for count in replies.values()) >= 3 and len(deleted) >= 9 and any(count >= 2 for count in followed.values()) \
            and all(any(isinstance(obj, str) and re.fullmatch(kind + r'\d+', obj) and count >= 2
                for obj, count in likes.items()) for kind in ('poster', 'paper', 'course'))
    return matched


if __name__ == '__main__':
    import json
    payload = json.load(sys.stdin)
    passed = complete(payload['probe'], payload['requests'], payload.get('expectedParameters'))
    if not passed: print('生产请求与 Smoke 合同存在差异：' + payload['probe'], file=sys.stderr)
    raise SystemExit(0 if passed else 1)
