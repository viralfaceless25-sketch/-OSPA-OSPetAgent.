import AvatarCore
import Foundation
import SwiftUI

struct AvatarView: View {
    @ObservedObject var model: AvatarModel
    @FocusState var commandFocused: Bool
    @FocusState var searchFocused: Bool

    // MARK: - Body

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
}
