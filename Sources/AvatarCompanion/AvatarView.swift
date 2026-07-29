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

                commandSurface
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
                TextField("Try “copy time”", text: $model.command)
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
                Button(role: .destructive, action: {
                    model.emergencyStop()
                }) {
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

    private var modeLabel: String {
        model.safety.observeOnly ? "Observe only" : "Action mode"
    }
}
