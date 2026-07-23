import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var touchView: TouchView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 640)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "gesture-lab"
        window.center()
        touchView = TouchView(frame: rect)
        window.contentView = touchView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(touchView)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit gesture-lab",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Toggle Recording",
                         action: #selector(AppDelegate.toggleRecording(_:)),
                         keyEquivalent: "r")
        fileMenu.addItem(withTitle: "Replay Recording…",
                         action: #selector(AppDelegate.replayRecording(_:)),
                         keyEquivalent: "o")
        fileItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleRecording(_ sender: Any?) {
        touchView.toggleRecording()
    }

    @objc private func replayRecording(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/recordings")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            print("=== replaying \(url.path) ===")
            _ = Replay.run(path: url.path, verbose: false)
        }
    }
}
