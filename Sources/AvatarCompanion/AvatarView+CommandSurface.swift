import AvatarCore
import Foundation
import SwiftUI

// MARK: - CommandSurface

extension AvatarView {
    var commandSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Command", systemImage: "text.bubble")
                    .font(.headline)

                Spacer()

                Button {
                    model.onHide?()
                } label: {
                    Image(systemName: "eye.slash")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide avatar")
            }

            HStack(spacing: 8) {
                TextField("Try “open Safari”", text: $model.command)
                    .textFieldStyle(.roundedBorder)
                    .focused($commandFocused)
                    .onSubmit(model.previewCommand)
                    .accessibilityLabel("Command")

                Button("Preview") {
                    model.previewCommand()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Toggle(
                "Natural language",
                isOn: Binding(
                    get: { model.isBrainEnabled },
                    set: { model.setBrainEnabled($0) }
                )
            )
            .disabled(model.safety.emergencyStopped)
            .accessibilityHint(
                "Uses the local model only after exact command parsing declines"
            )

            HStack(alignment: .top, spacing: 6) {
                if model.isBrainThinking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.brainStatus)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                Text(model.brainCorrectionStatus)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Clear learned corrections") {
                    model.clearBrainCorrections()
                }
                .buttonStyle(.borderless)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Button {
                model.openSearch()
                searchFocused = true
            } label: {
                Label("Search this Mac", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint(
                "Opens metadata scope review before local name search"
            )

            if model.isSearchPresented {
                localSearchSurface
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Status: \(model.status)")

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "app.dashed")
                Text(model.applicationActionStatus)
                Spacer()
                Text("Audit \(model.applicationAuditEvents.count)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let sequence = model.pendingTaskSequence {
                taskSequenceCard(sequence)
            }

            if !model.taskSequenceOutcomes.isEmpty {
                taskSequenceProgressCard()
            }

            if let sequence = model.pendingApplicationSequence {
                applicationSequenceCard(sequence)
            }

            if let proposal = model.pendingApplicationProposal {
                executableApplicationCard(proposal)
            }

            if let preview = model.spotlightOpenPreview {
                spotlightPreviewCard(preview)
            }

            if let plan = model.pendingLocalItemOpenPlan {
                localItemFallbackCard(plan)
            }

            if let action = model.previewedAction {
                VStack(alignment: .leading, spacing: 8) {
                    Label(action.title, systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))

                    Text(action.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Confirm and copy") {
                        model.performPreviewedAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        model.safety.observeOnly || model.safety.emergencyStopped
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            discoverySurface

            Toggle(
                "Observe only",
                isOn: Binding(
                    get: { model.safety.observeOnly },
                    set: { enabled in
                        model.setObserveOnly(enabled)
                    }
                )
            )
            .disabled(model.safety.emergencyStopped)
            .accessibilityHint("Blocks every action when enabled")

            if model.safety.emergencyStopped {
                Button("Clear stop in observe-only mode") {
                    model.resumeObservation()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button(
                    role: .destructive,
                    action: {
                        model.emergencyStop()
                    }
                ) {
                    Label("Emergency stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: [.command])
            }
        }
        .padding(16)
        .onAppear {
            commandFocused = true
        }
    }

}

