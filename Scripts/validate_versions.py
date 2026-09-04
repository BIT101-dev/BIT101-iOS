#!/usr/bin/env python3
"""Validate BIT101 marketing/build versions without invoking Xcode or a simulator."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
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
        APP_STORE_LOOKUP_URL,
        headers={"Accept": "application/json", "User-Agent": "BIT101-Version-CI/1.0"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = json.load(response)
    results = payload.get("results") or []
    if not results or not isinstance(results[0].get("version"), str):
        raise ValueError("Apple Lookup API 未返回 BIT101 版本")
    return results[0]["version"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compare-git-ref", help="拒绝相对指定 Git ref 的版本或 Build 倒退")
    parser.add_argument(
        "--check-app-store",
        action="store_true",
        help="发布前确认本地公开版本高于 App Store 当前版本",
    )
    args = parser.parse_args()

    try:
        version, build = extract_versions(PROJECT_PATH.read_text(encoding="utf-8"))
        validate_plists()
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
