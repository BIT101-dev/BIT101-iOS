#!/usr/bin/env python3
"""Match smoke responses to business routes and explicit pagination requests."""
from dataclasses import dataclass, field
import re
import sys
from urllib.parse import urlsplit

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

    def matches(self, request: dict) -> bool:
        try:
            endpoint = urlsplit(request['endpoint'])
            declared_port = endpoint.port
            port = declared_port if declared_port is not None else (443 if endpoint.scheme == 'https' else 80)
        except ValueError: return False
        query = request.get('query', {})
        return endpoint.scheme == self.scheme and request['statusCode'] in self.statuses \
            and (self.port is None or port == self.port) \
            and request['method'] == self.method and re.fullmatch(self.host, endpoint.hostname or '') is not None \
            and re.fullmatch(self.path, endpoint.path) is not None \
            and all(key not in query if pattern is None else re.fullmatch(pattern, query.get(key, '')) is not None
                for key, pattern in self.query.items())

    def complete(self, requests: list[dict]) -> bool:
        rows = [request for request in requests if self.matches(request)]
        if len(rows) < self.minimum: return False
        if not self.paging: return True
        values = [row.get('query', {}).get(self.paging) for row in rows]
        initial = str(sys.maxsize) if self.paging == 'last_id' else '0'
        normalized = [initial if value is None and self.paging == 'page' else value for value in values]
        if len(rows) < 2 or normalized[0] != initial: return False
        if self.paging == 'page': return '1' in normalized[1:]
        return all(isinstance(cursor, str) and re.fullmatch(r'[1-9]\d*', cursor)
            and isinstance(minimum := previous.get('responseMinimumID'), str) and re.fullmatch(r'\d+', minimum)
            and str(max(1, int(minimum))) == cursor for previous, cursor in zip(rows, normalized[1:]))


def community(path: str, *, query: dict | None = None, minimum: int = 1, paging: str = '', method: str = 'GET',
              statuses: range | tuple[int, ...] = range(200, 300)) -> RequestContract:
    return RequestContract(re.escape(API), path, method, query or {}, minimum, paging, statuses=statuses)


def teaching(path: str, method: str = 'GET', *, query: dict | None = None) -> RequestContract:
    return RequestContract(SCHOOL, VPN + re.escape(path), method, query or {})


CONTRACTS = {
    'BIT101 登录状态': [community('/user/check')],
    '话廊最新列表': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': None, 'hide_bot': None}, paging='page')],
    '话廊关注流': [community('/posters', query={'mode': 'follow', 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    '话廊热门流': [community('/posters', query={'mode': 'hot', 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    '话廊推荐流': [community('/posters', query={'mode': None, 'order': None, 'uid': None, 'search': None, 'hide_bot': None}, paging='page')],
    '话廊机器人流': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': None, 'hide_bot': None}, paging='page')],
    '话廊搜索': [community('/posters', query={'mode': 'search', 'order': 'new', 'uid': '-1', 'search': 'BIT101', 'hide_bot': None}, paging='page')],
    '话廊帖子详情': [community(r'/posters/\d+')],
    '话廊帖子评论': [community('/reaction/comments', query={'obj': r'poster\d+'}, paging='page')],
    '帖子声明列表': [community('/posters/claims')],
    '社区举报类型': [community('/manage/report_types')],
    '消息未读数': [community('/messages/unread_nums')],
    '学业课程列表': [community('/courses', paging='page')],
    '学业课程详情': [community(r'/courses/\d+')],
    '学业课程评论': [community('/reaction/comments', query={'obj': r'course\d+'}, paging='page')],
    '学业课程历史成绩': [community('/courses/histories/.+')],
    '文章列表': [community('/papers', query={'order': None}, paging='page')],
    '文章详情': [community(r'/papers/\d+')],
    '文章评论': [community('/reaction/comments', query={'obj': r'paper\d+'}, paging='page')],
    '我的资料': [community('/user/info/0')],
    '生产共享会话': [community('/user/info/0', minimum=2), community('/user/info/0', statuses=(401,))],
    '我的关注': [community('/user/followings', paging='page')],
    '我的粉丝': [community('/user/followers', paging='page')],
    '我的帖子': [community('/posters', query={'mode': 'search', 'uid': r'\d+'}, paging='page')],
    '用户帖子': [community('/posters', query={'mode': 'search', 'uid': r'\d+'}, paging='page')],
    '用户资料详情': [community(r'/user/info/\d+')],
    '当前学期': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do')],
    '生产学校会话': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/dqxnxq.do')],
    '教学中心接口预热': [teaching('/jwapp/sys/funauthapp/api/getAppConfig/wdkbby-5959167891382285.do'), teaching('/jwapp/i18n.do')],
    '切换学期列表': [teaching('/jwapp/sys/wdkbby/modules/jshkcb/xnxqcx.do')],
    '课表、考试与首周同步': [teaching(path, 'POST', query={'XNXQDM': '.+'}) for path in (
        '/jwapp/sys/wdkbby/modules/xskcb/cxxszhxqkb.do', '/jwapp/sys/wdksapMobile/modules/ksap/cxxsksap.do',
        '/jwapp/sys/wdkbby/wdkbByController/cxzkbrq.do')],
    '空教室校区列表': [teaching('/jwapp/sys/kxjasbyMobile/modules/jxllb/ggzdpx.do')],
    '空教室教学楼列表': [teaching('/jwapp/sys/kxjasbyMobile/modules/jxllb/cxjxl.do')],
    '空教室占用数据': [teaching('/jwapp/sys/kxjasbyMobile/kxjasbyController/cxkxjasqk.do', 'POST', query={'XNXQDM': '.+', 'JXLDM': '.+'})],
    '课程中心原生认证': [RequestContract(r'zy-eclass\.bit\.edu\.cn', '/api/my-courses', 'POST')],
    '课程中心 DDL 下载': [RequestContract(r'zy-eclass\.bit\.edu\.cn', '/api/my-courses', 'POST')],
    '乐学日历订阅地址': [RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + '/calendar/export.php', 'POST')],
    '乐学 DDL 下载': [RequestContract(r'(?:lexue|webvpn)\.bit\.edu\.cn', VPN + '/calendar/export_execute.php')],
    '成绩认证接口': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/auth/start', 'POST')],
    '成绩简略列表': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/bit101/score', 'POST', {'detail': 'false'})],
    '成绩详细列表': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/bit101/score', 'POST', {'detail': 'true'})],
    '可信成绩单接口': [RequestContract(r'login\.bit101\.flwfdd\.xyz', '/api/jwb/cjd/cookies', 'POST'),
        RequestContract(r'jwb\.bit\.edu\.cn', '/cjd/ScoreReport2/Index')],
    'App 链接关联配置': [RequestContract(r'open\.aihelpme\.dev', '/.well-known/apple-app-site-association')],
    '分享图标下载': [RequestContract(r'open\.aihelpme\.dev', '/share-icon.jpg')],
    'open.aihelpme.dev 首页跳转': [RequestContract(r'open\.aihelpme\.dev', '/?')],
    '话廊网页详情': [RequestContract(r'open\.aihelpme\.dev', r'/gallery/\d+')],
    '学业课程网页详情': [RequestContract(r'open\.aihelpme\.dev', r'/course/\d+')],
    '文章网页详情': [RequestContract(r'open\.aihelpme\.dev', r'/paper/\d+')],
    '话廊图片下载': [RequestContract(r'.+', '/.+', port=None)],
    '反馈接口跨域预检': [RequestContract(r'feedback\.aihelpme\.dev', '/api/error-reports', 'OPTIONS')],
    'feedback.aihelpme.dev 写入恢复': [RequestContract(r'feedback\.aihelpme\.dev', '/api/error-reports', 'POST')],
    'App Store 更新接口': [RequestContract(r'(?:itunes|apps)\.apple\.com', '/lookup')],
    '紧急更新配置接口': [RequestContract(r'update\.aihelpme\.dev', '/emergency-update.json')],
    '社区写入与清理': [community('/posters', method='POST'), community(r'/posters/\d+', method='DELETE'),
        community(r'/posters/\d+', method='PUT'), community('/papers', method='POST'),
        community(r'/papers/\d+', method='DELETE'), community(r'/papers/\d+', method='PUT'),
        community('/upload/image', method='POST', minimum=5),
        *[community('/reaction/comments', method='POST', query={'obj': kind + r'\d+'}, minimum=minimum)
            for kind, minimum in (('poster', 1), ('paper', 1), ('course', 1), ('comment', 3))],
        community(r'/reaction/comments/\d+', method='DELETE', minimum=6),
        *[community('/reaction/like', method='POST', query={'obj': kind + r'\d+'}, minimum=2)
            for kind in ('poster', 'paper', 'course')],
        community(r'/user/follow/\d+', method='POST', minimum=2)],
}


def contracts_for(probe: str) -> list[RequestContract]:
    if probe.startswith('消息列表-'):
        return [community('/messages', query={'type': re.escape(probe.removeprefix('消息列表-'))}, paging='last_id')]
    if probe.startswith('文章列表-'):
        orders = {'最新': None, '高赞': 'like', '热评': 'comment'}
        title = probe.removeprefix('文章列表-')
        return [community('/papers', query={'order': orders[title]}, paging='page')] if title in orders else []
    return CONTRACTS.get(probe, [])


def complete(probe: str, requests: list[dict], expected_parameters: dict | None = None) -> bool:
    contracts = contracts_for(probe)
    matched = bool(contracts) and all(contract.complete(requests) for contract in contracts)
    selectors = {'课表、考试与首周同步': {'XNXQDM'}, '空教室占用数据': {'XNXQDM', 'JXLDM'}}.get(probe, set())
    if matched and selectors:
        if not isinstance(expected_parameters, dict) or set(expected_parameters) != selectors \
                or not all(isinstance(value, str) and value for value in expected_parameters.values()): return False
        matched = all(all(row.get('query', {}).get(key) == expected for key, expected in expected_parameters.items())
            for row in requests if any(contract.matches(row) for contract in contracts))
    if matched and probe == '生产共享会话':
        return len(requests) == 3 and contracts[0].matches(requests[0]) \
            and contracts[1].matches(requests[1]) and contracts[0].matches(requests[2])
    if matched and probe == '社区写入与清理':
        comments = [row for row in requests if community('/reaction/comments', method='POST').matches(row)]
        replies = {row.get('query', {}).get('obj') for row in comments if row.get('query', {}).get('obj', '').startswith('comment')}
        deleted = {urlsplit(row['endpoint']).path for row in requests if community(r'/reaction/comments/\d+', method='DELETE').matches(row)}
        from collections import Counter
        likes = Counter(row.get('query', {}).get('obj') for row in requests if community('/reaction/like', method='POST').matches(row))
        followed = Counter(urlsplit(row['endpoint']).path for row in requests if community(r'/user/follow/\d+', method='POST').matches(row))
        return len(replies) >= 3 and len(deleted) >= 6 and any(count >= 2 for count in followed.values()) \
            and all(any(isinstance(obj, str) and re.fullmatch(kind + r'\d+', obj) and count >= 2
                for obj, count in likes.items()) for kind in ('poster', 'paper', 'course'))
    return matched


if __name__ == '__main__':
    import json
    payload = json.load(sys.stdin)
    passed = complete(payload['probe'], payload['requests'], payload.get('expectedParameters'))
    if not passed: print('生产请求与 Smoke 合同存在差异：' + payload['probe'], file=sys.stderr)
    raise SystemExit(0 if passed else 1)
