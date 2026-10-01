import SwiftSyntax

final class MuterRewriter: SyntaxRewriter {
    private let schemataMappings: SchemataMutationMapping

    required init(_ schemataMappings: SchemataMutationMapping) {
        self.schemataMappings = schemataMappings
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        guard let mutationSchemata = schemataMappings.schemata(node) else {
            return super.visit(node)
        }

        // Rewrite nested blocks while they still have the identities their
        // schemata are keyed by, then wrap the result. Wrapping first rebuilds
        // the children in a new tree, and their schemata never match.
        let childrenRewritten = super.visit(node)

        return MutationSwitch.apply(
            mutationSchemata: mutationSchemata,
            with: childrenRewritten
        )
    }
}
