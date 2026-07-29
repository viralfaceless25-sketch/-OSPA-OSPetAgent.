import AvatarCore
import SwiftUI

struct AvatarView: View {
    @ObservedObject var model: AvatarModel
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            avatarHeader

            if model.isExpanded {
                Divider()
                    .padding(.horizontal, 14)

                ScrollView {
                    commandSurface
                }
                .frame(height: 520)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: model.isExpanded ? 340 : 128)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(.white.opacity(0.2))
        }
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        .animation(.snappy(duration: 0.25), value: model.isExpanded)
        .accessibilityElement(children: .contain)
    }

    private var avatarHeader: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)

                HStack(spacing: 14) {
                    eye
                    eye
                }
                .offset(y: -5)

                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 24, height: 4)
                    .offset(y: 17)
            }
            .accessibilityLabel("Avatar companion")

            Text(model.safety.emergencyStopped ? "Stopped" : modeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.safety.emergencyStopped ? .red : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            model.toggleExpanded()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(model.isExpanded ? "Collapse controls" : "Open controls")
    }

    private var eye: some View {
        Circle()
            .fill(.white)
            .frame(width: 11, height: 11)
            .overlay {
                Circle()
                    .fill(.black.opacity(0.75))
                    .frame(width: 5, height: 5)
            }
    }

    private var commandSurface: some View {
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

            if let proposal = model.pendingApplicationProposal {
                executableApplicationCard(proposal)
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

    private func executableApplicationCard(
        _ proposal: ApplicationActionProposal
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Executable native app action",
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

            Text("Permissions: none. Mechanism: native macOS app activation.")
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
                    proposal.command.operation == .switchToRunning
                        ? "Confirm switch"
                        : "Confirm open"
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

    private var discoverySurface: some View {
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
                    "Request opens macOS consent UI. This app still has no code that reads UI or sends input."
                )
                .font(.caption)
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

    private func computerUsePreview(
        _ preview: ComputerUsePreview
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Non-executable preview", systemImage: "eye")
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

            Text("Execution: disabled by preview-only adapter.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var modeLabel: String {
        model.safety.observeOnly ? "Observe only" : "Action mode"
    }
}
