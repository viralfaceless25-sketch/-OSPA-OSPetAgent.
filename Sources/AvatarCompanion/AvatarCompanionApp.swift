import AppKit
import SwiftUI

@main
struct AvatarCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AvatarModel()
    private var panelController: FloatingPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = FloatingPanelController(model: model)
        panelController = controller
        configureStatusItem()
        controller.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "face.smiling.inverse",
            accessibilityDescription: "Avatar Companion"
        )

        let menu = NSMenu()
        let search = NSMenuItem(
            title: "Search This Mac…",
            action: #selector(openSearch),
            keyEquivalent: ""
        )
        search.target = self
        menu.addItem(search)

        let toggle = NSMenuItem(
            title: "Show or Hide Avatar",
            action: #selector(togglePanel),
            keyEquivalent: "a"
        )
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        menu.addItem(toggle)

        let stop = NSMenuItem(
            title: "Emergency Stop",
            action: #selector(emergencyStop),
            keyEquivalent: "."
        )
        stop.keyEquivalentModifierMask = [.command]
        stop.target = self
        menu.addItem(stop)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Avatar Companion",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        panelController?.toggleVisibility()
    }

    @objc private func openSearch() {
        model.openSearch()
        panelController?.show()
    }

    @objc private func emergencyStop() {
        model.emergencyStop()
        panelController?.show()
    }
}
