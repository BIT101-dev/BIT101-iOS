#!/usr/bin/env python3
"""Non-blocking reminder for tracked maintenance files that may be stale."""

from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import subprocess


MAINTAINED_SUFFIXES = {
    ".entitlements",
    ".json",
    ".md",
    ".plist",
    ".xcconfig",
    ".yaml",
    ".yml",
}
EXCLUDED_PARTS = {"Fixtures"}
EXCLUDED_SUFFIXES = {".xcodeproj", ".xcworkspace"}


def git(*arguments: str) -> str:
    return subprocess.check_output(
        ["git", *arguments],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()


def is_maintained_noncode_file(path: pathlib.PurePosixPath) -> bool:
    if path.suffix.lower() not in MAINTAINED_SUFFIXES:
        return False
    if EXCLUDED_PARTS.intersection(path.parts) or any(
        part.endswith(".xcassets") for part in path.parts
    ):
        return False
    return not any(part.endswith(tuple(EXCLUDED_SUFFIXES)) for part in path.parts)


def stale_files(days: int) -> list[tuple[int, str]]:
    now = dt.datetime.now(dt.timezone.utc)
    threshold = now - dt.timedelta(days=days)
    result: list[tuple[int, str]] = []

    for name in git("ls-files", "-z").split("\0"):
        if not name:
            continue
        path = pathlib.PurePosixPath(name)
        if not is_maintained_noncode_file(path):
            continue

        # 正在参与本次提交或仍有工作区修改的文件显然不属于“久未编辑”。
        if subprocess.run(
            ["git", "diff", "--quiet", "HEAD", "--", name],
            check=False,
        ).returncode != 0:
            continue

        timestamp = git("log", "-1", "--format=%ct", "--", name)
        if not timestamp:
            continue
        edited_at = dt.datetime.fromtimestamp(int(timestamp), tz=dt.timezone.utc)
        if edited_at < threshold:
            result.append(((now - edited_at).days, name))

    return sorted(result, key=lambda item: (-item[0], item[1]))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--all", action="store_true", help="show every stale file")
    arguments = parser.parse_args()

    files = stale_files(max(arguments.days, 1))
    if not files:
        return 0

    print(
        f"info: 检测到 {len(files)} 个非代码文件已经超过 {arguments.days} 天未编辑，"
        "请查看是否过时（非强制，可以忽略，如果确实不需要编辑）。"
    )
    visible = files if arguments.all else files[:10]
    for age, name in visible:
        print(f"  - {name}（{age} 天）")
    if len(visible) < len(files):
        print(
            f"  …其余 {len(files) - len(visible)} 个；"
            "运行 `python3 Scripts/check_stale_noncode_files.py --all` 查看全部。"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
