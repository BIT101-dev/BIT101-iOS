#!/usr/bin/env python3
"""逐份扫描项目源码，收口容易遗漏的代码风格约束。

硬错误会阻止静态审计；需要人工判断的事项写入固定报告，不制造新的临时文件。
"""

from __future__ import annotations

import re
import stat
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOTS = (
    ROOT / "BIT101-iOS",
    ROOT / "BIT101-iOSTests",
    ROOT / "BIT101ScheduleWidget",
    ROOT / "BIT101Watch",
    ROOT / "BIT101WatchWidgets",
)
SCRIPT_ROOT = ROOT / "Scripts"
REPORT_PATH = ROOT / ".build/code-quality-report.txt"
DESIGN_SYSTEM = ROOT / "BIT101-iOS/Shared/DesignSystem/AppDesignSystem.swift"
HAPTIC_SYSTEM = ROOT / "BIT101-iOS/Shared/DesignSystem/AppHapticFeedback.swift"

ALLOWED_STDOUT = {"BIT101-iOS/Shared/Infrastructure/ReleaseNetworkSmoke.swift"}
ALLOWED_URL_SESSION = {
    "BIT101-iOS/Shared/Infrastructure/AppUpdateChecker.swift",
    "BIT101-iOS/Shared/Infrastructure/EmergencyUpdateChecker.swift",
    "BIT101-iOS/Shared/Infrastructure/ErrorReportSupport.swift",
    "BIT101-iOS/Shared/Infrastructure/ReleaseNetworkSmoke.swift",
    "BIT101-iOS/Shared/Networking/HTTPClient.swift",
}
REMOVED_TERMS = (
    "举报并屏蔽",
    "举报该帖子",
    "屏蔽本文",
    "PaperArticleActionMenu",
    "CommunityReportAction",
    "CommunityReportService",
)
SEMANTIC_COLORS = (
    "orange",
    "red",
    "blue",
    "green",
    "pink",
    "purple",
    "yellow",
    "teal",
    "indigo",
    "brown",
    "gray",
)


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


def mask_literals_and_comments(source: str) -> str:
    """保留换行，屏蔽字符串与注释，避免把正则或文案里的 `!` 当成代码。"""
    output: list[str] = []
    index = 0
    state = "code"
    while index < len(source):
        if state == "code":
            if source.startswith("//", index):
                state = "line_comment"
                output.extend("  ")
                index += 2
            elif source.startswith("/*", index):
                state = "block_comment"
                output.extend("  ")
                index += 2
            elif source.startswith('"""', index):
                state = "multiline_string"
                output.extend("   ")
                index += 3
            elif source[index] == '"':
                state = "string"
                output.append(" ")
                index += 1
            else:
                output.append(source[index])
                index += 1
        elif state == "line_comment":
            if source[index] == "\n":
                state = "code"
                output.append("\n")
            else:
                output.append(" ")
            index += 1
        elif state == "block_comment":
            if source.startswith("*/", index):
                state = "code"
                output.extend("  ")
                index += 2
            else:
                output.append("\n" if source[index] == "\n" else " ")
                index += 1
        elif state == "multiline_string":
            if source.startswith('"""', index):
                state = "code"
                output.extend("   ")
                index += 3
            else:
                output.append("\n" if source[index] == "\n" else " ")
                index += 1
        else:
            if source[index] == "\\":
                output.extend("  ")
                index += 2
            elif source[index] == '"':
                state = "code"
                output.append(" ")
                index += 1
            else:
                output.append("\n" if source[index] == "\n" else " ")
                index += 1
    return "".join(output)


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
    numeric_layout = re.compile(
        r"\.(?:padding|frame|offset|cornerRadius|shadow|opacity|scaleEffect|spacing)\s*\([^\n]*\d"
    )
    direct_semantic_color = re.compile(
        rf"(?:\bColor\.(?:{'|'.join(SEMANTIC_COLORS)})\b|"
        rf"(?:(?:return|foregroundStyle|fill|tint)\s*\(?\s*)\.(?:{'|'.join(SEMANTIC_COLORS)})\b)"
    )
    direct_haptic = re.compile(
        r"\.sensoryFeedback\(|UIFeedbackGenerator|UI(Selection|Impact|Notification)FeedbackGenerator|"
        r"impactOccurred\(|selectionChanged\(|notificationOccurred\(|CHHapticEngine|"
        r"AudioServicesPlaySystemSound|kSystemSoundID_Vibrate|WKInterfaceDevice.*\.play"
    )
    direct_rounded_rectangle = re.compile(r"\bRoundedRectangle\s*\(")
    direct_list_style = re.compile(r"\.listStyle\(\s*\.(?:plain|insetGrouped)\s*\)|\.listSectionSpacing\(")
    direct_view_request = re.compile(r"\bURLRequest\s*\(")

    large_files: list[str] = []
    layout_counts: list[tuple[int, str]] = []
    force_unwraps: Counter[str] = Counter()
    semantic_colors: list[str] = []

    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        masked_source = mask_literals_and_comments(source)
        name = relative(path)

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

        if name not in ALLOWED_STDOUT and not name.startswith("BIT101-iOSTests/"):
            add_matches(
                errors,
                path,
                masked_source,
                re.compile(r"\b(?:print|debugPrint|NSLog)\s*\("),
                "主 App 与扩展不得直接输出日志",
            )
        if name not in ALLOWED_URL_SESSION:
            add_matches(
                errors,
                path,
                masked_source,
                re.compile(r"\bURLSession\.shared\b"),
                "网络请求必须经 HTTPClient 或场景化 Service",
            )
        if name != relative(HAPTIC_SYSTEM):
            add_matches(errors, path, masked_source, direct_haptic, "触感必须使用 AppHapticFeedback 公共接口")
        if path != DESIGN_SYSTEM:
            add_matches(errors, path, masked_source, direct_rounded_rectangle, "圆角必须使用 AppDesignSystem.roundedRectangle")
            if path.name != "GalleryMessagesView.swift":
                add_matches(errors, path, masked_source, direct_list_style, "列表样式必须使用公共设计系统修饰器")
        if path.name.endswith("View.swift") or path.name.endswith("Screen.swift"):
            add_matches(errors, path, masked_source, direct_view_request, "View 不应直接构造 URLRequest；请求移到 Service")

        for term in REMOVED_TERMS:
            if term in source:
                errors.append(f"{name}: 已移除的功能仍存在：{term}")

        if path != DESIGN_SYSTEM:
            add_matches(
                semantic_colors,
                path,
                masked_source,
                direct_semantic_color,
                "语义颜色应从 AppDesignSystem.Palette 读取",
            )

        if path != DESIGN_SYSTEM:
            count = len(numeric_layout.findall(masked_source))
            if count:
                layout_counts.append((count, name))
        force_count = len(force_unwrap.findall(masked_source))
        if force_count:
            force_unwraps[name] = force_count
        if len(source.splitlines()) > 800:
            large_files.append(name)

    # 设计系统本身允许定义语义颜色；业务代码不能再直接写颜色。
    review.extend(sorted(semantic_colors))
    if layout_counts:
        review.append(
            "固定布局值候选（仅供迁移审查）："
            + ", ".join(f"{name} × {count}" for count, name in sorted(layout_counts, reverse=True))
        )
    if force_unwraps:
        review.append(
            "强制解包候选文件（请确认是否可安全改为 guard/if let）："
            + ", ".join(f"{name} × {count}" for name, count in sorted(force_unwraps.items()))
        )
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
    docs_root = ROOT / "docs"
    for path in sorted(docs_root.rglob("*.md")):
        for target in markdown_link.findall(path.read_text(encoding="utf-8")):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target_path = (path.parent / target.split("#", 1)[0]).resolve()
            if not target_path.is_file():
                errors.append(f"{relative(path)}: 文档链接不存在：{target}")
    return errors


def main() -> int:
    errors, review = source_findings()
    errors.extend(script_findings())
    errors.extend(documentation_findings())
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
