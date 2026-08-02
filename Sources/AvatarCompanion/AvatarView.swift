import AvatarCore
import Foundation
import SwiftUI

struct AvatarView: View {
    @ObservedObject var model: AvatarModel
    @FocusState private var commandFocused: Bool
    @FocusState private var searchFocused: Bool

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

    private func applicationSequenceCard(
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

    private func sequenceStepStatus(
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

    private var localSearchSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Spotlight-style local search", systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Close") {
                    model.closeSearch()
                }
                .buttonStyle(.plain)
            }

            Text(
                "Name metadata only. Applications includes native and discoverable web-app bundles. Personal scopes require this explicit, expiring approval."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Applications (required)", isOn: .constant(true))
                .disabled(true)

            ForEach(
                [
                    LocalSearchScopeID.desktop,
                    .documents,
                    .downloads,
                ],
                id: \.self
            ) { scope in
                Toggle(
                    scope.displayName,
                    isOn: Binding(
                        get: {
                            model.draftSearchScopes.contains(scope)
                        },
                        set: { enabled in
                            model.setDraftSearchScope(
                                scope,
                                enabled: enabled
                            )
                        }
                    )
                )
            }

            Button("Approve scope for 15 minutes") {
                model.approveSearchScopes()
                searchFocused = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            TextField(
                "Search local names, e.g. net",
                text: Binding(
                    get: { model.searchQuery },
                    set: { model.updateSearchQuery($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)
            .disabled(model.searchAuthorization == nil)
            .accessibilityLabel("Search approved local metadata")

            Text(model.searchStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.searchCandidates) { candidate in
                Button {
                    model.selectSearchCandidate(candidate)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: searchIcon(candidate.item.kind))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(candidate.item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if candidate.item.isRunning {
                                    Text("Running")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(
                                "\(candidate.item.kind.displayName) • \(candidate.matchDescription)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(candidate.item.url.deletingLastPathComponent().path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    "Selects this exact result for preview; does not open it"
                )
            }

            Text(
                "Hidden items, package internals, file contents, browser history, URLs, and unapproved locations are excluded."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.blue.opacity(0.25))
        }
    }

    private func spotlightPreviewCard(
        _ preview: SpotlightOpenPreview
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Visible Command-Space route — preview only",
                systemImage: "keyboard"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.purple)

            Text(
                "Exact target: \(preview.item.name) • \(preview.item.kind.displayName)"
            )
            .font(.caption)
            Text(preview.item.url.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            ForEach(
                Array(preview.steps.enumerated()),
                id: \.offset
            ) { index, step in
                Text("\(index + 1). \(step.previewDescription)")
                    .font(.caption)
            }

            Text(preview.blocker)
                .font(.caption)
                .foregroundStyle(.orange)
            Text("No keyboard, mouse, screen, or Accessibility UI event ran.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.purple.opacity(0.25))
        }
    }

    private func localItemFallbackCard(
        _ plan: LocalItemOpenPlan
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Executable native exact-item fallback",
                systemImage: "bolt.shield"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)

            Text("Target: \(plan.item.name) • \(plan.item.kind.displayName)")
                .font(.caption)
            Text(plan.item.url.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(
                "Effect: macOS opens only this selected URL with its registered handler. No target-app API or input injection."
            )
            .font(.caption)
            Text(
                "Preview expires: \(plan.expiresAt.formatted(date: .omitted, time: .standard))"
            )
            .font(.caption)

            Button("Confirm exact open") {
                model.confirmLocalItemAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                model.safety.observeOnly
                    || model.safety.emergencyStopped
                    || model.isExecutingLocalItemAction
            )

            if model.safety.observeOnly {
                Text("Turn off Observe only to enable this one confirmation.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(model.localItemActionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Redacted audit events: \(model.localItemAuditEvents.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.green.opacity(0.25))
        }
    }

    private func searchIcon(_ kind: LocalSearchItemKind) -> String {
        switch kind {
        case .application: "app"
        case .folder: "folder"
        case .file: "doc"
        }
    }

    private func executableApplicationCard(
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
                    !model.hasLiveResearchAuthorization
                        || URL(string: model.officialDocumentationURL) == nil
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

    private func taskSequenceCard(_ sequence: TaskSequence) -> some View {
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

    private func taskSequenceProgressCard() -> some View {
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

    private func computerUsePreview(
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

    private func accessibilitySnapshotCard(
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

    private var modeLabel: String {
        model.safety.observeOnly ? "Observe only" : "Action mode"
    }
}
