"""Check shared UI source rules."""

from __future__ import annotations
from pathlib import Path
import re
import sys
from ui_source_facts import (
    ROOT,
    call_name,
    child_view_entries,
    mask_comments,
    mask_literals_and_comments,
    rendered_scope_facts,
    source_text,
    swift_files,
)


def is_interactive_list_row(row: dict, facts: dict) -> bool:
    if row["name"] == "LabeledContent":
        return False
    if any(
        item["scope"] == row["scope"] and item["start"] <= row["start"] < item["end"]
        for item in facts.get("nonRenderedRanges", [])
    ):
        return False
    if set(row.get("containers", [])) & {"List", "Form", "Section"}:
        return True
    # 按列表引用追踪返回 View 的属性和函数，核对实际渲染的交互行。
    helpers = []
    for binding in facts.get("bindings", []):
        match = re.match(
            r"(\w+)\s*:\s*some\s+View\s*\{", mask_literals_and_comments(binding["value"])
        )
        if match and binding["scope"] == row["scope"]:
            helpers.append(
                {
                    "name": match[1],
                    "start": binding["start"],
                    "end": binding["start"] + len(binding["value"].encode()),
                }
            )
    helpers += [
        item
        for item in facts.get("functionRanges", [])
        if item["scope"] == row["scope"] and item.get("returnsView")
    ]
    ranges = [
        (item["start"], item["start"] + len(item["invocation"].encode()))
        for item in facts.get("listControls", [])
        if item["scope"] == row["scope"]
    ]
    reachable = set()
    while ranges:
        start, end = ranges.pop()
        symbols = {
            item["value"]
            for item in facts.get("scopedIdentifiers", [])
            if item["scope"] == row["scope"] and start <= item["start"] < end
        }
        for helper in helpers:
            if helper["name"] in symbols and helper["name"] not in reachable:
                reachable.add(helper["name"])
                ranges.append((helper["start"], helper["end"]))
    return any(
        helper["name"] in reachable and helper["start"] <= row["start"] < helper["end"]
        for helper in helpers
    )


def interactive_list_row_findings(path: Path, facts: dict, syntax: dict[str, dict]) -> list[str]:
    """逐行核对样式；标题组件的显式前景色同样接受检查。"""
    findings = []
    neutral = re.compile(
        (
            "\\.foreground(?:Style|Color)\\s*\\(\\s*(?:AppDesignSystem\\.(?:Foreground\\.(?:second"
            "ary|tertiary)|Course\\.accent|Schedule\\.tabAccent|Palette\\.(?:Accent|Highlight)\\.["
            "\\w]+)|\\.(?:tint|secondary|tertiary|black|white|gray))\\s*\\)"
        )
    )

    def title_override(
        owner: dict, start: int, end: int, scope: list[str], visited: set[str]
    ) -> bool:
        texts = [
            item
            for item in owner.get("invocations", [])
            if start <= item["start"] < end
            and item["scope"] == scope
            and re.match(r"Text\s*\(", item["value"])
        ]
        labeled = [
            item
            for item in owner.get("accessibilityControls", [])
            if item["name"] == "LabeledContent"
            and start <= item["start"] < end
            and item["scope"] == scope
        ]
        first_text = min((item["start"] for item in texts), default=sys.maxsize)
        if labeled and min(item["start"] for item in labeled) < first_text:
            content = min(labeled, key=lambda item: item["start"])
            suffix = content["expression"][len(content["invocation"]) :]
            if neutral.search(mask_literals_and_comments(suffix)):
                return True
            return content["labelStart"] >= 0 and title_override(
                owner, content["labelStart"], content["labelEnd"], scope, visited
            )
        if texts:
            first_start = min(item["start"] for item in texts)
            expression = max(
                (item["value"] for item in texts if item["start"] == first_start), key=len
            )
            return bool(neutral.search(mask_literals_and_comments(expression)))
        for call in owner.get("calls", []):
            if not start <= call["start"] < end or call["scope"] != scope:
                continue
            for child_path, child, child_scope in child_view_entries(syntax, call["value"], scope):
                key = f"{child_path}:{'.'.join(child_scope)}"
                if key in visited:
                    continue
                rendered = rendered_scope_facts(child, child_scope, syntax)
                if title_override(rendered, 0, sys.maxsize, child_scope, visited | {key}):
                    return True
        return False

    def value_override(row: dict) -> bool:
        start, end = row["labelStart"], row["labelEnd"]
        if start < 0:
            return False
        labeled = [
            item
            for item in facts.get("accessibilityControls", [])
            if item["name"] == "LabeledContent" and start <= item["start"] < end
        ]
        trailing = re.compile(
            (
                "\\.foreground(?:Style|Color)\\s*\\(\\s*(?:AppDesignSystem\\.Foreground\\.[\\w]+|"
                "\\.(?:primary|secondary|tertiary))\\s*\\)"
            )
        )
        for item in labeled:
            content_end = (
                item["labelStart"]
                if item["labelStart"] >= 0
                else item["start"] + len(item["invocation"].encode())
            )
            expressions = [
                node["value"]
                for node in facts.get("invocations", [])
                if re.match(r"Text\s*\(", node.get("value", ""))
                and item["start"] <= node["start"] < content_end
            ]
            if any(trailing.search(mask_literals_and_comments(value)) for value in expressions):
                return True
        spacers = [
            node["start"]
            for node in facts.get("invocations", [])
            if node.get("calledExpression") == "Spacer" and start <= node["start"] < end
        ]
        if not labeled and spacers:
            texts = [
                node["value"]
                for node in facts.get("invocations", [])
                if re.match(r"Text\s*\(", node.get("value", ""))
                and min(spacers) < node["start"] < end
            ]
            if any(trailing.search(mask_literals_and_comments(value)) for value in texts):
                return True
        return False

    for row in facts.get("accessibilityControls", []):
        if row["name"] in {
            "TextField",
            "SecureField",
            "TextEditor",
            "Slider",
            "Stepper",
            "ScrollView",
            "List",
            "TabView",
            "onTapGesture",
            "onLongPressGesture",
            "gesture",
            "simultaneousGesture",
            "highPriorityGesture",
            "refreshable",
            "onSubmit",
            "onDelete",
            "onMove",
            "searchable",
            "contextMenu",
            "swipeActions",
        }:
            continue
        if not is_interactive_list_row(row, facts):
            continue
        suffix = mask_literals_and_comments(row["expression"][len(row["invocation"]) :])
        line = source_text(path).encode()[: row["start"]].count(b"\n") + 1 if path.is_file() else 1
        location = f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}:{line}"
        has_list_style = re.search(r"\.appInteractiveListRow\s*\(", suffix)
        if re.search(r"\.buttonStyle\s*\(\s*\.borderedProminent\s*\)", suffix):
            if has_list_style:
                findings.append(f"{location}: 填充按钮应沿用系统文字样式")
            continue
        if not has_list_style:
            findings.append(f"{location}: {row['name']} 交互列表行必须接入 appInteractiveListRow")
        if re.search(
            r"\brole\s*:\s*\.destructive\b", mask_comments(row["invocation"]).split("label:", 1)[0]
        ) and not re.search(r"appInteractiveListRow\s*\(\s*isDestructive:\s*true", suffix):
            findings.append(f"{location}: 删除列表行必须使用警示色")
        if neutral.search(suffix) or (
            row["labelStart"] >= 0
            and title_override(facts, row["labelStart"], row["labelEnd"], row["scope"], set())
        ):
            findings.append(f"{location}: 交互列表行左侧标题沿系统主文字色")
        if value_override(row):
            findings.append(f"{location}: 交互列表行右侧值使用页面主题色")
    return findings


def list_semantics_findings(syntax: dict[str, dict]) -> list[str]:
    findings = []
    for path, facts in syntax.items():
        for call in facts.get("invocations", []):
            name = call_name(call["calledExpression"])
            labels = call.get("argumentLabels", []) + call.get("trailingClosureLabels", [])
            if name == "Section" and "footer" in labels:
                line = facts["source"].encode()[: call["start"]].count(b"\n") + 1
                findings.append(
                    f"{path}:{line}: 列表分组内容使用正文行，Section footer 说明需要清理"
                )
            if call.get("scope", []) == ["AppListSectionHeader"] and name in {
                "font",
                "foregroundStyle",
                "foregroundColor",
            }:
                findings.append(f"{path}: 列表分组标题继承系统样式")
            if not (
                name == ("Image")
                and any(
                    (
                        value in str(call.get(("arguments"), []))
                        for value in (("chevron.right"), ("chevron.forward"), ("arrow.right"))
                    )
                )
            ):
                continue
            expression = mask_literals_and_comments(
                max(
                    (
                        node.get("value", "")
                        for node in facts.get("invocations", [])
                        if node["start"] == call["start"]
                    ),
                    key=len,
                    default="",
                )
            )
            if re.search(
                (
                    "\\.foreground(?:Style|Color)\\(\\s*(?:\\.tint|AppDesignSystem\\.(?:Course"
                    "\\.accent|Schedule\\.tabAccent))"
                ),
                expression,
            ):
                findings.append(f"{path}: 列表披露箭头沿系统符号颜色")
        refresh = [
            call
            for call in facts.get("accessibilityControls", [])
            if call["scope"] == ["AppRefreshStatusRow"] and call["name"] == "Button"
        ]
        if not (refresh):
            continue
        text = max(
            (
                call["value"]
                for call in facts.get("invocations", [])
                if re.match(r"Text\s*\(\s*trailingText\s*\)", call.get("value", ""))
            ),
            key=len,
            default="",
        )
        body_font = r"\.font\(\s*AppDesignSystem\.Typography\.body\s*\)"
        if not re.search(body_font, text) or any(
            not re.search(body_font, row["expression"]) for row in refresh
        ):
            findings.append(f"{path}: 更新时间行的操作和只读标记共同使用正文字号")
    return findings


def check_interactive_list_colors(errors: list[str], syntax: dict[str, dict]) -> None:
    errors.extend(list_semantics_findings(syntax))
    for path in swift_files():
        errors.extend(interactive_list_row_findings(path, syntax[str(path)], syntax))
