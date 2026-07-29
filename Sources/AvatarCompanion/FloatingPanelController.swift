import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController {
    private let model: AvatarModel
    private let panel: FloatingPanel

    init(model: AvatarModel) {
        self.model = model
        self.panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 132),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        wireModel()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggleVisibility() {
        panel.isVisible ? hide() : show()
    }

    private func configurePanel() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("AvatarCompanionFloatingPanel")
        panel.contentView = NSHostingView(rootView: AvatarView(model: model))

        if panel.setFrameUsingName("AvatarCompanionFloatingPanel") {
            let restoredFrame = panel.frame
            let collapsedSize = NSSize(width: 128, height: 132)
            panel.setFrame(
                NSRect(
                    x: restoredFrame.maxX - collapsedSize.width,
                    y: restoredFrame.maxY - collapsedSize.height,
                    width: collapsedSize.width,
                    height: collapsedSize.height
                ),
                display: false
            )
        } else if let visibleFrame = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: visibleFrame.maxX - panel.frame.width - 24,
                y: visibleFrame.maxY - panel.frame.height - 24
            )
            panel.setFrameOrigin(origin)
        }
    }

    private func wireModel() {
        model.onHide = { [weak self] in
            self?.hide()
        }
        model.onExpansionChanged = { [weak self] expanded in
            self?.resize(expanded: expanded)
        }
    }

    private func resize(expanded: Bool) {
        let oldFrame = panel.frame
        let availableHeight = panel.screen?.visibleFrame.height ?? 700
        let newSize = NSSize(
            width: expanded ? 340 : 128,
            height: expanded ? min(650, availableHeight - 32) : 132
        )
        let newOrigin = NSPoint(
            x: oldFrame.maxX - newSize.width,
            y: oldFrame.maxY - newSize.height
        )
        panel.setFrame(
            NSRect(origin: newOrigin, size: newSize),
            display: true,
            animate: true
        )
    }
}
