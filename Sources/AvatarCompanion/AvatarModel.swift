import AppKit
import AvatarCore
import AvatarPlatform
import Foundation

@MainActor
final class AvatarModel: ObservableObject {
    @Published var isExpanded = false
    @Published var command = ""
    @Published var previewedAction: AvatarAction?
    @Published var safety = SafetyState.initial
    @Published var status = "Observe-only mode is on."
    @Published var discoveredApp: AppIdentity?
    @Published var officialDocumentationURL = ""
    @Published var researchRequest: ResearchRequest?
    @Published var researchAuthorization: ResearchAuthorization?
    @Published var discoveryStatus =
        "Identify the foreground app without reading its screen or files."
    @Published var accessibilityPermissionGranted = false
    @Published var accessibilityStatus =
        "Accessibility permission has not been checked."
    @Published var computerUsePreview: ComputerUsePreview?
    @Published private(set) var previewAuditRecords: [PreviewAuditRecord] = []
    @Published var pendingApplicationProposal: ApplicationActionProposal?
    @Published var applicationProposalExpiresAt: Date?
    @Published var applicationActionStatus =
        "Executable app commands: “open Safari” or “switch to Notes”."
    @Published private(set) var applicationAuditEvents: [AuditEvent] = []
    @Published var isExecutingApplicationAction = false

    var onExpansionChanged: ((Bool) -> Void)?
    var onHide: (() -> Void)?

    private let interpreter = CommandInterpreter()
    private let gate = ActionGate()
    private let researchGate = ResearchGate()
    private let accessibilityPermission = AccessibilityPermissionController()
    private let previewAdapter = PreviewOnlyForegroundAdapter()
    private let foregroundComposer = ForegroundCommandComposer()
    private let applicationCommandParser = ApplicationCommandParser()
    private let applicationResolver = InstalledApplicationResolver()
    private let applicationPlanner = ApplicationActionPlanner()
    private let nativeApplicationExecutor = NativeApplicationExecutor()
    private var consumedConsentGrantIDs = Set<UUID>()

    func toggleExpanded() {
        isExpanded.toggle()
        onExpansionChanged?(isExpanded)
    }

    func previewCommand() {
        switch applicationCommandParser.parse(command) {
        case let .command(parsed):
            previewApplicationCommand(parsed)
            return
        case let .rejected(reason):
            previewedAction = nil
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status = "Unsupported executable command: \(reason)"
            return
        case .notApplicationCommand:
            break
        }

        switch interpreter.interpret(command) {
        case .help:
            previewedAction = nil
            status =
                "Try “copy time”, “focus this app”, “preview save”, or “preview find”."
        case .rejected:
            previewedAction = nil
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            composeForegroundCommand()
        case let .action(action):
            previewedAction = action
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            switch gate.evaluate(action, state: safety, userConfirmed: false) {
            case let .denied(reason):
                status = "\(action.preview) \(reason)"
            case let .needsConfirmation(preview):
                status = preview
            case .allowed:
                status = action.preview
            }
        }
    }

    func performPreviewedAction() {
        guard let action = previewedAction else {
            status = "Preview a command first."
            return
        }

        switch gate.evaluate(action, state: safety, userConfirmed: true) {
        case let .denied(reason):
            status = reason
        case .needsConfirmation:
            status = "Confirmation required."
        case .allowed:
            execute(action)
        }
    }

    func setObserveOnly(_ enabled: Bool) {
        safety.observeOnly = enabled
        if enabled {
            status = "Observe-only mode is on. Actions are blocked."
        } else {
            status = "Action mode on. Every action still needs explicit confirmation."
        }
    }

    func emergencyStop() {
        safety.emergencyStopped = true
        safety.observeOnly = true
        previewedAction = nil
        computerUsePreview = nil
        pendingApplicationProposal = nil
        applicationProposalExpiresAt = nil
        command = ""
        applicationActionStatus = "Emergency stop active. Pending app action cleared."
        status = "Stopped. All actions blocked."
    }

    func resumeObservation() {
        safety = .initial
        status = "Emergency stop cleared. Observe-only mode remains on."
    }

    func identifyForegroundApp() {
        guard
            let runningApp = NSWorkspace.shared.frontmostApplication,
            let bundleIdentifier = runningApp.bundleIdentifier,
            let displayName = runningApp.localizedName
        else {
            discoveredApp = nil
            discoveryStatus = "Could not identify the foreground app."
            return
        }

        discoveredApp = AppIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
        researchRequest = nil
        researchAuthorization = nil
        computerUsePreview = nil
        discoveryStatus =
            "Identified \(displayName) by bundle ID only. No app content was read."
    }

    func prepareResearchScope() {
        guard let app = discoveredApp else {
            discoveryStatus = "Identify an app first."
            return
        }
        guard let url = URL(string: officialDocumentationURL) else {
            discoveryStatus = "Enter a valid official HTTPS documentation URL."
            return
        }

        do {
            researchRequest = try researchGate.propose(
                app: app,
                officialDocumentationURL: url,
                now: Date()
            )
            researchAuthorization = nil
            discoveryStatus =
                "Review exact host and five-document limit. Nothing fetched yet."
        } catch {
            researchRequest = nil
            researchAuthorization = nil
            discoveryStatus = researchErrorMessage(error)
        }
    }

    func approveResearchScope() {
        guard let request = researchRequest else {
            discoveryStatus = "Prepare a valid research scope first."
            return
        }

        do {
            researchAuthorization = try researchGate.authorize(
                request,
                userApproved: true,
                now: Date()
            )
            let hosts = request.approvedHosts.sorted().joined(separator: ", ")
            discoveryStatus =
                "Approved \(hosts) for 15 minutes. Network fetch remains disabled in this milestone."
        } catch {
            discoveryStatus = researchErrorMessage(error)
        }
    }

    func refreshAccessibilityPermission() {
        accessibilityPermissionGranted = accessibilityPermission.isGranted()
        accessibilityStatus =
            accessibilityPermissionGranted
            ? "Accessibility permission granted. Execution remains disabled."
            : "Accessibility permission not granted. Preview remains available."
    }

    func requestAccessibilityPermission() {
        accessibilityPermissionGranted =
            accessibilityPermission.requestFromUser()
        accessibilityStatus =
            accessibilityPermissionGranted
            ? "Accessibility permission granted. Execution remains disabled."
            : "macOS permission requested. Approve Avatar Companion in System Settings, then check again."
    }

    func confirmApplicationAction() {
        guard let proposal = pendingApplicationProposal else {
            applicationActionStatus = "Preview an executable app command first."
            return
        }

        let now = Date()
        guard
            let proposalExpiry = applicationProposalExpiresAt,
            now < proposalExpiry
        else {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            applicationActionStatus = "Preview expired. Create it again."
            return
        }
        do {
            let currentApplication = try applicationResolver.resolveExact(
                named: proposal.command.requestedApplicationName
            )
            guard currentApplication.identity == proposal.application.identity else {
                applicationActionStatus =
                    "Installed app identity changed. Preview again."
                pendingApplicationProposal = nil
                applicationProposalExpiresAt = nil
                return
            }
            if proposal.command.operation == .switchToRunning,
                !currentApplication.isRunning
            {
                applicationActionStatus =
                    "Target app stopped running. Preview again."
                pendingApplicationProposal = nil
                applicationProposalExpiresAt = nil
                return
            }

            let executionProposal = ApplicationActionProposal(
                command: proposal.command,
                application: currentApplication,
                profile: proposal.profile,
                plan: proposal.plan
            )
            let consent = ConsentGrant(
                planID: proposal.plan.id,
                scopes: [],
                approvedAt: now,
                expiresAt: now.addingTimeInterval(30),
                oneShot: true
            )
            let validated = try PlanValidator().validate(
                plan: proposal.plan,
                profile: proposal.profile,
                consent: consent,
                safety: safety,
                userConfirmedPreview: true,
                now: now
            )
            guard consumedConsentGrantIDs.insert(consent.id).inserted else {
                applicationActionStatus = "One-shot consent was already used."
                return
            }

            let contract = ExecutionContract(
                validatedPlan: validated,
                issuedAt: now,
                expiresAt: consent.expiresAt
            )
            applicationAuditEvents.append(
                AuditEvent(
                    contractID: contract.id,
                    planID: proposal.plan.id,
                    timestamp: now,
                    outcome: .started
                )
            )
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            isExecutingApplicationAction = true
            applicationActionStatus =
                "macOS is performing one native app action. No input events are generated."

            nativeApplicationExecutor.execute(
                proposal: executionProposal,
                contract: contract,
                emergencyStopped: safety.emergencyStopped
            ) { [weak self] outcome in
                guard let self else { return }
                self.isExecutingApplicationAction = false
                self.applicationAuditEvents.append(
                    AuditEvent(
                        contractID: contract.id,
                        planID: proposal.plan.id,
                        timestamp: Date(),
                        outcome: self.redactedAuditOutcome(outcome)
                    )
                )
                self.applicationActionStatus =
                    self.applicationOutcomeMessage(
                        outcome,
                        appName:
                            executionProposal.application.identity.displayName
                    )
            }
        } catch PlanValidationError.observeOnly {
            applicationActionStatus =
                "Observe-only mode blocks execution. Turn it off, then confirm again."
        } catch PlanValidationError.emergencyStopped {
            applicationActionStatus =
                "Emergency stop blocks execution."
        } catch {
            applicationActionStatus =
                "Action changed or expired. Preview it again."
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
        }
    }

    func buildPreviewOnlyComputerUsePlan() {
        guard let app = discoveredApp else {
            discoveryStatus = "Identify an app before building a preview."
            return
        }

        let composition = foregroundComposer.compose(
            "preview save",
            target: app
        )
        guard case let .supported(intent) = composition else {
            discoveryStatus = "Built-in preview intent unavailable."
            return
        }
        buildPreview(for: intent)
    }

    private func composeForegroundCommand() {
        guard let app = discoveredApp else {
            status =
                "Not a local command. Identify the foreground app before requesting app actions."
            computerUsePreview = nil
            return
        }
        guard
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == app.bundleIdentifier
        else {
            status =
                "Foreground app changed. Identify it again before composing a plan."
            computerUsePreview = nil
            return
        }

        switch foregroundComposer.compose(command, target: app) {
        case let .supported(intent):
            buildPreview(for: intent)
            status =
                "Bound “\(intent.title)” to \(app.displayName). Review exact plan below; execution is disabled."
        case let .ambiguous(reason):
            computerUsePreview = nil
            status = "Ambiguous request: \(reason)"
        case let .unsupported(reason):
            computerUsePreview = nil
            status = "Unsupported request: \(reason)"
        }
    }

    private func previewApplicationCommand(
        _ parsed: ParsedApplicationCommand
    ) {
        previewedAction = nil
        computerUsePreview = nil

        do {
            let application = try applicationResolver.resolveExact(
                named: parsed.requestedApplicationName
            )
            let proposal = try applicationPlanner.propose(
                command: parsed,
                application: application,
                now: Date()
            )
            let previewConsent = ConsentGrant(
                planID: proposal.plan.id,
                scopes: [],
                approvedAt: Date(),
                expiresAt: Date().addingTimeInterval(60)
            )
            _ = try PlanValidator().validateForPreview(
                plan: proposal.plan,
                profile: proposal.profile,
                consent: previewConsent,
                userConfirmedPreview: true,
                now: Date()
            )

            pendingApplicationProposal = proposal
            applicationProposalExpiresAt = Date().addingTimeInterval(60)
            status =
                "Executable native app action prepared. Review exact target and confirm separately."
            applicationActionStatus =
                "Ready for one explicit confirmation. No Accessibility permission is required."
        } catch InstalledApplicationResolutionError.notFound {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status =
                "No installed app found with that exact name."
        } catch InstalledApplicationResolutionError.ambiguousExactName {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status =
                "Multiple installed apps share that exact name. This narrow milestone refuses ambiguous targets."
        } catch ApplicationProposalError.switchTargetNotRunning {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status =
                "Switch requires an already-running app. Use “open \(parsed.requestedApplicationName)” instead."
        } catch {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status = "Application action could not be planned safely."
        }
    }

    private func buildPreview(for intent: ComposedForegroundIntent) {
        let app = intent.target
        let now = Date()
        let permission = PermissionScope.accessibility(
            targetBundleIdentifier: app.bundleIdentifier
        )
        let capability = CapabilityDefinition(
            id: intent.capabilityID,
            name: intent.title,
            effectSummary: intent.effectPreviews.joined(separator: " "),
            adapter: .foregroundComputerUse,
            risk: .meaningful,
            requiredPermissions: [permission],
            evidence: .bundled
        )
        let profile = CapabilityProfile(
            app: app,
            capabilities: [capability],
            reviewedClaimIDs: [],
            approvedAt: now
        )
        let plan = ActionPlan(
            app: app,
            steps: zip(intent.steps, intent.effectPreviews).map {
                interaction, effect in
                PlannedStep(
                    capabilityID: capability.id,
                    targetBundleIdentifier: app.bundleIdentifier,
                    effectPreview: effect,
                    redactedParameterSummary:
                        interaction.previewDescription,
                    visibleInteraction: interaction
                )
            },
            createdAt: now
        )
        let consent = ConsentGrant(
            planID: plan.id,
            scopes: [permission],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(60),
            oneShot: true
        )

        do {
            let validated = try PlanValidator().validateForPreview(
                plan: plan,
                profile: profile,
                consent: consent,
                userConfirmedPreview: true,
                now: now
            )
            let contract = ComputerUsePreviewContract(
                validatedPlan: validated,
                issuedAt: now
            )
            let frontmostBundleIdentifier =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let preview = previewAdapter.render(
                contract,
                context: ExecutionContext(
                    frontmostBundleIdentifier: frontmostBundleIdentifier,
                    accessibilityPermissionGranted:
                        accessibilityPermissionGranted,
                    emergencyStopped: safety.emergencyStopped,
                    now: now
                )
            )
            computerUsePreview = preview
            previewAuditRecords.append(
                PreviewAuditRecord(preview: preview, renderedAt: now)
            )
            discoveryStatus =
                "Preview contract created and audited. It expires in 60 seconds and cannot execute."
        } catch {
            computerUsePreview = nil
            discoveryStatus = "Preview contract rejected: \(error)"
        }
    }

    private func execute(_ action: AvatarAction) {
        switch action {
        case .copyCurrentTime:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            let value = formatter.string(from: Date())

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            status = "Copied “\(value)” to clipboard."
            previewedAction = nil
            command = ""
        }
    }

    private func researchErrorMessage(_ error: Error) -> String {
        switch error {
        case ResearchBoundaryError.httpsRequired:
            "Only HTTPS documentation is eligible."
        case ResearchBoundaryError.exactHostRequired:
            "Enter one exact official host; wildcards are blocked."
        case ResearchBoundaryError.credentialsNotAllowed:
            "Credentials in documentation URLs are blocked."
        case ResearchBoundaryError.queryOrFragmentNotAllowed:
            "Remove query and fragment data before approval."
        case ResearchBoundaryError.invalidDocumentLimit:
            "Document limit must be between 1 and 10."
        default:
            "Research scope could not be prepared."
        }
    }

    private func redactedAuditOutcome(
        _ outcome: ExecutionOutcome
    ) -> ExecutionOutcome {
        switch outcome {
        case .started:
            .started
        case .succeeded:
            .succeeded
        case .cancelled:
            .cancelled
        case .denied:
            .denied("Native app action denied.")
        case .failed:
            .failed("Native app action failed.")
        }
    }

    private func applicationOutcomeMessage(
        _ outcome: ExecutionOutcome,
        appName: String
    ) -> String {
        switch outcome {
        case .succeeded:
            "\(appName) is now opening or foreground."
        case let .denied(reason):
            "Action denied: \(reason)"
        case let .failed(reason):
            "Action failed: \(reason)"
        case .cancelled:
            "Action cancelled."
        case .started:
            "Action started."
        }
    }
}
