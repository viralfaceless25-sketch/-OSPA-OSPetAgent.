import AvatarCore
import Foundation
import SwiftUI

// MARK: - LocalSearch

extension AvatarView {
    var localSearchSurface: some View {
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

    func spotlightPreviewCard(
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

    func localItemFallbackCard(
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

    func searchIcon(_ kind: LocalSearchItemKind) -> String {
        switch kind {
        case .application: "app"
        case .folder: "folder"
        case .file: "doc"
        }
    }

}
