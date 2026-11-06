"""Boundary checks for the repository's code style limits."""

from code_style_rules import (
    BANNED_WORDS,
    banned_word_findings,
    check_name,
    check_function_lines,
    emoji_findings,
    line_findings,
    python_findings,
    swift_file_type_findings,
    swift_findings,
    style_findings,
    tree_findings,
)


def self_test() -> None:
    from swift_source_index import swift_syntax_index_sources
    from code_format_tests import self_test as format_self_test

    format_self_test()
    function_length_self_test()

    from unittest.mock import patch

    with patch("swift_source_index._resolve_tests", side_effect=AssertionError("测试归属解析")):
        assert style_findings({"Sample.swift": "struct Sample {}\n"}) == []

    assert emoji_findings("text.md", "中文 ABC 123 # * → ±") == []
    assert style_findings({"README.md": chr(0x1F600)})
    for text in (
        "\U0001f600",
        "\U0001f44d\U0001f3fd",
        "\U0001f1e8\U0001f1f3",
        "1\ufe0f\u20e3",
        "*\u20e3",
        "\u2764\ufe0f",
        "\U0001f469\u200d\U0001f4bb",
    ):
        assert emoji_findings("text.md", "title\n" + text) == [
            "text.md:2: 包含 Emoji；请使用文字或 SF Symbol"
        ]

    word = BANNED_WORDS[0]
    assert banned_word_findings("a.md", "说明\n" + word) == [f"a.md:2: 包含禁用词 {word}"]
    assert banned_word_findings("AGENTS.md", word) == []

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
        "published.swift": "final class Model: ObservableObject { @Published var count = 0 }",
        "badType.swift": "struct lowerType {}",
        "badFunc.swift": "func UpperFunc() {}",
        "badVar.swift": "struct Item { let UpperValue: Int = 1 }",
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
                "published.swift",
                "badType.swift",
                "badFunc.swift",
                "badVar.swift",
            }
        ), (name, failures)

    pair = swift_syntax_index_sources(
        {"Alpha.swift": "struct Beta {}", "Beta.swift": "struct Alpha {}"}
    )
    assert len(swift_file_type_findings(pair)) == 2
    valid_pair = swift_syntax_index_sources(
        {"Alpha.swift": "struct Alpha {}", "Beta.swift": "struct Beta {}"}
    )
    assert swift_file_type_findings(valid_pair) == []

    conditional = "if a: pass\nelif b: pass\nelif c: pass\nelif d: pass\nelif e: pass"
    assert python_findings("file.py", conditional) == []
    assert python_findings("file.py", 'value = "if ' + "{" * 8 + '"') == []


def function_length_self_test() -> None:
    from swift_source_index import swift_syntax_index_sources

    assert check_function_lines("sample.py", 3, 200) == []
    assert check_function_lines("sample.py", 3, 201) == ["sample.py:3: 函数体共 201 行，上限为 200"]
    for count in (200, 201):
        statements = count - 2
        python = "async def sample():\n" + "    pass\n" * (count - 1)
        assert bool(python_findings("sample.py", python)) == (count > 200)
        for source, language in (
            ("sample() {\n" + "true\n" * statements + "}", "shell"),
            ("const sample = () => {\n" + "work();\n" * statements + "};", "javascript"),
            ("class Sample { method() {\n" + "work();\n" * statements + "} }", "javascript"),
        ):
            assert bool(tree_findings("sample", source, language)) == (count > 200)
        body = "\n" + "        work()\n" * statements + "    }"
        for declaration in ("func sample() {", "init() {", "var value: Int {", "let value = {"):
            source = "struct Sample {\n    " + declaration + body + "\n}"
            facts = swift_syntax_index_sources({"Sample.swift": source}, resolve_tests=False)
            findings = swift_findings("Sample.swift", source, facts["Sample.swift"])
            assert bool(findings) == (count > 200), (declaration, count, findings)
    nested = "def sample():\n    def child():\n" + "        pass\n" * 200
    assert len(python_findings("sample.py", nested)) == 2

    annotated = "@Test(arguments: [\n" + "0,\n" * 201 + "])\nfunc sample() { work() }"
    facts = swift_syntax_index_sources({"Sample.swift": annotated}, resolve_tests=False)
    assert swift_findings("Sample.swift", annotated, facts["Sample.swift"]) == []
