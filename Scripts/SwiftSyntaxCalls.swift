import Foundation
import SwiftSyntax

extension FactVisitor {
    func collectCall(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledExpression = node.calledExpression.tokens(viewMode: .sourceAccurate)
            .filter { $0.tokenKind != .postfixQuestionMark }.map(\.text).joined()
        let receiver = node.calledExpression.as(MemberAccessExprSyntax.self)?.base?.as(
            FunctionCallExprSyntax.self)?.calledExpression
        let receiverCall = receiver.map { FactText($0, source: sourceBytes) }
        var invocation = fact(
            node.trimmedDescription, start: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        invocation.calledExpression = calledExpression
        var expression = Syntax(node)
        while let parent = expression.parent,
            parent.is(AwaitExprSyntax.self) || parent.is(TryExprSyntax.self)
        {
            expression = parent
        }
        if let clause = expression.parent?.as(InitializerClauseSyntax.self),
            let binding = clause.parent?.as(PatternBindingSyntax.self)
        {
            invocation.expectedType = binding.typeAnnotation?.type.trimmedDescription
        } else if expression.parent?.is(ReturnStmtSyntax.self) == true {
            var parent = expression.parent
            while let current = parent, !current.is(ClosureExprSyntax.self) {
                if let function = current.as(FunctionDeclSyntax.self) {
                    invocation.expectedType =
                        function.signature.returnClause?.type.trimmedDescription
                    break
                }
                parent = current.parent
            }
        }
        invocation.receiverCall = receiverCall
        invocation.receiverElementCount =
            unwrappedExpression(node.calledExpression.as(MemberAccessExprSyntax.self)?.base)?.as(
                ArrayExprSyntax.self)?.elements.count
        invocation.argumentLabels = node.arguments.map { $0.label?.text ?? "" }
        invocation.arguments = node.arguments.map { $0.expression.trimmedDescription }
        invocation.argumentTypes = node.arguments.map { literalType($0.expression) }
        invocation.selectorArguments = node.arguments.map { selectorReference($0.expression) }
        invocation.argumentRanges = node.arguments.map {
            [
                $0.expression.positionAfterSkippingLeadingTrivia.utf8Offset,
                $0.expression.endPositionBeforeTrailingTrivia.utf8Offset,
            ]
        }
        invocation.closureArguments = node.arguments.enumerated().flatMap {
            index, argument -> [[Int]] in
            let expressions =
                argument.expression.as(ArrayExprSyntax.self)?.elements.map(\.expression) ?? [
                    argument.expression
                ]
            return expressions.compactMap { expression in
                guard let closure = expression.as(ClosureExprSyntax.self) else { return nil }
                return [
                    index, closure.positionAfterSkippingLeadingTrivia.utf8Offset,
                    closure.endPositionBeforeTrailingTrivia.utf8Offset,
                ]
            }
        }
        if let closure = node.trailingClosure {
            invocation.trailingClosureLabels =
                [""] + node.additionalTrailingClosures.map { $0.label.text }
            invocation.closureArguments?.append([
                node.arguments.count, closure.positionAfterSkippingLeadingTrivia.utf8Offset,
                closure.endPositionBeforeTrailingTrivia.utf8Offset,
            ])
        }
        for (index, argument) in node.additionalTrailingClosures.enumerated() {
            invocation.closureArguments?.append([
                node.arguments.count + index + 1,
                argument.closure.positionAfterSkippingLeadingTrivia.utf8Offset,
                argument.closure.endPositionBeforeTrailingTrivia.utf8Offset,
            ])
        }
        calls.append(invocations.count)
        invocations.append(invocation)
        let calledName =
            calledExpression.split(separator: ".").last.map(String.init) ?? calledExpression
        if [
            "task", "onAppear", "onDisappear", "onReceive", "onChange", "onPreferenceChange",
            "onGeometryChange",
        ].contains(calledName) {
            let callbacks: [ExprSyntax] =
                node.arguments.map(\.expression)
                + (node.trailingClosure.map { [ExprSyntax($0)] } ?? [])
                + node.additionalTrailingClosures.map { ExprSyntax($0.closure) }
            for callback in callbacks {
                lifecycleRanges.append(
                    ScopedRangeFact(
                        scope: scope,
                        start: callback.positionAfterSkippingLeadingTrivia.utf8Offset,
                        end: callback.endPositionBeforeTrailingTrivia.utf8Offset))
            }
        }
        if calledName == "alert", node.calledExpression.as(MemberAccessExprSyntax.self) != nil {
            alertModifiers.append(
                AlertModifierFact(
                    labels: node.arguments.map { $0.label?.text ?? "" },
                    arguments: node.arguments.map { $0.expression.trimmedDescription },
                    invocation: node.trimmedDescription,
                    identifiers: (node.arguments.flatMap { argument in
                        argument.expression.tokens(viewMode: .sourceAccurate).compactMap {
                            token -> String? in
                            if case .identifier(let name) = token.tokenKind { return name }
                            return nil
                        }
                    }
                        + (node.trailingClosure?.tokens(viewMode: .sourceAccurate).compactMap {
                            token -> String? in
                            if case .identifier(let name) = token.tokenKind { return name }
                            return nil
                        } ?? [])
                        + node.additionalTrailingClosures.flatMap { closure in
                            closure.closure.tokens(viewMode: .sourceAccurate).compactMap {
                                token -> String? in
                                if case .identifier(let name) = token.tokenKind { return name }
                                return nil
                            }
                        }),
                    scope: scope
                ))
        }
        if ["Label", "Button", "NavigationLink", "Image"].contains(calledName),
            let imageArgument = node.arguments.first(where: {
                $0.label?.text == "systemImage" || $0.label?.text == "systemName"
            })
        {
            listIcons.append(
                ListIconFact(
                    name: calledName,
                    symbol: imageArgument.expression.trimmedDescription,
                    scope: scope,
                    containers: listContainers
                ))
        }
        if (interactionNames.contains(calledName)
            || node.calledExpression.is(DeclReferenceExprSyntax.self) || calledName == "init"
            || calledName.first?.isUppercase == true)
            && (![
                "refreshable", "onSubmit", "onDelete", "onMove", "searchable", "contextMenu",
                "swipeActions",
            ].contains(calledName) || node.calledExpression.is(MemberAccessExprSyntax.self))
            && !(calledName == "onTapGesture" && node.arguments.isEmpty
                && node.trailingClosure?.statements.isEmpty == true)
        {
            let labelArgument = node.arguments.first(where: { $0.label?.text == "label" })
            let labelClosure = node.additionalTrailingClosures.first(where: {
                $0.label.text == "label"
            })?.closure
            let singleTrailingLabel: ClosureExprSyntax? = {
                guard labelArgument == nil, labelClosure == nil,
                    let trailingClosure = node.trailingClosure
                else {
                    return nil
                }
                let argumentLabels = Set(node.arguments.compactMap { $0.label?.text })
                switch calledName {
                case "Button":
                    return argumentLabels.contains("action") ? trailingClosure : nil
                case "NavigationLink":
                    return argumentLabels.contains("destination")
                        || argumentLabels.contains("value")
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
                    let base = member.base?.as(FunctionCallExprSyntax.self)
                {
                    carrier = base
                    if let modifier = base.calledExpression.as(MemberAccessExprSyntax.self) {
                        modifiers.insert(
                            "." + modifier.declName.baseName.text + "("
                                + base.arguments.trimmedDescription + ")", at: 0)
                    }
                }
            }
            while let parent = styledExpression.parent {
                if parent.is(MemberAccessExprSyntax.self) || parent.is(FunctionCallExprSyntax.self)
                {
                    if let call = parent.as(FunctionCallExprSyntax.self),
                        let member = call.calledExpression.as(MemberAccessExprSyntax.self)
                    {
                        modifiers.append(
                            "." + member.declName.baseName.text + "("
                                + call.arguments.trimmedDescription + ")")
                    }
                    styledExpression = parent
                } else {
                    break
                }
            }
            let control = AccessibilityControlFact(
                name: calledName,
                invocation: FactText(node, source: sourceBytes),
                label: labelSyntax.map { FactText($0, source: sourceBytes) } ?? .literal(""),
                hasTextTitle: titleArgument != nil,
                scope: scope,
                start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                labelStart: labelSyntax?.positionAfterSkippingLeadingTrivia.utf8Offset ?? -1,
                labelEnd: labelSyntax?.endPositionBeforeTrailingTrivia.utf8Offset ?? -1,
                containers: listContainers,
                expression: FactText(styledExpression, source: sourceBytes),
                modifiers: modifiers.joined(),
                callback: node.trailingClosure.map { FactText($0, source: sourceBytes) }
                    ?? .literal(""),
                carrierInvocation: FactText(carrier, source: sourceBytes)
            )
            if interactionNames.contains(calledName) {
                accessibilityControls.append(control)
            } else {
                accessibilityControlCandidates.append(control)
            }

            switch calledName {
            case "Button":
                excludeRenderedContent(
                    node.arguments.first(where: { $0.label?.text == "action" })?.expression.as(
                        ClosureExprSyntax.self)
                )
                if labelClosure != nil || titleArgument != nil {
                    excludeRenderedContent(node.trailingClosure)
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
            excludeRenderedContent(node.trailingClosure)
            for closure in node.additionalTrailingClosures {
                excludeRenderedContent(closure.closure)
            }
            for argument in node.arguments {
                excludeRenderedContent(argument.expression.as(ClosureExprSyntax.self))
            }
        }
        if ["List", "Form", "Section"].contains(calledName) {
            listContainers.append(calledName)
        }
        if calledName == "Picker" || calledName == "Toggle" {
            selectionControls.append(
                SelectionControlFact(
                    name: calledName,
                    invocation: node.trimmedDescription,
                    scope: scope,
                    start: node.positionAfterSkippingLeadingTrivia.utf8Offset
                ))
        }
        if calledName == "List" {
            listControls.append(
                SelectionControlFact(
                    name: calledName,
                    invocation: node.trimmedDescription,
                    scope: scope,
                    start: node.positionAfterSkippingLeadingTrivia.utf8Offset
                ))
        }
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
            memberAccess.trimmedDescription.hasSuffix(".appSelectionFeedback")
        {
            feedbackModifiers.append(
                FeedbackModifierFact(
                    name: "appSelectionFeedback",
                    base: memberAccess.base?.trimmedDescription ?? "",
                    scope: scope,
                    baseStart: memberAccess.base?.positionAfterSkippingLeadingTrivia.utf8Offset
                        ?? -1
                ))
        }
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
            memberAccess.trimmedDescription.hasSuffix(".appGroupedListStyle")
        {
            listStyleModifiers.append(
                FeedbackModifierFact(
                    name: "appGroupedListStyle",
                    base: memberAccess.base?.trimmedDescription ?? "",
                    scope: scope,
                    baseStart: memberAccess.base?.positionAfterSkippingLeadingTrivia.utf8Offset
                        ?? -1
                ))
        }
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
            memberAccess.trimmedDescription.hasSuffix(".accessibilityLabel")
        {
            accessibilityModifiers.append(
                FeedbackModifierFact(
                    name: "accessibilityLabel",
                    base: memberAccess.base?.trimmedDescription ?? "",
                    scope: scope,
                    baseStart: memberAccess.base?.positionAfterSkippingLeadingTrivia.utf8Offset
                        ?? -1
                ))
        }
        return .visitChildren
    }
}
