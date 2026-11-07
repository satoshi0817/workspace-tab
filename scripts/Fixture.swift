// Local UI fixture. Contains no accounts or user data.
import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        for (index, title) in ["Workspace QA · Alpha", "Workspace QA · Beta", "Workspace QA · Same", "Workspace QA · Same"].enumerated() {
            let window = NSWindow(contentRect: CGRect(x: 100 + index * 55, y: 120 + index * 35, width: 700, height: 470), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = title; window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: title + "\n\nWorkspace Tabs の動作確認専用ウインドウ\n実データは含まれていません。")
            label.font = .systemFont(ofSize: 23, weight: .medium); label.alignment = .center
            label.frame = CGRect(x: 40, y: 140, width: 620, height: 160); label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            window.contentView?.addSubview(label); windows.append(window); window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
let app = NSApplication.shared
let delegate = FixtureDelegate(); app.delegate = delegate
app.setActivationPolicy(.regular); app.run()
