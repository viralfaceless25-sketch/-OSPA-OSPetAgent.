import AvatarCore
import Foundation
import SwiftUI

// MARK: - Discovery

extension AvatarView {
    var discoverySurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("App discovery", systemImage: "app.badge.checkmark")
                .font(.headline)

            Text(model.discoveryStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.identifyForegroundApp()
            } label: {
                Label("Identify foreground app", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Reads app name and bundle identifier only")

            if let app = model.discoveredApp {
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(app.bundleIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                TextField(
                    "https://official.example/docs",
                    text: $model.officialDocumentationURL
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Official documentation URL")

                Button("Prepare research scope") {
                    model.prepareResearchScope()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if let request = model.researchRequest {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Approval preview")
                            .font(.caption.weight(.semibold))
                        Text("Hosts: \(request.approvedHosts.sorted().joined(separator: ", "))")
                        Text("Limit: \(request.maxDocuments) documents • 15 minutes")
                        Text("Fetched text remains untrusted until claim review.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Approve this research scope") {
                        model.approveResearchScope()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.researchAuthorization != nil)
                }

                TextField(
                    "What should I answer from this page?",
                    text: $model.readPageQuestion
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Question about approved page")

                Button("Read approved page") {
                    guard let url = URL(
                        string: model.officialDocumentationURL
                    ) else { return }
                    model.readApprovedPage(
                        url: url,
                        question: model.readPageQuestion
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    !model.canReadCurrentApprovedURL
                        || model.readPageQuestion.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        || model.safety.emergencyStopped
                )

                if !model.readPageStatus.isEmpty {
                    Text(model.readPageStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Redacted page-read audit records: \(model.pageReadAuditEvents.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Label("Accessibility permission", systemImage: "hand.raised")
                    .font(.subheadline.weight(.semibold))

                Text(model.accessibilityStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Check") {
                        model.refreshAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)

                    Button("Request from macOS") {
                        model.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)

                Text(
                    "Request opens macOS consent UI. Permission alone reads nothing and authorizes no input or execution."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Label(
                    "One-time redacted UI inspection",
                    systemImage: "rectangle.and.text.magnifyingglass"
                )
                .font(.subheadline.weight(.semibold))

                Text(model.accessibilityInspectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Prepare inspection scope") {
                    model.prepareAccessibilityInspection()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.safety.emergencyStopped)

                if let request = model.accessibilityInspectionRequest {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Approval preview")
                            .font(.caption.weight(.semibold))
                        Text(
                            "Target: \(request.target.displayName) (\(request.target.bundleIdentifier))"
                        )
                        Text(
                            "Cap: \(request.maximumControls) controls from \(request.maximumVisitedElements) visited elements, depth \(request.maximumDepth)"
                        )
                        Text(
                            "Expires: \(request.expiresAt.formatted(date: .omitted, time: .standard))"
                        )
                        Text(
                            "Reads interactive role, title/description label, and supported action names only. Never AXValue, selected text, document text, or pixels."
                        )
                        Text(
                            "Unknown labels are replaced with “[redacted label]” before storage."
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Approve and inspect once") {
                        model.approveAndInspectAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        model.accessibilityInspectionRequestConsumed
                            || model.safety.emergencyStopped
                    )
                }

                if let snapshot = model.accessibilityUISnapshot {
                    accessibilitySnapshotCard(snapshot)
                }

                Text(
                    "Redacted inspection audit records: \(model.accessibilityInspectionAuditRecords.count)"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                Button("Create preview-only ⌘S plan") {
                    model.buildPreviewOnlyComputerUsePlan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let preview = model.computerUsePreview {
                    computerUsePreview(preview)
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

}

