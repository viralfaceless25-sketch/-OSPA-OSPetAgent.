import AvatarCore
import Foundation
import SwiftUI

// MARK: - ComputerUse

extension AvatarView {
    func computerUsePreview(
        _ preview: ComputerUsePreview
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Plan preview — nothing runs until you confirm", systemImage: "eye")
                .font(.caption.weight(.semibold))

            Text(
                "Target: \(preview.target.displayName) (\(preview.target.bundleIdentifier))"
            )
            .font(.caption)

            Text(
                "Permission: Accessibility, internally scoped to this exact bundle ID."
            )
            .font(.caption)

            Text("Audit contract: \(preview.contractID.uuidString)")
                .font(.caption.monospaced())
                .textSelection(.enabled)

            Text(
                "Expires: \(preview.expiresAt.formatted(date: .omitted, time: .standard))"
            )
            .font(.caption)

            Text("In-memory preview records: \(model.previewAuditRecords.count)")
                .font(.caption)

            ForEach(preview.steps, id: \.self) { step in
                Text(step)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preview.readinessIssues.isEmpty {
                Text("Preflight: permission and foreground target match.")
                    .foregroundStyle(.green)
            } else {
                ForEach(
                    preview.readinessIssues.map(\.description),
                    id: \.self
                ) { issue in
                    Text("Blocked: \(issue)")
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            Text(model.computerUseActionStatus)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Confirm and run these steps") {
                model.confirmComputerUseAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.computerUseExecutionReady)

            if model.isExecutingComputerUseAction {
                Text("Running… keep the target app in front.")
                    .foregroundStyle(.orange)
            }

            Text(
                "Redacted action audit records: \(model.computerUseAuditEvents.count)"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    func accessibilitySnapshotCard(
        _ snapshot: AccessibilityUISnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Redacted Accessibility evidence",
                systemImage: "checkmark.shield"
            )
            .font(.caption.weight(.semibold))

            Text(
                "Exact target: \(snapshot.target.displayName) (\(snapshot.target.bundleIdentifier))"
            )
            Text(
                "Visited \(snapshot.visitedElementCount) elements • retained \(snapshot.controls.count) controls\(snapshot.truncated ? " • truncated" : "")"
            )
            Text(
                "Evidence expires: \(snapshot.expiresAt.formatted(date: .omitted, time: .standard))"
            )

            if snapshot.controls.isEmpty {
                Text(
                    "No supported accessible controls were exposed. The app may be loading, isolate web content, or provide no compatible Accessibility tree. No broader fallback ran."
                )
                .foregroundStyle(.orange)
            } else {
                ForEach(snapshot.controls) { control in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "\(control.id). \(control.role)\(control.label.map { " “\($0)”" } ?? "")"
                        )
                        .font(.caption.weight(.semibold))
                        Text(
                            control.actions.isEmpty
                                ? "Actions: none retained"
                                : "Actions: \(control.actions.map(\.displayName).joined(separator: ", "))"
                        )
                        .foregroundStyle(.secondary)
                        if control.labelWasRedacted {
                            Text("Original label discarded by allowlist redactor.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if let preview = model.accessibilityInteractionPreview {
                Divider()
                Text("Evidence-backed interaction preview")
                    .font(.caption.weight(.semibold))
                if preview.evidence.isEmpty {
                    Text(
                        "No supported action evidence is available for planning."
                    )
                    .foregroundStyle(.orange)
                } else {
                    ForEach(preview.evidence) { evidence in
                        Text(evidence.description)
                    }
                }
                Text("Execution: disabled. No action adapter is connected.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(10)
        .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.cyan.opacity(0.24))
        }
    }

}

