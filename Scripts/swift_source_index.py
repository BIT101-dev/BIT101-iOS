#!/usr/bin/env python3
"""Shared SwiftSyntax source facts and the fixed, reusable compiler artifact."""
from __future__ import annotations
import fcntl
import json
import os
import re
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
    let enumCases: [EnumCaseFact]
    let calls: [ScopedFact]
    let invocations: [ScopedFact]
    let functions: [ScopedFact]
    let tests: [ScopedFact]
    let functionReturns: [FunctionReturnFact]
    let selectionControls: [SelectionControlFact]
    let feedbackModifiers: [FeedbackModifierFact]
    let alertModifiers: [AlertModifierFact]
    let typedVariables: [TypedVariableFact]
    let typeAliases: [TypeAliasFact]
    let listIcons: [ListIconFact]
    let listControls: [SelectionControlFact]
    let listStyleModifiers: [FeedbackModifierFact]
    let accessibilityModifiers: [FeedbackModifierFact]
    let accessibilityControls: [AccessibilityControlFact]
    let functionRanges: [FunctionRangeFact]
    let callableRanges: [FunctionRangeFact]
    let initializers: [FunctionRangeFact]
    let nonRenderedRanges: [ScopedRangeFact]
    let lifecycleRanges: [ScopedRangeFact]
    let members: [ScopedFact]
    let forceUnwraps: [ScopedFact]
    let emptyCatchClauses: [ScopedFact]
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

struct EnumCaseFact: Encodable {
    let name: String
    let rawValue: String?
    let scope: [String]
}

struct ScopedFact: Encodable {
    let value: String
    let scope: [String]
    let start: Int
    let lexicalScope: [Int]
    var argumentLabels: [String]? = nil
    var arguments: [String]? = nil
    var argumentRanges: [[Int]]? = nil
    var isTestingTest: Bool? = nil
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
    let modifiers: String
    let callback: String
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
    let start: Int
    let lexicalScope: [Int]
}

struct TypeAliasFact: Encodable {
    let name: String
    let type: String
    let scope: [String]
    let start: Int
    let lexicalScope: [Int]
    let isFilePrivate: Bool
    let isExported: Bool
}

struct ListIconFact: Encodable {
    let name: String
    let symbol: String
    let scope: [String]
    let containers: [String]
}

struct FunctionRangeFact: Encodable {
    let name: String
    let returnType: String?
    let returnsView: Bool
    let scope: [String]
    let start: Int
    let end: Int
    let lexicalScope: [Int]
    let parameters: [FunctionParameterFact]
}

struct FunctionParameterFact: Encodable {
    let label: String
    let type: String
    let hasDefault: Bool
    let variadic: Bool
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
    private(set) var enumCases: [EnumCaseFact] = []
    private(set) var calls: [ScopedFact] = []
    private(set) var invocations: [ScopedFact] = []
    private(set) var functions: [ScopedFact] = []
    private(set) var tests: [ScopedFact] = []
    private(set) var functionReturns: [FunctionReturnFact] = []
    private(set) var scopedIdentifiers: [ScopedFact] = []
    private(set) var stringSegments: [ScopedFact] = []
    private(set) var selectionControls: [SelectionControlFact] = []
    private(set) var feedbackModifiers: [FeedbackModifierFact] = []
    private(set) var alertModifiers: [AlertModifierFact] = []
    private(set) var typedVariables: [TypedVariableFact] = []
    private(set) var typeAliases: [TypeAliasFact] = []
    private(set) var listIcons: [ListIconFact] = []
    private(set) var listControls: [SelectionControlFact] = []
    private(set) var listStyleModifiers: [FeedbackModifierFact] = []
    private(set) var accessibilityModifiers: [FeedbackModifierFact] = []
    private(set) var accessibilityControls: [AccessibilityControlFact] = []
    private(set) var functionRanges: [FunctionRangeFact] = []
    private(set) var callableRanges: [FunctionRangeFact] = []
    private(set) var initializers: [FunctionRangeFact] = []
    private(set) var nonRenderedRanges: [ScopedRangeFact] = []
    private(set) var lifecycleRanges: [ScopedRangeFact] = []
    private(set) var members: [ScopedFact] = []
    private(set) var forceUnwraps: [ScopedFact] = []
    private(set) var emptyCatchClauses: [ScopedFact] = []
    private(set) var expressions: [ScopedFact] = []
    private(set) var bindings: [ScopedFact] = []
    private(set) var controlFlow: [ScopedFact] = []
    private(set) var typeNames: [ScopedFact] = []
    private var scope: [String] = []
    private var lexicalScope: [Int] = []
    private var listContainers: [String] = []
    private var functionStack: [(name: String, scope: [String], closureDepth: Int)] = []
    private var closureDepth = 0

    private func enter(_ kind: String, _ name: String, _ inherited: [String]) -> SyntaxVisitorContinueKind {
        declarations.append(DeclarationFact(kind: kind, name: name, inheritedTypes: inherited, scope: scope))
        scope.append(name)
        return .visitChildren
    }

    private func leave() { _ = scope.popLast() }
    private func recordParameters(_ parameters: FunctionParameterListSyntax, body: CodeBlockSyntax?) {
        guard let body else { return }
        for parameter in parameters {
            let name = parameter.secondName ?? parameter.firstName
            guard name.text != "_" else { continue }
            typedVariables.append(TypedVariableFact(name: name.text, type: parameter.type.trimmedDescription,
                scope: scope, start: name.positionAfterSkippingLeadingTrivia.utf8Offset,
                lexicalScope: lexicalScope + [body.positionAfterSkippingLeadingTrivia.utf8Offset]))
        }
    }
    private func fact(_ value: String, start: Int) -> ScopedFact {
        ScopedFact(value: value, scope: scope, start: start, lexicalScope: lexicalScope)
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

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("protocol", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [])
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { leave() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        recordParameters(node.signature.parameterClause.parameters, body: node.body)
        let isTest = node.attributes.contains { element in
            ["Test", "Testing.Test"].contains(element.as(AttributeSyntax.self)?.attributeName.trimmedDescription ?? "")
        }
        if isTest || node.name.text.hasPrefix("test") && node.signature.parameterClause.parameters.isEmpty
            && !node.modifiers.contains(where: { ["static", "class"].contains($0.name.text) })
            && [nil, "Void", "()"].contains(node.signature.returnClause?.type.trimmedDescription) {
            var test = fact((scope + [node.name.text]).joined(separator: "/"), start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
            test.isTestingTest = isTest
            tests.append(test)
        }
        functions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        functionRanges.append(FunctionRangeFact(
            name: node.name.text,
            returnType: node.signature.returnClause?.type.trimmedDescription,
            returnsView: node.signature.returnClause?.type.trimmedDescription.contains("View") ?? false,
            scope: scope,
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
            end: node.endPositionBeforeTrailingTrivia.utf8Offset,
            lexicalScope: lexicalScope,
            parameters: node.signature.parameterClause.parameters.map {
                FunctionParameterFact(label: $0.firstName.text == "_" ? "" : $0.firstName.text, type: $0.type.trimmedDescription,
                    hasDefault: $0.defaultValue != nil, variadic: $0.ellipsis != nil)
            }
        ))
        functionStack.append((node.name.text, scope, closureDepth))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { _ = functionStack.popLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        recordParameters(node.signature.parameterClause.parameters, body: node.body)
        initializers.append(FunctionRangeFact(name: "init", returnType: nil, returnsView: false, scope: scope,
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset, end: node.endPositionBeforeTrailingTrivia.utf8Offset,
            lexicalScope: lexicalScope, parameters: node.signature.parameterClause.parameters.map {
                FunctionParameterFact(label: $0.firstName.text == "_" ? "" : $0.firstName.text, type: $0.type.trimmedDescription,
                    hasDefault: $0.defaultValue != nil, variadic: $0.ellipsis != nil)
            }))
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closureDepth += 1
        lexicalScope.append(node.positionAfterSkippingLeadingTrivia.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) {
        closureDepth -= 1
        _ = lexicalScope.popLast()
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        lexicalScope.append(node.positionAfterSkippingLeadingTrivia.utf8Offset)
        return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) { _ = lexicalScope.popLast() }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        typeAliases.append(TypeAliasFact(name: node.name.text, type: node.initializer.value.trimmedDescription,
            scope: scope, start: node.name.positionAfterSkippingLeadingTrivia.utf8Offset, lexicalScope: lexicalScope,
            isFilePrivate: node.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) },
            isExported: node.modifiers.contains { ["public", "package"].contains($0.name.text) }))
        return .visitChildren
    }

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

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            enumCases.append(EnumCaseFact(name: element.name.text, rawValue: element.rawValue?.value.trimmedDescription, scope: scope))
        }
        return .visitChildren
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
        let calledExpression = node.calledExpression.tokens(viewMode: .sourceAccurate).map(\.text).joined()
        calls.append(fact(calledExpression, start: node.calledExpression.positionAfterSkippingLeadingTrivia.utf8Offset))
        var invocation = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        invocation.argumentLabels = node.arguments.map { $0.label?.text ?? "" }
        invocation.arguments = node.arguments.map { $0.expression.trimmedDescription }
        invocation.argumentRanges = node.arguments.map {
            [$0.expression.positionAfterSkippingLeadingTrivia.utf8Offset, $0.expression.endPositionBeforeTrailingTrivia.utf8Offset]
        }
        invocations.append(invocation)
        let calledName = calledExpression.split(separator: ".").last.map(String.init) ?? calledExpression
        if ["task", "onAppear", "onReceive"].contains(calledName) || calledName == "onChange"
            && node.arguments.contains(where: { $0.expression.trimmedDescription.contains("scenePhase")
                || $0.label?.text == "initial" && $0.expression.trimmedDescription == "true" }) {
            let callbacks: [ExprSyntax] = node.arguments.map(\.expression)
                + (node.trailingClosure.map { [ExprSyntax($0)] } ?? [])
            for callback in callbacks {
                lifecycleRanges.append(ScopedRangeFact(scope: scope,
                    start: callback.positionAfterSkippingLeadingTrivia.utf8Offset,
                    end: callback.endPositionBeforeTrailingTrivia.utf8Offset))
            }
        }
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
        if ["Button", "NavigationLink", "Menu", "Picker", "Toggle", "DatePicker", "Link", "PhotosPicker", "LabeledContent", "TextField", "SecureField", "TextEditor", "Slider", "Stepper", "ShareLink", "refreshable", "onSubmit", "onDelete", "onMove", "searchable", "contextMenu", "swipeActions", "onTapGesture", "onLongPressGesture", "gesture", "simultaneousGesture", "highPriorityGesture"].contains(calledName)
            && (!["refreshable", "onSubmit", "onDelete", "onMove", "searchable", "contextMenu", "swipeActions"].contains(calledName) || node.calledExpression.is(MemberAccessExprSyntax.self))
            && !(calledName == "onTapGesture" && node.arguments.isEmpty && node.trailingClosure?.statements.isEmpty == true) {
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
                case "PhotosPicker", "Link":
                    return trailingClosure
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
            var modifiers: [String] = []
            while let parent = styledExpression.parent {
                if parent.is(MemberAccessExprSyntax.self) || parent.is(FunctionCallExprSyntax.self) {
                    if let call = parent.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                        modifiers.append("." + member.declName.baseName.text + "(" + call.arguments.trimmedDescription + ")")
                    }
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
                expression: styledExpression.trimmedDescription,
                modifiers: modifiers.joined(),
                callback: node.trailingClosure?.trimmedDescription ?? ""
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
        let calledExpression = node.calledExpression.tokens(viewMode: .sourceAccurate).map(\.text).joined()
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

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        if node.body.statements.isEmpty {
            emptyCatchClauses.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        }
        return .visitChildren
    }

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        forceUnwraps.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" {
            forceUnwraps.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        }
        return .visitChildren
    }

    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" {
            forceUnwraps.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        }
        return .visitChildren
    }

    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.text == "!" {
            forceUnwraps.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        }
        return .visitChildren
    }

    override func visit(_ node: ImplicitlyUnwrappedOptionalTypeSyntax) -> SyntaxVisitorContinueKind {
        forceUnwraps.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        bindings.append(ScopedFact(value: node.pattern.trimmedDescription + " in " + node.sequence.trimmedDescription,
            scope: scope, start: node.pattern.positionAfterSkippingLeadingTrivia.utf8Offset,
            lexicalScope: lexicalScope + [node.body.positionAfterSkippingLeadingTrivia.utf8Offset]))
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        expressions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        expressions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        let parts = Array(node.elements)
        if parts.count == 3, parts[1].is(AssignmentExprSyntax.self),
           parts[2].is(ClosureExprSyntax.self) || parts[2].is(MemberAccessExprSyntax.self) || parts[2].is(DeclReferenceExprSyntax.self),
           let name = parts[0].as(DeclReferenceExprSyntax.self)?.baseName.text ?? parts[0].as(MemberAccessExprSyntax.self)?.declName.baseName.text {
            callableRanges.append(FunctionRangeFact(name: name, returnType: nil, returnsView: false, scope: scope,
                start: parts[2].positionAfterSkippingLeadingTrivia.utf8Offset, end: parts[2].endPositionBeforeTrailingTrivia.utf8Offset,
                lexicalScope: lexicalScope, parameters: []))
        }
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        bindings.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        if let declaration = node.parent?.parent?.as(VariableDeclSyntax.self), declaration.parent?.is(MemberBlockItemSyntax.self) == true,
           node.initializer != nil, !declaration.modifiers.contains(where: { ["static", "class", "lazy"].contains($0.name.text) }) {
            initializers.append(FunctionRangeFact(name: "init", returnType: nil, returnsView: false, scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset, end: node.endPositionBeforeTrailingTrivia.utf8Offset,
                lexicalScope: lexicalScope, parameters: []))
        }
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self),
           node.typeAnnotation?.type.trimmedDescription.contains("->") == true
                || node.initializer?.value.is(ClosureExprSyntax.self) == true
                || node.initializer?.value.is(MemberAccessExprSyntax.self) == true
                || node.initializer?.value.is(DeclReferenceExprSyntax.self) == true {
            callableRanges.append(FunctionRangeFact(name: pattern.identifier.text,
                returnType: node.typeAnnotation?.type.trimmedDescription, returnsView: false, scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                end: node.endPositionBeforeTrailingTrivia.utf8Offset, lexicalScope: lexicalScope, parameters: []))
        }
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self),
           let type = node.typeAnnotation?.type
        {
            typedVariables.append(TypedVariableFact(
                name: pattern.identifier.text,
                type: type.trimmedDescription,
                scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                lexicalScope: lexicalScope
            ))
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        bindings.append(fact(node.pattern.trimmedDescription + (node.initializer.map { " " + $0.trimmedDescription } ?? ""),
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self), let type = node.typeAnnotation?.type {
            typedVariables.append(TypedVariableFact(name: pattern.identifier.text, type: type.trimmedDescription,
                scope: scope, start: node.positionAfterSkippingLeadingTrivia.utf8Offset, lexicalScope: lexicalScope))
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
final class EscapedIdentifierNormalizer: SyntaxRewriter {
    override func visit(_ original: TokenSyntax) -> TokenSyntax {
        guard case .identifier(let name) = original.tokenKind, name.hasPrefix("`"), name.hasSuffix("`") else { return original }
        var token = original
        token.tokenKind = .identifier(String(name.dropFirst().dropLast()))
        token.leadingTrivia += .spaces(1)
        token.trailingTrivia = .spaces(1) + token.trailingTrivia
        return token
    }
}
func indexSource(_ source: String, as key: String) {
    let tree = EscapedIdentifierNormalizer(viewMode: .sourceAccurate).rewrite(Parser.parse(source: source))
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
        enumCases: visitor.enumCases,
        calls: visitor.calls,
        invocations: visitor.invocations,
        functions: visitor.functions,
        tests: visitor.tests,
        functionReturns: visitor.functionReturns,
        selectionControls: visitor.selectionControls,
        feedbackModifiers: visitor.feedbackModifiers,
        alertModifiers: visitor.alertModifiers,
        typedVariables: visitor.typedVariables,
        typeAliases: visitor.typeAliases,
        listIcons: visitor.listIcons,
        listControls: visitor.listControls,
        listStyleModifiers: visitor.listStyleModifiers,
        accessibilityModifiers: visitor.accessibilityModifiers,
        accessibilityControls: visitor.accessibilityControls,
        functionRanges: visitor.functionRanges,
        callableRanges: visitor.callableRanges,
        initializers: visitor.initializers,
        nonRenderedRanges: visitor.nonRenderedRanges,
        lifecycleRanges: visitor.lifecycleRanges,
        members: visitor.members,
        forceUnwraps: visitor.forceUnwraps,
        emptyCatchClauses: visitor.emptyCatchClauses,
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
        compiler_cache = ROOT / ".build/compiler-cache"
        module_cache = compiler_cache / "ModuleCache.noindex"
        module_cache.mkdir(parents=True, exist_ok=True)
        source_text = SWIFT_SYNTAX_INDEXER + f"\n// Toolchain: {compiler}\n// Module cache: {module_cache}\n"
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
            environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(module_cache))
            with (compiler_cache / "cache.lock").open("a") as compilation_lock:
                fcntl.flock(compilation_lock, fcntl.LOCK_EX)
                compilation = subprocess.run([
                    str(compiler), "-target", f"{os.uname().machine}-apple-macosx14.0", "-sdk", sdk,
                    "-module-cache-path", str(module_cache), "-warnings-as-errors",
                    "-I", str(host_modules), "-L", str(host_modules),
                    "-lSwiftSyntax", "-lSwiftParser", "-Xlinker", "-rpath", "-Xlinker", str(host_modules),
                    str(source), "-o", str(executable),
                ], capture_output=True, text=True, env=environment)
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
    conformances = declaration_conformances(index)
    test_classes = {canonical_type_scope(declaration["scope"] + [declaration["name"]])
        for facts in index.values() for declaration in facts["declarations"] if declaration["kind"] == "class"
        and any(base.rsplit(".", 1)[-1] == "XCTestCase" for base in
            conformances[canonical_type_scope(declaration["scope"] + [declaration["name"]])])}
    for facts in index.values():
        facts["tests"] = [test for test in facts["tests"] if test.get("isTestingTest")
                          or canonical_type_scope(test["scope"]) in test_classes]
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


def expected_argument_types(facts: dict, reference: dict) -> list[str]:
    parents = [(call, index) for call in facts["invocations"] if call["start"] < reference["start"]
        for index, bounds in enumerate(call.get("argumentRanges") or []) if bounds[0] <= reference["start"] < bounds[1]]
    if not parents: return []
    call, index = min(parents, key=lambda entry: len(entry[0]["value"].encode()))
    name = re.match(r"(?:\w+\.)*(\w+)\s*\(", call["value"])
    if not name: return []
    name = name[1]
    labels = call.get("argumentLabels") or []
    functions = [function for function in facts["functionRanges"] if function["name"] == name
        and call["scope"][:len(function["scope"])] == function["scope"]
        and call["lexicalScope"][:len(function["lexicalScope"])] == function["lexicalScope"]]
    functions += [function for function in facts["initializers"] if function["scope"] and function["scope"][-1] == name]
    result = []
    for function in functions:
        parameters = function["parameters"]
        if len(parameters) == len(labels) and all(parameter["label"] == label for parameter, label in zip(parameters, labels)):
            result.append(parameters[index]["type"])
    if not functions and any(declaration["name"] == name and declaration["kind"] == "struct" for declaration in facts["declarations"]):
        result += [variable["type"] for variable in facts["typedVariables"] if variable["name"] == labels[index]
            and variable["scope"] and variable["scope"][-1] == name and not variable["lexicalScope"]]
    return result


def canonical_type_scope(names: list[str]) -> tuple[str, ...]:
    return tuple(part for name in names for part in re.sub(r"\s+", "", name).split("."))


def declaration_conformances(index: dict[str, dict]) -> dict[tuple[str, ...], set[str]]:
    result: dict[tuple[str, ...], set[str]] = {}
    for facts in index.values():
        for declaration in facts.get("declarations", []):
            owner = canonical_type_scope(declaration.get("scope", []) + [declaration["name"]])
            result.setdefault(owner, set()).update(re.sub(r"\s+", "", base) for base in declaration.get("inheritedTypes", []))
        for alias in facts.get("typeAliases", []):
            owner = canonical_type_scope(alias["scope"] + [alias["name"]])
            result.setdefault(owner, set()).add(re.sub(r"\s+", "", alias["type"]))
    while True:
        changed = False
        for owner, bases in result.items():
            inherited = set(bases)
            for base in bases:
                key = canonical_type_scope([base])
                parent = next((result[owner[:depth] + key] for depth in range(len(owner) - 1, -1, -1)
                               if owner[:depth] + key in result), set())
                inherited.update(parent)
            if inherited != bases:
                result[owner] = inherited
                changed = True
        if not changed: return result


def scope_contains_type(scope: list[str], owners) -> bool:
    parts = canonical_type_scope(scope)
    return any(parts[:len(owner)] == owner for owner in owners)


def resource_context_type(value: str, resource: str = "UserDefaults") -> bool:
    value = re.sub(r"\s+|@(?:Sendable|MainActor)\b", "", value).rstrip("?!").removeprefix("Swift.")
    for wrapper in ("Optional", "Array"):
        if value.startswith(wrapper + "<") and value.endswith(">"):
            return resource_context_type(value[len(wrapper) + 1:-1], resource)
    if value.startswith("[") and value.endswith("]"):
        return resource_context_type(value[1:-1].rsplit(":", 1)[-1], resource)
    if value.startswith("Dictionary<") and value.endswith(">"):
        return resource_context_type(value[len("Dictionary<"):-1].rsplit(",", 1)[-1], resource)
    if "->" in value: return resource_context_type(value.rsplit("->", 1)[-1].strip("()"), resource)
    return value.removeprefix("Foundation.").removeprefix("StorageCore.") == resource


def visible_variables(facts: dict, reference: dict, name: str, explicit_self: bool = False) -> list[dict]:
    lexical = reference.get("lexicalScope", [])
    candidates = [variable for variable in facts["typedVariables"] if variable["name"] == name
        and canonical_type_scope(reference["scope"])[:len(canonical_type_scope(variable["scope"]))] == canonical_type_scope(variable["scope"])
        and lexical[:len(variable.get("lexicalScope", []))] == variable.get("lexicalScope", [])
        and (not variable.get("lexicalScope") or variable.get("start", 0) <= reference["start"])
        and not (explicit_self and any(function["scope"] == variable["scope"]
            and function["start"] <= variable.get("start", 0) < function["end"] for function in facts["functionRanges"]))]
    return sorted(candidates, key=lambda variable: (len(variable["scope"]), len(variable.get("lexicalScope", [])), variable.get("start", 0)))


def matching_functions(facts: dict, name: str, call: dict) -> list[dict]:
    def matches(parameters: list[dict], labels: list[str]) -> bool:
        if not parameters: return not labels
        parameter, remaining = parameters[0], parameters[1:]
        if parameter["hasDefault"] and matches(remaining, labels): return True
        if parameter["variadic"]:
            return any(matches(remaining, labels[count:]) for count in range(len(labels) + 1)
                if all(label == (parameter["label"] if index == 0 else "") for index, label in enumerate(labels[:count])))
        return bool(labels) and labels[0] == parameter["label"] and matches(remaining, labels[1:])
    return [function for function in facts["functionRanges"] if function["name"] == name
        and call["scope"][:len(function["scope"])] == function["scope"]
        and call.get("lexicalScope", [])[:len(function["lexicalScope"])] == function["lexicalScope"]
        and matches(function["parameters"], call.get("argumentLabels", []))]


def compilation_type_context(index: dict) -> tuple:
    owners = declaration_conformances(index)
    properties = {(canonical_type_scope(value["scope"]), value["name"], value["type"])
        for facts in index.values() for value in facts["typedVariables"]
        if not value.get("lexicalScope") and canonical_type_scope(value["scope"]) in owners}
    methods = {(canonical_type_scope(value["scope"]), value["name"])
        for facts in index.values() for value in facts["functionRanges"]
        if not value.get("lexicalScope") and canonical_type_scope(value["scope"]) in owners}
    for owner, bases in owners.items():
        for base in bases:
            target = next((owner[:depth] + canonical_type_scope([base]) for depth in range(len(owner) - 1, -1, -1)
                if owner[:depth] + canonical_type_scope([base]) in owners), ())
            properties.update((owner, name, kind) for scope, name, kind in list(properties) if scope == target)
            methods.update((owner, name) for scope, name in list(methods) if scope == target)
    return tuple(sorted(properties)), tuple(sorted(methods))


def local_member_calls(source: str, names: tuple, context: tuple = ((), ())) -> set[int]:
    facts = swift_syntax_index_sources({"local-methods": source})["local-methods"]
    own_context = compilation_type_context({"local-methods": facts})
    methods = set(context[1]) | set(own_context[1])
    properties = set(context[0]) | set(own_context[0])
    result = set()
    for call in facts["invocations"]:
        match = re.match(r"(.+?)(\.\s*`?(" + "|".join(names) + r")`?\s*\()", call["value"], re.DOTALL)
        if not match: continue
        receiver = re.sub(r"^(?:try[!?]?\s+|await\s+)+", "", match[1].strip()).rstrip("?!")
        owner = canonical_type_scope(call["scope"])
        kind = None
        if receiver == "self": kind = ".".join(owner)
        elif constructor := re.fullmatch(r"([\w.]+)\s*\(.*\)", receiver, re.DOTALL): kind = constructor[1]
        elif variable := re.fullmatch(r"(?:self\.)?(\w+)", receiver):
            visible = visible_variables(facts, call, variable[1], receiver.startswith("self."))
            if visible: kind = visible[-1]["type"]
            if kind is None:
                for binding in facts["bindings"]:
                    value = re.match(re.escape(variable[1]) + r"\s*=\s*([\w.]+)\s*\(", binding["value"])
                    if value and binding["start"] < call["start"] and binding["scope"] == call["scope"] \
                        and call.get("lexicalScope", [])[:len(binding.get("lexicalScope", []))] == binding.get("lexicalScope", []): kind = value[1]
            if kind is None: kind = next((kind for scope, name, kind in properties if scope == owner and name == variable[1]), None)
        if kind is None: continue
        kind = canonical_type_scope([kind.rstrip("?!")])
        if any((owner[:depth] + kind, match[3]) in methods for depth in range(len(owner), -1, -1)):
            result.add(call["start"] + len(call["value"][:match.start(2)].encode()))
    return result
