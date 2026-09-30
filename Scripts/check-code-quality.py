#!/usr/bin/env python3
"""逐份扫描项目源码，收口容易遗漏的代码风格约束。

硬错误会阻止静态审计；需要人工判断的事项写入固定报告，不制造新的临时文件。
"""

from __future__ import annotations

import re
import json
import os
import importlib.util
import subprocess
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOTS = (
    ROOT / "Modules",
    ROOT / "BIT101-iOS",
    ROOT / "BIT101-iOSTests",
    ROOT / "BIT101ScheduleWidgets",
    ROOT / "BIT101Watch",
    ROOT / "BIT101WatchWidgets",
)
SCRIPT_ROOT = ROOT / "Scripts"
REPORT_PATH = ROOT / ".build/code-quality-report.txt"
MAX_SOURCE_LINES = 1000

DIRECT_STDOUT_LOG = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")

DIRECT_SHARED_URLSESSION = re.compile(r"\bURLSession\.shared\b")
DIRECT_VIEW_REQUEST = re.compile(r"\bURLRequest\s*\(")
FORCE_UNWRAP = re.compile(r"\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*!(?!=)|\)\s*!(?!=)")

DIRECT_DATE_FORMATTER = re.compile(
    r"\b(?:DateFormatter|ISO8601DateFormatter|RelativeDateTimeFormatter)\s*\("
)

URLSESSION_EXCEPTIONS = {
    "BIT101-iOS/Shared/Client/HTTPClient.swift",
    "BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift",
}

STDOUT_EXCEPTIONS = {"Shared/Client/ReleaseNetworkSmoke.swift"}

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
        if ["Button", "NavigationLink", "Menu"].contains(calledName) {
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
            accessibilityControls.append(AccessibilityControlFact(
                name: calledName,
                invocation: node.trimmedDescription,
                label: labelSyntax?.trimmedDescription ?? "",
                hasTextTitle: titleArgument != nil,
                scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                labelStart: labelSyntax?.positionAfterSkippingLeadingTrivia.utf8Offset ?? -1,
                labelEnd: labelSyntax?.endPositionBeforeTrailingTrivia.utf8Offset ?? -1
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
    result = subprocess.run(
        [
            str(swift_path), "-I", str(host_modules), "-L", str(host_modules),
            "-lSwiftSyntax", "-lSwiftParser", "-e", SWIFT_SYNTAX_INDEXER,
        ],
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


def ast_has_shared_urlsession(facts: dict) -> bool:
    return any(
        member["value"] == "URLSession.shared"
        or member["value"].startswith("URLSession.shared.")
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
    """保留换行，忽略字符串与注释，避免文案和注释伪造源码契约。"""
    output = list(source)
    index = 0
    comment_depth = 0
    while index < len(source):
        if comment_depth:
            if source.startswith("/*", index):
                comment_depth += 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            elif source.startswith("*/", index):
                comment_depth -= 1
                _blank_segment(output, source, index, index + 2)
                index += 2
            else:
                _blank_segment(output, source, index, index + 1)
                index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            _blank_segment(output, source, index, end)
            index = end
            continue
        if source.startswith("/*", index):
            comment_depth = 1
            _blank_segment(output, source, index, index + 2)
            index += 2
            continue

        raw_match = re.match(r"(#+)(\"{1,3})", source[index:])
        if raw_match:
            hashes, quote = raw_match.groups()
            terminator = quote + hashes
            content_start = index + len(hashes) + len(quote)
            end = source.find(terminator, content_start)
            end = len(source) if end < 0 else end + len(terminator)
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            end = len(source) if end < 0 else end + 3
            _blank_segment(output, source, index, end)
            index = end
            continue

        if source[index] == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    _blank_segment(output, source, index, index + 2)
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    _blank_segment(output, source, index, index + 1)
                    index += 1
            continue

        index += 1
    return "".join(output)


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
    shared_session_source = '''
// URLSession.shared.data(for: request)
let example = "URLSession.shared.data(for: request)"
URLSession.shared.data(for: request)
'''
    masked_session_source = mask_literals_and_comments(shared_session_source)
    if len(DIRECT_SHARED_URLSESSION.findall(masked_session_source)) != 1:
        findings.append("代码质量规则边界自检失败：网络调用与注释/字符串区分")

    unwrap_source = '''
// value!
let example = "value!"
let unwrapped = value!
let comparison = left != right
'''
    masked_unwrap_source = mask_literals_and_comments(unwrap_source)
    if len(FORCE_UNWRAP.findall(masked_unwrap_source)) != 1:
        findings.append("代码质量规则边界自检失败：强制解包与比较运算区分")

    shared_session_facts = {"members": [{"value": "URLSession.shared.data", "scope": []}]}
    literal_only_facts = {"members": [{"value": "URLSession.default.data", "scope": []}]}
    if not ast_has_shared_urlsession(shared_session_facts) or ast_has_shared_urlsession(literal_only_facts):
        findings.append("代码质量规则边界自检失败：SwiftSyntax 网络边界匹配")

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
    workflow_source = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    detached_release = workflow_source.replace("needs: static-audit", "needs: []", 1)
    if not any("必须依赖静态审计" in item for item in ci_wiring_findings(detached_release)):
        findings.append("代码质量规则边界自检失败：Release Job 与静态审计依赖识别")
    misplaced_audit = workflow_source.replace("run: Scripts/run-static-audit.sh", "run: echo skipped", 1)
    misplaced_audit += "\n# Scripts/run-static-audit.sh\n"
    if not any("静态审计 Job 缺少执行入口" in item for item in ci_wiring_findings(misplaced_audit)):
        findings.append("代码质量规则边界自检失败：CI 注释中的审计标记隔离")
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

        if path.is_relative_to(ROOT / "BIT101-iOS"):
            if name.removeprefix("BIT101-iOS/") not in STDOUT_EXCEPTIONS:
                for match in DIRECT_STDOUT_LOG.finditer(masked_source):
                    finding_line = source.count("\n", 0, match.start()) + 1
                    errors.append(f"{name}:{finding_line}: 调试输出统一由网络 smoke 维护")

            if name not in URLSESSION_EXCEPTIONS:
                facts = syntax_index.get(str(path)) if syntax_index else None
                if facts:
                    if ast_has_shared_urlsession(facts):
                        errors.append(f"{name}: 网络请求统一通过 HTTPClient 或场景化 Service")
                else:
                    for match in DIRECT_SHARED_URLSESSION.finditer(masked_source):
                        finding_line = source.count("\n", 0, match.start()) + 1
                        errors.append(f"{name}:{finding_line}: 网络请求统一通过 HTTPClient 或场景化 Service")

            if name.removeprefix("BIT101-iOS/").split("/", 1)[0] in {"Course", "Gallery", "Paper"} and is_view_source(path, masked_source):
                for match in DIRECT_DATE_FORMATTER.finditer(masked_source):
                    finding_line = source.count("\n", 0, match.start()) + 1
                    errors.append(
                        f"{name}:{finding_line}: 社区日期解析统一使用 AppDateText"
                    )

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
    markdown_files = [
        path
        for path in ROOT.rglob("*.md")
        if ".git" not in path.parts
        and ".build" not in path.parts
        and "build" not in path.parts
        and "node_modules" not in path.parts
        and "Fixtures" not in path.parts
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
        ("ComposerDraftStore", "Modules/GalleryFeature/Sources/GalleryComposerDraftSupport.swift"),
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

    for path in sorted((ROOT / "BIT101-iOS").rglob("*.swift")):
        if not path.name.endswith(("ViewModel.swift", "ViewModels.swift")):
            continue
        facts = syntax_index[str(path)]
        if not ast_has_identifier(facts, "TaskCancellation") and not ast_has_call(facts, "isCancellation"):
            errors.append(f"{relative(path)}: 状态模型必须统一处理任务取消，不能把取消当成业务失败")

    return errors


def audit_wiring_findings() -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    if "run_group checkers checker_audit" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入共享索引检查器审计")
    if "check_stale_docs.py --all" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入阻塞式文档新鲜度检查")
    if "run_group dependency-audit dependency_audit" not in audit_source:
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
    required_release_rules = (
        ("Scripts/run-extended-tests.sh catalyst", "CI 默认 Job 缺少 Mac Catalyst 行为测试"),
        ("xcodebuild build-for-testing", "默认编译 Job 未编译 iOS 测试 target"),
        ("-scheme BIT101-iOS", "CI 未编译 iOS scheme"),
        ("generic/platform=iOS", "iOS 编译不得选择模拟器"),
        ("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "发布编译未将 Swift 警告视为错误"),
        ("GCC_TREAT_WARNINGS_AS_ERRORS=YES", "发布编译未将 Clang 警告视为错误"),
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
    if len(report_lines) <= 1000:
        REPORT_PATH.unlink(missing_ok=True)
        print(report)
    else:
        REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
        REPORT_PATH.write_text(report, encoding="utf-8")
        print(f"检查结果共 {len(report_lines)} 行，详情写入 {relative(REPORT_PATH)}")

    if errors:
        return 1
    return 0


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
    if not quality_boundaries:
        print("[通过] 代码质量检查器自测")
    if not ui_boundaries:
        print("[通过] UI 一致性检查器自测")
    ui_status = module.main(syntax_index, ui_boundaries)
    quality_status = main(syntax_index, quality_boundaries)
    return int(ui_status != 0 or quality_status != 0)


if __name__ == "__main__":
    raise SystemExit(combined_main() if sys.argv[1:] == ["--combined"] else main())
