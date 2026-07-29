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
    private let metadataSearch = LocalMetadataSearchService()
    private let nativeLocalItemExecutor = NativeLocalItemExecutor()
    private let searchRanker = LocalSearchRanker()
    private let searchScopePolicy = LocalSearchScopePolicy()
    private var consumedConsentGrantIDs = Set<UUID>()
    private var indexedApplications: [ResolvedApplication] = []
    private var personalSearchItems: [LocalSearchItem] = []

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

        spotlightOpenPreview = SpotlightOpenPreview(item: candidate.item)
        previewedAction = nil
        computerUsePreview = nil
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
        spotlightOpenPreview = nil
        pendingLocalItemOpenPlan = nil

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

            pendingApplicationProposal = proposal
            applicationProposalExpiresAt = now.addingTimeInterval(60)
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
