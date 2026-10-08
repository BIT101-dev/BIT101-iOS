"""Write permanent source-text review candidates to their fixed report."""
from pathlib import Path
import re


def write_report(root: Path) -> None:
    production_roots = tuple(root / name for name in ("Modules", "BIT101-iOS", "BIT101ScheduleWidgets", "BIT101Watch", "BIT101WatchWidgets"))
    report = root / ".build/explanatory-text-report.txt"
    # 用户确认的文案进入白名单，其余候选写入固定报告。
    APPROVED_TEXTS = {
        "使用学校统一身份认证账号密码登录。若未注册过 BIT101 账号，将自动完成注册；密码仅会经不可逆加密后传输。",
        "本 App 尚处在开发中，不保证所有功能始终可用；如遇到问题，请联系 systemd@linux.do。开发者不对使用过程中造成的损失负责。",
        "本 App 为了完成 Apple 的合规性审查，加入了一些风味元素，功能与安卓版有所差异。",
        "换个关键词试试。",
        "请稍候",
        "先选定校区和教学楼，再刷新一次。",
        "先获取乐学日程，或手动添加一条。",
        "点击右上角的加号可以先新增一个。",
        "请调整学期或种类筛选条件。",
    }
    APPROVED_DYNAMIC = {
        ("Modules/DesignSystemKit/Sources/AppVerificationComponents.swift", "verificationHint"),
    }


    def masked(source: str) -> str:
        """保留结构字符，维持插值所在块的边界。"""
        def replace(match: re.Match[str]) -> str:
            return "".join("\n" if character == "\n" else " " for character in match.group(0))

        return re.sub(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"', replace, source)


    def block(source: str, start: int) -> str:
        structure = masked(source)
        opening = structure.find("{", start)
        if opening < 0:
            return ""
        depth = 0
        for index in range(opening, len(structure)):
            if structure[index] == "{":
                depth += 1
            elif structure[index] == "}":
                depth -= 1
                if depth == 0:
                    return source[opening + 1 : index]
        return source[opening + 1 :]


    def text_expressions(source: str, path: str) -> list[str]:
        expressions: list[str] = []
        for line in source.splitlines():
            match = re.match(r"Text\((.*)\)\s*$", line.strip())
            if not match:
                continue
            expression = match.group(1)
            if expression.startswith('"'):
                if expression[1:-1] not in APPROVED_TEXTS:
                    expressions.append(expression)
            elif expression == "verificationHint" and (path, expression) not in APPROVED_DYNAMIC:
                expressions.append(expression)
        return expressions


    footer_items: list[tuple[str, int, list[str]]] = []
    description_items: list[tuple[str, int, list[str]]] = []

    for path in sorted(path for source_root in production_roots for path in source_root.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        relative_path = path.relative_to(root).as_posix()
        if path.name != "ErrorReportSupport.swift":
            for match in re.finditer(r"\bfooter\s*:\s*\{", source):
                expressions = text_expressions(block(source, match.start()), relative_path)
                if expressions:
                    footer_items.append((path.relative_to(root).as_posix(), source.count("\n", 0, match.start()) + 1, expressions))

        for match in re.finditer(r"\bdescription\s*:\s*\{", source):
            expressions = text_expressions(block(source, match.start()), relative_path)
            if expressions:
                description_items.append((relative_path, source.count("\n", 0, match.start()) + 1, expressions))

        for match in re.finditer(r"\bdescription\s*:\s*Text\((.*)\)\s*$", source, re.MULTILINE):
            expression = match.group(1)
            if expression.startswith('"') and expression[1:-1] in APPROVED_TEXTS:
                continue
            description_items.append((relative_path, source.count("\n", 0, match.start()) + 1, [expression]))


    lines = [
        "# List/Form 与 ContentUnavailableView 解释文案审查候选",
        "# 扫描 Section footer 和 ContentUnavailableView description。",
        "",
        "## Section footer",
    ]
    for path, line, expressions in footer_items:
        lines.append(f"- {path}:{line}")
        lines.extend(f"  - Text({expression})" for expression in expressions)

    lines.append("")
    lines.append("## ContentUnavailableView description")
    for path, line, expressions in description_items:
        lines.append(f"- {path}:{line}")
        lines.extend(f"  - Text({expression})" for expression in expressions)

    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
