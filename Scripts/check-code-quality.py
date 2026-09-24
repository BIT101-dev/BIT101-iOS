#!/usr/bin/env python3
"""逐份扫描项目源码，收口容易遗漏的代码风格约束。

硬错误会阻止静态审计；需要人工判断的事项写入固定报告，不制造新的临时文件。
"""

from __future__ import annotations

import re
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOTS = (
    ROOT / "BIT101-iOS",
    ROOT / "BIT101-iOSTests",
    ROOT / "BIT101ScheduleWidgets",
    ROOT / "BIT101Watch",
    ROOT / "BIT101WatchWidgets",
)
SCRIPT_ROOT = ROOT / "Scripts"
REPORT_PATH = ROOT / ".build/code-quality-report.txt"

DIRECT_STDOUT_LOG = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")

DIRECT_SHARED_URLSESSION = re.compile(r"\bURLSession\.shared\b")

DIRECT_DATE_FORMATTER = re.compile(
    r"\b(?:DateFormatter|ISO8601DateFormatter|RelativeDateTimeFormatter)\s*\("
)

URLSESSION_EXCEPTIONS = {
    "BIT101-iOS/Shared/Client/HTTPClient.swift",
    "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift",
}

STDOUT_EXCEPTIONS = {"Shared/Client/ReleaseNetworkSmoke.swift"}


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def swift_files() -> list[Path]:
    return sorted(
        path
        for source_root in SOURCE_ROOTS
        if source_root.is_dir()
        for path in source_root.rglob("*.swift")
    )


def line_number(source: str, position: int) -> int:
    return source.count("\n", 0, position) + 1


def _blank_segment(output: list[str], source: str, start: int, end: int) -> None:
    for index in range(start, min(end, len(source))):
        if source[index] != "\n":
            output[index] = " "


def mask_comments(source: str) -> str:
    """移除注释并保留字符串，供需要识别 Swift 文案字面量的规则使用。"""
    output = list(source)
    index = 0
    depth = 0
    while index < len(source):
        if depth:
            if source.startswith("/*", index):
                depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
        elif source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
        elif source.startswith("/*", index):
            depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
        else:
            index += 1
    return "".join(output)


def mask_literals_and_comments(source: str) -> str:
    """保留换行，忽略字符串与注释，避免文案和注释伪造源码契约。"""
    output = list(source)
    index = 0
    comment_depth = 0
    while index < len(source):
        if comment_depth:
            if source.startswith("/*", index):
                comment_depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                comment_depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
            continue
        if source.startswith("/*", index):
            comment_depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
            continue

        raw_match = re.match(r"(#+)(\"{1,3})", source[index:])
        if raw_match:
            hashes, quote = raw_match.groups()
            terminator = quote + hashes
            content_start = index + len(hashes) + len(quote)
            end = source.find(terminator, content_start)
            end = len(source) if end < 0 else end + len(terminator)
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            end = len(source) if end < 0 else end + 3
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    _blank_segment(output, source, index, index + 2)
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    _blank_segment(output, source, index, index + 1)
                    index += 1
            continue

        index += 1
    return "".join(output)


def declaration_block(code: str, type_name: str) -> str:
    """返回类型或 extension 的源码块，避免用文件名和全文件关键词推断契约。"""
    declaration = re.compile(
        rf"\b(?:struct|class|enum|actor|extension)\s+{re.escape(type_name)}\b[^{{]*{{"
    ).search(code)
    if declaration is None:
        return ""
    opening = code.find("{", declaration.start(), declaration.end())
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return code[declaration.start() : index + 1]
    return code[declaration.start() :]


def has_identifier(code: str, identifier: str) -> bool:
    return re.search(rf"(?<![A-Za-z0-9_$]){re.escape(identifier)}(?![A-Za-z0-9_$])", code) is not None


def has_call(code: str, identifier: str) -> bool:
    return re.search(rf"(?<![A-Za-z0-9_$]){re.escape(identifier)}\s*\(", code) is not None


def is_view_source(path: Path, code: str) -> bool:
    if path.name.endswith(("View.swift", "Views.swift", "Screen.swift", "Screens.swift")):
        return True
    return re.search(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
        code,
    ) is not None


def view_declaration_ranges(code: str) -> list[tuple[int, int]]:
    """返回真实 View 声明的范围，避免把同文件的缓存/Loader 当成 View。"""
    ranges: list[tuple[int, int]] = []
    declaration = re.compile(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b[^{{]*{{"
    )
    for match in declaration.finditer(code):
        opening = code.find("{", match.start(), match.end())
        depth = 0
        for index in range(opening, len(code)):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
                if depth == 0:
                    ranges.append((match.start(), index + 1))
                    break
    return ranges


def add_matches(
    findings: list[str],
    path: Path,
    source: str,
    pattern: re.Pattern[str],
    message: str,
) -> None:
    for match in pattern.finditer(source):
        findings.append(f"{relative(path)}:{line_number(source, match.start())}: {message}")


def source_findings() -> tuple[list[str], list[str]]:
    errors: list[str] = []
    review: list[str] = []
    force_unwrap = re.compile(r"\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*!(?!=)|\)\s*!(?!=)")
    direct_view_request = re.compile(r"\bURLRequest\s*\(")
    direct_cancellation_check = re.compile(r"\berror\s+is\s+CancellationError\b")
    empty_catch = re.compile(r"\bcatch\s*\{\s*\}")
    unsafe_concurrency_escape = re.compile(
        r"\bnonisolated\s*\(\s*unsafe\s*\)|@\s*unchecked\s+Sendable"
    )

    large_files: list[str] = []
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        masked_source = mask_literals_and_comments(source)
        name = relative(path)

        if path.is_relative_to(ROOT / "BIT101-iOS"):
            if name.removeprefix("BIT101-iOS/") not in STDOUT_EXCEPTIONS:
                for match in DIRECT_STDOUT_LOG.finditer(masked_source):
                    finding_line = source.count("\n", 0, match.start()) + 1
                    errors.append(f"{name}:{finding_line}: 调试输出统一由网络 smoke 维护")

            if name not in URLSESSION_EXCEPTIONS:
                for match in DIRECT_SHARED_URLSESSION.finditer(masked_source):
                    finding_line = source.count("\n", 0, match.start()) + 1
                    errors.append(f"{name}:{finding_line}: 网络请求统一通过 HTTPClient 或场景化 Service")

            if name.removeprefix("BIT101-iOS/").split("/", 1)[0] in {"Course", "Gallery", "Paper"} and is_view_source(path, masked_source):
                for match in DIRECT_DATE_FORMATTER.finditer(masked_source):
                    finding_line = source.count("\n", 0, match.start()) + 1
                    errors.append(
                        f"{name}:{finding_line}: 社区日期解析统一使用 AppDateText"
                    )

        if source and not source.endswith("\n"):
            errors.append(f"{name}: 文件末尾缺少换行")
        if "\t" in source:
            errors.append(f"{name}: Swift 源码不得使用 Tab 缩进")
        if any(line.rstrip() != line for line in source.splitlines()):
            errors.append(f"{name}: 存在行尾空白")
        import_lines = [
            (match.start(), match.group(1), source.count("\n", 0, match.start()) + 1)
            for match in re.finditer(r"^import\s+([^\s]+)", source, re.MULTILINE)
        ]
        # 同一条件分支内相邻的重复 import 通常是复制残留；#if/#else 两个分支各自
        # 引入同一模块属于必要代码，不报告。
        for index, (position, module, line) in enumerate(import_lines[:-1]):
            next_position, next_module, next_line = import_lines[index + 1]
            if module == next_module and next_line - line <= 1:
                errors.append(f"{name}:{line}: 重复 import {module}")

        if re.search(r"^\s*#if\s+false\b", masked_source, re.MULTILINE):
            errors.append(f"{name}: 不应保留 #if false 死代码块")
        add_matches(errors, path, masked_source, re.compile(r"\b(?:TODO|FIXME|HACK)\b"), "请清理遗留 TODO/FIXME/HACK")

        if name != relative(ROOT / "BIT101-iOS/Shared/Client/TaskCancellation.swift"):
            add_matches(errors, path, masked_source, direct_cancellation_check, "任务取消必须通过 TaskCancellation.matches 统一识别")
        add_matches(errors, path, masked_source, empty_catch, "禁止静默吞掉异常；请记录诊断或显式处理错误")
        add_matches(errors, path, masked_source, unsafe_concurrency_escape, "禁止绕过 Swift 并发安全检查：请表达真实隔离或使用锁/Actor")
        view_ranges = view_declaration_ranges(masked_source)
        for match in direct_view_request.finditer(masked_source):
            if any(start <= match.start() < end for start, end in view_ranges):
                errors.append(
                    f"{name}:{line_number(source, match.start())}: "
                    "View 不应直接构造 URLRequest；请求移到 Service"
                )

        force_count = len(force_unwrap.findall(masked_source))
        if force_count:
            errors.append(f"{name}: 禁止强制解包，共 {force_count} 处；请改用 guard/if let/#require")
        if len(source.splitlines()) > 800:
            large_files.append(name)

    if large_files:
        review.append("大型文件候选（按独立生命周期拆分，不因长度机械拆分）：" + ", ".join(large_files))
    return errors, review


def script_findings() -> list[str]:
    errors: list[str] = []
    for path in sorted(SCRIPT_ROOT.glob("*")):
        if path.suffix not in {".sh", ".py"} or not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
        if not source.startswith("#!"):
            errors.append(f"{relative(path)}: 脚本缺少 shebang")
        if not (path.stat().st_mode & stat.S_IXUSR):
            errors.append(f"{relative(path)}: 脚本缺少用户可执行权限")
        if path.name != "check-code-quality.py" and path.suffix == ".py" and "py_compile" in source:
            errors.append(f"{relative(path)}: 不应使用 py_compile 生成无用的 __pycache__")
        if path.name != "check-code-quality.py" and re.search(
            r"(?:mktemp|date[^\n]*%|uuidgen|\$\$)\s*[^\n]*(?:/|PATH|DIR|FILE|OUTPUT)",
            source,
        ):
            errors.append(f"{relative(path)}: 输出路径疑似带时间、UUID或进程号，禁止无限新建同类产物")
    return errors


def documentation_findings() -> list[str]:
    errors: list[str] = []
    markdown_link = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
    markdown_files = [
        path
        for path in ROOT.rglob("*.md")
        if ".git" not in path.parts
        and ".build" not in path.parts
        and "build" not in path.parts
        and "node_modules" not in path.parts
        and "Fixtures" not in path.parts
    ]
    for path in sorted(markdown_files):
        for target in markdown_link.findall(path.read_text(encoding="utf-8")):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target_path = (path.parent / target.split("#", 1)[0]).resolve()
            if not target_path.is_file():
                errors.append(f"{relative(path)}: 文档链接不存在：{target}")
    return errors


def automatic_school_fetch_findings() -> list[str]:
    """保证启动、回前台和账号切换不会重新引入学校/WebVPN 自动请求。"""
    errors: list[str] = []
    forbidden_identifiers = (
        "SchoolDataRefreshCoordinator",
        "refreshOnEntry",
        "ScheduleAutoRefreshPreferences",
        "ScoreAutomaticRefreshPolicy",
        "autoRefreshCourses",
        "prepareClassroomIfNeeded",
        "refreshClassroomMetaInBackgroundIfNeeded",
        "claimAutomaticPreparation",
    )
    forbidden_literals = ("schedule.auto-refresh", "silent-refresh")
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        code = mask_literals_and_comments(source)
        literals = mask_comments(source)
        for term in forbidden_identifiers:
            if has_identifier(code, term):
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")
        for term in forbidden_literals:
            if term in literals:
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")

    app_source = (ROOT / "BIT101-iOS/BIT101_iOSApp.swift").read_text(encoding="utf-8")
    app_code = mask_literals_and_comments(app_source)
    if has_call(app_code, "refreshFromCloudIfNeeded"):
        errors.append("BIT101-iOS/BIT101_iOSApp.swift: 启动生命周期不得自动拉取 iCloud 数据")

    schedule_source = (ROOT / "BIT101-iOS/Schedule/ScheduleViewModel.swift").read_text(encoding="utf-8")
    schedule_code = mask_literals_and_comments(schedule_source)
    if re.search(r"\bScheduleCloudSyncManager\.shared\.refreshFromCloudIfNeeded\s*\(", schedule_code):
        errors.append("BIT101-iOS/Schedule/ScheduleViewModel.swift: 日程页面本地恢复不得自动拉取 iCloud")

    score_source = (ROOT / "BIT101-iOS/Score/ScoreRootView.swift").read_text(encoding="utf-8")
    score_code = mask_literals_and_comments(score_source)
    if re.search(r"\bawait\s+viewModel\.bootstrapIfNeeded\s*\(", score_code):
        errors.append("BIT101-iOS/Score/ScoreRootView.swift: 成绩页不得自动触发学校查询")
    required_manual_contracts = {
        "BIT101-iOS/Score/ScoreRootView.swift": (
            lambda source, code: has_call(code, "restoreCachedDataIfNeeded"),
            "restoreCachedDataIfNeeded",
        ),
        "BIT101-iOS/Schedule/FreeClassroomViews.swift": (
            lambda source, code: re.search(
                r"\bactionTitle\s*:\s*[^\n]*\"刷新空教室\"", mask_comments(source)
            )
            is not None,
            "刷新空教室",
        ),
        "BIT101-iOS/Schedule/ScheduleRootView.swift": (
            lambda source, code: has_call(code, "startClassroomPageRefresh"),
            "startClassroomPageRefresh",
        ),
        "BIT101-iOS/Schedule/ScheduleViewModel+Classroom.swift": (
            lambda source, code: has_call(code, "waitForClassroomAuthentication"),
            "waitForClassroomAuthentication",
        ),
        "BIT101-iOS/Schedule/ScheduleViewModel+CourseSync.swift": (
            lambda source, code: ".classroomRefresh" in code,
            ".classroomRefresh",
        ),
    }
    for file_name, (predicate, marker) in required_manual_contracts.items():
        path = ROOT / file_name
        if path.is_file():
            source = path.read_text(encoding="utf-8")
            if predicate(source, mask_literals_and_comments(source)):
                continue
            errors.append(f"{file_name}: 缺少显式学校请求/验证码入口：{marker}")
    return errors


def architectural_contract_findings() -> list[str]:
    """检查已确认的模块关系，防止同一概念在新文件中重新分叉。"""
    errors: list[str] = []
    sources = {
        path: mask_literals_and_comments(path.read_text(encoding="utf-8"))
        for path in swift_files()
    }

    required_conformances = {
        "CoursePagedState": "PagedItemsState",
        "GalleryFeedState": "PagedItemsState",
        "GalleryMessageListState": "CursorPagedItemsState",
        "GalleryCommentState": "PagedItemsState",
        "MinePagedState": "PagedItemsState",
        "PaperListState": "PagedItemsState",
    }
    for type_name, protocol_name in required_conformances.items():
        pattern = re.compile(
            rf"\bextension\s+{re.escape(type_name)}\s*:\s*[^{{\n]*\b{re.escape(protocol_name)}\b"
        )
        if not any(pattern.search(source) for source in sources.values()):
            errors.append(
                f"{type_name}: 缺少已统一的分页结构约束：{protocol_name}"
            )

    community_services = (
        "CourseService",
        "GalleryService",
        "MineService",
        "PaperService",
        "SettingsNetworkService",
    )
    for type_name in community_services:
        blocks = [
            declaration_block(source, type_name)
            for source in sources.values()
            if declaration_block(source, type_name)
        ]
        if not blocks:
            errors.append(f"{type_name}: 找不到社区服务声明")
            continue
        if not any(
            re.search(r"\bCommunityAPIClient\s*(?:<|[A-Za-z_])", block)
            and re.search(r"\bCommunityAPIClient\s*\(", block)
            for block in blocks
        ):
            errors.append(
                f"{type_name}: 社区服务必须通过 CommunityAPIClient 初始化网络边界"
            )

    storage_contracts = (
        ("ScheduleCacheStore", "BIT101-iOS/Schedule/ScheduleCacheStore.swift"),
        ("ComposerDraftStore", "BIT101-iOS/Gallery/GalleryComposerView.swift"),
    )
    for type_name, file_name in storage_contracts:
        blocks = [
            declaration_block(source, type_name)
            for source in sources.values()
            if declaration_block(source, type_name)
        ]
        if not any("AppFileDirectories.applicationSupport" in block for block in blocks):
            errors.append(
                f"{file_name}: 持久化仓库必须复用 AppFileDirectories.applicationSupport"
            )

    for path in sorted((ROOT / "BIT101-iOS").rglob("*.swift")):
        if not path.name.endswith(("ViewModel.swift", "ViewModels.swift")):
            continue
        source = sources[path]
        if not has_identifier(source, "TaskCancellation") and not has_call(source, "isCancellation"):
            errors.append(f"{relative(path)}: 状态模型必须统一处理任务取消，不能把取消当成业务失败")

    return errors


def audit_wiring_findings() -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    if "run_group ui-consistency ui_consistency" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入统一 UI 审计")
    if "run_group code-quality code_quality" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入统一代码质量审计")
    if "check_stale_docs.py" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入文档状态检查")
    if "release-network-smoke" in audit_source:
        errors.append("Scripts/run-static-audit.sh: 静态审计不得调用网络 smoke")

    workflow_path = ROOT / ".github/workflows/ci.yml"
    if not workflow_path.is_file():
        errors.append(".github/workflows/ci.yml: CI 工作流不存在")
    else:
        workflow_source = workflow_path.read_text(encoding="utf-8")
        required_ci_rules = (
            ("Scripts/run-static-audit.sh", "CI 未执行统一静态审计"),
            ("static-audit:", "CI 未声明静态审计 Job"),
            ("release_build:", "CI 未提供发布前远程编译开关"),
            ("release-build:", "CI 未声明发布编译 Job"),
            ("xcodebuild build-for-testing", "发布编译 Job 未保留 build-for-testing"),
            ("generic/platform=iOS", "发布编译不得默认选择模拟器"),
            ("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "发布编译未将 Swift 警告视为错误"),
            ("GCC_TREAT_WARNINGS_AS_ERRORS=YES", "发布编译未将 Clang 警告视为错误"),
        )
        for marker, message in required_ci_rules:
            if marker not in workflow_source:
                errors.append(f".github/workflows/ci.yml: {message}")
    return errors


def main() -> int:
    errors, review = source_findings()
    errors.extend(script_findings())
    errors.extend(documentation_findings())
    errors.extend(automatic_school_fetch_findings())
    errors.extend(architectural_contract_findings())
    errors.extend(audit_wiring_findings())
    audit_doc = (ROOT / "docs/CODE_QUALITY_AUDIT.md").read_text(encoding="utf-8")
    if re.search(r"行号|行数", audit_doc):
        errors.append("docs/CODE_QUALITY_AUDIT.md: 不记录行号或行数")

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    report_lines = [
        "# 逐份源码质量审查",
        "",
        f"扫描 Swift 文件：{len(swift_files())} 个",
        "",
        "## 需要修复",
        *(errors or ["无"]),
        "",
        "## 人工审查候选",
        *(review or ["无"]),
        "",
    ]
    REPORT_PATH.write_text("\n".join(report_lines), encoding="utf-8")

    if errors:
        print("[失败] 代码质量检查：")
        print("\n".join(errors))
        print(f"报告：{relative(REPORT_PATH)}")
        return 1
    print(f"[通过] 代码质量检查（逐份扫描 {len(swift_files())} 个 Swift 文件；审查候选见 {relative(REPORT_PATH)}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
