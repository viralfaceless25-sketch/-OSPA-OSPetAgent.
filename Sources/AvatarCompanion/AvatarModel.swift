import AppKit
import AvatarCore
import AvatarPlatform
import Foundation

@MainActor
final class AvatarModel: ObservableObject {
    private enum BrainProposalBinding {
        case application(planID: UUID, reason: String)
        case taskSequence(sequenceID: UUID)

        var reason: String? {
            guard case let .application(_, reason) = self else { return nil }
            return reason
        }
    }

    private struct TaskSequencePreviewRequest {
        let command: ParsedApplicationCommand
        let reason: String?
    }

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
    @Published private(set) var computerUseAuditEvents: [AuditEvent] = []
    @Published var isExecutingComputerUseAction = false
    @Published var pendingTaskSequence: TaskSequence? {
        didSet {
            clearBrainBindingIfDetached()
            scheduleTaskSequenceExpiry()
        }
    }
    @Published private(set) var taskSequenceOutcomes: [TaskSequenceStepOutcome] = []
    @Published var isExecutingTaskSequence = false
    @Published var taskSequenceStatus =
        "Ask for two or three things at once, like “open Safari and open Notes”."
    @Published var computerUseActionStatus =
        "No visible foreground action is pending."
    @Published var accessibilityInspectionRequest: AccessibilityInspectionRequest?
    @Published var accessibilityUISnapshot: AccessibilityUISnapshot?
    @Published var accessibilityInteractionPreview: AccessibilityInteractionPreview?
    @Published var accessibilityInspectionStatus =
        "No Accessibility UI inspection is prepared."
    @Published private(set) var accessibilityInspectionAuditRecords:
        [AccessibilityInspectionAuditRecord] = []
    @Published var accessibilityInspectionRequestConsumed = false
    @Published var pendingApplicationProposal: ApplicationActionProposal? {
        didSet { clearBrainBindingIfDetached() }
    }
    @Published var applicationProposalExpiresAt: Date?
    @Published var applicationActionStatus =
        "Executable app commands: “open Safari” or “switch to Notes”. Follow-up goals preview only."
    @Published private(set) var applicationAuditEvents: [AuditEvent] = []
    @Published var isExecutingApplicationAction = false
    @Published var pendingApplicationSequence: ApplicationSequenceProposal?
    @Published var applicationSequenceFirstStepCompleted = false
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    @Published var draftSearchScopes: Set<LocalSearchScopeID> = [.applications]
    @Published private(set) var searchAuthorization: LocalSearchAuthorization?
    @Published private(set) var searchCandidates: [LocalSearchCandidate] = []
    @Published var searchStatus =
        "Open search, review metadata scope, then approve this session."
    @Published var spotlightOpenPreview: SpotlightOpenPreview?
    @Published var pendingLocalItemOpenPlan: LocalItemOpenPlan?
    @Published var localItemActionStatus =
        "No file or folder action is pending."
    @Published private(set) var localItemAuditEvents: [AuditEvent] = []
    @Published var isExecutingLocalItemAction = false
    @Published var isBrainEnabled = false
    @Published var isBrainThinking = false
    @Published var brainStatus = "Natural language is off. Type exact commands."
    var brainReason: String? { brainProposalBinding?.reason }

    var onExpansionChanged: ((Bool) -> Void)?
    var onHide: (() -> Void)?

    private let interpreter = CommandInterpreter()
    private let gate = ActionGate()
    private let researchGate = ResearchGate()
    private let accessibilityPermission = AccessibilityPermissionController()
    private let accessibilityUIInspector = AccessibilityUIInspector()
    private let previewAdapter = PreviewOnlyForegroundAdapter()
    private let foregroundComposer = ForegroundCommandComposer()
    private let applicationCommandParser = ApplicationCommandParser()
    private let applicationSequenceParser = ApplicationSequenceParser()
    private let applicationResolver = InstalledApplicationResolver()
    private let applicationPlanner = ApplicationActionPlanner()
    private let applicationSequencePlanner = ApplicationSequencePlanner()
    private let nativeApplicationExecutor = NativeApplicationExecutor()
    private let metadataSearch = LocalMetadataSearchService()
    private let nativeLocalItemExecutor = NativeLocalItemExecutor()
    private let searchRanker = LocalSearchRanker()
    private let searchScopePolicy = LocalSearchScopePolicy()
    private let computerUseConsentLedger = ConsentUseLedger()
    private lazy var computerUseAdapter = RealForegroundInputAdapter(
        probe: SystemForegroundEnvironmentProbe(
            isEmergencyStopped: { [weak self] in
                self?.safety.emergencyStopped ?? true
            }
        ),
        accessibilityPerformer: SystemAccessibilityActionPerformer(),
        keyboardPerformer: SystemKeyboardShortcutPerformer(),
        activationPerformer: SystemForegroundActivationPerformer(),
        consentLedger: computerUseConsentLedger
    )
    private lazy var taskSequenceApplicationAdapter =
        NativeApplicationPlanAdapter(
            isEmergencyStopped: { [weak self] in
                self?.safety.emergencyStopped ?? true
            }
        )
    private let taskSequenceCommandParser = TaskSequenceCommandParser()
    private let taskSequenceValidator = TaskSequenceValidator()
    private let taskSequenceRunner = TaskSequenceRunner()
    private let brainValidator = BrainProposalValidator()
    private let usageSource: any ApplicationUsageSource
    private let brainService: any LocalBrainService
    private let brainIntentRouter: any LocalBrainIntentRouting
    private let brainChatService: any LocalBrainChatService
    private let brainServerController: LocalBrainServerController
    private let brainIdleShutdownInterval: TimeInterval
    private let frontmostBundleIdentifier: @MainActor @Sendable () -> String?
    private var pendingComputerUsePlan: ActionPlan?
    private var pendingComputerUseProfile: CapabilityProfile?
    private var consumedConsentGrantIDs = Set<UUID>()
    private var consumedInspectionRequestIDs = Set<UUID>()
    private var indexedApplications: [ResolvedApplication] = []
    private var personalSearchItems: [LocalSearchItem] = []
    private var brainProposalBinding: BrainProposalBinding?
    private var brainTask: Task<Void, Never>?
    private var brainIdleShutdownTask: Task<Void, Never>?
    private var taskSequenceExpiryTask: Task<Void, Never>?

    init(
        usageSource: any ApplicationUsageSource = SpotlightApplicationUsageSource(),
        brainService: any LocalBrainService = MLXBrainClient(),
        brainIntentRouter: any LocalBrainIntentRouting = MLXBrainClient(),
        brainChatService: any LocalBrainChatService = MLXBrainClient(),
        brainServerController: LocalBrainServerController? = nil,
        brainIdleShutdownInterval: TimeInterval = 300,
        frontmostBundleIdentifier: @MainActor @Sendable @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.usageSource = usageSource
        self.brainService = brainService
        self.brainIntentRouter = brainIntentRouter
        self.brainChatService = brainChatService
        self.brainServerController =
            brainServerController ?? Self.makeLiveBrainServerController()
        self.brainIdleShutdownInterval = brainIdleShutdownInterval
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
    }

    func toggleExpanded() {
        isExpanded.toggle()
        onExpansionChanged?(isExpanded)
    }

    func openSearch() {
        if !isExpanded {
            toggleExpanded()
        }
        spotlightOpenPreview = nil
        pendingLocalItemOpenPlan = nil
        pendingApplicationSequence = nil
        applicationSequenceFirstStepCompleted = false
        isSearchPresented = true
        searchQuery = ""
        draftSearchScopes = [.applications]
        searchAuthorization = nil
        searchCandidates = []
        personalSearchItems = []
        searchStatus =
            "Applications metadata only. Add personal scopes if wanted, then approve for 15 minutes."
    }

    func closeSearch() {
        isSearchPresented = false
        metadataSearch.cancel()
    }

    func setDraftSearchScope(
        _ scope: LocalSearchScopeID,
        enabled: Bool
    ) {
        guard scope != .applications else { return }
        if enabled {
            draftSearchScopes.insert(scope)
        } else {
            draftSearchScopes.remove(scope)
        }
        searchAuthorization = nil
        searchCandidates = []
        personalSearchItems = []
        metadataSearch.cancel()
        searchStatus =
            "Scope changed. Review and approve it before searching."
    }

    func approveSearchScopes() {
        do {
            searchAuthorization = try searchScopePolicy.authorize(
                scopes: draftSearchScopes,
                userApproved: true,
                now: Date()
            )
            searchStatus =
                "Approved metadata scopes for 15 minutes. Indexing application bundles…"
            applicationResolver.loadIndex { [weak self] applications, complete in
                guard let self else { return }
                self.indexedApplications = applications
                self.updateSearchResults()
                if self.searchQuery.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    self.searchStatus =
                        complete
                        ? "Ready. Search exact names across approved metadata scopes."
                        : "Applications ready; registered app metadata is still loading."
                }
            }
        } catch {
            searchAuthorization = nil
            searchStatus = "Search scope approval failed."
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        personalSearchItems = []
        updateSearchResults()

        guard let authorization = validSearchAuthorization() else {
            metadataSearch.cancel()
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let personalScopes = authorization.approvedScopes.filter(\.isPersonal)
        guard trimmed.count >= 2, !personalScopes.isEmpty else {
            metadataSearch.cancel()
            if !personalScopes.isEmpty, !trimmed.isEmpty {
                searchStatus =
                    "Enter at least two characters before personal metadata search."
            }
            return
        }

        searchStatus = "Searching matching names in approved metadata scopes…"
        metadataSearch.search(
            nameQuery: trimmed,
            approvedScopes: authorization.approvedScopes
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(items):
                self.personalSearchItems = items
                self.updateSearchResults()
                self.searchStatus =
                    "Found \(self.searchCandidates.count) ranked exact local candidates."
            case .failure(.queryTooShort):
                self.searchStatus =
                    "Enter at least two characters before personal metadata search."
            case .failure(.noPersonalScope):
                self.searchStatus =
                    "Only application bundle metadata is approved."
            case .failure:
                self.searchStatus =
                    "macOS could not read that approved metadata scope. No broader scan was attempted."
            }
        }
    }

    func selectSearchCandidate(_ candidate: LocalSearchCandidate) {
        guard let authorization = validSearchAuthorization() else { return }
        do {
            try searchScopePolicy.validate(
                item: candidate.item,
                authorization: authorization,
                now: Date()
            )
        } catch {
            searchStatus = "Search approval expired or does not cover that result."
            return
        }

        // Selecting an exact result replaces every brain-originated preview
        // and cancels an in-flight result before it can publish over the
        // user's newer choice.
        cancelBrainProposal()
        spotlightOpenPreview = SpotlightOpenPreview(item: candidate.item)
        previewedAction = nil
        computerUsePreview = nil
        clearAccessibilityInspection()
        pendingApplicationProposal = nil
        applicationProposalExpiresAt = nil
        pendingLocalItemOpenPlan = nil

        if candidate.item.kind == .application,
            let application = indexedApplications.first(where: {
                $0.applicationURL.standardizedFileURL
                    == candidate.item.url.standardizedFileURL
            })
        {
            let command = ParsedApplicationCommand(
                operation: .launchOrActivate,
                requestedApplicationName:
                    application.identity.displayName
            )
            prepareApplicationProposal(
                command,
                application: application
            )
        } else {
            let now = Date()
            pendingLocalItemOpenPlan = LocalItemOpenPlan(
                item: candidate.item,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            )
            localItemActionStatus =
                "Native exact-item fallback ready for separate confirmation."
            status =
                "Selected exact \(candidate.item.kind.rawValue). Review both routes below."
        }
        isSearchPresented = false
        searchStatus =
            "Selected exact result \(candidate.item.name). No action ran."
    }

    func previewCommand() {
        cancelBrainProposal()
        spotlightOpenPreview = nil
        pendingLocalItemOpenPlan = nil
        pendingApplicationSequence = nil
        applicationSequenceFirstStepCompleted = false
        pendingTaskSequence = nil

        // A request whose every clause is executable becomes one ordered chain.
        // Anything else falls through to the existing single-command and
        // deferred-goal handling below.
        switch taskSequenceCommandParser.parse(command) {
        case let .sequence(commands):
            previewTaskSequence(commands)
            return
        case let .rejected(reason):
            previewedAction = nil
            status = "Multi-step request rejected: \(reason)"
            return
        case .notSequence:
            break
        }

        switch applicationSequenceParser.parse(command) {
        case let .sequence(sequence):
            previewApplicationSequence(sequence)
            return
        case let .rejected(reason):
            previewedAction = nil
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status = "Multi-step plan rejected: \(reason)"
            return
        case .notSequence:
            break
        }

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
                "Try “copy time”, “open Netflix and continue playing One Piece”, “focus this app”, or “preview save”."
        case .rejected:
            previewedAction = nil
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            let handledDeterministically = composeForegroundCommand(
                reportUnsupported: !isBrainEnabled
            )
            if !handledDeterministically, isBrainEnabled {
                // Deterministic parsing already declined, so ask the local model
                // which lane this belongs to. Typed exact commands never reach
                // this path, and classification never chooses an app itself.
                startBrainRouting(for: command)
            }
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

    func setBrainEnabled(_ enabled: Bool) {
        isBrainEnabled = enabled
        if enabled {
            brainStatus = "Natural language is on. Type what you want in ordinary words."
        } else {
            cancelBrainProposal()
            brainStatus = "Natural language is off. Type exact commands."
            brainIdleShutdownTask?.cancel()
            brainIdleShutdownTask = nil
            Task { await brainServerController.shutdown() }
        }
    }

    func emergencyStop() {
        safety.emergencyStopped = true
        safety.observeOnly = true
        previewedAction = nil
        cancelBrainProposal()
        brainIdleShutdownTask?.cancel()
        brainIdleShutdownTask = nil
        brainStatus = "Emergency stop active. Thinking cancelled."
        Task { await brainServerController.shutdown() }
        clearPendingComputerUsePlan()
        clearAccessibilityInspection()
        pendingApplicationProposal = nil
        applicationProposalExpiresAt = nil
        pendingApplicationSequence = nil
        applicationSequenceFirstStepCompleted = false
        pendingTaskSequence = nil
        taskSequenceStatus =
            "Emergency stop active. Pending multi-step request cleared."
        pendingLocalItemOpenPlan = nil
        spotlightOpenPreview = nil
        searchAuthorization = nil
        searchCandidates = []
        personalSearchItems = []
        isSearchPresented = false
        searchQuery = ""
        metadataSearch.cancel()
        command = ""
        applicationActionStatus = "Emergency stop active. Pending app action cleared."
        localItemActionStatus =
            "Emergency stop active. Pending local item action cleared."
        status = "Stopped. All actions blocked."
    }

    func resumeObservation() {
        safety = .initial
        status = "Emergency stop cleared. Observe-only mode remains on."
        brainStatus = isBrainEnabled
            ? "Natural language is on. Type what you want in ordinary words."
            : "Natural language is off. Type exact commands."
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
        clearPendingComputerUsePlan()
        clearAccessibilityInspection()
        computerUseActionStatus = "No visible foreground action is pending."
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
        if !accessibilityPermissionGranted {
            clearAccessibilityInspection()
        }
        accessibilityStatus =
            accessibilityPermissionGranted
            ? "Accessibility permission granted. Inspection and any action each still need separate approval."
            : "Accessibility permission not granted. Preview remains available."
    }

    func requestAccessibilityPermission() {
        accessibilityPermissionGranted =
            accessibilityPermission.requestFromUser()
        accessibilityStatus =
            accessibilityPermissionGranted
            ? "Accessibility permission granted. Inspection and any action each still need separate approval."
            : "macOS permission requested. Approve Avatar Companion in System Settings, then check again."
    }

    func prepareAccessibilityInspection() {
        guard !safety.emergencyStopped else {
            accessibilityInspectionStatus =
                "Emergency stop blocks inspection preparation."
            return
        }
        guard let app = discoveredApp else {
            accessibilityInspectionStatus =
                "Identify the foreground app before preparing inspection."
            return
        }
        guard accessibilityPermissionGranted else {
            accessibilityInspectionStatus =
                "Use Check or Request from macOS first. No inspection was prepared."
            return
        }
        guard
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == app.bundleIdentifier
        else {
            accessibilityInspectionStatus =
                "Foreground app changed. Identify it again before preparing inspection."
            return
        }

        let now = Date()
        accessibilityInspectionRequest = AccessibilityInspectionRequest(
            target: app,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        accessibilityUISnapshot = nil
        accessibilityInteractionPreview = nil
        accessibilityInspectionRequestConsumed = false
        accessibilityInspectionStatus =
            "Review exact target, 20-control/60-element cap, redaction, and 60-second expiry. Nothing was read yet."
    }

    func approveAndInspectAccessibility() {
        guard let request = accessibilityInspectionRequest else {
            accessibilityInspectionStatus =
                "Prepare an inspection scope first."
            return
        }
        guard !accessibilityInspectionRequestConsumed else {
            accessibilityInspectionStatus =
                "This one-shot inspection was already used. Prepare a new scope."
            return
        }

        let now = Date()
        let permissionGranted = accessibilityPermission.isGranted()
        accessibilityPermissionGranted = permissionGranted
        let frontmost = NSWorkspace.shared.frontmostApplication
        let consent = ConsentGrant(
            planID: request.id,
            scopes: [
                .accessibility(
                    targetBundleIdentifier:
                        request.target.bundleIdentifier
                )
            ],
            approvedAt: now,
            expiresAt: min(
                request.expiresAt,
                now.addingTimeInterval(30)
            ),
            oneShot: true
        )

        do {
            let validated = try AccessibilityInspectionValidator()
                .validate(
                    request: request,
                    consent: consent,
                    context: AccessibilityInspectionContext(
                        frontmostBundleIdentifier:
                            frontmost?.bundleIdentifier,
                        accessibilityPermissionGranted:
                            permissionGranted,
                        emergencyStopped: safety.emergencyStopped,
                        now: now
                    ),
                    userApproved: true
                )
            guard
                consumedInspectionRequestIDs.insert(request.id)
                    .inserted
            else {
                accessibilityInspectionRequestConsumed = true
                accessibilityInspectionStatus =
                    "This inspection scope was already consumed."
                return
            }
            accessibilityInspectionRequestConsumed = true
            accessibilityInspectionAuditRecords.append(
                AccessibilityInspectionAuditRecord(
                    requestID: request.id,
                    targetBundleIdentifier:
                        request.target.bundleIdentifier,
                    timestamp: now,
                    outcome: .started
                )
            )
            guard let processIdentifier = frontmost?.processIdentifier else {
                recordAccessibilityInspectionFailure(
                    request: request,
                    at: now
                )
                accessibilityInspectionStatus =
                    "Exact foreground process became unavailable. Nothing was inspected."
                return
            }

            switch accessibilityUIInspector.inspect(
                processIdentifier: processIdentifier,
                validated: validated,
                capturedAt: now
            ) {
            case let .success(snapshot):
                accessibilityUISnapshot = snapshot
                accessibilityInteractionPreview =
                    AccessibilityInteractionPreview(
                        snapshot: snapshot
                    )
                accessibilityInspectionAuditRecords.append(
                    AccessibilityInspectionAuditRecord(
                        requestID: request.id,
                        targetBundleIdentifier:
                            request.target.bundleIdentifier,
                        timestamp: Date(),
                        outcome: .succeeded(
                            controlCount: snapshot.controls.count,
                            truncated: snapshot.truncated
                        )
                    )
                )
                accessibilityInspectionStatus =
                    snapshot.controls.isEmpty
                    ? "The app exposed no supported accessible controls in this bounded snapshot. No broader or pixel inspection was attempted."
                    : "Captured \(snapshot.controls.count) redacted control summaries. Evidence preview cannot execute."
            case .failure(.permissionDenied):
                recordAccessibilityInspectionFailure(
                    request: request,
                    at: Date()
                )
                accessibilityInspectionStatus =
                    "macOS Accessibility permission is unavailable. Prepare a new scope after granting permission."
            case .failure(.targetNoLongerForeground):
                recordAccessibilityInspectionFailure(
                    request: request,
                    at: Date()
                )
                accessibilityInspectionStatus =
                    "Foreground focus changed during inspection. Partial metadata was discarded."
            case .failure(.targetUnavailable):
                recordAccessibilityInspectionFailure(
                    request: request,
                    at: Date()
                )
                accessibilityInspectionStatus =
                    "The target exposed no readable Accessibility root. It may not support accessible controls in its current state."
            case .failure(.inspectionFailed):
                recordAccessibilityInspectionFailure(
                    request: request,
                    at: Date()
                )
                accessibilityInspectionStatus =
                    "Accessibility inspection failed without retaining partial metadata."
            }
        } catch AccessibilityInspectionValidationError.targetNotForeground {
            recordAccessibilityInspectionDenied(request: request, at: now)
            accessibilityInspectionStatus =
                "Foreground app no longer matches the approved bundle ID. Nothing was inspected."
        } catch AccessibilityInspectionValidationError
            .accessibilityPermissionMissing
        {
            recordAccessibilityInspectionDenied(request: request, at: now)
            accessibilityInspectionStatus =
                "macOS Accessibility permission is not granted. Nothing was inspected."
        } catch AccessibilityInspectionValidationError.requestExpired {
            recordAccessibilityInspectionDenied(request: request, at: now)
            accessibilityInspectionStatus =
                "Inspection approval expired. Prepare a new scope."
        } catch AccessibilityInspectionValidationError.emergencyStopped {
            recordAccessibilityInspectionDenied(request: request, at: now)
            accessibilityInspectionStatus =
                "Emergency stop blocks Accessibility inspection."
        } catch {
            recordAccessibilityInspectionDenied(request: request, at: now)
            accessibilityInspectionStatus =
                "Inspection preflight rejected the request. Nothing was inspected."
        }
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
                url: proposal.application.applicationURL,
                identity: proposal.application.identity
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
                if self.pendingApplicationSequence?
                    .applicationProposal.plan.id == proposal.plan.id
                {
                    if outcome == .succeeded {
                        self.applicationSequenceFirstStepCompleted = true
                        self.status =
                            "Step 1 completed. Step 2 remains unsupported, was not attempted, and is not queued."
                        self.applicationActionStatus +=
                            " Deferred app goal was not attempted."
                    } else {
                        self.status =
                            "Step 1 did not complete. Step 2 remains unsupported and was not attempted."
                    }
                }
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

    func confirmLocalItemAction() {
        guard
            let plan = pendingLocalItemOpenPlan,
            let authorization = searchAuthorization
        else {
            localItemActionStatus = "Select one exact file or folder first."
            return
        }

        let now = Date()
        let consent = ConsentGrant(
            planID: plan.id,
            scopes: [],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30),
            oneShot: true
        )
        do {
            let validated = try LocalItemOpenValidator().validate(
                plan: plan,
                authorization: authorization,
                consent: consent,
                safety: safety,
                userConfirmedPreview: true,
                now: now
            )
            guard consumedConsentGrantIDs.insert(consent.id).inserted else {
                localItemActionStatus = "One-shot consent was already used."
                return
            }
            let contract = LocalItemOpenExecutionContract(
                validated: validated,
                issuedAt: now,
                expiresAt: consent.expiresAt
            )
            localItemAuditEvents.append(
                AuditEvent(
                    contractID: contract.id,
                    planID: plan.id,
                    timestamp: now,
                    outcome: .started
                )
            )
            pendingLocalItemOpenPlan = nil
            isExecutingLocalItemAction = true
            localItemActionStatus =
                "macOS is opening one exact local item. No input events are generated."

            nativeLocalItemExecutor.execute(
                contract: contract,
                emergencyStopped: safety.emergencyStopped
            ) { [weak self] outcome in
                guard let self else { return }
                self.isExecutingLocalItemAction = false
                let auditOutcome: ExecutionOutcome
                switch outcome {
                case .succeeded:
                    auditOutcome = .succeeded
                    self.localItemActionStatus =
                        "\(plan.item.name) is now opening."
                case .blocked:
                    auditOutcome = .denied("Local item action denied.")
                    self.localItemActionStatus =
                        "Emergency stop blocked the action."
                case .expired:
                    auditOutcome = .denied("Local item contract expired.")
                    self.localItemActionStatus =
                        "Confirmation expired. Select the result again."
                case .targetChanged:
                    auditOutcome = .denied("Local item identity changed.")
                    self.localItemActionStatus =
                        "Item moved or changed. Search and select it again."
                case .failed:
                    auditOutcome = .failed("Local item open failed.")
                    self.localItemActionStatus =
                        "macOS could not open that exact item."
                }
                self.localItemAuditEvents.append(
                    AuditEvent(
                        contractID: contract.id,
                        planID: plan.id,
                        timestamp: Date(),
                        outcome: auditOutcome
                    )
                )
            }
        } catch LocalItemOpenValidationError.observeOnly {
            localItemActionStatus =
                "Observe-only mode blocks execution. Turn it off, then confirm again."
        } catch LocalItemOpenValidationError.emergencyStopped {
            localItemActionStatus = "Emergency stop blocks execution."
        } catch LocalItemOpenValidationError.expired,
            LocalSearchAuthorizationError.expired
        {
            pendingLocalItemOpenPlan = nil
            localItemActionStatus =
                "Search or action approval expired. Search again."
        } catch {
            pendingLocalItemOpenPlan = nil
            localItemActionStatus =
                "Exact-item preflight changed. Search and select again."
        }
    }

    var taskSequenceExecutionReady: Bool {
        guard let sequence = pendingTaskSequence,
            !safety.observeOnly,
            !safety.emergencyStopped,
            !isExecutingTaskSequence
        else {
            return false
        }
        return Date() < sequence.expiresAt
    }

    /// Builds one ordered chain from a multi-clause request. Nothing runs here;
    /// the user sees every step first and confirms the chain as a whole.
    private func previewTaskSequence(
        _ commands: [ParsedApplicationCommand]
    ) {
        _ = previewTaskSequence(
            commands.map {
                TaskSequencePreviewRequest(command: $0, reason: nil)
            }
        )
    }

    /// Plans into a local array and publishes only after every request succeeds.
    /// A model-produced chain therefore cannot expose a valid prefix when a
    /// later target fails resolution or planning.
    @discardableResult
    private func previewTaskSequence(
        _ requests: [TaskSequencePreviewRequest]
    ) -> TaskSequence? {
        previewedAction = nil
        clearPendingComputerUsePlan()
        pendingApplicationProposal = nil
        applicationProposalExpiresAt = nil
        pendingApplicationSequence = nil
        applicationSequenceFirstStepCompleted = false
        pendingTaskSequence = nil
        taskSequenceOutcomes = []

        let now = Date()
        var steps: [SequencedPlan] = []

        for (index, request) in requests.enumerated() {
            do {
                let application = try applicationResolver.resolveExact(
                    named: request.command.requestedApplicationName
                )
                let proposal = try applicationPlanner.propose(
                    command: request.command,
                    application: application,
                    now: now
                )
                let action =
                    "\(request.command.operation == .switchToRunning ? "Switch to" : "Open") \(application.identity.displayName)"
                let summary = request.reason.map { "\(action) — \($0)" } ?? action
                steps.append(
                    SequencedPlan(
                        summary: summary,
                        plan: proposal.plan,
                        profile: proposal.profile
                    )
                )
            } catch {
                pendingTaskSequence = nil
                taskSequenceStatus = taskSequenceStepFailureMessage(
                    error,
                    index: index,
                    total: requests.count,
                    requestedName: request.command.requestedApplicationName
                )
                status = "That multi-step request was not prepared."
                return nil
            }
        }

        let sequence = TaskSequence(
            steps: steps,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        pendingTaskSequence = sequence
        status =
            "Prepared \(steps.count) requests. Review them, then confirm once to run them in order."
        taskSequenceStatus =
            "Nothing runs until you confirm. Each step is checked again as it starts."
        return sequence
    }

    func confirmTaskSequence() {
        guard let sequence = pendingTaskSequence else {
            taskSequenceStatus = "Prepare a multi-step request first."
            return
        }

        do {
            let validated = try taskSequenceValidator.validate(
                sequence: sequence,
                safety: safety,
                userConfirmed: true,
                now: Date()
            )
            pendingTaskSequence = nil
            taskSequenceOutcomes = []
            isExecutingTaskSequence = true
            taskSequenceStatus =
                "Running \(validated.sequence.steps.count) requests in order…"

            let adapter = taskSequenceApplicationAdapter
            Task { [weak self] in
                guard let self else { return }
                let result = await taskSequenceRunner.run(
                    validated,
                    adapter: adapter,
                    isEmergencyStopped: { [weak self] in
                        await self?.safety.emergencyStopped ?? true
                    },
                    now: { Date() },
                    onStepOutcome: { [weak self] outcome in
                        await self?.appendTaskSequenceOutcome(outcome)
                    }
                )
                self.isExecutingTaskSequence = false
                self.taskSequenceStatus = self.taskSequenceResultMessage(result)
            }
        } catch TaskSequenceValidationError.observeOnly {
            taskSequenceStatus =
                "Observe-only mode blocks execution. Turn it off, then confirm again."
        } catch TaskSequenceValidationError.emergencyStopped {
            taskSequenceStatus = "Emergency stop blocks execution."
        } catch TaskSequenceValidationError.sequenceExpired {
            pendingTaskSequence = nil
            taskSequenceStatus = "That request expired. Ask again."
        } catch let TaskSequenceValidationError.stepRejected(index) {
            pendingTaskSequence = nil
            taskSequenceStatus =
                "Request \(index + 1) is no longer valid. Ask again."
        } catch {
            pendingTaskSequence = nil
            taskSequenceStatus = "That request could not be prepared safely."
        }
    }

    private func appendTaskSequenceOutcome(_ outcome: TaskSequenceStepOutcome) {
        taskSequenceOutcomes.append(outcome)
        computerUseAuditEvents.append(
            AuditEvent(
                contractID: UUID(),
                planID: outcome.planID,
                timestamp: Date(),
                outcome: redactedComputerUseOutcome(outcome.outcome)
            )
        )
    }

    private func taskSequenceResultMessage(
        _ result: TaskSequenceResult
    ) -> String {
        switch result {
        case let .completed(outcomes):
            return "Done. All \(outcomes.count) requests finished."
        case let .halted(index, outcomes):
            let reason: String
            switch outcomes.last?.outcome {
            case let .denied(message), let .failed(message):
                reason = message
            default:
                reason = "It could not be completed."
            }
            return
                "Stopped at request \(index + 1). \(reason) The remaining requests were not attempted."
        }
    }

    private func taskSequenceStepFailureMessage(
        _ error: Error,
        index: Int,
        total: Int,
        requestedName: String
    ) -> String {
        let prefix = "Request \(index + 1) of \(total):"
        switch error {
        case InstalledApplicationResolutionError.notFound:
            return "\(prefix) no installed app is named “\(requestedName)”."
        case InstalledApplicationResolutionError.ambiguousExactName:
            return
                "\(prefix) several apps share the name “\(requestedName)”. Use Search this Mac to pick one."
        case ApplicationProposalError.switchTargetNotRunning:
            return
                "\(prefix) “\(requestedName)” is not running, so it cannot be switched to. Say “open \(requestedName)” instead."
        default:
            return "\(prefix) it could not be planned safely."
        }
    }

    /// True only when a real plan is pending and every gate currently allows it.
    /// The preview itself stays non-executable; this drives the separate
    /// confirmation affordance.
    var computerUseExecutionReady: Bool {
        guard let preview = computerUsePreview,
            pendingComputerUsePlan != nil,
            preview.readinessIssues.isEmpty,
            !safety.observeOnly,
            !safety.emergencyStopped,
            !isExecutingComputerUseAction
        else {
            return false
        }
        return Date() < preview.expiresAt
    }

    func confirmComputerUseAction() {
        guard
            let plan = pendingComputerUsePlan,
            let profile = pendingComputerUseProfile
        else {
            computerUseActionStatus = "Create a plan before confirming."
            return
        }

        let now = Date()
        let permission = PermissionScope.accessibility(
            targetBundleIdentifier: plan.app.bundleIdentifier
        )
        let consent = ConsentGrant(
            planID: plan.id,
            scopes: [permission],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30),
            oneShot: true
        )

        do {
            let validated = try PlanValidator().validate(
                plan: plan,
                profile: profile,
                consent: consent,
                safety: safety,
                userConfirmedPreview: true,
                now: now
            )
            let contract = ExecutionContract(
                validatedPlan: validated,
                issuedAt: now,
                expiresAt: consent.expiresAt
            )
            computerUseAuditEvents.append(
                AuditEvent(
                    contractID: contract.id,
                    planID: plan.id,
                    timestamp: now,
                    outcome: .started
                )
            )
            clearPendingComputerUsePlan()
            isExecutingComputerUseAction = true
            computerUseActionStatus =
                "Performing the visible steps in \(plan.app.displayName). Keep it in front."

            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.computerUseAdapter.execute(contract)
                self.isExecutingComputerUseAction = false
                self.computerUseAuditEvents.append(
                    AuditEvent(
                        contractID: contract.id,
                        planID: plan.id,
                        timestamp: Date(),
                        outcome: self.redactedComputerUseOutcome(outcome)
                    )
                )
                self.computerUseActionStatus =
                    self.computerUseOutcomeMessage(outcome)
            }
        } catch PlanValidationError.observeOnly {
            computerUseActionStatus =
                "Observe-only mode blocks execution. Turn it off, then confirm again."
        } catch PlanValidationError.emergencyStopped {
            computerUseActionStatus = "Emergency stop blocks execution."
        } catch {
            clearPendingComputerUsePlan()
            computerUseActionStatus =
                "The plan no longer validates. Create it again."
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

    @discardableResult
    private func composeForegroundCommand(
        reportUnsupported: Bool = true
    ) -> Bool {
        guard let app = discoveredApp else {
            if reportUnsupported {
                status =
                    "Not a local command. Identify the foreground app before requesting app actions."
            }
            computerUsePreview = nil
            return false
        }
        guard
            frontmostBundleIdentifier() == app.bundleIdentifier
        else {
            status =
                "Foreground app changed. Identify it again before composing a plan."
            computerUsePreview = nil
            return true
        }

        switch foregroundComposer.compose(command, target: app) {
        case let .supported(intent):
            buildPreview(for: intent)
            status =
                "Bound “\(intent.title)” to \(app.displayName). Review exact plan below; execution is disabled."
            return true
        case let .ambiguous(reason):
            computerUsePreview = nil
            status = "Ambiguous request: \(reason)"
            return true
        case let .unsupported(reason):
            computerUsePreview = nil
            if reportUnsupported {
                status = "Unsupported request: \(reason)"
            }
            return false
        }
    }

    /// Asks the local model to interpret plain language, then treats its answer
    /// as untrusted input. A validated proposal enters the same preview path a
    /// typed command uses, so confirmation and every downstream gate stay intact.
    /// Honest copy for a request no installed capability can serve. Fixed text,
    /// never model-authored, so an unsupported answer cannot be influenced by
    /// the request that triggered it.
    private static let unsupportedRequestMessage =
        "I can’t browse the web or use current online information yet. "
        + "I can open or switch Mac apps, or chat about things that don’t need "
        + "current information."

    /// Classifies which lane a request belongs to before any action is
    /// considered. The router is given no application inventory and no
    /// argument-bearing tools, so it can only pick a lane — it cannot name an
    /// app, author arguments, build a plan, or execute anything. The
    /// `nativeApp` lane hands straight to the unchanged proposal path, where
    /// `BrainProposalValidator` remains the sole safety authority.
    private func startBrainRouting(for request: String) {
        brainTask?.cancel()
        brainIdleShutdownTask?.cancel()
        brainIdleShutdownTask = nil
        clearBrainOriginatedProposal()
        isBrainThinking = true
        brainStatus = "Thinking…"

        let router = brainIntentRouter
        let serverController = brainServerController

        brainTask = Task { [weak self] in
            let outcome: Result<LocalBrainIntentLane, any Error>
            do {
                guard await serverController.ensureReady() == .ready else {
                    throw LocalBrainError.unavailable
                }
                let lane = try await serverController.withTrackedRequest {
                    try await router.route(request: request)
                }
                outcome = .success(lane)
            } catch {
                outcome = .failure(error)
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishBrainRouting(outcome, for: request)
            }
        }
    }

    private func finishBrainRouting(
        _ outcome: Result<LocalBrainIntentLane, any Error>,
        for request: String
    ) {
        brainTask = nil

        // A late result must never publish after the user turned the brain off
        // or hit Emergency Stop; both paths already set their own status.
        guard isBrainEnabled, !safety.emergencyStopped else {
            isBrainThinking = false
            return
        }

        switch outcome {
        case let .success(lane):
            switch lane {
            case .nativeApp:
                // Unchanged slice-1 path, validator and all.
                startBrainProposal(for: request)
            case .chat:
                startBrainChat(for: request)
            case .unsupported:
                isBrainThinking = false
                previewedAction = nil
                pendingApplicationProposal = nil
                applicationProposalExpiresAt = nil
                pendingTaskSequence = nil
                clearBrainOriginatedProposal()
                brainStatus = Self.unsupportedRequestMessage
                scheduleBrainIdleShutdown()
            }
        case let .failure(error):
            isBrainThinking = false
            brainStatus = Self.brainMessage(for: error)
            scheduleBrainIdleShutdown()
        }
    }

    /// Answers offline, in text only. This path has no plan, no proposal, and no
    /// action state: nothing it returns can become something OSPA does.
    private func startBrainChat(for request: String) {
        brainTask?.cancel()
        isBrainThinking = true
        brainStatus = "Thinking…"

        let chatService = brainChatService
        let serverController = brainServerController

        brainTask = Task { [weak self] in
            let outcome: Result<String, any Error>
            do {
                guard await serverController.ensureReady() == .ready else {
                    throw LocalBrainError.unavailable
                }
                let answer = try await serverController.withTrackedRequest {
                    try await chatService.answer(request: request)
                }
                outcome = .success(answer)
            } catch {
                outcome = .failure(error)
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishBrainChat(outcome)
            }
        }
    }

    private func finishBrainChat(_ outcome: Result<String, any Error>) {
        brainTask = nil
        isBrainThinking = false

        guard isBrainEnabled, !safety.emergencyStopped else { return }

        switch outcome {
        case let .success(answer):
            // Text only. No preview, no proposal, no plan.
            previewedAction = nil
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            pendingTaskSequence = nil
            clearBrainOriginatedProposal()
            brainStatus = answer
        case let .failure(error):
            brainStatus = Self.brainMessage(for: error)
        }
        scheduleBrainIdleShutdown()
    }

    private func startBrainProposal(for request: String) {
        brainTask?.cancel()
        brainIdleShutdownTask?.cancel()
        brainIdleShutdownTask = nil
        clearBrainOriginatedProposal()
        isBrainThinking = true
        brainStatus = "Thinking…"

        let inventory = usageSource.currentInventory()
        let installedNames = Set(inventory.map(\.displayName))
        let service = brainService
        let validator = brainValidator
        let serverController = brainServerController

        brainTask = Task { [weak self] in
            let outcome: Result<[BrainProposal], any Error>
            do {
                guard await serverController.ensureReady() == .ready else {
                    throw LocalBrainError.unavailable
                }
                let raw = try await serverController.withTrackedRequest {
                    try await service.propose(
                        request: request,
                        inventory: inventory
                    )
                }
                outcome = .success(
                    try validator.validate(
                        raw,
                        installedApplicationNames: installedNames
                    )
                )
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run {
                self?.scheduleBrainIdleShutdown()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishBrainProposal(outcome)
            }
        }
    }

    private func finishBrainProposal(
        _ outcome: Result<[BrainProposal], any Error>
    ) {
        brainTask = nil
        isBrainThinking = false

        guard !safety.emergencyStopped else {
            brainStatus = "Emergency stop is active."
            return
        }

        switch outcome {
        case let .success(proposals):
            guard let proposal = proposals.first else {
                brainStatus = Self.brainMessage(
                    for: BrainProposalError.noToolCalls
                )
                return
            }

            if proposals.count == 1 {
                if let command = proposal.parsedApplicationCommand {
                    previewApplicationCommand(command)
                    if let planID = pendingApplicationProposal?.plan.id {
                        bindBrainReason(proposal.reason, to: planID)
                    } else {
                        brainStatus = proposal.reason
                    }
                } else {
                    brainStatus = proposal.reason
                }
                return
            }

            var requests: [TaskSequencePreviewRequest] = []
            for proposal in proposals {
                guard let command = proposal.parsedApplicationCommand else {
                    pendingApplicationProposal = nil
                    applicationProposalExpiresAt = nil
                    pendingTaskSequence = nil
                    brainStatus =
                        "I couldn’t prepare every requested step, so nothing was prepared."
                    return
                }
                requests.append(
                    TaskSequencePreviewRequest(
                        command: command,
                        reason: proposal.reason
                    )
                )
            }

            guard let sequence = previewTaskSequence(requests) else {
                brainStatus =
                    "I couldn’t prepare every requested step, so nothing was prepared."
                return
            }
            bindBrainSequence(to: sequence.id)
            brainStatus =
                "Prepared \(sequence.steps.count) requests. Review the exact list before confirming."
        case let .failure(error):
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            pendingTaskSequence = nil
            brainStatus = Self.brainMessage(for: error)
        }
    }

    private func cancelBrainProposal() {
        brainTask?.cancel()
        brainTask = nil
        isBrainThinking = false
        clearBrainOriginatedProposal()
        if isBrainEnabled, !safety.emergencyStopped {
            brainStatus = "Natural language is on. Type what you want in ordinary words."
        }
    }

    private func bindBrainReason(_ reason: String, to planID: UUID) {
        guard pendingApplicationProposal?.plan.id == planID else { return }
        brainProposalBinding = .application(
            planID: planID, reason: reason
        )
        brainStatus = reason
    }

    private func bindBrainSequence(to sequenceID: UUID) {
        guard pendingTaskSequence?.id == sequenceID else { return }
        brainProposalBinding = .taskSequence(sequenceID: sequenceID)
    }

    private func clearBrainOriginatedProposal() {
        guard let binding = brainProposalBinding else { return }
        switch binding {
        case let .application(planID, _):
            if pendingApplicationProposal?.plan.id == planID {
                pendingApplicationProposal = nil
                applicationProposalExpiresAt = nil
            }
        case let .taskSequence(sequenceID):
            if pendingTaskSequence?.id == sequenceID {
                pendingTaskSequence = nil
            }
        }
        clearBrainProposalBinding()
    }

    private func clearBrainBindingIfDetached() {
        guard let binding = brainProposalBinding else { return }
        let isDetached =
            switch binding {
            case let .application(planID, _):
                pendingApplicationProposal?.plan.id != planID
            case let .taskSequence(sequenceID):
                pendingTaskSequence?.id != sequenceID
            }
        if isDetached {
            clearBrainProposalBinding()
        }
    }

    private func clearBrainProposalBinding() {
        guard let binding = brainProposalBinding else { return }
        brainProposalBinding = nil
        let ownsCurrentStatus =
            switch binding {
            case let .application(_, reason): brainStatus == reason
            case .taskSequence: true
            }
        if ownsCurrentStatus {
            brainStatus = isBrainEnabled
                ? "Natural language is on. Type what you want in ordinary words."
                : "Natural language is off. Type exact commands."
        }
    }

    private func scheduleBrainIdleShutdown() {
        brainIdleShutdownTask?.cancel()
        let interval = max(0, brainIdleShutdownInterval)
        let serverController = brainServerController
        brainIdleShutdownTask = Task {
            if interval > 0 {
                let nanoseconds = UInt64(min(interval, 86_400) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            await serverController.shutdownIfIdle()
        }
    }

    private func scheduleTaskSequenceExpiry() {
        taskSequenceExpiryTask?.cancel()
        guard let sequence = pendingTaskSequence else {
            taskSequenceExpiryTask = nil
            return
        }

        let sequenceID = sequence.id
        let expiresAt = sequence.expiresAt
        let delay = max(0, min(expiresAt.timeIntervalSinceNow, 86_400))
        let nanoseconds = UInt64(delay * 1_000_000_000)
        taskSequenceExpiryTask = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled, let self,
                self.pendingTaskSequence?.id == sequenceID
            else {
                return
            }
            // A nanosecond conversion may wake just before the wall-clock
            // deadline. Reschedule rather than leaving a stale preview.
            guard Date() >= expiresAt else {
                self.scheduleTaskSequenceExpiry()
                return
            }
            self.pendingTaskSequence = nil
            self.status = "That request expired. Ask again."
            self.taskSequenceStatus = "That request expired. Ask again."
        }
    }

    /// Plain language only. These strings are read by someone who does not know
    /// what a model, a port, or a tool call is.
    private static func brainMessage(for error: any Error) -> String {
        if let proposalError = error as? BrainProposalError {
            switch proposalError {
            case let .applicationNotInstalled(name):
                return "\(name) isn’t installed on this Mac."
            case .unknownTool:
                // The model understood the request and proposed something
                // outside the closed menu. Saying "I didn't understand" would
                // misdescribe what happened; the request was refused, not
                // misread.
                return
                    "That’s not allowed. I can only open or switch apps that are "
                    + "already installed on this Mac."
            case .noToolCalls, .tooManyToolCalls,
                .malformedArguments, .missingArgument, .unsafeApplicationName,
                .unsafeReason:
                return "I didn’t understand that well enough to suggest something safe."
            }
        }

        if let localError = error as? LocalBrainError {
            switch localError {
            case .unavailable:
                return "I can’t think right now. You can still type an exact command."
            case .timedOut:
                return "That took too long, so I stopped."
            case .noToolCall, .badResponse:
                return "I couldn’t work out what to do with that."
            }
        }

        return "Something went wrong working that out."
    }

    nonisolated private static func makeLiveBrainServerController()
        -> LocalBrainServerController
    {
        let executableURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Models/.venv/bin/python")
        let process = ManagedLocalBrainProcess(
            executableURL: executableURL,
            arguments: [
                "-m", "mlx_lm", "server",
                "--model", "mlx-community/Qwen3-8B-4bit",
                "--host", "127.0.0.1",
                "--port", "8081",
                "--chat-template-args", #"{"enable_thinking": false}"#,
            ]
        )

        return LocalBrainServerController(
            launch: { try process.launch() },
            terminate: { process.terminate() },
            isHealthy: { await localBrainServerIsHealthy() },
            now: Date.init,
            startupTimeout: 60,
            idleShutdownInterval: 300
        )
    }

    nonisolated private static func localBrainServerIsHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8081/v1/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func previewApplicationCommand(
        _ parsed: ParsedApplicationCommand
    ) {
        previewedAction = nil
        computerUsePreview = nil
        pendingApplicationSequence = nil
        applicationSequenceFirstStepCompleted = false

        do {
            let application = try applicationResolver.resolveExact(
                named: parsed.requestedApplicationName
            )
            prepareApplicationProposal(parsed, application: application)
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

    private func previewApplicationSequence(
        _ sequence: ParsedApplicationSequence
    ) {
        previewedAction = nil
        computerUsePreview = nil

        do {
            let application = try applicationResolver.resolveExact(
                named: sequence.firstCommand.requestedApplicationName
            )
            let proposal = try applicationSequencePlanner.propose(
                sequence: sequence,
                application: application,
                now: Date()
            )
            try publishApplicationProposal(
                proposal.applicationProposal
            )
            pendingApplicationSequence = proposal
            applicationSequenceFirstStepCompleted = false
            status =
                "Ordered plan ready. Only step 1 can be confirmed now; step 2 is unsupported and not queued."
            applicationActionStatus =
                "One confirmation authorizes only the exact app launch/focus step."
        } catch InstalledApplicationResolutionError.notFound {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            pendingApplicationSequence = nil
            status =
                "No installed app found with that exact first-step name. Use Search this Mac to select it."
        } catch InstalledApplicationResolutionError.ambiguousExactName {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            pendingApplicationSequence = nil
            status =
                "Multiple apps share that first-step name. Select an exact result in Search this Mac."
        } catch ApplicationProposalError.switchTargetNotRunning {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            pendingApplicationSequence = nil
            status =
                "Step 1 switch requires a running app. Use “open \(sequence.firstCommand.requestedApplicationName) and …” instead."
        } catch {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            pendingApplicationSequence = nil
            status = "The ordered app plan could not be prepared safely."
        }
    }

    private func prepareApplicationProposal(
        _ command: ParsedApplicationCommand,
        application: ResolvedApplication
    ) {
        do {
            let now = Date()
            let proposal = try applicationPlanner.propose(
                command: command,
                application: application,
                now: now
            )
            try publishApplicationProposal(proposal, now: now)
            status =
                "Executable native app action prepared. Review exact target and confirm separately."
            applicationActionStatus =
                "Ready for one explicit confirmation. No Accessibility permission is required."
        } catch ApplicationProposalError.switchTargetNotRunning {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status =
                "Switch requires an already-running app. Use “open \(command.requestedApplicationName)” instead."
        } catch {
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            status = "Application action could not be planned safely."
        }
    }

    private func publishApplicationProposal(
        _ proposal: ApplicationActionProposal,
        now: Date = Date()
    ) throws {
        let previewConsent = ConsentGrant(
            planID: proposal.plan.id,
            scopes: [],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        _ = try PlanValidator().validateForPreview(
            plan: proposal.plan,
            profile: proposal.profile,
            consent: previewConsent,
            userConfirmedPreview: true,
            now: now
        )

        clearBrainProposalBinding()
        pendingApplicationProposal = proposal
        applicationProposalExpiresAt = now.addingTimeInterval(60)
    }

    private func updateSearchResults() {
        guard validSearchAuthorization() != nil else {
            searchCandidates = []
            return
        }
        let applications = indexedApplications.map {
            LocalSearchItem(
                name: $0.identity.displayName,
                url: $0.applicationURL,
                kind: .application,
                scope: .applications,
                bundleIdentifier: $0.identity.bundleIdentifier,
                isRunning: $0.isRunning
            )
        }
        searchCandidates = searchRanker.search(
            query: searchQuery,
            items: applications + personalSearchItems,
            limit: 12
        )
        let trimmed = searchQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmed.isEmpty {
            searchStatus =
                searchCandidates.isEmpty
                ? "No approved local metadata name matches “\(trimmed)”. No website, URL, or broader scope will be guessed."
                : "Found \(searchCandidates.count) ranked exact local candidates."
        }
    }

    private func validSearchAuthorization() -> LocalSearchAuthorization? {
        guard let authorization = searchAuthorization else {
            searchStatus = "Review and approve metadata scope before searching."
            return nil
        }
        guard Date() < authorization.expiresAt else {
            searchAuthorization = nil
            searchCandidates = []
            personalSearchItems = []
            searchStatus = "Search scope approval expired. Approve it again."
            return nil
        }
        return authorization
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
            pendingComputerUsePlan = plan
            pendingComputerUseProfile = profile
            previewAuditRecords.append(
                PreviewAuditRecord(preview: preview, renderedAt: now)
            )
            discoveryStatus =
                "Preview contract created and audited. It expires in 60 seconds."
            computerUseActionStatus =
                preview.readinessIssues.isEmpty
                ? "Ready for one explicit confirmation. Nothing runs until you confirm."
                : "Blocked until the listed readiness issues are cleared."
        } catch {
            clearPendingComputerUsePlan()
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

    private func clearAccessibilityInspection() {
        accessibilityInspectionRequest = nil
        accessibilityUISnapshot = nil
        accessibilityInteractionPreview = nil
        accessibilityInspectionRequestConsumed = false
        accessibilityInspectionStatus =
            "No Accessibility UI inspection is prepared."
    }

    private func recordAccessibilityInspectionDenied(
        request: AccessibilityInspectionRequest,
        at timestamp: Date
    ) {
        accessibilityInspectionAuditRecords.append(
            AccessibilityInspectionAuditRecord(
                requestID: request.id,
                targetBundleIdentifier:
                    request.target.bundleIdentifier,
                timestamp: timestamp,
                outcome: .denied
            )
        )
    }

    private func recordAccessibilityInspectionFailure(
        request: AccessibilityInspectionRequest,
        at timestamp: Date
    ) {
        accessibilityInspectionAuditRecords.append(
            AccessibilityInspectionAuditRecord(
                requestID: request.id,
                targetBundleIdentifier:
                    request.target.bundleIdentifier,
                timestamp: timestamp,
                outcome: .failed
            )
        )
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

    private func clearPendingComputerUsePlan() {
        pendingComputerUsePlan = nil
        pendingComputerUseProfile = nil
        computerUsePreview = nil
    }

    /// Audit keeps outcome shape only. Reasons can name on-screen controls, so
    /// they stay in the user-facing status and never reach the audit record.
    private func redactedComputerUseOutcome(
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
            .denied("Visible foreground action denied.")
        case .failed:
            .failed("Visible foreground action failed.")
        }
    }

    private func computerUseOutcomeMessage(
        _ outcome: ExecutionOutcome
    ) -> String {
        switch outcome {
        case .succeeded:
            "Done. The visible steps completed."
        case let .denied(reason):
            "Stopped before acting: \(reason)"
        case let .failed(reason):
            "Couldn't finish: \(reason)"
        case .cancelled:
            "Action cancelled."
        case .started:
            "Action started."
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

private final class ManagedLocalBrainProcess: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }

        if process?.isRunning == true {
            return
        }

        let next = Process()
        next.executableURL = executableURL
        next.arguments = arguments
        next.standardOutput = FileHandle.nullDevice
        next.standardError = FileHandle.nullDevice
        try next.run()
        process = next
    }

    func terminate() {
        lock.lock()
        let runningProcess = process
        process = nil
        lock.unlock()

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }
}
