#!/usr/bin/env python3
"""Shared SwiftSyntax source facts and the fixed, reusable compiler artifact."""
from __future__ import annotations
import fcntl
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

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
