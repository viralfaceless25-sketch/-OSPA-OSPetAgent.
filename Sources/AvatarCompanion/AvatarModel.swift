import AppKit
import AvatarCore
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

    var onExpansionChanged: ((Bool) -> Void)?
    var onHide: (() -> Void)?

    private let interpreter = CommandInterpreter()
    private let gate = ActionGate()
    private let researchGate = ResearchGate()
    private let accessibilityPermission = AccessibilityPermissionController()
    private let previewAdapter = PreviewOnlyForegroundAdapter()
    private let foregroundComposer = ForegroundCommandComposer()

    func toggleExpanded() {
        isExpanded.toggle()
        onExpansionChanged?(isExpanded)
    }

    func previewCommand() {
        switch interpreter.interpret(command) {
        case .help:
            previewedAction = nil
            status =
                "Try “copy time”, “focus this app”, “preview save”, or “preview find”."
        case .rejected:
            previewedAction = nil
            composeForegroundCommand()
        case let .action(action):
            previewedAction = action
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
        command = ""
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
}
