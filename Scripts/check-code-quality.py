#!/usr/bin/env python3
"""逐份扫描项目源码，收口容易遗漏的代码风格约束。

硬错误会阻止静态审计；需要人工判断的事项写入固定报告，不制造新的临时文件。
"""

from __future__ import annotations

import fcntl
import re
import json
import os
import importlib.util
import subprocess
import stat
import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOTS = (
    ROOT / "Modules",
    ROOT / "BIT101-iOS",
    ROOT / "BIT101-iOSTests",
    ROOT / "ModuleTests",
    ROOT / "BIT101ScheduleWidgets",
    ROOT / "BIT101Watch",
    ROOT / "BIT101WatchWidgets",
)
SCRIPT_ROOT = ROOT / "Scripts"
REPORT_PATH = ROOT / ".build/code-quality-report.txt"
MAX_SOURCE_LINES = 1000

DIRECT_STDOUT_LOG = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")

DIRECT_VIEW_REQUEST = re.compile(r"\bURLRequest\s*\(")
FORCE_UNWRAP = re.compile(r"\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*!(?!=)|\)\s*!(?!=)")

DIRECT_DATE_FORMATTER = re.compile(
    r"\b(?:DateFormatter|ISO8601DateFormatter|RelativeDateTimeFormatter)\s*\("
)

STDOUT_EXCEPTIONS = {"BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"}

SWIFT_SYNTAX_INDEXER = r'''
import Foundation
import SwiftSyntax
import SwiftParser

struct FileFacts: Encodable {
    let hasParseErrors: Bool
    let identifiers: [String]
    let scopedIdentifiers: [ScopedFact]
    let stringSegments: [ScopedFact]
    let declarations: [DeclarationFact]
    let calls: [ScopedFact]
    let invocations: [ScopedFact]
    let functions: [ScopedFact]
    let functionReturns: [FunctionReturnFact]
    let selectionControls: [SelectionControlFact]
    let feedbackModifiers: [FeedbackModifierFact]
    let alertModifiers: [AlertModifierFact]
    let typedVariables: [TypedVariableFact]
    let listIcons: [ListIconFact]
    let listControls: [SelectionControlFact]
    let listStyleModifiers: [FeedbackModifierFact]
    let accessibilityModifiers: [FeedbackModifierFact]
    let accessibilityControls: [AccessibilityControlFact]
    let functionRanges: [FunctionRangeFact]
    let nonRenderedRanges: [ScopedRangeFact]
    let members: [ScopedFact]
    let expressions: [ScopedFact]
    let bindings: [ScopedFact]
    let controlFlow: [ScopedFact]
    let typeNames: [ScopedFact]
}

struct DeclarationFact: Encodable {
    let kind: String
    let name: String
    let inheritedTypes: [String]
    let scope: [String]
}

struct ScopedFact: Encodable {
    let value: String
    let scope: [String]
    let start: Int
}

struct SelectionControlFact: Encodable {
    let name: String
    let invocation: String
    let scope: [String]
    let start: Int
}

struct FeedbackModifierFact: Encodable {
    let name: String
    let base: String
    let scope: [String]
    let baseStart: Int
}

struct AccessibilityControlFact: Encodable {
    let name: String
    let invocation: String
    let label: String
    let hasTextTitle: Bool
    let scope: [String]
    let start: Int
    let labelStart: Int
    let labelEnd: Int
    let containers: [String]
    let expression: String
}

struct AlertModifierFact: Encodable {
    let labels: [String]
    let arguments: [String]
    let invocation: String
    let identifiers: [String]
    let scope: [String]
}

struct TypedVariableFact: Encodable {
    let name: String
    let type: String
    let scope: [String]
}

struct ListIconFact: Encodable {
    let name: String
    let symbol: String
    let scope: [String]
    let containers: [String]
}

struct FunctionRangeFact: Encodable {
    let name: String
    let returnsView: Bool
    let scope: [String]
    let start: Int
    let end: Int
}

struct FunctionReturnFact: Encodable {
    let name: String
    let scope: [String]
    let value: String
}

struct ScopedRangeFact: Encodable {
    let scope: [String]
    let start: Int
    let end: Int
}

final class FactVisitor: SyntaxVisitor {
    private(set) var declarations: [DeclarationFact] = []
    private(set) var calls: [ScopedFact] = []
    private(set) var invocations: [ScopedFact] = []
    private(set) var functions: [ScopedFact] = []
    private(set) var functionReturns: [FunctionReturnFact] = []
    private(set) var scopedIdentifiers: [ScopedFact] = []
    private(set) var stringSegments: [ScopedFact] = []
    private(set) var selectionControls: [SelectionControlFact] = []
    private(set) var feedbackModifiers: [FeedbackModifierFact] = []
    private(set) var alertModifiers: [AlertModifierFact] = []
    private(set) var typedVariables: [TypedVariableFact] = []
    private(set) var listIcons: [ListIconFact] = []
    private(set) var listControls: [SelectionControlFact] = []
    private(set) var listStyleModifiers: [FeedbackModifierFact] = []
    private(set) var accessibilityModifiers: [FeedbackModifierFact] = []
    private(set) var accessibilityControls: [AccessibilityControlFact] = []
    private(set) var functionRanges: [FunctionRangeFact] = []
    private(set) var nonRenderedRanges: [ScopedRangeFact] = []
    private(set) var members: [ScopedFact] = []
    private(set) var expressions: [ScopedFact] = []
    private(set) var bindings: [ScopedFact] = []
    private(set) var controlFlow: [ScopedFact] = []
    private(set) var typeNames: [ScopedFact] = []
    private var scope: [String] = []
    private var listContainers: [String] = []
    private var functionStack: [(name: String, scope: [String], closureDepth: Int)] = []
    private var closureDepth = 0

    private func enter(_ kind: String, _ name: String, _ inherited: [String]) -> SyntaxVisitorContinueKind {
        declarations.append(DeclarationFact(kind: kind, name: name, inheritedTypes: inherited, scope: scope))
        scope.append(name)
        return .visitChildren
    }

    private func leave() { _ = scope.popLast() }
    private func fact(_ value: String, start: Int) -> ScopedFact {
        ScopedFact(value: value, scope: scope, start: start)
    }
    private func excludeFromRenderedContent(_ closure: ClosureExprSyntax?) {
        guard let closure else { return }
        nonRenderedRanges.append(ScopedRangeFact(
            scope: scope,
            start: closure.positionAfterSkippingLeadingTrivia.utf8Offset,
            end: closure.endPositionBeforeTrailingTrivia.utf8Offset
        ))
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("struct", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
    }
    override func visitPost(_ node: StructDeclSyntax) { leave() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        functionRanges.append(FunctionRangeFact(
            name: node.name.text,
            returnsView: node.signature.returnClause?.type.trimmedDescription.contains("View") ?? false,
            scope: scope,
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
            end: node.endPositionBeforeTrailingTrivia.utf8Offset
        ))
        functionStack.append((node.name.text, scope, closureDepth))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { _ = functionStack.popLast() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closureDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { closureDepth -= 1 }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let function = functionStack.last,
           closureDepth == function.closureDepth,
           let expression = node.expression
        {
            functionReturns.append(FunctionReturnFact(
                name: function.name,
                scope: function.scope,
                value: expression.trimmedDescription
            ))
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("class", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
    }
    override func visitPost(_ node: ClassDeclSyntax) { leave() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("enum", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
    }
    override func visitPost(_ node: EnumDeclSyntax) { leave() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("actor", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
    }
    override func visitPost(_ node: ActorDeclSyntax) { leave() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("extension", node.extendedType.trimmedDescription, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { leave() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledExpression = node.calledExpression.trimmedDescription
        calls.append(fact(calledExpression, start: node.calledExpression.positionAfterSkippingLeadingTrivia.utf8Offset))
        invocations.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        let calledName = calledExpression.split(separator: ".").last.map(String.init) ?? calledExpression
        if calledName == "alert", node.calledExpression.as(MemberAccessExprSyntax.self) != nil {
            alertModifiers.append(AlertModifierFact(
                labels: node.arguments.map { $0.label?.text ?? "" },
                arguments: node.arguments.map { $0.expression.trimmedDescription },
                invocation: node.trimmedDescription,
                identifiers: (
                    node.arguments.flatMap { argument in
                        argument.expression.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
                            if case .identifier(let name) = token.tokenKind { return name }
                            return nil
                        }
                    }
                    + (node.trailingClosure?.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
                        if case .identifier(let name) = token.tokenKind { return name }
                        return nil
                    } ?? [])
                    + node.additionalTrailingClosures.flatMap { closure in
                        closure.closure.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
                            if case .identifier(let name) = token.tokenKind { return name }
                            return nil
                        }
                    }
                ),
                scope: scope
            ))
        }
        if ["Label", "Button", "NavigationLink", "Image"].contains(calledName),
           let imageArgument = node.arguments.first(where: {
               $0.label?.text == "systemImage" || $0.label?.text == "systemName"
           })
        {
            listIcons.append(ListIconFact(
                name: calledName,
                symbol: imageArgument.expression.trimmedDescription,
                scope: scope,
                containers: listContainers
            ))
        }
        if ["Button", "NavigationLink", "Menu", "Picker", "Toggle", "DatePicker", "Link", "PhotosPicker", "LabeledContent"].contains(calledName) {
            let labelArgument = node.arguments.first(where: { $0.label?.text == "label" })
            let labelClosure = node.additionalTrailingClosures.first(where: { $0.label.text == "label" })?.closure
            let singleTrailingLabel: ClosureExprSyntax? = {
                guard labelArgument == nil, labelClosure == nil, let trailingClosure = node.trailingClosure else {
                    return nil
                }
                let argumentLabels = Set(node.arguments.compactMap { $0.label?.text })
                switch calledName {
                case "Button":
                    return argumentLabels.contains("action") ? trailingClosure : nil
                case "NavigationLink":
                    return argumentLabels.contains("destination") || argumentLabels.contains("value")
                        ? trailingClosure
                        : nil
                default:
                    return nil
                }
            }()
            let labelSyntax: Syntax?
            if let labelArgument {
                labelSyntax = Syntax(labelArgument.expression)
            } else if let labelClosure {
                labelSyntax = Syntax(labelClosure)
            } else if let singleTrailingLabel {
                labelSyntax = Syntax(singleTrailingLabel)
            } else {
                labelSyntax = nil
            }
            let titleArgument = node.arguments.first(where: { $0.label == nil })?.expression
            var styledExpression = Syntax(node)
            while let parent = styledExpression.parent {
                if parent.is(MemberAccessExprSyntax.self) || parent.is(FunctionCallExprSyntax.self) {
                    styledExpression = parent
                } else {
                    break
                }
            }
            accessibilityControls.append(AccessibilityControlFact(
                name: calledName,
                invocation: node.trimmedDescription,
                label: labelSyntax?.trimmedDescription ?? "",
                hasTextTitle: titleArgument != nil,
                scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                labelStart: labelSyntax?.positionAfterSkippingLeadingTrivia.utf8Offset ?? -1,
                labelEnd: labelSyntax?.endPositionBeforeTrailingTrivia.utf8Offset ?? -1,
                containers: listContainers,
                expression: styledExpression.trimmedDescription
            ))

            switch calledName {
            case "Button":
                excludeFromRenderedContent(
                    node.arguments.first(where: { $0.label?.text == "action" })?.expression.as(ClosureExprSyntax.self)
                )
                if labelClosure != nil || titleArgument != nil {
                    excludeFromRenderedContent(node.trailingClosure)
                }
            case "Menu":
                break
            case "NavigationLink":
                break
            default:
                break
            }
        }
        if [
            "onTapGesture", "onLongPressGesture", "onAppear", "onDisappear", "onChange",
            "onReceive", "task", "refreshable", "onSubmit", "onDelete", "onMove",
            "alert", "confirmationDialog",
        ].contains(calledName) {
            excludeFromRenderedContent(node.trailingClosure)
            for closure in node.additionalTrailingClosures {
                excludeFromRenderedContent(closure.closure)
            }
            for argument in node.arguments {
                excludeFromRenderedContent(argument.expression.as(ClosureExprSyntax.self))
            }
        }
        if ["List", "Form", "Section"].contains(calledName) {
            listContainers.append(calledName)
        }
        if calledName == "Picker" || calledName == "Toggle" {
            selectionControls.append(SelectionControlFact(
                name: calledName,
                invocation: node.trimmedDescription,
                scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset
            ))
        }
        if calledName == "List" {
            listControls.append(SelectionControlFact(
                name: calledName,
                invocation: node.trimmedDescription,
                scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset
            ))
        }
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.trimmedDescription.hasSuffix(".appSelectionFeedback")
        {
            feedbackModifiers.append(FeedbackModifierFact(
                name: "appSelectionFeedback",
                base: memberAccess.base?.trimmedDescription ?? "",
                scope: scope,
                baseStart: memberAccess.base?.positionAfterSkippingLeadingTrivia.utf8Offset ?? -1
            ))
        }
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.trimmedDescription.hasSuffix(".appGroupedListStyle")
        {
            listStyleModifiers.append(FeedbackModifierFact(
                name: "appGroupedListStyle",
                base: memberAccess.base?.trimmedDescription ?? "",
                scope: scope,
                baseStart: memberAccess.base?.positionAfterSkippingLeadingTrivia.utf8Offset ?? -1
            ))
        }
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.trimmedDescription.hasSuffix(".accessibilityLabel")
        {
            accessibilityModifiers.append(FeedbackModifierFact(
                name: "accessibilityLabel",
                base: memberAccess.base?.trimmedDescription ?? "",
                scope: scope,
                baseStart: memberAccess.base?.positionAfterSkippingLeadingTrivia.utf8Offset ?? -1
            ))
        }
        return .visitChildren
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        let calledExpression = node.calledExpression.trimmedDescription
        let calledName = calledExpression.split(separator: ".").last.map(String.init) ?? calledExpression
        if ["List", "Form", "Section"].contains(calledName), listContainers.last == calledName {
            _ = listContainers.popLast()
        }
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        switch token.tokenKind {
        case .identifier(let value):
            scopedIdentifiers.append(fact(value, start: token.positionAfterSkippingLeadingTrivia.utf8Offset))
        case .stringSegment(let value):
            stringSegments.append(fact(value, start: token.positionAfterSkippingLeadingTrivia.utf8Offset))
        default:
            break
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        members.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        expressions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        expressions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        bindings.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self),
           let type = node.typeAnnotation?.type
        {
            typedVariables.append(TypedVariableFact(
                name: pattern.identifier.text,
                type: type.trimmedDescription,
                scope: scope
            ))
        }
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        controlFlow.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        controlFlow.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        typeNames.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }
}

struct SourceInput: Decodable { let name: String; let source: String }
struct Input: Decodable { let paths: [String]; let sources: [SourceInput]? }

let inputData = FileHandle.standardInput.readDataToEndOfFile()
let input = try JSONDecoder().decode(Input.self, from: inputData)
var output: [String: FileFacts] = [:]
func indexSource(_ source: String, as key: String) {
    let tree = Parser.parse(source: source)
    let visitor = FactVisitor(viewMode: .sourceAccurate)
    visitor.walk(tree)
    let identifiers = tree.tokens(viewMode: .sourceAccurate).compactMap { token -> String? in
        if case .identifier(let name) = token.tokenKind { return name }
        return nil
    }
    output[key] = FileFacts(
        hasParseErrors: tree.hasError,
        identifiers: identifiers,
        scopedIdentifiers: visitor.scopedIdentifiers,
        stringSegments: visitor.stringSegments,
        declarations: visitor.declarations,
        calls: visitor.calls,
        invocations: visitor.invocations,
        functions: visitor.functions,
        functionReturns: visitor.functionReturns,
        selectionControls: visitor.selectionControls,
        feedbackModifiers: visitor.feedbackModifiers,
        alertModifiers: visitor.alertModifiers,
        typedVariables: visitor.typedVariables,
        listIcons: visitor.listIcons,
        listControls: visitor.listControls,
        listStyleModifiers: visitor.listStyleModifiers,
        accessibilityModifiers: visitor.accessibilityModifiers,
        accessibilityControls: visitor.accessibilityControls,
        functionRanges: visitor.functionRanges,
        nonRenderedRanges: visitor.nonRenderedRanges,
        members: visitor.members,
        expressions: visitor.expressions,
        bindings: visitor.bindings,
        controlFlow: visitor.controlFlow,
        typeNames: visitor.typeNames
    )
}
for path in input.paths {
    indexSource(try String(contentsOfFile: path, encoding: .utf8), as: path)
}
for source in input.sources ?? [] {
    indexSource(source.source, as: source.name)
}
let encoded = try JSONEncoder().encode(output)
print(String(decoding: encoded, as: UTF8.self))
'''


def _run_swift_syntax_index(request: dict) -> dict[str, dict]:
    swift = os.environ.get("SWIFT")
    if not swift:
        swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    swift_path = Path(swift).absolute()
    host_modules = swift_path.parent.parent / "lib/swift/host"
    if not (host_modules / "SwiftSyntax.swiftmodule").is_dir():
        raise RuntimeError(f"Xcode SwiftSyntax modules not found: {host_modules}")
    cache = ROOT / ".build/static-audit"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "swift-syntax-indexer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = cache / "swift-syntax-indexer.swift"
        executable = cache / "swift-syntax-indexer"
        compiler = swift_path.with_name("swiftc")
        source_text = SWIFT_SYNTAX_INDEXER + f"\n// Toolchain: {compiler}\n"
        source_changed = not source.exists() or source.read_text() != source_text
        toolchain_modified = max(
            compiler.stat().st_mtime_ns,
            (host_modules / "libSwiftSyntax.dylib").stat().st_mtime_ns,
            (host_modules / "libSwiftParser.dylib").stat().st_mtime_ns,
        )
        if source_changed or not executable.exists() or executable.stat().st_mtime_ns < toolchain_modified:
            source.write_text(source_text)
            executable.unlink(missing_ok=True)
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            compilation = subprocess.run([
                str(compiler), "-target", f"{os.uname().machine}-apple-macosx14.0", "-sdk", sdk,
                "-I", str(host_modules), "-L", str(host_modules),
                "-lSwiftSyntax", "-lSwiftParser", "-Xlinker", "-rpath", "-Xlinker", str(host_modules),
                str(source), "-o", str(executable),
            ], capture_output=True, text=True)
            if compilation.returncode:
                executable.unlink(missing_ok=True)
                raise RuntimeError(compilation.stderr.strip() or "SwiftSyntax indexer compilation failed")
        result = subprocess.run(
            [str(executable)],
            input=json.dumps(request),
            text=True,
            capture_output=True,
        )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "SwiftSyntax indexing failed")
    try:
        index = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"SwiftSyntax returned invalid JSON: {error}") from error
    parse_failures = [path for path, facts in index.items() if facts["hasParseErrors"]]
    if parse_failures:
        raise RuntimeError("SwiftSyntax parse errors: " + ", ".join(parse_failures))
    return index


def swift_syntax_index(files: list[Path]) -> dict[str, dict]:
    return _run_swift_syntax_index({"paths": [str(path) for path in files]})


def swift_syntax_index_sources(sources: dict[str, str]) -> dict[str, dict]:
    return _run_swift_syntax_index({
        "paths": [],
        "sources": [
            {"name": name, "source": source}
            for name, source in sources.items()
        ],
    })


def ast_has_identifier(facts: dict, name: str) -> bool:
    return name in facts["identifiers"]


def ast_has_call(facts: dict, name: str, scope: str | None = None) -> bool:
    return any(
        (call["value"] == name or call["value"].endswith("." + name))
        and (scope is None or scope in call["scope"])
        for call in facts["calls"]
    )


def ast_has_member(facts: dict, expression: str, scope: str | None = None) -> bool:
    return any(
        member["value"] == expression
        and (scope is None or scope in member["scope"])
        for member in facts["members"]
    )


def ast_has_view_request(facts: dict) -> bool:
    view_types = {
        declaration["name"]
        for declaration in facts["declarations"]
        if any(
            inherited.rsplit(".", 1)[-1] == "View"
            for inherited in declaration["inheritedTypes"]
        )
    }
    return any(
        call["value"] in {"URLRequest", "Swift.URLRequest"}
        and any(view_type in call["scope"] for view_type in view_types)
        for call in facts["calls"]
    )


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def swift_files() -> list[Path]:
    return sorted(
        path
        for source_root in SOURCE_ROOTS
        if source_root.is_dir()
        for path in source_root.rglob("*.swift")
    )


def line_number(source: str, position: int) -> int:
    return source.count("\n", 0, position) + 1


def _blank_segment(output: list[str], source: str, start: int, end: int) -> None:
    for index in range(start, min(end, len(source))):
        if source[index] != "\n":
            output[index] = " "


def mask_comments(source: str) -> str:
    """移除注释并保留字符串，供需要识别 Swift 文案字面量的规则使用。"""
    output = list(source)
    index = 0
    depth = 0
    while index < len(source):
        if depth:
            if source.startswith("/*", index):
                depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
        elif source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
        elif source.startswith("/*", index):
            depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
        else:
            index += 1
    return "".join(output)


def mask_literals_and_comments(source: str) -> str:
    """复用模块检查器的 Swift 词法扫描，保留插值表达式与源码位置。"""
    name = "check_module_boundaries_lexer"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, SCRIPT_ROOT / "check-module-boundaries.py")
        if spec is None or spec.loader is None:
            raise RuntimeError("Swift 词法扫描器加载失败")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name].swift_code(source)


def declaration_block(code: str, type_name: str) -> str:
    """返回类型或 extension 的源码块，避免用文件名和全文件关键词推断契约。"""
    declaration = re.compile(
        rf"\b(?:struct|class|enum|actor|extension)\s+{re.escape(type_name)}\b[^{{]*{{"
    ).search(code)
    if declaration is None:
        return ""
    opening = code.find("{", declaration.start(), declaration.end())
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return code[declaration.start() : index + 1]
    return code[declaration.start() :]


def has_identifier(code: str, identifier: str) -> bool:
    return re.search(rf"(?<![A-Za-z0-9_$]){re.escape(identifier)}(?![A-Za-z0-9_$])", code) is not None


def has_call(code: str, identifier: str) -> bool:
    return re.search(rf"(?<![A-Za-z0-9_$]){re.escape(identifier)}\s*\(", code) is not None


def is_view_source(path: Path, code: str) -> bool:
    if path.name.endswith(("View.swift", "Views.swift", "Screen.swift", "Screens.swift")):
        return True
    return re.search(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
        code,
    ) is not None


def view_declaration_ranges(code: str) -> list[tuple[int, int]]:
    """返回真实 View 声明的范围，避免把同文件的缓存/Loader 当成 View。"""
    ranges: list[tuple[int, int]] = []
    declaration = re.compile(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b[^{}]*\{"
    )
    for match in declaration.finditer(code):
        opening = code.find("{", match.start(), match.end())
        depth = 0
        for index in range(opening, len(code)):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
                if depth == 0:
                    ranges.append((match.start(), index + 1))
                    break
    return ranges


def view_request_matches(code: str) -> list[re.Match[str]]:
    ranges = view_declaration_ranges(code)
    return [
        match
        for match in DIRECT_VIEW_REQUEST.finditer(code)
        if any(start <= match.start() < end for start, end in ranges)
    ]


def add_matches(
    findings: list[str],
    path: Path,
    source: str,
    pattern: re.Pattern[str],
    message: str,
) -> None:
    for match in pattern.finditer(source):
        findings.append(f"{relative(path)}:{line_number(source, match.start())}: {message}")


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


def owner_has_member_suffix(syntax_index: dict[str, dict], owner: str, suffix: str) -> bool:
    return any(
        any(member["value"].endswith(suffix) and member["scope"] == scope for member in facts["members"])
        for facts, scope in owner_scopes(syntax_index, owner)
    )


def owner_has_identifier(syntax_index: dict[str, dict], owner: str, identifier: str) -> bool:
    return any(
        any(item["value"] == identifier and item["scope"] == scope for item in facts["scopedIdentifiers"])
        for facts, scope in owner_scopes(syntax_index, owner)
    )


def owner_has_literal(syntax_index: dict[str, dict], owner: str, literal: str) -> bool:
    return any(
        any(item["value"] == literal and item["scope"] == scope for item in facts["stringSegments"])
        for facts, scope in owner_scopes(syntax_index, owner)
    )


def uses_application_support_storage(member: dict) -> bool:
    return any(
        entry in member["value"]
        for entry in (
            "AppFileDirectories.applicationSupport",
            "AppFileDirectories.accountSupportFileURL",
        )
    )


def checker_boundary_findings() -> list[str]:
    findings: list[str] = []
    findings.extend(script_output_boundary_findings())
    unwrap_source = '''
// value!
let example = "value!"
let unwrapped = value!
let comparison = left != right
'''
    masked_unwrap_source = mask_literals_and_comments(unwrap_source)
    if len(FORCE_UNWRAP.findall(masked_unwrap_source)) != 1:
        findings.append("代码质量规则边界自检失败：强制解包与比较运算区分")

    view_source = "struct SampleView: View { let request = URLRequest(url: url) }"
    model_source = "struct SampleModel { let request = URLRequest(url: url) }"
    if len(view_request_matches(view_source)) != 1 or view_request_matches(model_source):
        findings.append("代码质量规则边界自检失败：View 请求构造范围识别")

    view_facts = {
        "declarations": [{"name": "SampleView", "inheritedTypes": ["SwiftUI.View"]}],
        "calls": [{"value": "URLRequest", "scope": ["SampleView"]}],
    }
    model_facts = {
        "declarations": [{"name": "SampleModel", "inheritedTypes": ["ObservableObject"]}],
        "calls": [{"value": "URLRequest", "scope": ["SampleModel"]}],
    }
    if not ast_has_view_request(view_facts) or ast_has_view_request(model_facts):
        findings.append("代码质量规则边界自检失败：SwiftSyntax View 请求范围匹配")

    if not uses_application_support_storage({"value": "AppFileDirectories.accountSupportFileURL"}) or uses_application_support_storage(
        {"value": "FileManager.default.urls(for: .applicationSupportDirectory)"}
    ):
        findings.append("代码质量规则边界自检失败：持久化仓库的统一存储入口识别")

    relocated_facts = {
        "declarations": [{"kind": "struct", "name": "ExampleView", "scope": []}],
        "calls": [{"value": "restoreCache", "scope": ["ExampleView"]}],
        "members": [],
        "scopedIdentifiers": [],
        "stringSegments": [],
    }
    relocated_index = {"Moved/ExampleView.swift": relocated_facts}
    if not owner_has_call(relocated_index, "ExampleView", "restoreCache"):
        findings.append("代码质量规则边界自检失败：类型迁移后仍按声明作用域匹配契约")
    if owner_has_call(relocated_index, "MissingView", "restoreCache"):
        findings.append("代码质量规则边界自检失败：缺少契约类型应保持失败")
    module_path = ROOT / "Modules/GalleryFeature/Sources/ExampleView.swift"
    for source, marker in (
        ('struct ExampleView: View { func load() { print("value") } }', "Logger"),
        ('struct ExampleView: View { let formatter = DateFormatter() }', "AppDateText"),
        (r'let text = "\(print("value"))"', "Logger"),
    ):
        if not any(marker in finding for finding in client_source_findings(module_path, source)):
            findings.append("代码质量规则边界自检失败：模块与插值中的客户端规则")
    if client_source_findings(module_path, '// print("value")\nlet example = "DateFormatter()"'):
        findings.append("代码质量规则边界自检失败：模块文案进入执行代码规则")
    model_path = ROOT / "Modules/GalleryFeature/Sources/ExampleViewModel.swift"
    if not model_cancellation_findings(model_path, {"identifiers": [], "calls": []}):
        findings.append("代码质量规则边界自检失败：模块状态模型取消契约")
    if model_cancellation_findings(model_path, {"identifiers": ["TaskCancellation"], "calls": []}):
        findings.append("代码质量规则边界自检失败：公共取消识别入口")
    findings.extend(smoke_script_boundary_findings())
    workflow_source = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    detached_release = workflow_source.replace("needs: static-audit", "needs: []", 1)
    if not any("必须依赖静态审计" in item for item in ci_wiring_findings(detached_release)):
        findings.append("代码质量规则边界自检失败：Release Job 与静态审计依赖识别")
    misplaced_audit = workflow_source.replace("run: Scripts/run-static-audit.sh", "run: echo skipped", 1)
    misplaced_audit += "\n# Scripts/run-static-audit.sh\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则边界自检失败：CI 注释中的审计标记隔离")
    detached_catalyst = re.sub(r"(?s)(  catalyst-tests:.*?)    needs: static-audit", r"\1    needs: []", workflow_source, count=1)
    if not any("Catalyst 行为 Job 需要依赖静态审计" in item for item in ci_wiring_findings(detached_catalyst)):
        findings.append("代码质量规则边界自检失败：Catalyst Job 与静态审计依赖识别")
    skipped_catalyst = workflow_source.replace("run: Scripts/run-extended-tests.sh catalyst", "run: echo skipped", 1)
    if not any("Catalyst 行为 Job 需要执行" in item for item in ci_wiring_findings(skipped_catalyst)):
        findings.append("代码质量规则边界自检失败：并行 Catalyst 行为用例执行门禁")
    extension_graph = {"objects": {
        "app": {"isa": "PBXNativeTarget", "name": "BIT101-iOS", "dependencies": ["widget-edge", "watch-edge"]},
        "widget": {"isa": "PBXNativeTarget", "name": "BIT101ScheduleWidgets"},
        "watch": {"isa": "PBXNativeTarget", "name": "BIT101Watch", "dependencies": ["watch-widget-edge"]},
        "watch-widget": {"isa": "PBXNativeTarget", "name": "BIT101WatchWidgets"},
        "widget-edge": {"target": "widget", "platformFilter": "ios"},
        "watch-edge": {"target": "watch", "platformFilter": "ios"},
        "watch-widget-edge": {"target": "watch-widget"},
    }}
    if extension_dependency_findings(extension_graph):
        findings.append("代码质量规则边界自检失败：父 target 的扩展编译覆盖识别")
    extension_graph["objects"]["watch-edge"].pop("platformFilter")
    if not extension_dependency_findings(extension_graph):
        findings.append("代码质量规则边界自检失败：Mac Catalyst 的扩展平台隔离")
    extension_graph["objects"]["watch-edge"]["platformFilter"] = "ios"
    extension_graph["objects"]["watch"]["dependencies"] = []
    if not extension_dependency_findings(extension_graph):
        findings.append("代码质量规则边界自检失败：扩展依赖断开应触发门禁")
    return findings


def script_output_boundary_findings() -> list[str]:
    """通过内存命令输出验证阈值、完整留档及进程状态。"""
    from contextlib import nullcontext, redirect_stdout
    from io import StringIO
    from types import SimpleNamespace
    from unittest.mock import patch

    source = (SCRIPT_ROOT / "script-support.sh").read_text()
    block = re.search(r"<<'PY'\n(.*?)^PY$", source, re.MULTILINE | re.DOTALL)
    if block is None:
        return ["日志自测需要公共输出处理器"]
    findings: list[str] = []
    for status, count, ci in ((0, 10, False), (7, 40, False), (7, 41, False),
                              (-15, 1, False), (0, 41, True), (7, 41, True)):
        lines = [f"error: diagnostic {index}\n" for index in range(count)]
        process = SimpleNamespace(stdout=iter(lines), wait=lambda: status)
        visible, log = StringIO(), StringIO()
        with patch.object(sys, "argv", ["logger", "/audit/build.log", "logger", "fake"]), \
             patch.object(subprocess, "Popen", return_value=process), \
             patch.object(Path, "mkdir"), patch.object(Path, "open", return_value=nullcontext(log)), \
             patch.dict(os.environ, {"GITHUB_ACTIONS": "true" if ci else "false"}), \
             redirect_stdout(visible):
            try:
                exec(compile(block[1], "logger-self-test", "exec"), {})
            except SystemExit as error:
                expected = status if status >= 0 else 128 - status
                if error.code != expected:
                    findings.append("日志自测：进程退出状态传递")
            else:
                findings.append("日志自测：进程退出状态缺失")
        output = visible.getvalue()
        if log.getvalue() != "".join(lines):
            findings.append("日志自测：完整输出留档")
        show_details = count <= 40 or (ci and status != 0)
        if ("[输出]" in output) == show_details:
            findings.append("日志自测：本地展示阈值与 CI 失败诊断")
        if show_details and sum(line.startswith("error:") for line in output.splitlines()) != count:
            findings.append("日志自测：完整诊断展示")
    script = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    header = script.split("set -euo pipefail", 1)[0]
    fixture = ROOT / ".build/static-audit/script-snapshot.sh"
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(header + 'print -r -- "print replacement" > "$0"\n' + "# padding\n" * 2000 + "print snapshot-survived\n")
    try:
        result = subprocess.run(["zsh", str(fixture)], capture_output=True, text=True)
        if result.returncode or result.stdout.strip() != "snapshot-survived":
            findings.append("脚本快照自测：执行期间改写源码影响既有流程")
    finally:
        fixture.unlink(missing_ok=True)
    findings.extend(build_cache_boundary_findings())
    findings.extend(script_command_boundary_findings())
    support = (SCRIPT_ROOT / "script-support.sh").read_text()
    routing = subprocess.run(["zsh", "-c", support + r'''
bit101_build_cache() { print cached; }
bit101_log_command() { print direct; }
bit101_run_logged /log test xcodebuild test-without-building
bit101_run_logged /log build xcodebuild build-for-testing
'''], capture_output=True, text=True)
    if routing.returncode or routing.stdout.splitlines() != ["direct", "cached"]:
        findings.append("脚本自测：测试执行与编译缓存锁的生命周期")
    audit = (SCRIPT_ROOT / "run-static-audit.sh").read_text()
    tail = audit[audit.index("failed_groups=()"):]
    tail = re.sub(r'  line_count="[^\n]+"', "  line_count=0", tail)
    harness = r'''
set -euo pipefail
LOG_DIR=/audit
AUDIT_STARTED=$SECONDS
cat() { :; }
run_group() {
    print -r -- "RAN $1"
    case "$1" in shell-parse|docs) return 7;; esac
    return 0
}
'''
    aggregation = subprocess.run(["zsh", "-c", harness + tail], capture_output=True, text=True)
    groups = re.findall(r"^RAN (.+)$", aggregation.stdout, re.MULTILINE)
    if aggregation.returncode != 1 or len(set(groups)) != 10 or "shell-parse, docs" not in aggregation.stderr:
        findings.append("静态审计自测：并行分组执行完整性与多个失败汇总")
    return findings


def script_command_boundary_findings() -> list[str]:
    "通过内存替身验证自动选机、操作分派、筛选合并及参数拒绝。"
    import os
    import shlex
    import plistlib
    from contextlib import nullcontext, redirect_stdout
    from io import BytesIO, StringIO
    from unittest.mock import Mock, patch

    findings = []
    support = SCRIPT_ROOT / "script-support.sh"
    frame = r'''
bit101_require_device() {
  print DEVICE
  export BIT101_XCODE_DEVICE_ID=udid BIT101_DEVICETCL_DEVICE_ID=core
  export BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME=phone
}
bit101_build_cache() { print CACHE; }
mkdir() { :; }
rm() { :; }
ditto() { :; }
open() { :; }
pgrep() { return 1; }
trap() { :; }
xcrun() {
  if [[ "$*" == *lockState* ]]; then print '{"result":{"isLocked":false}}';
  else print -ru2 -- "TOOL $*"; fi
}
'''
    ui_test_count = sum(
        len(re.findall(r"^\s*(?:@objc )?func test\w+\(", path.read_text(), re.MULTILINE))
        for path in (ROOT / "BIT101-iOSUITests").glob("*.swift")
    )
    cases = (
        ("build-install-device.sh", [], 0, "platform=iOS,id=udid", "DEVICE"),
        ("build-install-device.sh", ["build"], 0, "generic/platform=iOS", ""),
        ("build-install-device.sh", ["mac"], 0, "variant=Mac Catalyst", ""),
        ("build-install-device.sh", ["info"], 0, "phone", "DEVICE"),
        ("build-install-device.sh", ["screenshot"], 0, "截图已保存", "DEVICE"),
        ("run-extended-tests.sh", ["build"], 0, "build-for-testing", ""),
        ("run-extended-tests.sh", ["build", "ui"], 0, "BIT101-iOS-UIAutomation", ""),
        ("run-extended-tests.sh", ["build", "network-smoke"], 0, "RELEASE_NETWORK_SMOKE", ""),
        ("run-extended-tests.sh", ["build", "icloud-smoke"], 0, "ICLOUD_CROSS_DEVICE_SMOKE", ""),
        ("run-extended-tests.sh", ["build", "modules"], 0, "swift build", ""),
        ("run-extended-tests.sh", ["build", "catalyst"], 0, "variant=Mac Catalyst", ""),
        ("run-extended-tests.sh", ["ui", "About", "About"], 86, "LoginAndScheduleUITests/testAboutLicenseUpdateAndResetConfirmation", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "Schedule"], 86, "testScheduleWeekButtonsAndSectionSwipes", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "DDLEditor"], 86, "InteractionCoverageUITests/testDDLEditorDetailsDatePickerValidationAndCancelEditing", "DEVICE"),
        ("run-extended-tests.sh", ["ui", "test"], 86, f"{ui_test_count} 项 UI 用例", "DEVICE"),
        ("run-extended-tests.sh", ["modules"], 86, "swift test", ""),
        ("run-extended-tests.sh", [], 86, "-only-testing:BIT101-iOSTests", "DEVICE"),
        ("run-extended-tests.sh", ["NetworkClientTests"], 86, "BIT101-iOSTests/NetworkClientTests", "DEVICE"),
        ("run-extended-tests.sh", ["cache"], 0, "CACHE", ""),
        ("release-network-smoke.sh", ["ddl"], 86, "RELEASE_NETWORK_SMOKE", "DEVICE"),
        ("run_icloud_cross_device_smoke.sh", [], 86, "ICLOUD_CROSS_DEVICE_SMOKE", "DEVICE"),
    )
    environment = dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD="1", BIT101_DEFER_APP_RESTORE="1")
    for filename, arguments, expected, marker, device in cases:
        path = SCRIPT_ROOT / filename
        source = path.read_text().replace('source "$ROOT_DIR/Scripts/script-support.sh"',
                                         f"source {shlex.quote(str(support))}\n" + frame)
        stop = "exit 86" if expected == 86 else "return 0"
        source = source.replace(frame, frame + f'\nbit101_run_logged() {{ print -r -- "BUILD $*"; {stop}; }}\n')
        source = re.sub(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$",
                        'ui_test_plan() { print -r -- /audit/ui.xctestrun; }', source, count=1)
        result = subprocess.run(["zsh", "-c", source, str(path), *arguments], env=environment,
                                capture_output=True, text=True)
        if result.returncode != expected or marker not in result.stdout or ("DEVICE\n" in result.stdout) != bool(device):
            findings.append(f"命令自测：{filename} {' '.join(arguments)} 分派及自动选机；{result.stderr[:160]}")
        if filename == "run-extended-tests.sh" and arguments[:2] == ["ui", "About"] and result.stdout.count(marker) != 1:
            findings.append("命令自测：重复 UI 关键词合并为一个用例")
        if arguments == ["ui", "Schedule"] and "testAboutLicense" in result.stdout:
            findings.append("命令自测：方法关键词按实际流程筛选")
        if arguments == ["ui", "test"] and result.stdout.count("-only-testing:BIT101-iOSUITests/") != ui_test_count:
            findings.append("命令自测：两个测试类的全部交互用例可通过关键词选择")
    for filename, arguments in (
        ("build-install-device.sh", ["build", "extra"]),
        ("run-extended-tests.sh", ["ui", "unmatched-keyword"]),
        ("run-extended-tests.sh", ["build", "unknown"]),
        ("run-extended-tests.sh", ["verify", "unknown"]),
        ("release-network-smoke.sh", ["unknown"]),
        ("run_icloud_cross_device_smoke.sh", ["unknown"]),
    ):
        result = subprocess.run(["zsh", str(SCRIPT_ROOT / filename), *arguments], capture_output=True, text=True)
        if result.returncode != 64:
            findings.append(f"命令自测：{filename} 错误参数在执行前拒绝")

    plan_function = re.search(r"(?ms)^ui_test_plan\(\) \{\n.*?^\}$", (SCRIPT_ROOT / "run-extended-tests.sh").read_text())
    plan_source = re.search(r"<<'PY'\n(.*?)^PY$", plan_function[0], re.MULTILINE | re.DOTALL)[1]
    configuration = {"TestConfigurations": [{"TestTargets": [
        {"IsUITestBundle": True, "UITargetAppMainThreadCheckerEnabled": True,
         "UITargetAppPerformanceAntipatternCheckerEnabled": True, "TestBundlePath": "UI.xctest"},
        {"IsUITestBundle": False, "UITargetAppMainThreadCheckerEnabled": True, "TestBundlePath": "App.xctest"},
    ]}]}
    older, newer = Mock(), Mock()
    older.stat.return_value.st_mtime = 1
    newer.stat.return_value.st_mtime = 2
    written = BytesIO()
    newer.open.side_effect = [nullcontext(BytesIO(plistlib.dumps(configuration))), nullcontext(written)]
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), \
         patch.object(Path, "glob", return_value=[older, newer]), redirect_stdout(StringIO()):
        exec(compile(plan_source, "ui-plan-self-test", "exec"), {})
    targets = plistlib.loads(written.getvalue())["TestConfigurations"][0]["TestTargets"]
    if older.open.called or targets[0]["UITargetAppMainThreadCheckerEnabled"] \
            or targets[0]["UITargetAppPerformanceAntipatternCheckerEnabled"] \
            or targets[0]["TestBundlePath"] != "UI.xctest" or targets[1] != configuration["TestConfigurations"][0]["TestTargets"][1]:
        findings.append("UI 计划自测：最新构建选择、诊断设置及业务 target 配置保留")
    with patch.object(sys, "argv", ["ui-plan", "/audit/Products"]), patch.object(Path, "glob", return_value=[]):
        try:
            exec(compile(plan_source, "ui-plan-empty-self-test", "exec"), {})
        except SystemExit as error:
            if ".xctestrun" not in str(error):
                findings.append("UI 计划自测：冷缓存缺少运行配置时的诊断")
        else:
            findings.append("UI 计划自测：运行配置完整性检查")

    def candidate(name, transport, tunnel="connected", pairing="paired", reality="physical"):
        return {"identifier": name, "hardwareProperties": {"udid": name, "deviceType": "iPhone", "reality": reality},
                "connectionProperties": {"transportType": transport, "tunnelState": tunnel, "pairingState": pairing},
                "deviceProperties": {"name": name}}

    for devices, expected in (
        ([candidate("wireless", "localNetwork"), candidate("wired", "wired")], "wired"),
        ([candidate("wireless", "localNetwork"), candidate("offline", None)], "wireless"),
        ([candidate("pending", "wired", "disconnected"), candidate("connected", "wired")], "connected"),
        ([candidate("unpaired", "wired", pairing="unpaired"), candidate("virtual", "wired", reality="virtual")], ""),
    ):
        snapshot = shlex.quote(json.dumps({"result": {"devices": devices}}))
        code = f'source {shlex.quote(str(support))}\nunset BIT101_XCODE_DEVICE_ID BIT101_DEVICETCL_DEVICE_ID BIT101_DEVICE_TRANSPORT BIT101_DEVICE_NAME\n'
        code += f'bit101_device_snapshot() {{ print -r -- {snapshot}; }}\nbit101_find_device || exit 1\nprint -r -- "$BIT101_DEVICE_NAME"\n'
        result = subprocess.run(["zsh", "-c", code], capture_output=True, text=True)
        if (expected and (result.returncode or result.stdout.strip() != expected)) or (not expected and result.returncode != 1):
            findings.append("设备自测：有线优先、无线发现、连接状态及真实配对设备范围")
    return findings


def build_cache_boundary_findings() -> list[str]:
    "验证缓存合并、热文件保留、链接复用和清理边界。"
    from contextlib import redirect_stdout
    from io import StringIO
    import os
    import shutil
    from unittest.mock import patch

    source = (SCRIPT_ROOT / "script-support.sh").read_text()
    function = source.split("bit101_build_cache() {", 1)[1].split("\n}\n", 1)[0]
    block = re.search(r"<<'PY'\n(.*?)^PY$", function, re.MULTILINE | re.DOTALL)
    fixture = ROOT / ".build/static-audit/cache-self-test"
    findings: list[str] = []
    try:
        shared = fixture / ".build/compiler-cache/ModuleCache.noindex"
        old = fixture / ".build/extended-automation/ModuleCache.noindex"
        shared.mkdir(parents=True, exist_ok=True)
        old.mkdir(parents=True, exist_ok=True)
        (shared / "warm").write_text("retain warm module")
        (old / "warm").write_text("old module")
        os.utime(old / "warm", ns=(1, 1))
        (old / "unique").write_text("preserve unique module")
        module = old / "module.pcm"
        content = b"compiled module fixture\n" * 4096
        module.write_bytes(content)
        modified = module.stat().st_mtime_ns
        contexts = {
            "simulator": "arm64-apple-ios27.0-simulator",
            "watch-simulator": "arm64-apple-watchos27.0-simulator",
            "phone": "arm64-apple-ios27.0",
            "mac": "arm64-apple-ios27.0-macabi",
            "unreadable": None,
        }
        for name in contexts:
            (shared / name).mkdir()
            (shared / name / f"{name}.pcm").write_bytes(content)
        command_run = subprocess.run
        builds = []

        def inspect_module(command, **options):
            if command[:2] == ["zsh", "-c"]:
                builds.append(command)
                return subprocess.CompletedProcess(command, 0)
            if command[:3] == ["xcrun", "clang", "-module-file-info"]:
                triple = contexts.get(Path(command[3]).stem)
                return subprocess.CompletedProcess(command, 0 if triple else 1,
                                                   f"Target options:\n  Triple: {triple}\n" if triple else "", "")
            return command_run(command, **options)

        obsolete = fixture / ".build/ui-authorization.logarchive"
        obsolete.mkdir()
        diagnostics = fixture / ".build/extended-automation/diagnostics"
        diagnostics.mkdir()
        products = fixture / ".build/extended-automation/Build/Products"
        for platform in ("Release-iphoneos", "Release-iphonesimulator"):
            (products / platform).mkdir(parents=True)
            (products / platform / "product").write_text(platform)
        symbols = products / "Release-iphoneos/product.dSYM"
        symbols.mkdir()
        (symbols / "debug-info").write_bytes(content)
        bundled_symbols = products / "Release-iphoneos/Runner.app/PlugIns/tests.xctest.dSYM/debug-info"
        bundled_symbols.parent.mkdir(parents=True)
        bundled_symbols.write_bytes(content)
        result = fixture / ".build/extended-automation/test-results.xcresult"
        result.mkdir()
        (result / "evidence").write_text("retain result")
        sdk = fixture / ".build/extended-automation/SDKExplicitPrecompiledModules"
        sdk.mkdir()
        (sdk / "referenced.pcm").write_bytes(content)
        (sdk / "unused.pcm").write_bytes(content)
        dependencies = products.parent / "Intermediates.noindex/fixture-dependencies.json"
        dependencies.parent.mkdir()
        debug_object = dependencies.parent / "debug.o"
        debug_object.write_bytes(content)
        dependencies.write_text(json.dumps([{"clangModulePath": str(sdk / "referenced.pcm")}]))
        for _ in range(2):
            with patch.object(sys, "argv", ["cache", str(fixture), "--maintenance"]), \
                    patch.object(subprocess, "run", inspect_module), redirect_stdout(StringIO()):
                exec(compile(block[1], "cache-self-test", "exec"), {})
        if not old.is_symlink() or old.resolve() != shared.resolve():
            findings.append("缓存自测：同类缓存目录共享")
        if (old / "warm").read_text() != "retain warm module" or (old / "unique").read_text() != "preserve unique module":
            findings.append("缓存自测：保留热模块及唯一模块")
        if module.read_bytes() != content or module.stat().st_mtime_ns != modified:
            findings.append("缓存自测：合并保留内容和修改时间")
        if any((shared / name).exists() for name in ("simulator", "watch-simulator")):
            findings.append("缓存自测：停用平台的隐式模块清理")
        if any((shared / name / f"{name}.pcm").read_bytes() != content for name in ("phone", "mac", "unreadable")):
            findings.append("缓存自测：保留真机、Mac 及平台归属待核对的模块")
        if obsolete.exists() or diagnostics.exists() or symbols.exists() or (products / "Release-iphonesimulator").exists():
            findings.append("缓存自测：清理诊断与失效平台产物")
        if debug_object.read_bytes() != content:
            findings.append("缓存自测：保留目标文件中的调试信息")
        if bundled_symbols.read_bytes() != content:
            findings.append("缓存自测：保留运行包内部的调试资源")
        if not (products / "Release-iphoneos/product").is_file() or not (result / "evidence").is_file():
            findings.append("缓存自测：保留增量构建及测试证据")
        if not (sdk / "referenced.pcm").is_file() or (sdk / "unused.pcm").exists():
            findings.append("缓存自测：依赖清单引用模块保留")
        (sdk / "incomplete-map.pcm").write_bytes(content)
        dependencies.write_text("{")
        with patch.object(sys, "argv", ["cache", str(fixture), "--maintenance"]), \
                patch.object(subprocess, "run", inspect_module), redirect_stdout(StringIO()):
            exec(compile(block[1], "cache-self-test", "exec"), {})
        if not (sdk / "incomplete-map.pcm").is_file():
            findings.append("缓存自测：依赖清单受损时保留缓存")
        for action, settings, expected in (
            ("build", [], ["DEBUG_INFORMATION_FORMAT=dwarf"]),
            ("test", ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"], ["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"]),
            ("archive", [], []),
            ("build-for-testing", ["SWIFT_COMPILATION_MODE=wholemodule"], ["DEBUG_INFORMATION_FORMAT=dwarf"]),
        ):
            arguments = ["cache", str(fixture), "build.log", "build", "xcodebuild", action, *settings]
            with patch.object(sys, "argv", arguments), patch.object(subprocess, "run", inspect_module):
                try:
                    exec(compile(block[1], "cache-self-test", "exec"), {})
                except SystemExit as result:
                    if result.code != 0:
                        raise
            if [value for value in builds[-1] if value.startswith("DEBUG_INFORMATION_FORMAT=")] != expected:
                findings.append("缓存自测：开发 DWARF、显式符号设置和发行归档边界")
            expected_mode = [] if action == "archive" else ["SWIFT_COMPILATION_MODE=wholemodule" if settings == ["SWIFT_COMPILATION_MODE=wholemodule"] else "SWIFT_COMPILATION_MODE=singlefile"]
            if [value for value in builds[-1] if value.startswith("SWIFT_COMPILATION_MODE=")] != expected_mode:
                findings.append("缓存自测：开发增量编译、显式编译模式和发行归档边界")
    finally:
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def smoke_script_boundary_findings() -> list[str]:
    "通过故障注入验证恢复顺序、状态传播和失败证据保留。"
    from contextlib import redirect_stdout
    from io import StringIO
    from unittest.mock import patch

    import os
    import signal

    source = (SCRIPT_ROOT / "run_icloud_cross_device_smoke.sh").read_text()
    findings: list[str] = []

    def shell_function(name: str, script_source: str = source) -> str:
        match = re.search(rf"(?ms)^([ \t]*){name}\(\) \{{\n.*?^\1\}}$", script_source)
        if match is None:
            raise RuntimeError(f"Smoke 自测需要 {name} 函数")
        return match[0]

    phone_function = shell_function("run_phone_test")
    stub = r'''
set -euo pipefail
DERIVED_ROOT=/smoke
RESULT_BUNDLE=/smoke/test-results.xcresult
DEVICE_ID=device
TEST_CLASS=smoke
common_args=()
rm() { print -r -- "DELETE $*"; }
bit101_run_logged() { print -r -- "RUN $*"; }
record_result() { print -r -- "RECORD $*"; }
'''
    cleanup = subprocess.run(["zsh", "-c", stub + phone_function + "\nrun_phone_test testCleanup"], capture_output=True, text=True)
    if cleanup.returncode or "DELETE" in cleanup.stdout or "-resultBundlePath" in cleanup.stdout:
        findings.append("Smoke 恢复自测失败：清理覆盖业务阶段结果包")
    business = subprocess.run(["zsh", "-c", stub + phone_function + "\nrun_phone_test testPhoneRoundTrip"], capture_output=True, text=True)
    if business.returncode or "-resultBundlePath" not in business.stdout:
        findings.append("Smoke 恢复自测失败：业务阶段结果包保存")

    worker = re.search(r"<<'PYWORKER'\n(.*?)^PYWORKER$", source, re.MULTILINE | re.DOTALL)
    handlers = {}
    child = type("Worker", (), {"pid": 42, "wait": lambda self: (handlers[signal.SIGTERM](signal.SIGTERM, None), -signal.SIGTERM)[1]})()
    with patch.object(sys, "argv", ["worker", source, "/root", "/derived", "/bundle", "/report", "device", "suite"]), \
         patch.object(subprocess, "Popen", return_value=child) as launch, \
         patch.object(signal, "signal", side_effect=lambda signum, handler: handlers.update({signum: handler})), \
         patch.object(os, "killpg") as cancel:
        try:
            exec(compile(worker[1], "phone-worker-self-test", "exec"), {})
        except SystemExit as result:
            if result.code != 143:
                findings.append("Smoke 并行自测：手机宿主信号退出状态")
        if launch.call_args.kwargs.get("start_new_session") is not True or cancel.call_args.args != (42, signal.SIGTERM):
            findings.append("Smoke 并行自测：中断时终止手机测试进程组")

    finish = shell_function("finish_smoke").replace('"$ROOT_DIR/Scripts/build-install-device.sh"', "restore_normal_app")
    trap_registration = "\n".join(re.findall(r"(?m)^trap .+$", source))
    cases = ((7, 0, 0, 7), (7, 1, 0, 7), (7, 0, 1, 7), (0, 1, 0, 1), (0, 0, 1, 1), (0, 0, 0, 0), (130, 0, 0, 130), (143, 0, 0, 143))
    for initial, cleanup_status, restore_status, expected in cases:
        triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
        if initial in (130, 143):
            triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
        for trigger in triggers:
            harness = f'''
set -euo pipefail
PHONE_TESTS_STARTED=true
PHONE_CLEANED_UP=false
PHONE_TEST_PID=""
CLEANUP_ONLY=false
SUMMARY_PATH=/smoke/report.json
DEVICE_ID=device
BIT101_DEFER_APP_RESTORE=0
run_phone_test() {{ print cleanup; return {cleanup_status}; }}
restore_normal_app() {{ print restore; return {restore_status}; }}
report_result() {{ print report; }}
python3() {{ cat >/dev/null; }}
{finish}
{trap_registration}
{trigger}
'''
            result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
            if result.returncode != expected or not re.search(r"(?ms)^cleanup$.*^restore$.*^report$", result.stdout):
                findings.append(f"Smoke 恢复自测失败：状态 {initial}/{cleanup_status}/{restore_status}；{trigger}")

    network_source = (SCRIPT_ROOT / "release-network-smoke.sh").read_text()
    restore = shell_function("restore_normal_app", network_source).replace(
        '"$ROOT_DIR/Scripts/build-install-device.sh" >/dev/null 2>&1',
        "restore_release",
    )
    network_traps = "\n".join(line.strip() for line in network_source.splitlines() if line.strip().startswith("trap "))
    for initial, restore_status, expected in ((7, 0, 7), (7, 1, 7), (0, 1, 1), (0, 0, 0)):
        harness = f'''
set -euo pipefail
DEVICE_ID=device
restore_release() {{ print restore; return {restore_status}; }}
{restore}
{network_traps}
fail_command() {{ return {initial}; }}
fail_command
'''
        result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
        if result.returncode != expected or result.stdout.count("restore\n") != 1:
            findings.append(f"网络 Smoke 恢复自测失败：状态 {initial}/{restore_status}")

    extended_source = (SCRIPT_ROOT / "run-extended-tests.sh").read_text()
    for name in ("finish_verification", "restore_release_app"):
        recovery = shell_function(name, extended_source).replace(
            '"$ROOT_DIR/Scripts/build-install-device.sh"', "restore_release",
        )
        registration = re.search(rf"(?m)^[ \t]*trap {name} [^\n]+(?:\n[ \t]*trap [^\n]+)*", extended_source)
        if registration is None:
            findings.append(f"测试恢复自测需要 {name} 错误钩子")
            continue
        for initial, restore_status, expected in ((7, 0, 7), (7, 1, 7), (0, 1, 1), (0, 0, 0), (130, 0, 130), (143, 0, 143)):
            triggers = [f"exit {initial}", f"fail_command() {{ return {initial}; }}; fail_command"]
            if initial in (130, 143):
                triggers.append(f"kill -s {'INT' if initial == 130 else 'TERM'} $$")
            for trigger in triggers:
                harness = f'''
set -euo pipefail
verification_needs_device=true
UI_TEST_EXECUTION_STARTED=true
WORKFLOW_STARTED_SECONDS=$SECONDS
DERIVED_ROOT=/dev/null
restore_release() {{ print restore; return {restore_status}; }}
{recovery}
{registration[0]}
{trigger}
'''
                result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
                if result.returncode != expected or result.stdout.count("restore\n") != 1:
                    findings.append(f"测试恢复自测失败：{name}；状态 {initial}/{restore_status}；{trigger}")
        if name == "restore_release_app":
            for initial in (1, 130, 143):
                harness = f'''
set -euo pipefail
UI_TEST_EXECUTION_STARTED=false
WORKFLOW_STARTED_SECONDS=$SECONDS
DERIVED_ROOT=/dev/null
restore_release() {{ print restore; return 0; }}
{recovery}
{registration[0]}
exit {initial}
'''
                result = subprocess.run(["zsh", "-c", harness], capture_output=True, text=True)
                if result.returncode != initial or "restore\n" in result.stdout:
                    findings.append(f"UI 编译失败恢复自测失败：状态 {initial}")

    match = re.search(r"(?ms)^record_result\(\).*?<<'PY'\n(.*?)^PY$", source)
    if match is None:
        return [*findings, "Smoke 自测需要阶段结果记录器"]
    state = {}
    def read(path: Path, *args, **kwargs) -> str:
        return state.get(str(path), "Test case 'ICloudCrossDeviceSmokeTests.testCleanup()' passed on 'device' (0.01 seconds)\n")
    def write(path: Path, value: str, *args, **kwargs) -> int:
        state[str(path)] = value
        return len(value)
    summary = {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0,
               "testFailures": [{"failureText": "business failure"}]}
    with patch.object(Path, "is_file", lambda path: str(path) in state), patch.object(Path, "is_dir", return_value=True), \
         patch.object(Path, "read_text", read), patch.object(Path, "write_text", write), \
         patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(summary))) as result_tool:
        for stage, process_status, expected in (("testPhoneRoundTrip", "65", 65), ("testCleanup", "0", 0)):
            with patch.object(sys, "argv", ["record", "/smoke/report.json", "/smoke/results.xcresult", stage, process_status, "/smoke/log"]), redirect_stdout(StringIO()):
                try:
                    exec(compile(match[1], "smoke-stage-record", "exec"), {})
                except SystemExit as error:
                    if error.code != expected:
                        findings.append("Smoke 结果自测失败：阶段状态码传播")
        report = json.loads(state["/smoke/report.json"])
        if report["stages"][0].get("testFailures") != summary["testFailures"] or len(report["stages"]) != 2 or result_tool.call_count != 1:
            findings.append("Smoke 结果自测失败：失败阶段与清理阶段的证据归属")
        for log, expected in (("", 1), ("skipped", 1), ("failed", 1), ("passed", 0)):
            state["/smoke/log"] = f"Test case 'ICloudCrossDeviceSmokeTests.testCleanup()' {log} on 'device' (0.01 seconds)\n" if log else ""
            with patch.object(sys, "argv", ["record", "/smoke/report.json", "/smoke/results.xcresult", "testCleanup", "0", "/smoke/log"]), redirect_stdout(StringIO()):
                try:
                    exec(compile(match[1], "smoke-cleanup-record", "exec"), {})
                except SystemExit as error:
                    if error.code != expected:
                        findings.append(f"Smoke 清理验收自测失败：{log or '零用例'}")
    return findings


def model_cancellation_findings(path: Path, facts: dict) -> list[str]:
    if not path.is_relative_to(ROOT / "Modules") and not path.is_relative_to(ROOT / "BIT101-iOS"):
        return []
    if not path.name.endswith(("ViewModel.swift", "ViewModels.swift")):
        return []
    if ast_has_identifier(facts, "TaskCancellation") or ast_has_call(facts, "isCancellation"):
        return []
    return [f"{relative(path)}: 状态模型通过公共取消识别入口处理任务取消"]


def client_source_findings(path: Path, source: str, facts: dict | None = None) -> list[str]:
    production_roots = (ROOT / "Modules", ROOT / "BIT101-iOS", ROOT / "BIT101ScheduleWidgets", ROOT / "BIT101Watch", ROOT / "BIT101WatchWidgets")
    if not any(path.is_relative_to(root) for root in production_roots):
        return []
    errors: list[str] = []
    name = relative(path)
    code = mask_literals_and_comments(source)
    if name not in STDOUT_EXCEPTIONS:
        add_matches(errors, path, code, DIRECT_STDOUT_LOG, "诊断输出使用所属模块的 Logger")
    community_roots = tuple(ROOT / "Modules" / module for module in ("CourseFeature", "GalleryFeature", "PaperFeature", "MineFeature", "CommunityUI"))
    if any(path.is_relative_to(root) for root in community_roots) and is_view_source(path, code):
        add_matches(errors, path, code, DIRECT_DATE_FORMATTER, "社区日期解析统一使用 AppDateText")
    return errors


def source_findings(syntax_index: dict[str, dict] | None = None) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    review: list[str] = []
    direct_cancellation_check = re.compile(r"\berror\s+is\s+CancellationError\b")
    empty_catch = re.compile(r"\bcatch\s*\{\s*\}")
    unsafe_concurrency_escape = re.compile(
        r"\bnonisolated\s*\(\s*unsafe\s*\)|@\s*unchecked\s+Sendable"
    )

    large_files: list[str] = []
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        masked_source = mask_literals_and_comments(source)
        name = relative(path)

        errors.extend(client_source_findings(path, source, syntax_index.get(str(path)) if syntax_index else None))

        if source and not source.endswith("\n"):
            errors.append(f"{name}: 文件末尾缺少换行")
        if "\t" in source:
            errors.append(f"{name}: Swift 源码不得使用 Tab 缩进")
        if any(line.rstrip() != line for line in source.splitlines()):
            errors.append(f"{name}: 存在行尾空白")
        import_lines = [
            (match.start(), match.group(1), source.count("\n", 0, match.start()) + 1)
            for match in re.finditer(r"^import\s+([^\s]+)", source, re.MULTILINE)
        ]
        # 同一条件分支内相邻的重复 import 通常是复制残留；#if/#else 两个分支各自
        # 引入同一模块属于必要代码，不报告。
        for index, (position, module, line) in enumerate(import_lines[:-1]):
            next_position, next_module, next_line = import_lines[index + 1]
            if module == next_module and next_line - line <= 1:
                errors.append(f"{name}:{line}: 重复 import {module}")

        if re.search(r"^\s*#if\s+false\b", masked_source, re.MULTILINE):
            errors.append(f"{name}: 不应保留 #if false 死代码块")
        add_matches(errors, path, masked_source, re.compile(r"\b(?:TODO|FIXME|HACK)\b"), "请清理遗留 TODO/FIXME/HACK")

        if name != relative(ROOT / "BIT101-iOS/Shared/Client/TaskCancellation.swift"):
            add_matches(errors, path, masked_source, direct_cancellation_check, "任务取消必须通过 TaskCancellation.matches 统一识别")
        add_matches(errors, path, masked_source, empty_catch, "禁止静默吞掉异常；请记录诊断或显式处理错误")
        add_matches(errors, path, masked_source, unsafe_concurrency_escape, "禁止绕过 Swift 并发安全检查：请表达真实隔离或使用锁/Actor")
        facts = syntax_index.get(str(path)) if syntax_index else None
        if facts and ast_has_view_request(facts):
            errors.append(f"{name}: View 不应直接构造 URLRequest；请求移到 Service")
        elif facts is None:
            for match in view_request_matches(masked_source):
                errors.append(
                    f"{name}:{line_number(source, match.start())}: "
                    "View 不应直接构造 URLRequest；请求移到 Service"
                )

        force_count = len(FORCE_UNWRAP.findall(masked_source))
        if force_count:
            errors.append(f"{name}: 禁止强制解包，共 {force_count} 处；请改用 guard/if let/#require")
        source_line_count = len(source.splitlines())
        if source_line_count >= MAX_SOURCE_LINES:
            errors.append(
                f"{name}: 检测到过大的代码，请拆分文件（{source_line_count} 行，文件应少于 {MAX_SOURCE_LINES} 行）"
            )
        if source_line_count > 800:
            large_files.append(name)

    if large_files:
        review.append("大型文件候选（按独立生命周期拆分，不因长度机械拆分）：" + ", ".join(large_files))
    return errors, review


def script_findings() -> list[str]:
    errors: list[str] = []
    for path in sorted(SCRIPT_ROOT.glob("*")):
        if path.suffix not in {".sh", ".py"} or not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
        if not source.startswith("#!"):
            errors.append(f"{relative(path)}: 脚本缺少 shebang")
        if not (path.stat().st_mode & stat.S_IXUSR):
            errors.append(f"{relative(path)}: 脚本缺少用户可执行权限")
        if path.name != "check-code-quality.py" and path.suffix == ".py" and "py_compile" in source:
            errors.append(f"{relative(path)}: 不应使用 py_compile 生成无用的 __pycache__")
        if path.name != "check-code-quality.py" and re.search(
            r"(?:mktemp|date[^\n]*%|uuidgen|\$\$)\s*[^\n]*(?:/|PATH|DIR|FILE|OUTPUT)",
            source,
        ):
            errors.append(f"{relative(path)}: 输出路径疑似带时间、UUID或进程号，禁止无限新建同类产物")
    return errors


def documentation_findings() -> list[str]:
    errors: list[str] = []
    markdown_link = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
    documents = subprocess.check_output([
        "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.md",
    ], cwd=ROOT, text=True)
    markdown_files = [
        ROOT / name for name in set(documents.split("\0"))
        if name and "Fixtures" not in Path(name).parts and (ROOT / name).is_file()
    ]
    for path in sorted(markdown_files):
        for target in markdown_link.findall(path.read_text(encoding="utf-8")):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target_path = (path.parent / target.split("#", 1)[0]).resolve()
            if not target_path.is_file():
                errors.append(f"{relative(path)}: 文档链接不存在：{target}")
    return errors


def automatic_school_fetch_findings(syntax_index: dict[str, dict]) -> list[str]:
    """保证启动、回前台和账号切换不会重新引入学校/WebVPN 自动请求。"""
    errors: list[str] = []
    forbidden_identifiers = (
        "SchoolDataRefreshCoordinator",
        "refreshOnEntry",
        "ScheduleAutoRefreshPreferences",
        "ScoreAutomaticRefreshPolicy",
        "autoRefreshCourses",
        "prepareClassroomIfNeeded",
        "refreshClassroomMetaInBackgroundIfNeeded",
        "claimAutomaticPreparation",
    )
    forbidden_literals = ("schedule.auto-refresh", "silent-refresh")
    for path in swift_files():
        facts = syntax_index[str(path)]
        for term in forbidden_identifiers:
            if ast_has_identifier(facts, term):
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")
        for term in forbidden_literals:
            if any(term in literal["value"] for literal in facts["stringSegments"]):
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")

    if owner_has_call(syntax_index, "BIT101_iOSApp", "refreshFromCloudIfNeeded"):
        errors.append("BIT101_iOSApp: 启动生命周期不得自动拉取 iCloud 数据")
    if owner_has_call(syntax_index, "ScheduleViewModel", "refreshFromCloudIfNeeded"):
        errors.append("ScheduleViewModel: 日程页面本地恢复不得自动拉取 iCloud")
    if owner_has_call(syntax_index, "ScoreListPage", "bootstrapIfNeeded"):
        errors.append("ScoreListPage: 成绩页不得自动触发学校查询")

    required_manual_contracts = (
        ("ScoreListPage", lambda: owner_has_call(syntax_index, "ScoreListPage", "restoreCachedDataIfNeeded"), "restoreCachedDataIfNeeded"),
        (
            "FreeClassroomTabView",
            lambda: owner_has_literal(syntax_index, "FreeClassroomTabView", "刷新空教室")
            and owner_has_identifier(syntax_index, "FreeClassroomTabView", "actionTitle"),
            "刷新空教室 actionTitle",
        ),
        ("ScheduleRootView", lambda: owner_has_call(syntax_index, "ScheduleRootView", "startClassroomPageRefresh"), "startClassroomPageRefresh"),
        ("ScheduleViewModel", lambda: owner_has_call(syntax_index, "ScheduleViewModel", "waitForClassroomAuthentication"), "waitForClassroomAuthentication"),
        ("ScheduleViewModel", lambda: owner_has_member_suffix(syntax_index, "ScheduleViewModel", ".classroomRefresh"), ".classroomRefresh"),
    )
    missing_owners: set[str] = set()
    for owner, predicate, marker in required_manual_contracts:
        if not owner_scopes(syntax_index, owner):
            missing_owners.add(owner)
        elif not predicate():
            errors.append(f"{owner}: 缺少显式学校请求/验证码入口：{marker}")
    for owner in sorted(missing_owners):
        errors.append(f"{owner}: 找不到必需的类型或 extension；学校请求契约保持启用")
    return errors


def architectural_contract_findings(syntax_index: dict[str, dict]) -> list[str]:
    """检查已确认的模块关系，防止同一概念在新文件中重新分叉。"""
    errors: list[str] = []

    required_conformances = {
        "CoursePagedState": "PagedItemsState",
        "GalleryFeedState": "PagedItemsState",
        "GalleryMessageListState": "CursorPagedItemsState",
        "CommunityCommentState": "PagedItemsState",
        "MinePagedState": "PagedItemsState",
        "PaperListState": "PagedItemsState",
    }
    for type_name, protocol_name in required_conformances.items():
        conforms = any(
            declaration["kind"] == "extension"
            and declaration["name"] == type_name
            and protocol_name in declaration["inheritedTypes"]
            for facts in syntax_index.values()
            for declaration in facts["declarations"]
        )
        if not conforms:
            errors.append(
                f"{type_name}: 缺少已统一的分页结构约束：{protocol_name}"
            )

    community_services = (
        "CourseService",
        "GalleryService",
        "MineService",
        "PaperService",
        "SettingsNetworkService",
    )
    for type_name in community_services:
        scoped_facts = [
            facts
            for facts in syntax_index.values()
            if any(declaration["name"] == type_name for declaration in facts["declarations"])
        ]
        if not scoped_facts:
            errors.append(f"{type_name}: 找不到社区服务声明")
            continue
        has_client_type = any(
            type_name in reference["scope"] and "CommunityAPIClient" in reference["value"]
            for facts in scoped_facts
            for reference in facts["typeNames"]
        )
        initializes_client = any(
            type_name in call["scope"] and (
                call["value"].startswith("CommunityAPIClient")
                or (
                    call["value"] == "session.client"
                    and any("CommunitySession" in ref["value"] for ref in facts["typeNames"])
                    and any(
                        "CommunitySession" in factory["scope"]
                        and factory["value"].startswith("CommunityAPIClient")
                        for session_facts in syntax_index.values()
                        for factory in session_facts["calls"]
                    )
                )
            )
            for facts in scoped_facts
            for call in facts["calls"]
        )
        if not has_client_type or not initializes_client:
            errors.append(
                f"{type_name}: 社区服务必须通过 CommunityAPIClient 初始化网络边界"
            )

    storage_contracts = (
        ("ScheduleCacheStore", "BIT101-iOS/Schedule/ScheduleCacheStore.swift"),
        ("ComposerDraftStore", "Modules/CommunityPersistence/Sources/ComposerDraftStore.swift"),
    )
    for type_name, file_name in storage_contracts:
        stores_in_scope = any(
            type_name in member["scope"]
            and uses_application_support_storage(member)
            for facts in syntax_index.values()
            for member in facts["members"]
        )
        if type_name == "ComposerDraftStore":
            store_source = (ROOT / file_name).read_text(encoding="utf-8")
            assembly_source = (ROOT / "BIT101-iOS/Shell/AppAccountStores.swift").read_text(encoding="utf-8")
            stores_in_scope = all(marker in store_source for marker in (
                "private let applicationSupport: URL",
                "self.applicationSupport = applicationSupport",
                "applicationSupport.appending(path: Self.directoryName",
            )) and "applicationSupport: AppFileDirectories.applicationSupport" in assembly_source
        if not stores_in_scope:
            errors.append(
                f"{file_name}: 持久化仓库必须复用 AppFileDirectories.applicationSupport"
            )

    for path in swift_files():
        errors.extend(model_cancellation_findings(path, syntax_index[str(path)]))

    return errors


def audit_wiring_findings() -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    groups = re.search(r"^group_names=\(([^\n]+)\)$", audit_source, re.MULTILINE)
    commands = re.search(r"^group_commands=\(([^\n]+)\)$", audit_source, re.MULTILINE)
    wiring = dict(zip(groups[1].split(), commands[1].split())) if groups and commands and len(groups[1].split()) == len(commands[1].split()) else {}
    if wiring.get("checkers") != "checker_audit":
        errors.append("Scripts/run-static-audit.sh: 未接入共享索引检查器审计")
    if "check_stale_docs.py --all" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入阻塞式文档新鲜度检查")
    if wiring.get("dependency-audit") != "dependency_audit":
        errors.append("Scripts/run-static-audit.sh: 未接入锁定依赖漏洞审计")
    if "npm audit --audit-level=high" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 依赖漏洞审计门槛缺失")
    if "release-network-smoke" in audit_source:
        errors.append("Scripts/run-static-audit.sh: 静态审计不得调用网络 smoke")

    workflow_path = ROOT / ".github/workflows/ci.yml"
    if not workflow_path.is_file():
        errors.append(".github/workflows/ci.yml: CI 工作流不存在")
    else:
        errors.extend(ci_wiring_findings(workflow_path.read_text(encoding="utf-8")))
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / "BIT101-iOS.xcodeproj/project.pbxproj"),
    ], text=True))
    errors.extend(extension_dependency_findings(project))
    for configuration in project["objects"].values():
        if configuration.get("isa") == "XCBuildConfiguration" and "SWIFT_COMPILATION_MODE" in configuration.get("buildSettings", {}):
            if "$(BIT101_WORKFLOW_CONDITIONS)" not in configuration["buildSettings"].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""):
                errors.append("App 工程编译条件需要接入工作流变量")
    for name in ("run-extended-tests.sh", "run_icloud_cross_device_smoke.sh", "release-network-smoke.sh"):
        if "SWIFT_ACTIVE_COMPILATION_CONDITIONS=" in (SCRIPT_ROOT / name).read_text():
            errors.append(f"{name}: 工作流条件需要限定在 App 工程")

    test_script = ROOT / "Scripts/run-extended-tests.sh"
    if not test_script.is_file():
        errors.append("Scripts/run-extended-tests.sh: 真机测试入口不存在")
    else:
        test_source = test_script.read_text(encoding="utf-8")
        required_test_metrics = (
            ("-enableCodeCoverage YES", "真机测试未启用代码覆盖率"),
            ("ENABLE_CODE_COVERAGE=YES", "Release 测试构建未覆盖项目级关闭项"),
            ("xccov", "真机测试未提取代码覆盖率"),
            ("test-metrics.txt", "真机测试指标未写入固定报告"),
            ("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "发布测试编译需要 Swift 警告门禁"),
            ("GCC_TREAT_WARNINGS_AS_ERRORS=YES", "发布测试编译需要 Clang 警告门禁"),
            ("--enable-code-coverage", "模块测试需要生产源码覆盖率"),
            ("generic/platform=iOS", "测试编译需要通用 iOS 目的地"),
            ("extensions)", "缺少扩展共享逻辑测试分组"),
            ("ExternalScheduleInfrastructureTests", "扩展共享逻辑分组未执行对应测试套件"),
        )
        for marker, message in required_test_metrics:
            if marker not in test_source:
                errors.append(f"Scripts/run-extended-tests.sh: {message}")

    hook_path = ROOT / ".githooks/pre-commit"
    if not hook_path.is_file() or "Scripts/check_stale_docs.py --all" not in hook_path.read_text(encoding="utf-8"):
        errors.append(".githooks/pre-commit: 提交前必须阻塞过期文档")
    return errors


def extension_dependency_findings(project: dict) -> list[str]:
    objects = project["objects"]
    targets = {value["name"]: key for key, value in objects.items() if value.get("isa") == "PBXNativeTarget"}
    errors = []
    for parent, child in (
        ("BIT101-iOS", "BIT101ScheduleWidgets"),
        ("BIT101-iOS", "BIT101Watch"),
        ("BIT101Watch", "BIT101WatchWidgets"),
    ):
        dependencies = objects.get(targets.get(parent), {}).get("dependencies", [])
        children = {objects[dependency].get("target") for dependency in dependencies}
        if targets.get(child) is None or targets[child] not in children:
            errors.append(f"project.pbxproj: {parent} 必须通过 target 依赖编译 {child}")
        if parent == "BIT101-iOS":
            for dependency in dependencies:
                edge = objects[dependency]
                if edge.get("target") == targets.get(child) and edge.get("platformFilter") != "ios":
                    errors.append(f"project.pbxproj: {child} 的 App 依赖应限定为 iOS 平台")
    return errors


def ci_wiring_findings(workflow_source: str) -> list[str]:
    errors: list[str] = []
    active_lines = [line for line in workflow_source.splitlines() if not line.lstrip().startswith("#")]
    source = "\n".join(active_lines) + "\n"

    def job_body(name: str) -> str | None:
        match = re.search(
            rf"(?ms)^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:|\Z)",
            source,
        )
        return match.group("body") if match else None

    def run_commands(job: str) -> list[str]:
        commands: list[str] = []
        lines = job.splitlines()
        for index, line in enumerate(lines):
            match = re.match(r"^        run:\s*(.*?)\s*$", line)
            if match is None:
                continue
            command = match.group(1)
            if command in {"|", "|-", ">", ">-"}:
                body: list[str] = []
                for following in lines[index + 1:]:
                    if following.strip() and len(following) - len(following.lstrip()) <= 8:
                        break
                    body.append(following.strip())
                command = " ".join(body)
            commands.append(command)
        return commands

    static_job = job_body("static-audit")
    release_job = job_body("release-build")
    catalyst_job = job_body("catalyst-tests")
    if static_job is None:
        errors.append(".github/workflows/ci.yml: CI 未声明静态审计 Job")
    elif "Scripts/run-static-audit.sh" not in run_commands(static_job):
        errors.append(".github/workflows/ci.yml: 静态审计 Job 缺少执行入口")
    if release_job is None:
        errors.append(".github/workflows/ci.yml: 缺少默认 Release 编译 Job")
        return errors
    if re.search(r"^    if:", release_job, re.MULTILINE):
        errors.append(".github/workflows/ci.yml: Release 编译 Job 必须默认执行")
    if not re.search(r"^    needs:\s*static-audit\s*$", release_job, re.MULTILINE):
        errors.append(".github/workflows/ci.yml: Release 编译 Job 必须依赖静态审计")
    if catalyst_job is None:
        errors.append(".github/workflows/ci.yml: CI 需要独立 Mac Catalyst 行为 Job")
    else:
        if re.search(r"^    if:", catalyst_job, re.MULTILINE):
            errors.append(".github/workflows/ci.yml: Mac Catalyst 行为 Job 需要默认执行")
        if not re.search(r"^    needs:\s*static-audit\s*$", catalyst_job, re.MULTILINE):
            errors.append(".github/workflows/ci.yml: Mac Catalyst 行为 Job 需要依赖静态审计")
        if "Scripts/run-extended-tests.sh catalyst" not in run_commands(catalyst_job):
            errors.append(".github/workflows/ci.yml: Mac Catalyst 行为 Job 需要执行行为用例")
    required_release_rules = (
        ("Scripts/run-extended-tests.sh build release", "CI 需要通用 iOS Release 测试构建"),
        ("Scripts/run-extended-tests.sh build ui", "CI 需要 UI 宿主与测试构建"),
        ("Scripts/run-extended-tests.sh build network-smoke", "CI 需要网络 Smoke 编译条件构建"),
        ("Scripts/run-extended-tests.sh build icloud-smoke", "CI 需要 iCloud Smoke 编译条件构建"),
    )
    release_commands = "\n".join(run_commands(release_job))
    for marker, message in required_release_rules:
        if marker not in release_commands:
            errors.append(f".github/workflows/ci.yml: {message}")
    return errors


def main(shared_syntax: dict[str, dict] | None = None, boundary_findings: list[str] | None = None) -> int:
    if sys.argv[1:] == ["--swift-syntax-index"]:
        try:
            print(json.dumps(swift_syntax_index(swift_files()), ensure_ascii=False))
            return 0
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            print(f"SwiftSyntax 索引失败：{error}", file=sys.stderr)
            return 1

    if sys.argv[1:] == ["--self-test"]:
        findings = checker_boundary_findings()
        if findings:
            print("[失败] 代码质量检查器自测：", file=sys.stderr)
            print("\n".join(findings), file=sys.stderr)
            return 1
        print("[通过] 代码质量检查器自测")
        return 0

    errors: list[str] = []
    if shared_syntax is None:
        try:
            syntax_index = swift_syntax_index(swift_files())
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            syntax_index = {}
            errors.append(f"SwiftSyntax 索引失败：{error}")
    else:
        syntax_index = shared_syntax
    source_errors, review = source_findings(syntax_index or None)
    errors.extend(source_errors)
    errors.extend(checker_boundary_findings() if boundary_findings is None else boundary_findings)
    errors.extend(script_findings())
    errors.extend(documentation_findings())
    if syntax_index:
        errors.extend(automatic_school_fetch_findings(syntax_index))
        errors.extend(architectural_contract_findings(syntax_index))
    errors.extend(audit_wiring_findings())

    report_lines = [
        "# 逐份源码质量审查",
        "",
        f"扫描 Swift 文件：{len(swift_files())} 个",
        "",
        "## 需要修复",
        *(errors or ["无"]),
        "",
        "## 人工审查候选",
        *(review or ["无"]),
        "",
    ]
    report = "\n".join(report_lines)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(report, encoding="utf-8")
    findings = [*errors, *review]
    if len(findings) <= 1000:
        if findings:
            print("\n".join(findings))
    else:
        print(f"代码质量检查共 {len(findings)} 项 · {relative(REPORT_PATH)}")

    if errors:
        return 1
    return 0


def explanatory_text_report() -> None:
    root = ROOT
    source_root = root / "BIT101-iOS"
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

    for path in sorted(source_root.rglob("*.swift")):
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

    count = sum(len(expressions) for _, _, expressions in footer_items + description_items)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    findings = [
        f"{path}:{line}: Text({expression})"
        for path, line, expressions in footer_items + description_items
        for expression in expressions
    ]
    if len(findings) <= 1000:
        if findings:
            print("解释文案审查候选：\n" + "\n".join(findings))
    else:
        print(f"解释文案审查候选共 {count} 条 · {report.relative_to(root)}")


def combined_main() -> int:
    try:
        syntax_index = swift_syntax_index(swift_files())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"[失败] SwiftSyntax 索引：{error}", file=sys.stderr)
        return 1
    ui_path = SCRIPT_ROOT / "check-ui-consistency.py"
    spec = importlib.util.spec_from_file_location("check_ui_consistency", ui_path)
    if spec is None or spec.loader is None:
        print(f"[失败] UI 检查器加载：{ui_path}", file=sys.stderr)
        return 1
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    quality_boundaries = checker_boundary_findings()
    ui_boundaries = [
        *module.ast_marker_boundary_findings(),
        *module.source_boundary_findings(),
        *module.map_theme_color_contract_findings(),
    ]
    ui_status = module.main(syntax_index, ui_boundaries)
    quality_status = main(syntax_index, quality_boundaries)
    explanatory_text_report()
    return int(ui_status != 0 or quality_status != 0)


if __name__ == "__main__":
    raise SystemExit(combined_main() if sys.argv[1:] == ["--combined"] else main())
