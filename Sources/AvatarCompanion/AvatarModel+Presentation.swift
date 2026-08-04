import AvatarCore
import AvatarPlatform
import Foundation

// MARK: - Presentation

@MainActor
extension AvatarModel {
    func toggleExpanded() {
        isExpanded.toggle()
        onExpansionChanged?(isExpanded)
    }
}
