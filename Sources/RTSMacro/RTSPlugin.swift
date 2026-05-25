//
//  RTSPlugin.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-25.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct RTSPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RTSEncodeNullsMacro.self,
        RTSSchemaMacro.self,
    ]
}
