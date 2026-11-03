import SwiftSyntax

struct StyleFact: Encodable {
    let start: Int
    let depth: Int
}

struct LiteralPartFact: Encodable {
    let start: Int
    let end: Int
    let isExpression: Bool
}

struct LiteralFact: Encodable {
    let start: Int
    let end: Int
    let pounds: String
    let quote: String
    let value: String?
    let parts: [LiteralPartFact]
}

final class StyleVisitor: SyntaxAnyVisitor {
    private(set) var nesting: [StyleFact] = []
    private(set) var literals: [LiteralFact] = []
    private var levels = [0]

    private func isRoot(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self)
            || node.is(InitializerDeclSyntax.self)
            || node.is(DeinitializerDeclSyntax.self)
            || node.is(AccessorBlockSyntax.self)
            || node.is(AccessorDeclSyntax.self)
            || node.is(SubscriptDeclSyntax.self)
            || node.is(StructDeclSyntax.self)
            || node.is(ClassDeclSyntax.self)
            || node.is(EnumDeclSyntax.self)
            || node.is(ActorDeclSyntax.self)
    }

    private func isLevel(_ node: Syntax) -> Bool {
        if node.is(IfExprSyntax.self), node.parent?.is(IfExprSyntax.self) == true {
            return false
        }
        return node.is(IfExprSyntax.self)
            || node.is(GuardStmtSyntax.self)
            || node.is(ForStmtSyntax.self)
            || node.is(WhileStmtSyntax.self)
            || node.is(RepeatStmtSyntax.self)
            || node.is(SwitchExprSyntax.self)
            || node.is(DoStmtSyntax.self)
            || node.is(DeferStmtSyntax.self)
            || node.is(ClosureExprSyntax.self)
            || node.is(TernaryExprSyntax.self)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if let literal = node.as(StringLiteralExprSyntax.self) {
            literals.append(LiteralFact(
                start: literal.positionAfterSkippingLeadingTrivia.utf8Offset,
                end: literal.endPositionBeforeTrailingTrivia.utf8Offset,
                pounds: literal.openingPounds?.text ?? "",
                quote: literal.openingQuote.text,
                value: literal.representedLiteralValue,
                parts: literal.segments.map { part in
                    LiteralPartFact(
                        start: part.position.utf8Offset,
                        end: part.endPosition.utf8Offset,
                        isExpression: part.is(ExpressionSegmentSyntax.self)
                    )
                }
            ))
        }
        if isRoot(node) {
            levels.append(0)
        } else if isLevel(node) {
            levels[levels.count - 1] += 1
            nesting.append(
                StyleFact(
                    start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                    depth: levels[levels.count - 1]
                ))
        }
        return .visitChildren
    }

    override func visitAnyPost(_ node: Syntax) {
        if isRoot(node) {
            levels.removeLast()
        } else if isLevel(node) {
            levels[levels.count - 1] -= 1
        }
    }
}
