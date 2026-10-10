import Foundation

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
    var iterationSource: String? = nil
    var thenRange: [Int]? = nil
    var elseRange: [Int]? = nil
    var arguments: [String]? = nil
    var argumentTypes: [String?]? = nil
    var argumentRanges: [[Int]]? = nil
    var isTestingTest: Bool? = nil
    var receiverCall: String? = nil
    var closureArguments: [[Int]]? = nil
    var trailingClosureLabels: [String]? = nil
    var calledExpression: String? = nil
    var bindingName: String? = nil
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
    var isAccessor: Bool = false
    var bodyStart: Int? = nil
    var isExported: Bool = false
    var isPrivate: Bool = false
    var isAsync: Bool = false
    var isThrowing: Bool = false
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
