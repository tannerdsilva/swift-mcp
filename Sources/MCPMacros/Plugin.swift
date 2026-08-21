import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MCPMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        MCPCommandMacro.self,
        MCPApplicationMacro.self,
        ToolMacro.self,
    ]
}
