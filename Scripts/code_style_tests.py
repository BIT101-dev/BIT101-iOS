"""Boundary checks for the repository's code style limits."""

from code_style_rules import (
    check_name,
    emoji_findings,
    line_findings,
    python_findings,
    swift_findings,
    style_findings,
    tree_findings,
)


def self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from code_format_tests import self_test as format_self_test

    format_self_test()

    assert emoji_findings("text.md", "中文 ABC 123 # * → ±") == []
    assert style_findings({"README.md": chr(0x1F600)})
    for text in (
        "\U0001f600", "\U0001f44d\U0001f3fd", "\U0001f1e8\U0001f1f3",
        "1\ufe0f\u20e3", "*\u20e3", "\u2764\ufe0f", "\U0001f469\u200d\U0001f4bb",
    ):
        assert emoji_findings("text.md", "title\n" + text) == [
            "text.md:2: 包含 Emoji；请使用文字或 SF Symbol"
        ]

    assert line_findings("file.py", "界" * 100) == []
    assert len(line_findings("file.py", "界" * 101)) == 1
    assert check_name("file.py", 1, "a" * 42) == []
    assert check_name("file.py", 1, "a" * 43)
    long_name = "a" * 43
    assert python_findings("file.py", f"def {long_name}(\n    arg\n): pass")
    assert tree_findings("file.js", f"function {long_name}() {{}}", "javascript")
    assert tree_findings("file.js", f"const {long_name} = () => 1", "javascript")
    assert tree_findings("file.sh", f"{long_name}() {{ true; }}", "shell")

    for source in (
        f"const value = function {long_name}() {{}}",
        f"function* {long_name}() {{}}",
        f"const obj = {{ {long_name}: () => 1 }}",
        f"obj.{long_name} = () => 1",
    ):
        assert tree_findings("file.js", source, "javascript")
    chain = "if (a) {} " + "else if (b) {} " * 5
    assert tree_findings("file.js", chain, "javascript") == []

    for count in (4, 5):
        lines = ["def run():"]
        lines.extend("    " * (index + 1) + "if ready:" for index in range(count))
        lines.append("    " * (count + 1) + "pass")
        assert bool(python_findings("file.py", "\n".join(lines))) == (count == 5)
        body = "if (ready) {" * count + "run();" + "}" * count
        assert bool(tree_findings("file.js", body, "javascript")) == (count == 5)
        body = "if ready; then " * count + "true; " + "fi; " * count
        assert bool(tree_findings("file.sh", body, "shell")) == (count == 5)

    sources = {
        "name.swift": f"func {long_name}(\n    arg: Int\n) {{}}",
        "four.swift": "func run() {" + "if ready {" * 4 + "run()" + "}" * 5,
        "five.swift": "func run() {" + "if ready {" * 5 + "run()" + "}" * 6,
        "closure.swift": "func run() {" + "items.map {" * 5 + "value" + "}" * 6,
        "literal.swift": 'func run() { let text = "{{{{{ func longName()" }',
        "sdk.swift": (
            "class Delegate: UIApplicationDelegate {"
            "func applicationProtectedDataDidBecomeAvailable(_ app: UIApplication) {} }"
        ),
        "custom.swift": (f"class Delegate {{func {long_name}(_ app: Any) {{}} }}"),
        "elif.swift": "func run() { if a {} else if b {} else if c {} else if d {} }",
    }
    facts = swift_syntax_index_sources(sources)
    for name, source in sources.items():
        failures = swift_findings(name, source, facts[name])
        assert bool(failures) == (
            name
            in {
                "name.swift",
                "five.swift",
                "closure.swift",
                "custom.swift",
            }
        ), (name, failures)

    conditional = "if a: pass\nelif b: pass\nelif c: pass\nelif d: pass\nelif e: pass"
    assert python_findings("file.py", conditional) == []
    assert python_findings("file.py", 'value = "if ' + "{" * 8 + '"') == []
