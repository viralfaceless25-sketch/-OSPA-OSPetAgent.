import AvatarCore
import Foundation
import SwiftUI

// MARK: - Application

extension AvatarView {
    func applicationSequenceCard(
        _ sequence: ApplicationSequenceProposal
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Ordered local plan", systemImage: "list.number")
                .font(.subheadline.weight(.semibold))

            Text(
                "Bound target: \(sequence.applicationProposal.application.identity.displayName) (\(sequence.applicationProposal.application.identity.bundleIdentifier))"
            )
            .font(.caption)
            .textSelection(.enabled)

            ForEach(sequence.orderedSteps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(step.id)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .frame(width: 20, height: 20)
                        .background(
                            step.availability == .confirmableNow
                                ? .green.opacity(0.18)
                                : .orange.opacity(0.18),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.caption.weight(.semibold))
                        Text(step.effectPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            sequenceStepStatus(
                                step,
                                firstStepCompleted:
                                    model.applicationSequenceFirstStepCompleted,
                                firstStepAvailable:
                                    model.pendingApplicationProposal != nil,
                                firstStepExecuting:
                                    model.isExecutingApplicationAction
                            )
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            step.availability == .confirmableNow
                                ? .green : .orange
                        )
                    }
                }
            }

            Text(
                "The green confirmation authorizes step 1 only. Step 2 needs future visible app interaction, exact UI-state verification, and a new user confirmation."
            )
            .font(.caption)
            .foregroundStyle(.orange)

            Text(
                "No playback, login, content lookup, screen inspection, input injection, or follow-up action is attempted or queued."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.orange.opacity(0.24))
        }
    }

    func sequenceStepStatus(
        _ step: ApplicationSequenceStep,
        firstStepCompleted: Bool,
        firstStepAvailable: Bool,
        firstStepExecuting: Bool
    ) -> String {
        switch step.availability {
        case .confirmableNow:
            if firstStepCompleted {
                "Completed"
            } else if firstStepExecuting {
                "Executing confirmed step 1"
            } else if firstStepAvailable {
                "Available now after separate confirmation"
            } else {
                "Expired or changed • preview again"
            }
        case .deferredUnsupported:
            "Unsupported • not executable • not queued"
        }
    }

    func executableApplicationCard(
        _ proposal: ApplicationActionProposal
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Executable native exact-app fallback",
                systemImage: "bolt.shield"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)

            Text(
                "Target: \(proposal.application.identity.displayName) (\(proposal.application.identity.bundleIdentifier))"
            )
            .font(.caption)
            .textSelection(.enabled)

            ForEach(proposal.plan.steps) { step in
                Text(step.visibleInteraction?.previewDescription ?? step.effectPreview)
                    .font(.caption)
                Text("Effect: \(step.effectPreview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                "Permissions: none. Fallback mechanism: native macOS app activation; no target-app API or input injection."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let expiry = model.applicationProposalExpiresAt {
                Text(
                    "Preview expires: \(expiry.formatted(date: .omitted, time: .standard))"
                )
                .font(.caption)
            }

            Text(model.applicationActionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.confirmApplicationAction()
            } label: {
                Text(
                    model.pendingApplicationSequence != nil
                        ? (proposal.command.operation == .switchToRunning
                            ? "Confirm step 1 — switch"
                            : "Confirm step 1 — open")
                        : (proposal.command.operation == .switchToRunning
                            ? "Confirm switch"
                            : "Confirm open")
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                model.safety.observeOnly
                    || model.safety.emergencyStopped
                    || model.isExecutingApplicationAction
            )

            Button("Not this app") {
                model.declineApplicationAction()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isExecutingApplicationAction)
            .accessibilityHint(
                model.brainReason == nil
                    ? "Dismisses this proposal without running it"
                    : "Dismisses this proposal and stores a local correction"
            )

            if model.safety.observeOnly {
                Text("Turn off Observe only to enable this one confirmation.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Redacted execution audit events: \(model.applicationAuditEvents.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.green.opacity(0.25))
        }
    }

}
