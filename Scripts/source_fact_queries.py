"""Shared source facts and school request ownership checks."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def ast_has_identifier(facts: dict, name: str) -> bool:
    return name in facts["identifiers"]


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def owner_scopes(syntax_index: dict[str, dict], owner: str) -> list[tuple[dict, list[str]]]:
    return [
        (facts, declaration["scope"] + [declaration["name"]])
        for facts in syntax_index.values()
        for declaration in facts["declarations"]
        if declaration["name"] == owner
        and declaration["kind"] in {"struct", "class", "actor", "extension"}
    ]


def owner_has_call(syntax_index: dict[str, dict], owner: str, call_name: str) -> bool:
    return any(
        any(
            (call["value"] == call_name or call["value"].endswith("." + call_name))
            and call["scope"] == scope
            for call in facts["calls"]
        )
        for facts, scope in owner_scopes(syntax_index, owner)
    )
