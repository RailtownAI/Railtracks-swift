//
//  MathTools.swift
//  RailtracksSwiftDemo
//

import SwiftUI

struct RTSStepsView: View {
    let steps: [RTSStepState]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, state in
                RTSStepRow(
                    state: state,
                    number: index + 1,
                    showsConnector: index < steps.count - 1
                )
            }
        }
    }
}

private struct RTSStepRow: View {
    let state: RTSStepState
    let number: Int
    let showsConnector: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                RTSStepAvatar(status: state.status, number: number)
                    .frame(width: 28, height: 28)
                if showsConnector || !state.chips.isEmpty {
                    Rectangle()
                        .fill(connectorColor)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(titleColor)
                if let subtitle = state.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !state.chips.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.chips.enumerated()), id: \.element.id) { idx, chip in
                            RTSSubStepRow(
                                chip: chip,
                                showsConnector: idx < state.chips.count - 1
                            )
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, showsConnector ? 8 : 0)
                }
            }
            .padding(.bottom, (showsConnector || !state.chips.isEmpty) ? 0 : 8)
        }
    }

    private var titleColor: Color {
        switch state.status {
        case .pending:    .secondary
        case .inProgress: Color.accentColor
        case .complete:   .primary
        case .failed:     .red
        }
    }

    private var subtitleColor: Color {
        switch state.status {
        case .inProgress: Color.accentColor.opacity(0.85)
        default:          .secondary
        }
    }

    private var connectorColor: Color {
        switch state.status {
        case .complete: Color.green.opacity(0.5)
        default:        Color.secondary.opacity(0.25)
        }
    }
}

private struct RTSSubStepRow: View {
    let chip: ChipState
    let showsConnector: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                RTSStepAvatar(status: chip.status, number: nil)
                    .frame(width: 20, height: 20)
                if showsConnector {
                    Rectangle()
                        .fill(subConnectorColor)
                        .frame(width: 1.5)
                        .frame(minHeight: 6, maxHeight: 24)
                }
            }
            Text(chip.label)
                .font(.subheadline)
                .foregroundStyle(labelColor)
                .padding(.top, 2)
        }
    }

    private var labelColor: Color {
        switch chip.status {
        case .pending:    .secondary
        case .inProgress: Color.accentColor
        case .complete:   .primary
        case .failed:     .red
        }
    }

    private var subConnectorColor: Color {
        switch chip.status {
        case .complete: Color.green.opacity(0.5)
        default:        Color.secondary.opacity(0.20)
        }
    }
}

private struct RTSStepAvatar: View {
    let status: StepStatus
    let number: Int?

    var body: some View {
        ZStack {
            switch status {
            case .complete:
                Circle().fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.system(size: number == nil ? 9 : 13, weight: .bold))
                    .foregroundStyle(.white)
            case .inProgress:
                Circle().fill(Color.accentColor)
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            case .pending:
                Circle().fill(Color.secondary.opacity(0.18))
                if let number {
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            case .failed:
                Circle().fill(Color.red)
                Image(systemName: "xmark")
                    .font(.system(size: number == nil ? 9 : 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}
