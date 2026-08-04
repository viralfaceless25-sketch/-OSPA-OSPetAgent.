import AvatarCore
import Foundation
import SwiftUI

// MARK: - Header

extension AvatarView {
    var avatarHeader: some View {
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

    var eye: some View {
        Circle()
            .fill(.white)
            .frame(width: 11, height: 11)
            .overlay {
                Circle()
                    .fill(.black.opacity(0.75))
                    .frame(width: 5, height: 5)
            }
    }

    var modeLabel: String {
        model.safety.observeOnly ? "Observe only" : "Action mode"
    }
}
