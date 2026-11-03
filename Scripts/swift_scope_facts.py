"""Resolve compilation units and visible Swift variables."""

from pathlib import Path
from functools import cache


@cache
def package_target_paths() -> dict:
    from validation_inputs import read_manifest, manifest_targets

    return manifest_targets(read_manifest(Path(__file__).resolve().parents[1]))


def compilation_unit(path: str) -> str:
    parts = Path(path).parts
    for directory in ("Modules", "ModuleTests"):
        if not (directory in parts):
            continue
        offset = parts.index(directory)
        if directory == "Modules":
            return parts[offset + 1]
        relative = Path(*parts[offset:])
        for name, target in package_target_paths().items():
            if relative.is_relative_to(target["path"]):
                return name
        raise ValueError(f"包级测试源码需要归属已声明的 SwiftPM target：{path}")
    from validation_inputs import NATIVE_PRODUCT_ROOTS, NATIVE_TEST_ROOTS

    roots = set(NATIVE_PRODUCT_ROOTS + NATIVE_TEST_ROOTS)
    return next((part for part in reversed(parts) if part in roots), "fixture")


def canonical_type_scope(names: list[str]) -> tuple[str, ...]:
    return _canonical_type_scope(tuple(names))


@cache
def _canonical_type_scope(names: tuple[str, ...]) -> tuple[str, ...]:
    parts = []
    for name in names:
        nominal, depth = [], 0
        for index, character in enumerate(name):
            if character == "<":
                depth += 1
            elif character == ">" and (index == 0 or name[index - 1] != "-"):
                depth -= 1
            elif depth == 0 and not character.isspace():
                nominal.append(character)
        parts.extend("".join(nominal).split("."))
    return tuple(parts)


def visible_variables(
    facts: dict, reference: dict, name: str, explicit_self: bool = False
) -> list[dict]:
    lexical = reference.get("lexicalScope", [])
    candidates = [
        variable
        for variable in facts["typedVariables"]
        if variable["name"] == name
        and canonical_type_scope(reference["scope"])[: len(canonical_type_scope(variable["scope"]))]
        == canonical_type_scope(variable["scope"])
        and lexical[: len(variable.get("lexicalScope", []))] == variable.get("lexicalScope", [])
        and (
            not variable.get("visibilityRange")
            or variable["visibilityRange"][0] <= reference["start"] < variable["visibilityRange"][1]
        )
        and (not variable.get("lexicalScope") or variable.get("start", 0) <= reference["start"])
        and not (
            explicit_self
            and any(
                function["scope"] == variable["scope"]
                and function["start"] <= variable.get("start", 0) < function["end"]
                for function in facts["functionRanges"]
            )
        )
    ]
    return sorted(
        candidates,
        key=lambda variable: (
            len(variable["scope"]),
            len(variable.get("lexicalScope", [])),
            variable.get("start", 0),
        ),
    )
