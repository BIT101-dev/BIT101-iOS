import Foundation
import SwiftSyntax
import SwiftParser
import SwiftOperators

func unwrappedExpression(_ value: ExprSyntax?) -> ExprSyntax? {
    var expression = value
    while let tuple = expression?.as(TupleExprSyntax.self), tuple.elements.count == 1,
          let element = tuple.elements.first, element.label == nil { expression = element.expression }
    return expression
}

func selectorReference(_ expression: ExprSyntax?) -> String? {
    let value = unwrappedExpression(expression)
    if let macro = value?.as(MacroExpansionExprSyntax.self), macro.macroName.text == "selector" {
        return macro.arguments.first?.expression.trimmedDescription
    }
    guard let call = value?.as(FunctionCallExprSyntax.self), call.arguments.count == 1,
          ["Selector", "Foundation.Selector", "NSSelectorFromString", "Foundation.NSSelectorFromString"]
            .contains(call.calledExpression.trimmedDescription) else { return nil }
    return unwrappedExpression(call.arguments.first?.expression)?.as(StringLiteralExprSyntax.self)?.representedLiteralValue
}

func collectionElementCount(_ value: ExprSyntax?) -> Int? {
    guard let expression = unwrappedExpression(value) else { return nil }
    if let array = expression.as(ArrayExprSyntax.self) { return array.elements.count }
    guard let call = expression.as(FunctionCallExprSyntax.self), call.trailingClosure == nil,
          call.additionalTrailingClosures.isEmpty else { return nil }
    let name = call.calledExpression.trimmedDescription
    if call.arguments.isEmpty,
       name.hasPrefix("[") && name.hasSuffix("]") || name.hasPrefix("Array<") || name.hasPrefix("Swift.Array<") {
        return 0
    }
    guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
          let count = collectionElementCount(member.base), call.arguments.count <= 1 else { return nil }
    let method = member.declName.baseName.text
    let amount: Int
    if let argument = call.arguments.first {
        guard argument.label == nil,
              let literal = unwrappedExpression(argument.expression)?.as(IntegerLiteralExprSyntax.self),
              let value = Int(literal.literal.text.replacingOccurrences(of: "_", with: "")), value >= 0 else { return nil }
        amount = value
    } else {
        guard ["dropFirst", "dropLast"].contains(method) else { return nil }
        amount = 1
    }
    if ["prefix", "suffix"].contains(method) { return min(count, amount) }
    if ["dropFirst", "dropLast"].contains(method) { return max(0, count - amount) }
    return nil
}

func iterationBounds(_ expression: ExprSyntax) -> [String]? {
    guard let folded = try? OperatorTable.standardOperators.foldAll(expression),
          let infix = unwrappedExpression(folded.as(ExprSyntax.self))?.as(InfixOperatorExprSyntax.self),
          ["..<", "..."].contains(infix.operator.trimmedDescription) else { return nil }
    return [infix.leftOperand.trimmedDescription, infix.operator.trimmedDescription, infix.rightOperand.trimmedDescription]
}

func enclosingExpression(_ node: Syntax) -> Syntax {
    var expression = node
    while let element = expression.parent?.as(LabeledExprSyntax.self),
          let tuple = element.parent?.parent?.as(TupleExprSyntax.self), tuple.elements.count == 1,
          element.label == nil { expression = Syntax(tuple) }
    return expression
}

func discardsExpression(_ node: Syntax) -> Bool {
    let expression = enclosingExpression(node)
    return expression.parent?.is(CodeBlockItemSyntax.self) == true
        || expression.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self)?.pattern.is(WildcardPatternSyntax.self) == true
        || expression.parent?.trimmedDescription.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).hasPrefix("_=") == true
}

final class DiscardedValueVisitor: SyntaxVisitor {
    let name: String
    let after: AbsolutePosition
    var consumed = false
    init(name: String, after: AbsolutePosition) { self.name = name; self.after = after; super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let statements = enclosingExpression(Syntax(node)).parent?.parent?.as(CodeBlockItemListSyntax.self)
        let implicitReturn = statements?.count == 1 && statements?.parent?.is(ClosureExprSyntax.self) == true
        if node.positionAfterSkippingLeadingTrivia >= after && node.baseName.text == name
            && (!discardsExpression(Syntax(node)) || implicitReturn) { consumed = true }
        return .visitChildren
    }
}

func discardsOptionalTry(_ node: TryExprSyntax) -> Bool {
    guard node.questionOrExclamationMark?.text == "?" else { return false }
    if discardsExpression(Syntax(node)) { return true }
    guard let binding = enclosingExpression(Syntax(node)).parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
          let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
          let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self),
          let statements = declaration.parent?.parent?.as(CodeBlockItemListSyntax.self) else { return false }
    let visitor = DiscardedValueVisitor(name: name, after: binding.endPositionBeforeTrailingTrivia)
    for statement in statements where statement.endPositionBeforeTrailingTrivia > binding.endPositionBeforeTrailingTrivia {
        visitor.walk(statement)
    }
    return !visitor.consumed
}

func discardsCaughtError(_ node: CatchClauseSyntax) -> Bool {
    let names = Set(["error"] + node.catchItems.compactMap { item in
        (item.pattern?.as(ValueBindingPatternSyntax.self)?.pattern ?? item.pattern)?.as(IdentifierPatternSyntax.self)?.identifier.text
    })
    func caughtReference(_ value: ExprSyntax?) -> Bool {
        unwrappedExpression(value)?.as(DeclReferenceExprSyntax.self).map { names.contains($0.baseName.text) } ?? false
    }
    return node.body.statements.allSatisfy { statement in
        if let sequence = statement.item.as(SequenceExprSyntax.self) {
            let parts = Array(sequence.elements)
            return parts.count == 3 && parts[0].is(DiscardAssignmentExprSyntax.self)
                && parts[1].is(AssignmentExprSyntax.self) && caughtReference(parts[2])
        }
        if let declaration = statement.item.as(VariableDeclSyntax.self) {
            return !declaration.bindings.isEmpty && declaration.bindings.allSatisfy {
                $0.pattern.is(WildcardPatternSyntax.self) && caughtReference($0.initializer?.value)
            }
        }
        return false
    }
}

struct SourceInput: Decodable { let name: String; let source: String }
struct Input: Decodable { let paths: [String]; let sources: [SourceInput]?; let interactionNames: [String] }

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
    let genericConstraints: [GenericConstraintFact]
    let listIcons: [ListIconFact]
    let listControls: [SelectionControlFact]
    let listStyleModifiers: [FeedbackModifierFact]
    let accessibilityModifiers: [FeedbackModifierFact]
    let accessibilityControls: [AccessibilityControlFact]
    let accessibilityControlCandidates: [AccessibilityControlFact]
    let functionRanges: [FunctionRangeFact]
    let accessorRanges: [FunctionRangeFact]
    let callableRanges: [FunctionRangeFact]
    let inlineClosureRanges: [FunctionRangeFact]
    let initializers: [FunctionRangeFact]
    let nonRenderedRanges: [ScopedRangeFact]
    let lifecycleRanges: [ScopedRangeFact]
    let members: [ScopedFact]
    let forceUnwraps: [ScopedFact]
    let emptyCatchClauses: [ScopedFact]
    let discardedOptionalTries: [ScopedFact]
    let expressions: [ScopedFact]
    let bindings: [ScopedFact]
    let controlFlow: [ScopedFact]
    let expressionFlow: [ScopedFact]
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
    var conditionElements: [String]? = nil
    var iterationSource: String? = nil
    var iterationSourceRange: [Int]? = nil
    var iterationBounds: [String]? = nil
    var collectionElementCount: Int? = nil
    var thenRange: [Int]? = nil
    var elseRange: [Int]? = nil
    var arguments: [String]? = nil
    var argumentTypes: [String?]? = nil
    var selectorArguments: [String?]? = nil
    var selectorTarget: String? = nil
    var expectedType: String? = nil
    var argumentRanges: [[Int]]? = nil
    var isTestingTest: Bool? = nil
    var testCaseCount: Int? = nil
    var receiverCall: String? = nil
    var receiverElementCount: Int? = nil
    var closureArguments: [[Int]]? = nil
    var trailingClosureLabels: [String]? = nil
    var calledExpression: String? = nil
    var bindingName: String? = nil
    var isStaticBinding: Bool? = nil
    var visibilityRange: [Int]? = nil
    var bindingType: String? = nil
    var initializerCall: String? = nil
    var initializerReference: String? = nil
    var constantInitializer: String? = nil
    var deadRange: [Int]? = nil
    var followingRange: [Int]? = nil
    var branchRanges: [[Int]]? = nil
    var switchSubject: String? = nil
    var switchCases: [SwitchCaseFact]? = nil
    var isExpressionReference: Bool = false
    var isAssignmentTarget: Bool = false
}

struct SwitchCaseFact: Encodable {
    let isDefault: Bool
    let patterns: [SwitchPatternFact]
}

struct SwitchPatternFact: Encodable {
    let value: String
    let condition: String?
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
    var isTaskLocal: Bool = false
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

struct GenericConstraintFact: Encodable {
    let name: String
    let type: String
    let scope: [String]
    let start: Int
    let end: Int
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
    var isDeinitializer: Bool = false
    var isAccessor: Bool = false
    var bodyStart: Int? = nil
    var isExported: Bool = false
    var isPrivate: Bool = false
    var isAsync: Bool = false
    var isStatic: Bool = false
    var isThrowing: Bool = false
    var referenceTarget: String? = nil
    var isPropertyAssignment: Bool = false
    var isAssignment: Bool = false
    var isUnqualifiedAssignment: Bool = false
    var returnedCall: String? = nil
}

func deinitializerRange(_ node: DeinitializerDeclSyntax, scope: [String], lexicalScope: [Int]) -> FunctionRangeFact {
    FunctionRangeFact(name: "deinit", returnType: nil, returnsView: false, scope: scope,
        start: node.positionAfterSkippingLeadingTrivia.utf8Offset, end: node.endPositionBeforeTrailingTrivia.utf8Offset,
        lexicalScope: lexicalScope, parameters: [], isDeinitializer: true,
        bodyStart: node.body?.positionAfterSkippingLeadingTrivia.utf8Offset)
}

struct FunctionParameterFact: Encodable {
    let label: String
    let type: String
    let hasDefault: Bool
    let variadic: Bool
    var name: String = ""
    var defaultExpressionRange: [Int]? = nil
}

func functionParameterFact(_ node: FunctionParameterSyntax) -> FunctionParameterFact {
    FunctionParameterFact(label: node.firstName.text == "_" ? "" : node.firstName.text,
        type: node.type.trimmedDescription, hasDefault: node.defaultValue != nil,
        variadic: node.ellipsis != nil, name: (node.secondName ?? node.firstName).text,
        defaultExpressionRange: node.defaultValue.map {
            [$0.value.positionAfterSkippingLeadingTrivia.utf8Offset, $0.value.endPositionBeforeTrailingTrivia.utf8Offset]
        })
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

final class ExpressionFlowVisitor: SyntaxVisitor {
    let record: (String, ExprSyntax, ExprSyntax?, ExprSyntax?) -> Void
    init(record: @escaping (String, ExprSyntax, ExprSyntax?, ExprSyntax?) -> Void) {
        self.record = record
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let operation = node.operator.trimmedDescription
        if operation == "&&" { record(operation, node.leftOperand, node.rightOperand, nil) }
        if operation == "||" { record(operation, node.leftOperand, nil, node.rightOperand) }
        return .visitChildren
    }
    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        record("?:", node.condition, node.thenExpression, node.elseExpression)
        return .visitChildren
    }
}

func functionType(in type: TypeSyntax?) -> FunctionTypeSyntax? {
    guard let type else { return nil }
    if let function = type.as(FunctionTypeSyntax.self) { return function }
    if let optional = type.as(OptionalTypeSyntax.self) { return functionType(in: optional.wrappedType) }
    if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return functionType(in: optional.wrappedType) }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1 {
        return functionType(in: tuple.elements.first?.type)
    }
    return nil
}
