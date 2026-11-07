// Fault injection only. No AX reads/writes to any real application's windows.
enum WindowAccess {
    enum Availability { case available, temporarilyUnavailable, gone }
    static func identity(_ window: ExternalWindow) -> WindowIdentity { WindowIdentity(bundleID: window.bundleID, title: window.title) }
    static var trusted = true
    static var inventory: [ExternalWindow] = []
    static var roleFailure = false
    static var gone = false
    static var activationSuccess = true
    static var focused: (pid_t, AXUIElement)? = nil
    static var writes: [CGRect] = []
    static var observedFrame = CGRect(x: 100, y: 100, width: 700, height: 500)
    static var primaryTop: CGFloat { 1169 }
    static func requestPermission() {}
    static func availability(_ window: ExternalWindow) -> Availability {
        gone ? .gone : roleFailure ? .temporarilyUnavailable : .available
    }
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        roleFailure || gone ? nil : "AXWindow" as CFString
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? { "Renamed page" }
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool { false }
    static func frame(_ element: AXUIElement) -> CGRect? { roleFailure ? nil : observedFrame }
    @discardableResult static func setFrame(_ frame: CGRect, of element: AXUIElement) -> Bool { writes.append(frame); return true }
    static func windows() -> [ExternalWindow] { inventory }
    static func dragWindow() -> ExternalWindow? { inventory.first }
    static func focusedWindow() -> (pid_t, AXUIElement)? { focused }
    static func activate(_ window: ExternalWindow) -> Bool { activationSuccess }
}
