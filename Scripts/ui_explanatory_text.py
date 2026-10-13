"""Write permanent source-text review candidates to their fixed report."""
from pathlib import Path
from swift_source_index import swift_syntax_index


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


    footer_items: list[tuple[str, int, list[str]]] = []
    description_items: list[tuple[str, int, list[str]]] = []
    paths = sorted(path for source_root in production_roots for path in source_root.rglob("*.swift"))
    index = swift_syntax_index(paths)
    for path in paths:
        facts = index[str(path)]
        source = facts['source'].encode('utf-8')
        relative_path = path.relative_to(root).as_posix()

        def approved(expression: str) -> bool:
            return expression == 'nil' or expression.startswith('"') and expression[1:-1] in APPROVED_TEXTS \
                or (relative_path, expression) in APPROVED_DYNAMIC

        for call in facts['invocations']:
            name = call['calledExpression'].removeprefix('SwiftUI.')
            if name not in {'Section', 'ContentUnavailableView', 'AppEmptyState', 'AppFailureState'}: continue
            label = 'footer' if name == 'Section' else 'description'
            if label == 'footer' and path.name == 'ErrorReportSupport.swift': continue
            arguments, labels = call.get('arguments', []), call.get('argumentLabels', [])
            expressions, ranges = [], []
            if name in {'AppEmptyState', 'AppFailureState'}:
                expressions = [arguments[i] for i, item in enumerate(labels) if item == 'message']
            else:
                all_labels = labels + call.get('trailingClosureLabels', [])
                ranges.extend(call['argumentRanges'][i] for i, item in enumerate(labels) if item == label)
                ranges.extend([start, end] for i, start, end in call.get('closureArguments', []) if all_labels[i] == label)
                expressions = [text['arguments'][0] for text in facts['invocations']
                    if text['calledExpression'] in {'Text', 'SwiftUI.Text'} and text.get('arguments')
                    and any(start <= text['start'] < end for start, end in ranges)]
            expressions = [expression for expression in expressions if not approved(expression)]
            if expressions:
                items = footer_items if label == 'footer' else description_items
                items.append((relative_path, source.count(b'\n', 0, call['start']) + 1, expressions))


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
