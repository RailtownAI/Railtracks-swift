//
//  RTSStampFactory.swift
//  RailtracksSwift
//
//  Created by Mark Su on 2026-05-08.
//

import Foundation

/// Singular timestamp factory that is meant to be shared to generate RTSStamp with consistant step index
actor RTSStampFactory {
    private var counter: Int = 0

    func makeStamp(event: RTSStamp.Event) -> RTSStamp {
        let stamp = RTSStamp(stepIndex: counter, event: event)
        counter += 1
        return stamp
    }
}
