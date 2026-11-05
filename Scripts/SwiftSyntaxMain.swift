import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

@main
enum SwiftSyntaxMain {
    static func main() throws {
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        let input = try JSONDecoder().decode(Input.self, from: inputData)
        var output: [String: FileFacts] = [:]
        final class EscapedIdentifierNormalizer: SyntaxRewriter {
            override func visit(_ original: TokenSyntax) -> TokenSyntax {
                guard case .identifier(let name) = original.tokenKind, name.hasPrefix("`"),
                    name.hasSuffix("`")
                else { return original }
                var token = original
                token.tokenKind = .identifier(String(name.dropFirst().dropLast()))
                token.leadingTrivia += .spaces(1)
                token.trailingTrivia = .spaces(1) + token.trailingTrivia
                return token
            }
        }
        func indexSource(_ source: String, as key: String) {
            let tree = EscapedIdentifierNormalizer(viewMode: .sourceAccurate).rewrite(
                Parser.parse(source: source))
            let visitor = FactVisitor(viewMode: .sourceAccurate)
            visitor.interactionNames = Set(input.interactionNames)
            visitor.sourceBytes = Array(source.utf8)
            visitor.walk(tree)
            let style = StyleVisitor(viewMode: .sourceAccurate)
            let parsed = Parser.parse(source: source)
            let folded = try? OperatorTable.standardOperators.foldAll(parsed)
            style.walk(folded ?? Syntax(parsed))
            let identifiers = tree.tokens(viewMode: .sourceAccurate).compactMap {
                token -> String? in
                if case .identifier(let name) = token.tokenKind { return name }
                return nil
            }
            output[key] = FileFacts(
                source: source,
                styleNesting: style.nesting,
                styleLiterals: style.literals,
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
                genericConstraints: visitor.genericConstraints,
                listIcons: visitor.listIcons,
                listControls: visitor.listControls,
                listStyleModifiers: visitor.listStyleModifiers,
                accessibilityModifiers: visitor.accessibilityModifiers,
                accessibilityControls: visitor.accessibilityControls,
                accessibilityControlCandidates: visitor.accessibilityControlCandidates,
                functionRanges: visitor.functionRanges,
                accessorRanges: visitor.accessorRanges,
                callableRanges: visitor.callableRanges,
                inlineClosureRanges: visitor.inlineClosureRanges,
                initializers: visitor.initializers,
                nonRenderedRanges: visitor.nonRenderedRanges,
                lifecycleRanges: visitor.lifecycleRanges,
                members: visitor.members,
                forceUnwraps: visitor.forceUnwraps,
                emptyCatchClauses: visitor.emptyCatchClauses,
                discardedOptionalTries: visitor.discardedOptionalTries,
                expressions: visitor.expressions,
                bindings: visitor.bindings,
                controlFlow: visitor.controlFlow,
                expressionFlow: visitor.expressionFlow,
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
    }
}
