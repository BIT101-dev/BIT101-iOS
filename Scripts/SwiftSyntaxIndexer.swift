import Foundation
import SwiftSyntax
import SwiftParser

struct FileFacts: Encodable {
    let hasParseErrors: Bool
    let imports: [String]
    let identifiers: [String]
    let scopedIdentifiers: [ScopedFact]
    let stringSegments: [ScopedFact]
    let regexRanges: [ScopedRangeFact]
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
    let accessibilityControlCandidates: [AccessibilityControlFact]
    let functionRanges: [FunctionRangeFact]
    let accessorRanges: [FunctionRangeFact]
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
    let isFilePrivate: Bool
    let isExported: Bool
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
    var condition: String? = nil
    var iterationSource: String? = nil
    var thenRange: [Int]? = nil
    var elseRange: [Int]? = nil
    var arguments: [String]? = nil
    var argumentRanges: [[Int]]? = nil
    var isTestingTest: Bool? = nil
    var receiverCall: String? = nil
    var closureArguments: [[Int]]? = nil
    var calledExpression: String? = nil
    var bindingName: String? = nil
    var bindingType: String? = nil
    var initializerCall: String? = nil
    var initializerReference: String? = nil
    var booleanValue: Bool? = nil
    var deadRange: [Int]? = nil
    var isExpressionReference: Bool = false
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
    let carrierInvocation: String
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
    var escapingParameters: [Int] = []
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
    var isExplicitInitializer: Bool = false
    var bodyStart: Int? = nil
    var isExported: Bool = false
    var isPrivate: Bool = false
    var isAsync: Bool = false
    var referenceTarget: String? = nil
    var returnedCall: String? = nil
}

struct FunctionParameterFact: Encodable {
    let label: String
    let type: String
    let hasDefault: Bool
    let variadic: Bool
    var name: String = ""
}

struct FunctionReturnFact: Encodable {
    let name: String
    let scope: [String]
    let value: String
    let start: Int
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
    private(set) var regexRanges: [ScopedRangeFact] = []
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
    private(set) var accessibilityControlCandidates: [AccessibilityControlFact] = []
    private(set) var functionRanges: [FunctionRangeFact] = []
    private(set) var accessorRanges: [FunctionRangeFact] = []
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

    private(set) var imports: [String] = []
    override func visit(_ node: RegexLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        regexRanges.append(ScopedRangeFact(scope: scope,
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
            end: node.endPositionBeforeTrailingTrivia.utf8Offset))
        return .skipChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let module = node.path.first?.name.text { imports.append(module) }
        return .skipChildren
    }

    private func enter(_ kind: String, _ name: String, _ inherited: [String], _ modifiers: DeclModifierListSyntax) -> SyntaxVisitorContinueKind {
        declarations.append(DeclarationFact(kind: kind, name: name, inheritedTypes: inherited, scope: scope,
            isFilePrivate: modifiers.contains { ["private", "fileprivate"].contains($0.name.text) },
            isExported: modifiers.contains { ["public", "package", "open"].contains($0.name.text) }))
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
    private func escapingParameters(_ type: TypeSyntax) -> [Int] {
        if let attributed = type.as(AttributedTypeSyntax.self) { return escapingParameters(attributed.baseType) }
        guard let function = type.as(FunctionTypeSyntax.self) else { return [] }
        return function.parameters.enumerated().compactMap { index, parameter in
            parameter.type.as(AttributedTypeSyntax.self)?.attributes.contains(where: {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "escaping"
            }) == true ? index : nil
        }
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
        enter("struct", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [], node.modifiers)
    }
    override func visitPost(_ node: StructDeclSyntax) { leave() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("protocol", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [], node.modifiers)
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { leave() }

    private func declarationIsExported(_ modifiers: DeclModifierListSyntax, parent: Syntax?) -> Bool {
        let access = Set(["public", "package", "open", "internal", "fileprivate", "private"])
        let exported = Set(["public", "package", "open"])
        if let modifier = modifiers.first(where: { access.contains($0.name.text) }) {
            return exported.contains(modifier.name.text)
        }
        var parent = parent
        while let ancestor = parent {
            if let extensionNode = ancestor.as(ExtensionDeclSyntax.self) {
                return extensionNode.modifiers.contains { exported.contains($0.name.text) }
            }
            if ancestor.is(DeclSyntax.self) { return false }
            parent = ancestor.parent
        }
        return false
    }

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
                    hasDefault: $0.defaultValue != nil, variadic: $0.ellipsis != nil, name: ($0.secondName ?? $0.firstName).text)
            }, bodyStart: node.body?.positionAfterSkippingLeadingTrivia.utf8Offset,
            isExported: declarationIsExported(node.modifiers, parent: node.parent),
            isPrivate: node.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) },
            isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil, returnedCall: returnedCall(node.body?.statements)
        ))
        functionStack.append((node.name.text, scope, closureDepth))
        if let body = node.body, body.statements.count == 1,
           let expression = body.statements.first?.item.as(ExprSyntax.self) {
            functionReturns.append(FunctionReturnFact(name: node.name.text, scope: scope,
                value: expression.trimmedDescription, start: expression.positionAfterSkippingLeadingTrivia.utf8Offset))
        }
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { _ = functionStack.popLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        recordParameters(node.signature.parameterClause.parameters, body: node.body)
        initializers.append(FunctionRangeFact(name: "init", returnType: nil, returnsView: false, scope: scope,
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset, end: node.endPositionBeforeTrailingTrivia.utf8Offset,
            lexicalScope: lexicalScope, parameters: node.signature.parameterClause.parameters.map {
                FunctionParameterFact(label: $0.firstName.text == "_" ? "" : $0.firstName.text, type: $0.type.trimmedDescription,
                    hasDefault: $0.defaultValue != nil, variadic: $0.ellipsis != nil, name: ($0.secondName ?? $0.firstName).text)
            }, isExplicitInitializer: true, bodyStart: node.body?.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closureDepth += 1
        lexicalScope.append(node.positionAfterSkippingLeadingTrivia.utf8Offset)
        switch node.signature?.parameterClause {
        case .simpleInput(let parameters):
            for parameter in parameters where parameter.name.text != "_" {
                typedVariables.append(TypedVariableFact(name: parameter.name.text, type: "", scope: scope,
                    start: parameter.positionAfterSkippingLeadingTrivia.utf8Offset, lexicalScope: lexicalScope))
            }
        case .parameterClause(let clause):
            for parameter in clause.parameters {
                let name = parameter.secondName ?? parameter.firstName
                guard name.text != "_" else { continue }
                typedVariables.append(TypedVariableFact(name: name.text, type: parameter.type?.trimmedDescription ?? "", scope: scope,
                    start: parameter.positionAfterSkippingLeadingTrivia.utf8Offset, lexicalScope: lexicalScope))
            }
        case nil: break
        @unknown default: break
        }
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
            isExported: node.modifiers.contains { ["public", "package"].contains($0.name.text) },
            escapingParameters: escapingParameters(node.initializer.value)))
        return .visitChildren
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        recordTermination(Syntax(node))
        if let function = functionStack.last,
           closureDepth == function.closureDepth,
           let expression = node.expression
        {
            functionReturns.append(FunctionReturnFact(
                name: function.name,
                scope: function.scope,
                value: expression.trimmedDescription,
                start: expression.positionAfterSkippingLeadingTrivia.utf8Offset
            ))
        }
        return .visitChildren
    }

    private func recordTermination(_ node: Syntax) {
        guard let list = node.parent?.parent?.as(CodeBlockItemListSyntax.self) else { return }
        var item = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        item.deadRange = [node.endPositionBeforeTrailingTrivia.utf8Offset, list.endPositionBeforeTrailingTrivia.utf8Offset]
        controlFlow.append(item)
    }

    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
        recordTermination(Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
        recordTermination(Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
        recordTermination(Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("class", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [], node.modifiers)
    }
    override func visitPost(_ node: ClassDeclSyntax) { leave() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("enum", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [], node.modifiers)
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            enumCases.append(EnumCaseFact(name: element.name.text, rawValue: element.rawValue?.value.trimmedDescription, scope: scope))
        }
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { leave() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("actor", node.name.text, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [], node.modifiers)
    }
    override func visitPost(_ node: ActorDeclSyntax) { leave() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter("extension", node.extendedType.trimmedDescription, node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? [], node.modifiers)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { leave() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledExpression = node.calledExpression.tokens(viewMode: .sourceAccurate).map(\.text).joined()
        var call = fact(calledExpression, start: node.calledExpression.positionAfterSkippingLeadingTrivia.utf8Offset)
        call.receiverCall = node.calledExpression.as(MemberAccessExprSyntax.self)?.base?
            .as(FunctionCallExprSyntax.self)?.calledExpression.trimmedDescription
        calls.append(call)
        var invocation = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        invocation.calledExpression = calledExpression
        invocation.receiverCall = call.receiverCall
        invocation.argumentLabels = node.arguments.map { $0.label?.text ?? "" }
        invocation.arguments = node.arguments.map { $0.expression.trimmedDescription }
        invocation.argumentRanges = node.arguments.map {
            [$0.expression.positionAfterSkippingLeadingTrivia.utf8Offset, $0.expression.endPositionBeforeTrailingTrivia.utf8Offset]
        }
        invocation.closureArguments = node.arguments.enumerated().compactMap { index, argument in
            guard let closure = argument.expression.as(ClosureExprSyntax.self) else { return nil }
            return [index, closure.positionAfterSkippingLeadingTrivia.utf8Offset, closure.endPositionBeforeTrailingTrivia.utf8Offset]
        }
        if let closure = node.trailingClosure {
            invocation.closureArguments?.append([node.arguments.count, closure.positionAfterSkippingLeadingTrivia.utf8Offset,
                closure.endPositionBeforeTrailingTrivia.utf8Offset])
        }
        for (index, argument) in node.additionalTrailingClosures.enumerated() {
            invocation.closureArguments?.append([node.arguments.count + index + 1,
                argument.closure.positionAfterSkippingLeadingTrivia.utf8Offset, argument.closure.endPositionBeforeTrailingTrivia.utf8Offset])
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
        let interactionNames = ["Button", "NavigationLink", "Menu", "Picker", "Toggle", "DatePicker", "Link", "PhotosPicker", "LabeledContent", "TextField", "SecureField", "TextEditor", "Slider", "Stepper", "ScrollView", "List", "TabView", "ShareLink", "refreshable", "onSubmit", "onDelete", "onMove", "searchable", "contextMenu", "swipeActions", "onTapGesture", "onLongPressGesture", "gesture", "simultaneousGesture", "highPriorityGesture", "accessibilityAction", "keyboardShortcut"]
        if (interactionNames.contains(calledName)
            || node.calledExpression.is(DeclReferenceExprSyntax.self) || calledName == "init" || calledName.first?.isUppercase == true)
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
                    return interactionNames.contains(calledName) ? nil : trailingClosure
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
            var carrier = node
            if ["accessibilityAction", "keyboardShortcut"].contains(calledName) {
                while let member = carrier.calledExpression.as(MemberAccessExprSyntax.self),
                      let base = member.base?.as(FunctionCallExprSyntax.self) {
                    carrier = base
                    if let modifier = base.calledExpression.as(MemberAccessExprSyntax.self) {
                        modifiers.insert("." + modifier.declName.baseName.text + "(" + base.arguments.trimmedDescription + ")", at: 0)
                    }
                }
            }
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
            let control = AccessibilityControlFact(
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
                callback: node.trailingClosure?.trimmedDescription ?? "",
                carrierInvocation: carrier.trimmedDescription
            )
            if interactionNames.contains(calledName) { accessibilityControls.append(control) }
            else { accessibilityControlCandidates.append(control) }

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
            var reference = fact(value, start: token.positionAfterSkippingLeadingTrivia.utf8Offset)
            reference.isExpressionReference = token.parent?.is(DeclReferenceExprSyntax.self) == true
            scopedIdentifiers.append(reference)
        case .stringSegment(let value):
            stringSegments.append(fact(value, start: token.positionAfterSkippingLeadingTrivia.utf8Offset))
        default:
            break
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        var member = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        member.receiverCall = node.base?.as(FunctionCallExprSyntax.self)?.calledExpression.trimmedDescription
        members.append(member)
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
        var loop = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        loop.iterationSource = node.sequence.trimmedDescription
        loop.thenRange = [node.body.positionAfterSkippingLeadingTrivia.utf8Offset, node.body.endPosition.utf8Offset]
        controlFlow.append(loop)
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        expressions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    private func functionReference(_ value: ExprSyntax?) -> String? {
        guard let value, value.is(MemberAccessExprSyntax.self) || value.is(DeclReferenceExprSyntax.self) else { return nil }
        return value.tokens(viewMode: .sourceAccurate).map(\.text).joined()
    }

    private func returnedCall(_ statements: CodeBlockItemListSyntax?) -> String? {
        guard let statements, statements.count == 1, let item = statements.first?.item else { return nil }
        let expression = item.as(ExprSyntax.self) ?? item.as(ReturnStmtSyntax.self)?.expression
        return expression?.as(FunctionCallExprSyntax.self)?.calledExpression.tokens(viewMode: .sourceAccurate).map(\.text).joined()
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        expressions.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        let parts = Array(node.elements)
        if parts.count == 3, parts[1].is(AssignmentExprSyntax.self),
           parts[2].is(ClosureExprSyntax.self) || parts[2].is(MemberAccessExprSyntax.self) || parts[2].is(DeclReferenceExprSyntax.self),
           let name = parts[0].as(DeclReferenceExprSyntax.self)?.baseName.text ?? parts[0].as(MemberAccessExprSyntax.self)?.declName.baseName.text {
            callableRanges.append(FunctionRangeFact(name: name, returnType: nil, returnsView: false, scope: scope,
                start: parts[2].positionAfterSkippingLeadingTrivia.utf8Offset, end: parts[2].endPositionBeforeTrailingTrivia.utf8Offset,
                lexicalScope: lexicalScope, parameters: [], referenceTarget: functionReference(parts[2])))
        }
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let declaration = node.parent?.parent?.as(VariableDeclSyntax.self), let block = node.accessorBlock {
            let modifiers = declaration.modifiers
            func recordGetter(_ body: some SyntaxProtocol, isAsync: Bool, statements: CodeBlockItemListSyntax?) {
                accessorRanges.append(FunctionRangeFact(name: name, returnType: node.typeAnnotation?.type.trimmedDescription,
                    returnsView: false, scope: scope, start: body.positionAfterSkippingLeadingTrivia.utf8Offset,
                    end: body.endPositionBeforeTrailingTrivia.utf8Offset, lexicalScope: lexicalScope, parameters: [],
                    bodyStart: body.positionAfterSkippingLeadingTrivia.utf8Offset,
                    isExported: declarationIsExported(modifiers, parent: declaration.parent),
                    isPrivate: modifiers.contains { ["private", "fileprivate"].contains($0.name.text) },
                    isAsync: isAsync, returnedCall: returnedCall(statements)))
            }
            if case .getter(let statements) = block.accessors {
                recordGetter(block, isAsync: false, statements: statements)
            } else if case .accessors(let accessors) = block.accessors {
                for accessor in accessors where accessor.accessorSpecifier.text == "get" && accessor.body != nil {
                    recordGetter(accessor, isAsync: accessor.effectSpecifiers?.asyncSpecifier != nil, statements: accessor.body?.statements)
                }
            }
        }
        var binding = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        binding.bindingName = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        binding.bindingType = node.typeAnnotation?.type.trimmedDescription
        binding.initializerCall = node.initializer?.value.as(FunctionCallExprSyntax.self)?.calledExpression.tokens(viewMode: .sourceAccurate).map(\.text).joined()
        binding.initializerReference = functionReference(node.initializer?.value)
        if node.parent?.parent?.as(VariableDeclSyntax.self)?.bindingSpecifier.text == "let",
           let literal = node.initializer?.value.as(BooleanLiteralExprSyntax.self) {
            binding.booleanValue = literal.literal.text == "true"
        }
        bindings.append(binding)
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
                end: node.endPositionBeforeTrailingTrivia.utf8Offset, lexicalScope: lexicalScope, parameters: [],
                referenceTarget: functionReference(node.initializer?.value),
                returnedCall: returnedCall(node.initializer?.value.as(ClosureExprSyntax.self)?.statements)))
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
        var binding = fact(node.pattern.trimmedDescription + (node.initializer.map { " " + $0.trimmedDescription } ?? ""),
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        binding.bindingName = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        binding.bindingType = node.typeAnnotation?.type.trimmedDescription
        binding.initializerCall = node.initializer?.value.as(FunctionCallExprSyntax.self)?.calledExpression.tokens(viewMode: .sourceAccurate).map(\.text).joined()
        binding.initializerReference = functionReference(node.initializer?.value)
        bindings.append(binding)
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self), let type = node.typeAnnotation?.type {
            typedVariables.append(TypedVariableFact(name: pattern.identifier.text, type: type.trimmedDescription,
                scope: scope, start: node.positionAfterSkippingLeadingTrivia.utf8Offset, lexicalScope: lexicalScope))
        }
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        var item = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        item.condition = node.conditions.trimmedDescription
        item.thenRange = [node.body.positionAfterSkippingLeadingTrivia.utf8Offset, node.body.endPositionBeforeTrailingTrivia.utf8Offset]
        if let alternative = node.elseBody {
            item.elseRange = [alternative.positionAfterSkippingLeadingTrivia.utf8Offset, alternative.endPositionBeforeTrailingTrivia.utf8Offset]
        }
        controlFlow.append(item)
        return .visitChildren
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        controlFlow.append(fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset))
        return .visitChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        var item = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        item.condition = node.conditions.trimmedDescription
        item.thenRange = [node.body.positionAfterSkippingLeadingTrivia.utf8Offset, node.body.endPositionBeforeTrailingTrivia.utf8Offset]
        controlFlow.append(item)
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        var item = fact(node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        item.condition = node.conditions.trimmedDescription
        item.elseRange = [node.body.positionAfterSkippingLeadingTrivia.utf8Offset, node.body.endPositionBeforeTrailingTrivia.utf8Offset]
        controlFlow.append(item)
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
        imports: visitor.imports,
        identifiers: identifiers,
        scopedIdentifiers: visitor.scopedIdentifiers,
        stringSegments: visitor.stringSegments,
        regexRanges: visitor.regexRanges,
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
        accessibilityControlCandidates: visitor.accessibilityControlCandidates,
        functionRanges: visitor.functionRanges,
        accessorRanges: visitor.accessorRanges,
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
