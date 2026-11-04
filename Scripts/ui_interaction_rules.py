"""Check shared UI source rules."""

from __future__ import annotations
from pathlib import Path
from collections import Counter
import json
import re
from ui_source_facts import (
    ROOT,
    call_name,
    image_only_label_facts,
    view_scopes,
)
from ui_design_contracts import (
    SWIFTUI_INTERACTION_KINDS as INTERACTION_KINDS,
    SWIFTUI_CONTROL_ACTIONS,
    SWIFTUI_MODIFIER_ACTIONS,
    SWIFTUI_GESTURE_MODIFIERS,
)
from ui_native_interactions import (
    native_interaction_inventory,
    native_runtime_controls,
)


def resolved_interaction_name(types, path, call):
    from swift_source_index import canonical_type_scope

    name = call["value"].removesuffix(".init")
    if call_name(name) in INTERACTION_KINDS:
        return call_name(name)
    resolved = types.terminal_name(path, name, call["scope"] + call.get("lexicalScope", []))
    parts = canonical_type_scope([resolved])
    return parts[-1] if parts else call_name(name)


def inventory_component_names(syntax: dict[str, dict], types: object) -> set[str]:
    target_modules = ("DesignSystemKit", "CommunityUI", "MediaKit")
    components = set()
    for path, facts in syntax.items():
        if not any(f"/{module}/" in path for module in target_modules):
            continue
        for scope in view_scopes(facts):
            matched = any(
                resolved_interaction_name(types, path, call) in INTERACTION_KINDS
                and call["scope"][: len(scope)] == scope
                for call in facts["calls"]
            )
            if matched:
                components.add(scope[0])
    return components


def interaction_source_inventory(syntax: dict[str, dict]) -> dict[str, dict[str, int]]:
    from swift_type_index import SwiftTypeIndex

    types = SwiftTypeIndex(syntax)
    components = inventory_component_names(syntax, types)
    inventory = {}
    for path, facts in syntax.items():
        if any(
            Path(path).is_relative_to(ROOT / root)
            for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")
        ):
            continue
        for scope in {tuple(call["scope"]) for call in facts["calls"]}:
            controls = Counter(
                resolved_interaction_name(types, path, call)
                for call in facts["calls"]
                if tuple(call["scope"]) == scope
                and resolved_interaction_name(types, path, call) in INTERACTION_KINDS | components
                and call["value"] not in {"onSubmit", "onDelete", "onMove"}
            )
            if controls:
                inventory[
                    Path(path).relative_to(ROOT).as_posix() + ":" + (".".join(scope) or "global")
                ] = dict(sorted(controls.items()))
    for source, controls in native_interaction_inventory(syntax).items():
        inventory[source] = dict(sorted((Counter(inventory.get(source, {})) + controls).items()))
    return dict(sorted(inventory.items()))


def source_inventory_findings(
    syntax: dict[str, dict], documented: dict[str, tuple[dict, set]], tests: set[str]
) -> list[str]:
    actual = interaction_source_inventory(syntax)
    errors = []
    for source, controls in actual.items():
        contract, journeys = documented.get(source, ({}, set()))
        if controls != contract:
            errors.append(f"UI 源码交互清单需要同步：{source}")
        if not journeys or any(
            journey not in tests | {"manual:watch", "manual:widget", "manual:web-interactions"}
            for journey in journeys
        ):
            errors.append(f"UI 源码交互需要验收归属：{source}")
        for journey in journeys:
            if journey.startswith("manual:") and not manual_source_matches(source, journey):
                errors.append(f"UI 手工验收归属需要匹配平台：{source} · {journey}")
    errors.extend(
        f"UI 源码交互清单需要清理：{source}" for source in documented.keys() - actual.keys()
    )
    return errors


def manual_source_matches(source: str, journey: str) -> bool:
    return (
        journey == "manual:watch"
        and source.startswith("BIT101Watch/")
        or journey == "manual:widget"
        and source.startswith(("BIT101ScheduleWidgets/", "BIT101WatchWidgets/"))
    )


def configured_interactions() -> dict[str, tuple[dict, set]]:
    records = json.loads((ROOT / "Scripts/ui-interactions.json").read_text())
    return {
        source: (record["controls"], set(record["tests"])) for source, record in records.items()
    }


def interaction_selector(control: dict, syntax: dict) -> tuple[str, tuple[str, ...]] | None:
    if "nativeSelector" in control:
        return control["nativeSelector"]
    literal = r'"((?:[^"\\]|\\.)+)"'
    if control["name"] in {"refreshable", "onSubmit", "onDelete", "onMove"}:
        marker = re.search(
            r"interactionEvidence\??\(\s*" + literal, control.get("callback", control["invocation"])
        )
        return ("identifier", (marker[1],)) if marker else None
    modifiers = control.get("modifiers", control["expression"])
    identifiers = re.findall(r"\.accessibilityIdentifier\(\s*" + literal + r"\s*\)", modifiers)
    if identifiers:
        return "identifier", (identifiers[-1],)
    forwarded = re.search(
        r"\.accessibilityIdentifier\(\s*(\w+)\s*\?\?\s*" + literal + r"\s*\)", modifiers
    )
    if forwarded:
        names = {forwarded[2]}
        for facts in syntax.values():
            for call in facts.get("invocations", []):
                if control["scope"] and call_name(call["value"]) == control["scope"][-1]:
                    names.update(
                        re.findall(
                            r"\b" + re.escape(forwarded[1]) + r":\s*" + literal, call["value"]
                        )
                    )
        return "identifier", tuple(sorted(names))
    label = re.search(r"\.accessibilityLabel\(\s*" + literal + r"\s*\)", modifiers)
    if ".accessibilityLabel(" in modifiers and not label:
        return None
    title = (
        re.match(r"\w+\(\s*" + literal, control.get("carrierInvocation", control["invocation"]))
        if control.get("hasTextTitle")
        else None
    )
    label_content = re.search(r"\b(?:Text|Label|LabeledContent)\(\s*" + literal, control["label"])
    prompt = re.search(r"AppInputPrompt\.text\(\s*" + literal + r"\s*\)", control["invocation"])
    selector = label or title or label_content or prompt
    return ("label", (selector[1],)) if selector else None


def gesture_actions(control: dict, facts: dict, types, path: str) -> set[str]:
    kinds = {
        "MagnificationGesture": "pinch",
        "MagnifyGesture": "pinch",
        "RotationGesture": "rotate",
        "LongPressGesture": "press",
        "TapGesture": "tap",
        "DragGesture": "pan",
    }
    invocation = next(
        (
            node
            for node in facts.get("invocations", [])
            if node["start"] == control["start"] and node.get("value") == control["invocation"]
        ),
        None,
    )
    if not invocation or not invocation.get("argumentRanges"):
        return {"pan"}
    start, end = invocation["argumentRanges"][0]
    closures = facts.get("callableRanges", []) + facts.get("inlineClosureRanges", [])
    return {
        kinds[name]
        for node in facts.get("invocations", [])
        if start <= node["start"] < end
        and not any(
            start <= closure["start"] <= node["start"] < closure["end"] for closure in closures
        )
        if (
            name := types.terminal_name(
                path, node.get("calledExpression", ""), node["scope"]
            ).removeprefix("SwiftUI.")
        )
        in kinds
    } or {"pan"}


def resolve_control_action(
    control: dict, gestures: set[str], actions: dict[str, str], native_actions: dict[str, str]
) -> str:
    native = control.get("nativeAction")
    if native:
        return native
    name = control["name"]
    if name == "onTapGesture":
        return "tap"
    if name == "onLongPressGesture":
        return "press"
    if name in gestures:
        return "gesture"
    return actions.get(name, native_actions.get(name, ""))


def source_runtime_interaction_findings(
    syntax: dict[str, dict], documented: dict[str, tuple[dict, set]], evidence: list[dict]
) -> list[str]:
    from validation_compilation import active_swift_source
    from swift_type_index import SwiftTypeIndex

    types = SwiftTypeIndex(syntax)
    actions, native_actions, gestures = (
        SWIFTUI_MODIFIER_ACTIONS,
        SWIFTUI_CONTROL_ACTIONS,
        SWIFTUI_GESTURE_MODIFIERS,
    )
    errors = []
    selectors = Counter()
    contracts = {}
    expressions = {}
    carriers = {}
    native = native_runtime_controls(syntax)
    for path, facts in syntax.items():
        if any(
            Path(path).is_relative_to(ROOT / root)
            for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")
        ):
            continue
        active = (
            active_swift_source(Path(path).read_text(), "ui", path=path).encode()
            if Path(path).is_file()
            else None
        )
        for control in (
            facts.get("accessibilityControls", [])
            + facts.get("accessibilityControlCandidates", [])
            + native.get(path, [])
        ):
            if "nativeAction" not in control:
                control = dict(
                    control,
                    name=resolved_interaction_name(
                        types, path, dict(control, value=control["name"])
                    ),
                )
                if control["name"] not in native_actions.keys() | gestures | actions.keys():
                    continue
            if active is not None and active[control["start"] : control["start"] + 1] == b" ":
                continue
            source = (
                Path(path).relative_to(ROOT).as_posix()
                + ":"
                + (".".join(control["scope"]) or "global")
            )
            journeys = documented.get(source, ({}, set()))[1]
            tests = {journey for journey in journeys if not journey.startswith("manual:")}
            if (
                not tests
                and journeys
                and all(manual_source_matches(source, journey) for journey in journeys)
            ):
                continue
            selector = interaction_selector(control, syntax)
            if selector is None:
                errors.append(
                    f"源码交互需要明确的标识或标签约定：{source} · {control['name']} · {control['start']}"
                )
                continue
            kind, names = selector
            action = resolve_control_action(control, gestures, actions, native_actions)
            required = (
                gesture_actions(control, facts, types, path) if action == "gesture" else {action}
            )
            if control["name"] == "accessibilityAction":
                named = re.search(
                    r'accessibilityAction\(\s*named:\s*"((?:[^"\\]|\\.)+)"', control["invocation"]
                )
                if named:
                    action += ":" + named[1]
                required = {action}
            for action in required:
                key = (source, kind, names, action)
                selectors[key] += 1
                contracts[key] = tests
                expressions.setdefault(key, set()).add(control["expression"])
                carriers.setdefault(key, set()).add((path, control["start"]))

    def shares_carrier(key, other):
        native_carrier = len(expressions[key]) == 1 and next(iter(expressions[key])).startswith(
            "UIKit:"
        )
        return (
            (key[0] == other[0] or native_carrier)
            and key[1:3] == other[1:3]
            and key[3] != other[3]
            and (
                len(carriers[key]) == 1
                and carriers[key] == carriers[other]
                or any(
                    action in {"scroll", "keyboard"} or action.startswith("accessibility")
                    for action in (key[3], other[3])
                )
            )
            and len(expressions[key]) == 1
            and expressions[key] == expressions[other]
        )

    demands = []
    for (source, kind, names, action), count in selectors.items():
        key = (source, kind, names, action)
        overlaps = any(
            other != key
            and other[1:3] == (kind, names)
            and not shares_carrier(key, other)
            and contracts[other] & contracts[(source, kind, names, action)]
            for other in selectors
        )
        if count > 1 or overlaps:
            errors.append(f"源码交互需要明确的标识区分分支：{source} · {' | '.join(names)}")
        patterns = [
            ".+".join(re.escape(part) for part in re.split(r"\\\((?:[^()]|\([^()]*\))*\)", name))
            for name in names
        ]

        def matches(row):
            scoped = any(
                all(
                    re.search(r"(?<!\w)" + re.escape(part) + r"(?!\w)", row.get("scope", ""))
                    for part in journey.split("/")
                )
                for journey in contracts[(source, kind, names, action)]
            )
            value = row.get(kind, "").strip()
            accepted_actions = (
                {"tap", "selection"}
                if action == "selection"
                else {"swipe", "drag"}
                if action == "pan"
                else {"scroll", "scroll-fit"}
                if action == "scroll"
                else {action}
            )
            return (
                scoped
                and bool(accepted_actions & set(row.get("actions", [])))
                and any(
                    re.fullmatch(pattern, value) is not None
                    or kind == "label"
                    and re.match(pattern + r",\s", value) is not None
                    for pattern in patterns
                )
            )

        shared = any(shares_carrier(key, other) for other in selectors)
        visited = {
            (row.get("instance") or json.dumps(row, sort_keys=True), action if shared else "")
            for row in evidence
            if matches(row)
        }
        demands.extend(((source, names), visited) for _ in range(count))
    owners = {}

    def assign(index, seen):
        for instance in sorted(demands[index][1] - seen):
            seen.add(instance)
            if instance not in owners or assign(owners[instance], seen):
                owners[instance] = index
                return True
        return False

    for index, ((source, names), _) in enumerate(demands):
        if not assign(index, set()):
            errors.append(f"源码交互需要独立访问证据：{source} · {' | '.join(names)}")
    return list(dict.fromkeys(errors))


def check_ui_test_inventory(errors: list[str], syntax: dict[str, dict]) -> None:
    """Keep the interaction map aligned with every executable UI journey."""
    from validation_test_areas import test_inventory
    from validation_provenance import normalized_test_id

    actual = {normalized_test_id(test) for test in test_inventory("ui")}
    document = (ROOT / "docs/UI_INTERACTION_COVERAGE.md").read_text()
    documented = set(re.findall(r"\b(\w+UITests/test\w+)\b", document))
    sources = configured_interactions()
    documented.update(
        test for _, tests in sources.values() for test in tests if not test.startswith("manual:")
    )
    errors.extend(f"UI interaction map missing: {name}" for name in sorted(actual - documented))
    errors.extend(
        f"UI interaction map references an absent journey: {name}"
        for name in sorted(documented - actual)
    )
    errors.extend(source_inventory_findings(syntax, sources, actual))
    errors.extend(
        error
        for error in source_runtime_interaction_findings(syntax, sources, [])
        if "明确的标识" in error
    )


def check_accessibility_coverage(errors: list[str], syntax: dict[str, dict]) -> None:
    for path, facts in syntax.items():
        if not path.startswith(str(ROOT) + "/") or "/BIT101-iOSTests/" in path:
            continue
        for invocation in image_only_label_facts(facts):
            errors.append(
                (
                    f"{Path(path).relative_to(ROOT)}"
                    f": "
                    f"{'.'.join(invocation['scope'])}"
                    f" 图片型操作控件需提供 accessibilityLabel（"
                    f"{invocation['value'][:96].replace(chr(10), ' ')}"
                    f"）"
                )
            )
