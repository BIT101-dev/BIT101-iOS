"""Check physical lines, function names and syntax nesting."""

from __future__ import annotations

import ast
import re
import regex
from pathlib import Path

LINE_LIMIT = 100
NAME_LIMIT = 42
DEPTH_LIMIT = 4
EMOJI = regex.compile(
    r"\p{Extended_Pictographic}|\p{Emoji_Presentation}|[#*0-9]\ufe0f?\u20e3"
)
BANNED_WORDS = "口径 回归 合同 语义 夹具 边界 治理 落盘 根因".split()
BANNED_EXEMPT = {"AGENTS.md", "Scripts/code_style_rules.py"}
CODE_SUFFIXES = {".swift", ".py", ".sh", ".js"}


def is_code(name: str) -> bool:
    path = Path(name)
    return path.suffix in CODE_SUFFIXES or path.parts[0] == ".githooks"


def issue(name: str, line: int, message: str) -> str:
    return f"{name}:{line}: {message}"


def check_name(name: str, line: int, value: str) -> list[str]:
    if len(value) <= NAME_LIMIT:
        return []
    return [issue(name, line, f"函数名 {value} 为 {len(value)} 字符，上限为 {NAME_LIMIT}")]


def check_depth(name: str, line: int, depth: int) -> list[str]:
    if depth <= DEPTH_LIMIT:
        return []
    return [issue(name, line, f"嵌套 {depth} 层，上限为 {DEPTH_LIMIT}")]


def line_findings(name: str, source: str) -> list[str]:
    return [
        issue(name, line, f"行长 {len(text)} 字符，上限为 {LINE_LIMIT}")
        for line, text in enumerate(source.splitlines(), 1)
        if len(text) > LINE_LIMIT
    ]


def emoji_findings(name: str, source: str) -> list[str]:
    return [
        issue(name, number, "包含 Emoji；请使用文字或 SF Symbol")
        for number, text in enumerate(source.splitlines(), 1)
        if EMOJI.search(text)
    ]


def banned_word_findings(name: str, source: str) -> list[str]:
    if name in BANNED_EXEMPT:
        return []
    return [
        issue(name, number, f"包含禁用词 {word}")
        for number, text in enumerate(source.splitlines(), 1)
        for word in BANNED_WORDS
        if word in text
    ]


def python_findings(name: str, source: str, base_line: int = 0) -> list[str]:
    findings = []
    branches = (
        ast.If,
        ast.For,
        ast.AsyncFor,
        ast.While,
        ast.With,
        ast.AsyncWith,
        ast.Try,
        ast.TryStar,
        ast.Match,
        ast.Lambda,
        ast.IfExp,
    )
    roots = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)

    def visit(node, depth):
        if isinstance(node, roots):
            depth = 0
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                findings.extend(check_name(name, node.lineno + base_line, node.name))
        elif isinstance(node, branches):
            depth += 1
            findings.extend(check_depth(name, node.lineno + base_line, depth))
        elif isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
            depth += sum(1 + len(item.ifs) for item in node.generators)
            findings.extend(check_depth(name, node.lineno + base_line, depth))
        for field, value in ast.iter_fields(node):
            children = value if isinstance(value, list) else [value]
            for child in children:
                if isinstance(child, ast.AST):
                    is_elif = (
                        isinstance(node, ast.If)
                        and field == "orelse"
                        and len(children) == 1
                        and isinstance(child, ast.If)
                    )
                    visit(child, depth - int(is_elif))

    visit(ast.parse(source), 0)
    return findings


def swift_findings(name: str, source: str, facts: dict) -> list[str]:
    findings = []
    data = source.encode()
    for function in facts.get("functionRanges", []):
        value = function["name"].strip("`")
        line = data[: function["start"]].count(b"\n") + 1
        findings.extend(check_name(name, line, value))
    for level in facts["styleNesting"]:
        line = data[: level["start"]].count(b"\n") + 1
        findings.extend(check_depth(name, line, level["depth"]))
    return findings


def shell_tokens(source: str) -> str:
    """Keep Zsh parameter payloads opaque to the shell grammar."""
    result = list(source)
    position = 0
    while position < len(source) - 1:
        if source[position : position + 2] != "${":
            position += 1
            continue
        end = position + 2
        depth = 1
        while end < len(source) and depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        for index in range(position + 1, end):
            result[index] = "\n" if source[index] == "\n" else " "
        result[position] = "x"
        position = end
    patterns = (
        r"<[0-9]*-[0-9]*>"
        r"|(?<=\[)\([A-Za-z]+\)"
        r"|(?<=\S)\([A-Za-z.]+\)(?=\s|$)"
    )
    return re.sub(patterns, lambda match: "x" * len(match[0]), "".join(result))


def embedded_findings(name: str, source: str) -> list[str]:
    from python_shell import visit_python_shell

    findings = []

    def check(body, start, end, inline):
        offset = source[:start].count("\n")
        findings.extend(python_findings(name, body, offset))

    visit_python_shell(source, name, check)
    return findings


def tree_findings(name: str, source: str, language: str) -> list[str]:
    from tree_sitter import Language, Parser
    import tree_sitter_bash
    import tree_sitter_javascript

    grammar = tree_sitter_bash if language == "shell" else tree_sitter_javascript
    tokens = shell_tokens(source) if language == "shell" else source
    tree = Parser(Language(grammar.language())).parse(tokens.encode())
    roots = {
        "function_declaration",
        "generator_function_declaration",
        "function_definition",
        "method_definition",
    }
    closures = {"arrow_function", "function_expression", "generator_function"}
    branches = {
        "if_statement",
        "for_statement",
        "for_in_statement",
        "while_statement",
        "do_statement",
        "switch_statement",
        "try_statement",
        "with_statement",
        *closures,
        "case_statement",
        "c_style_for_statement",
        "subshell",
        "command_substitution",
        "ternary_expression",
    }
    findings = []

    def visit(node, depth):
        if node.type in roots:
            depth = 0
            field = node.child_by_field_name("name")
            if field is not None:
                value = field.text.decode()
                findings.extend(check_name(name, field.start_point.row + 1, value))
        elif node.type in branches:
            is_elif = (
                language == "javascript"
                and node.type == "if_statement"
                and node.parent.type == "else_clause"
            )
            depth += int(not is_elif)
            findings.extend(check_depth(name, node.start_point.row + 1, depth))
        if node.type in closures:
            field = node.child_by_field_name("name")
            if field is not None:
                findings.extend(check_name(name, field.start_point.row + 1, field.text.decode()))
        if node.type in {"variable_declarator", "pair", "assignment_expression"}:
            value = node.child_by_field_name("value") or node.child_by_field_name("right")
            field = (
                node.child_by_field_name("name")
                or node.child_by_field_name("key")
                or node.child_by_field_name("left")
            )
            if value is not None and value.type in closures and field is not None:
                if field.type == "member_expression":
                    field = field.child_by_field_name("property")
                if field is not None:
                    findings.extend(
                        check_name(name, field.start_point.row + 1, field.text.decode())
                    )
        for child in node.named_children:
            visit(child, depth)

    visit(tree.root_node, 0)
    if tree.root_node.has_error:
        findings.append(issue(name, 1, f"{language} 语法解析失败"))
    if language == "shell":
        findings.extend(embedded_findings(name, source))
    return findings


def style_findings(contents: dict[str, str]) -> list[str]:
    from swift_source_index import swift_syntax_index_sources

    sources = {name: text for name, text in contents.items() if is_code(name)}
    swift = {name: text for name, text in sources.items() if name.endswith(".swift")}
    facts = swift_syntax_index_sources(swift) if swift else {}
    findings = [
        finding
        for name, source in contents.items()
        for finding in emoji_findings(name, source) + banned_word_findings(name, source)
    ]
    for name, source in sources.items():
        findings.extend(line_findings(name, source))
        suffix = Path(name).suffix
        if suffix == ".swift":
            findings.extend(swift_findings(name, source, facts[name]))
        elif suffix == ".py":
            findings.extend(python_findings(name, source))
        else:
            language = "javascript" if suffix == ".js" else "shell"
            findings.extend(tree_findings(name, source, language))
    return findings
