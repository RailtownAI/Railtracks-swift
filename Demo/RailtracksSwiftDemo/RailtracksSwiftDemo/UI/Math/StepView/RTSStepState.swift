//
//  MathTools.swift
//  RailtracksSwiftDemo
//

import Foundation

enum StepStatus: Sendable, Equatable {
    case pending
    case inProgress
    case complete
    case failed
}

struct RTSStepState: Identifiable, Sendable {
    let id: String
    let title: String
    var status: StepStatus
    var subtitle: String?
    var chips: [ChipState]
}

struct ChipState: Identifiable, Sendable {
    let id: String
    let label: String
    var status: StepStatus
}
