import AvatarCore
import Foundation
import SwiftUI

// MARK: - TaskSequence

extension AvatarView {
    func taskSequenceCard(_ sequence: TaskSequence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "\(sequence.steps.count) requests, in order",
                systemImage: "list.number"
            )
            .font(.caption.weight(.semibold))

            ForEach(Array(sequence.steps.enumerated()), id: \.element.id) {
                index, step in
                Text("\(index + 1). \(step.summary)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.taskSequenceStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Confirm and run all \(sequence.steps.count)") {
                model.confirmTaskSequence()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.taskSequenceExecutionReady)

            Text(
                "One confirmation authorizes this exact list. Each step is re-checked as it starts, and the first failure stops the rest."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    func taskSequenceProgressCard() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Progress", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))

            ForEach(model.taskSequenceOutcomes, id: \.index) { outcome in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(
                        systemName: outcome.outcome == .succeeded
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    )
                    .foregroundStyle(
                        outcome.outcome == .succeeded ? .green : .orange
                    )
                    Text("\(outcome.index + 1). \(outcome.summary)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }

            if model.isExecutingTaskSequence {
                Text("Working…").foregroundStyle(.orange).font(.caption)
            } else {
                Text(model.taskSequenceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

}

