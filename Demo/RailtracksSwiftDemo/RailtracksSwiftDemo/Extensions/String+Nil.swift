//
//  String+Nil.swift
//  RailtracksSwiftDemo
//
//  Created by Mark Su on 2026-04-27.
//

import Foundation

extension Optional where Wrapped == String {
    var isNil: Bool {
        self == nil
    }
    
    var isNotNilNorEmpty: Bool {
        self?.isEmpty == false
    }
}
