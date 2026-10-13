#!/usr/bin/env python3
"""Validate BIT101 marketing/build versions without invoking Xcode or a simulator."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
import plistlib
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT_PATH = ROOT / "BIT101-iOS.xcodeproj/project.pbxproj"
APP_STORE_LOOKUP_URL = "https://itunes.apple.com/lookup?id=6761147125&country=cn"
SEMVER_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def extract_versions(project_text: str) -> tuple[str, int]:
    marketing_values = re.findall(r"MARKETING_VERSION\s*=\s*([^;\s]+)\s*;", project_text)
    build_values = re.findall(r"CURRENT_PROJECT_VERSION\s*=\s*([^;\s]+)\s*;", project_text)

    if not marketing_values or not build_values:
        raise ValueError("工程中缺少 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION")
    if len(set(marketing_values)) != 1:
        raise ValueError(f"各 Target/Configuration 的版本号不一致：{sorted(set(marketing_values))}")
    if len(set(build_values)) != 1:
        raise ValueError(f"各 Target/Configuration 的 Build 不一致：{sorted(set(build_values))}")

    marketing_version = marketing_values[0]
    build_text = build_values[0]
    if not SEMVER_PATTERN.fullmatch(marketing_version):
        raise ValueError(f"版本号必须为三段数字，例如 1.7.1；当前为 {marketing_version}")
    if not build_text.isdigit() or int(build_text) <= 0:
        raise ValueError(f"Build 必须为正整数；当前为 {build_text}")

    return marketing_version, int(build_text)


def version_tuple(value: str) -> tuple[int, int, int]:
    if not SEMVER_PATTERN.fullmatch(value):
        raise ValueError(f"无法比较非三段数字版本号：{value}")
    return tuple(int(component) for component in value.split("."))  # type: ignore[return-value]


def validate_release_tag(tag: str, version: str) -> None:
    if tag != "v" + version:
        raise ValueError(f"发布标签 {tag} 需要对应工程版本 v{version}")


def validate_plists() -> None:
    plist_paths = [
        ROOT / "AppInfo.plist",
        ROOT / "BIT101Watch/Info.plist",
        ROOT / "BIT101ScheduleWidgets/Info.plist",
        ROOT / "BIT101WatchWidgets/Info.plist",
    ]
    for path in plist_paths:
        with path.open("rb") as file:
            plist = plistlib.load(file)
        if plist.get("CFBundleShortVersionString") != "$(MARKETING_VERSION)":
            raise ValueError(f"{path.relative_to(ROOT)} 未引用 $(MARKETING_VERSION)")
        if plist.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)":
            raise ValueError(f"{path.relative_to(ROOT)} 未引用 $(CURRENT_PROJECT_VERSION)")
        if path.name == "AppInfo.plist" and (plist.get('UIRequiresFullScreen', False) is not False
                or set(plist.get('UISupportedInterfaceOrientations~ipad', [])) != {
                    'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
                    'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'}):
            raise ValueError('iPad 配置需要支持旋转与系统窗口尺寸调整')


def project_text_at_git_ref(ref: str) -> str:
    result = subprocess.run(
        ["git", "show", f"{ref}:BIT101-iOS.xcodeproj/project.pbxproj"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def validate_not_older_than_ref(ref: str, version: str, build: int) -> None:
    old_version, old_build = extract_versions(project_text_at_git_ref(ref))
    if version_tuple(version) < version_tuple(old_version):
        raise ValueError(f"版本号从 {old_version} 倒退为 {version}")
    if build < old_build:
        raise ValueError(f"Build 从 {old_build} 倒退为 {build}")
    if version != old_version and build <= old_build:
        raise ValueError(f"版本号已变化，但 Build 未高于基准值 {old_build}")


def app_store_version() -> str:
    request = urllib.request.Request(
        APP_STORE_LOOKUP_URL + "&" + urllib.parse.urlencode({"requestTime": int(time.time())}),
        headers={"Accept": "application/json", "User-Agent": "BIT101-Version-CI/1.0", "Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        origin = urllib.parse.urlsplit(response.geturl())
        if response.status != 200 or origin.scheme != 'https' or origin.hostname != 'itunes.apple.com' \
                or origin.port not in (None, 443) or origin.username or origin.password or origin.path != '/lookup':
            raise ValueError('Apple Lookup API 响应需要来自原查询端点')
        payload = json.load(response)
    results = payload.get('results') if isinstance(payload, dict) else None
    count = payload.get('resultCount') if isinstance(payload, dict) else None
    if type(count) is not int or count <= 0 or not isinstance(results, list) or count != len(results) \
            or not isinstance(results[0], dict):
        raise ValueError('Apple Lookup API 的记录数量需要匹配有效结果')
    result = results[0]
    if result.get('bundleId') != 'BIT101-dev.BIT101-iOS' or type(result.get('trackId')) is not int \
            or result['trackId'] != 6761147125 or not isinstance(result.get('version'), str):
        raise ValueError('Apple Lookup API 需要返回 BIT101 的应用身份与版本')
    version_tuple(result['version'])
    if not isinstance(result.get('trackViewUrl'), str): raise ValueError('Apple Lookup API 需要有效的商店链接')
    url = urllib.parse.urlsplit(result['trackViewUrl'])
    if url.scheme != 'https' or url.hostname != 'apps.apple.com' or url.port not in (None, 443) \
            or url.username or url.password or 'id6761147125' not in url.path.split('/'):
        raise ValueError('Apple Lookup API 的商店链接需要匹配 BIT101')
    date = result.get('currentVersionReleaseDate')
    if not isinstance(date, str) or 'T' not in date or datetime.fromisoformat(date).tzinfo is None:
        raise ValueError('Apple Lookup API 需要有效的发布时刻')
    return result['version']


def app_store_request_self_test() -> list[str]:
    from io import StringIO
    from unittest.mock import patch
    valid = dict(resultCount=1, results=[dict(version='99.0.0', bundleId='BIT101-dev.BIT101-iOS', trackId=6761147125,
        trackViewUrl='https://apps.apple.com/cn/app/bit101/id6761147125', currentVersionReleaseDate='2026-01-01T00:00:00Z')])
    def response(payload, url=APP_STORE_LOOKUP_URL, status=200):
        value = StringIO(json.dumps(payload))
        value.geturl = lambda: url
        value.status = status
        return value
    findings = []
    validate_release_tag("v2.0.0", "2.0.0")
    for tag in ("v9.0.0", "v2.0", "v2.0.0-rc1"):
        try: validate_release_tag(tag, "2.0.0")
        except ValueError: pass
        else: findings.append("发布版本自测：标签与工程公开版本对应")
    for instant in (100, 200):
        with patch.object(time, "time", return_value=instant), patch.object(urllib.request, "urlopen",
                return_value=response(valid)) as opener:
            if app_store_version() != "99.0.0": findings.append("发布版本自测：商店版本解析")
            request = opener.call_args.args[0]
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)
            if query != {"id": ["6761147125"], "country": ["cn"], "requestTime": [str(instant)]} \
                    or request.get_header("Cache-control") != "no-cache":
                findings.append("发布版本自测：商店查询缓存刷新契约")
    invalid = [[], {}, dict(valid, resultCount=0), dict(valid, resultCount=True), dict(valid, results=[])]
    for field, value in [('bundleId', 'other.application'), ('trackId', 1), ('version', ''),
            ('currentVersionReleaseDate', 'invalid'), ('currentVersionReleaseDate', '2026-01-01'),
            ('trackViewUrl', 'https://apps.apple.com/cn/app/other/id1'),
            ('trackViewUrl', 1),
            ('trackViewUrl', 'https://apps.apple.com@fixture.invalid/id6761147125')]:
        invalid.append(dict(valid, results=[dict(valid['results'][0], **{field: value})]))
    for payload, url, status in [(payload, APP_STORE_LOOKUP_URL, 200) for payload in invalid] + [
            (valid, 'https://fixture.invalid/lookup', 200), (valid, 'https://itunes.apple.com/other', 200),
            (valid, 'http://itunes.apple.com/lookup', 200), (valid, APP_STORE_LOOKUP_URL, 201)]:
        with patch.object(urllib.request, 'urlopen', return_value=response(payload, url, status)):
            try: app_store_version()
            except ValueError: pass
            else: findings.append('发布版本自测：应用身份、记录数量、发布时间和响应端点需要匹配')
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compare-git-ref", help="拒绝相对指定 Git ref 的版本或 Build 倒退")
    parser.add_argument("--release-tag", default=os.environ.get("GITHUB_REF", "").removeprefix("refs/tags/")
        if os.environ.get("GITHUB_REF", "").startswith("refs/tags/") else "", help="发布标签与工程版本对应")
    parser.add_argument(
        "--check-app-store",
        action="store_true",
        help="发布前确认本地公开版本高于 App Store 当前版本",
    )
    args = parser.parse_args()

    try:
        version, build = extract_versions(PROJECT_PATH.read_text(encoding="utf-8"))
        validate_plists()
        if args.release_tag:
            validate_release_tag(args.release_tag, version)
        if args.compare_git_ref:
            validate_not_older_than_ref(args.compare_git_ref, version, build)
        if args.check_app_store:
            live_version = app_store_version()
            if version_tuple(version) <= version_tuple(live_version):
                raise ValueError(
                    f"发布检查失败：本地 {version} 必须高于 App Store 当前版本 {live_version}"
                )
            print(f"App Store 发布检查通过：{live_version} -> {version}")
        print(f"版本检查通过：{version} ({build})")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"版本检查失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
