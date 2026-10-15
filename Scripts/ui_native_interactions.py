"""Resolve UIKit constructors and their actual interaction evidence contracts."""
import re
from pathlib import Path
from swift_source_index import ROOT, canonical_type_scope, expected_argument_types
from swift_type_index import SwiftTypeIndex, SwiftBindingTypes

NATIVE_INTERACTION_ACTIONS = {
    "UIAction": "tap", "UIButton": "tap", "UIBarButtonItem": "tap", "UITextField": "input", "UITextView": "input",
    "UISwitch": "tap", "UISlider": "drag", "UIStepper": "tap", "UISegmentedControl": "selection",
    "UIPageControl": "selection", "UIPickerView": "selection", "UIDatePicker": "selection", "UIScrollView": "scroll",
    "UITapGestureRecognizer": "tap", "UILongPressGestureRecognizer": "press", "UIPanGestureRecognizer": "pan",
    "UIPinchGestureRecognizer": "pinch", "UISwipeGestureRecognizer": "swipe", "UIRotationGestureRecognizer": "rotate",
}
NATIVE_INTERACTION_KINDS = set(NATIVE_INTERACTION_ACTIONS)
LITERAL = r'"((?:[^"\\]|\\.)+)"'


def native_controls(syntax: dict):
    types = SwiftTypeIndex(syntax)
    bindings = SwiftBindingTypes(syntax, types)
    constructor_names = NATIVE_INTERACTION_KINDS | {owner[-1] for namespace, owner in types.records
        if (namespace, owner) in types.aliases or any(base.removeprefix("UIKit.") in NATIVE_INTERACTION_KINDS
            for base in types.bases((namespace, owner)))}
    for path, facts in syntax.items():
        if any(Path(path).is_relative_to(ROOT / root) for root in ("ModuleTests", "BIT101-iOSTests", "BIT101-iOSUITests")): continue
        for call in facts.get("invocations", []):
            called = call["value"].split("(", 1)[0].strip()
            candidates = [called.removesuffix(".init")]
            if called == ".init":
                candidates = expected_argument_types(facts, call, context=bindings, path=path)
                returns = [value for value in facts.get("functionReturns", []) if value["start"] == call["start"]]
                candidates += [function.get("returnType", "") for function in facts.get("functionRanges", [])
                    if function["start"] <= call["start"] < function["end"]
                    and any(value["name"] == function["name"] and value["scope"] == function["scope"] for value in returns)]
                for binding in facts.get("bindings", []):
                    if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode()):
                        typed = re.match(r"\w+\s*:\s*([^=]+)=", binding["value"])
                        if typed: candidates.append(typed[1].strip())
            for candidate in candidates:
                parts = canonical_type_scope([candidate])
                if not parts or parts[-1] not in constructor_names: continue
                owner = types.resolve(path, candidate, call["scope"] + call.get("lexicalScope", []))
                candidate = types.terminal_name(path, candidate, call["scope"] + call.get("lexicalScope", []))
                parts = canonical_type_scope([candidate])
                bases = types.bases(owner) if owner else set()
                kind = parts[-1] if parts and parts[-1] in NATIVE_INTERACTION_KINDS else next(
                    (base.removeprefix("UIKit.") for base in sorted(bases)
                     if base.removeprefix("UIKit.") in NATIVE_INTERACTION_KINDS), None)
                if kind:
                    if kind == 'UIBarButtonItem' and re.search(r'\b(?:systemItem|barButtonSystemItem):\s*(?:UIBarButtonItem\.SystemItem)?\.(?:flexibleSpace|fixedSpace)\b', call['value']): continue
                    if kind == 'UIBarButtonItem' and re.search(r'\bcustomView:', call['value']): continue
                    action = NATIVE_INTERACTION_ACTIONS[kind]
                    if kind == "UITextView":
                        for binding in facts.get("bindings", []):
                            if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode()):
                                name = re.escape(binding.get("bindingName", ""))
                                if any(value["scope"] == call["scope"]
                                    and value.get("lexicalScope", []) == binding.get("lexicalScope", [])
                                    and re.fullmatch(name + r'\.isEditable\s*=\s*false', value["value"])
                                    for value in facts.get("expressions", [])): action = "tap"
                    yield path, facts, dict(call, name=kind, owner=owner, nativeAction=action)
                    break


def native_interaction_inventory(syntax: dict) -> dict:
    from collections import Counter
    inventory = {}
    for path, _, call in native_controls(syntax):
        source = Path(path).relative_to(ROOT).as_posix() + ":" + (".".join(call["scope"]) or "global")
        inventory.setdefault(source, Counter())[call["name"]] += 1
    return inventory


def native_selector(syntax, types, path, facts, call):
    action = call["nativeAction"]
    end = call["start"] + len(call["value"].encode())
    bindings = [binding for binding in facts.get("bindings", [])
        if binding["start"] <= call["start"] < binding["start"] + len(binding["value"].encode())]
    binding = min(bindings, key=lambda value: len(value["value"])) if bindings else None
    setup = [value["value"] for value in facts.get("invocations", []) if binding
        and value["scope"] == call["scope"]
        and value.get("calledExpression", "").removeprefix("self.") == binding.get("bindingName", "") + ".addTarget"]
    targets = re.findall(r'#selector\(\s*(?:[\w.]+\.)?(\w+)\s*(?:\(|\))', " ".join([call["value"], *setup]))
    ranges = [(call["start"], end)] + [(function["start"], function["end"])
        for function in facts.get("functionRanges", []) if function["scope"] == call["scope"] and function["name"] in targets]
    for invocation in facts.get("invocations", []):
        if not any(start <= invocation["start"] < finish for start, finish in ranges): continue
        marker = re.fullmatch(r'(?:self\??\.)?interactionEvidence\??\(\s*' + LITERAL + r'\s*,\s*' + LITERAL + r'\s*\)', invocation["value"])
        if marker and marker[2] == action:
            return ("identifier", (marker[1],)), "callback:" + marker[1]
    if call["name"] == "UIAction":
        identifier = re.search(r'\bidentifier:\s*(?:UIAction\.)?Identifier\(\s*' + LITERAL + r'\s*\)', call["value"])
        title = re.search(r'\btitle:\s*' + LITERAL, call["value"])
        selector = identifier or title
        return (("identifier" if identifier else "label", (selector[1],)), call["value"]) if selector else (None, call["value"])
    if binding:
        name = binding.get("bindingName", "")
        expressions = [value for value in facts.get("expressions", []) if value["scope"] == call["scope"]
            and value.get("lexicalScope", []) == binding.get("lexicalScope", [])]
        for value in expressions:
            identifier = re.fullmatch(re.escape(name) + r'\.accessibilityIdentifier\s*=\s*' + LITERAL, value["value"])
            if identifier: return ("identifier", (identifier[1],)), "binding:" + path + ":" + str(binding["start"])
    owner = call.get("owner")
    if call["name"].endswith("GestureRecognizer"):
        owner = types.resolve(path, ".".join(call["scope"]), aliases=False)
    if owner:
        declaration_facts = syntax[types.paths[owner]]
        for value in declaration_facts.get("expressions", []):
            if canonical_type_scope(value["scope"]) != owner[1]: continue
            identifier = re.fullmatch(r'(?:self\.)?accessibilityIdentifier\s*=\s*' + LITERAL, value["value"])
            if identifier: return ("identifier", (identifier[1],)), "UIKit:" + repr(owner)
    return None, call["value"]


def native_runtime_controls(syntax: dict) -> dict:
    types = SwiftTypeIndex(syntax)
    result = {}
    for path, facts, call in native_controls(syntax):
        selector, carrier = native_selector(syntax, types, path, facts, call)
        result.setdefault(path, []).append(dict(call, invocation=call["value"], expression=carrier,
            nativeSelector=selector))
    return result
