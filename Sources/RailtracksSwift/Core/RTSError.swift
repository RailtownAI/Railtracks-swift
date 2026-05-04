//
//  RTSError.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-04.
//

import Foundation

public enum RTSError: Error {
    case missingInput(String)
    case missingOutput(String)
}
