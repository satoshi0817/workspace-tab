import AppKit
import os

/// WebKit re-sends unhandled key events through NSApplication.sendEvent.
/// Local NSEvent monitors are insufficient for this second dispatch.
@MainActor final class BrowserApplication: NSApplication {
    var escapeAction:(()->Void)?
    @discardableResult func routeEscape(_ event:NSEvent)->Bool {
        guard BrowserWindow.isEscape(event),let window=(event.window ?? keyWindow) as? BrowserWindow,window.attachedSheet == nil else{return false}
        escapeAction?()
        window.sendEvent(event)
        return true
    }
    override func sendEvent(_ event:NSEvent) {
        if routeEscape(event) {return}
        super.sendEvent(event)
    }
}

@MainActor class BrowserWindow: NSWindow {
    private static let log=Logger(subsystem:"com.ssuzuki.WorkspaceTabs",category:"KeyboardRouting")
    func trace(_ stage:String) {
        let event=NSApp.currentEvent
        let code=event.map{[NSEvent.EventType.keyDown,.keyUp,.flagsChanged].contains($0.type) ? Int($0.keyCode):-1} ?? -1
        Self.log.notice("\(stage,privacy:.public) fullscreen=\(self.styleMask.contains(.fullScreen)) event=\(code) responder=\(String(describing:type(of:self.firstResponder as Any)),privacy:.public)")
    }
    static func isEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53 &&
        event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty
    }

    // NSWindow's fullscreen handling can consume Escape before cancelOperation.
    // Bypass that dispatch only for Escape, delivering the real event to the
    // focused responder so WebKit/IME/editors can still dismiss their own UI.
    override func sendEvent(_ event: NSEvent) {
        if Self.isEscape(event), attachedSheet == nil {
            trace("escape-dispatch")
            deliverEscape(event)
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isEscape(event), attachedSheet == nil {
            trace("escape-dispatch")
            deliverEscape(event)
            return true
        }
        return super.performKeyEquivalent(with:event)
    }

    private var deliveringEscape=false
    private var lastEscapeEvent:NSEvent?
    private func deliverEscape(_ event: NSEvent) {
        // Give the real event to the web page once. WebKit's asynchronous resend
        // must not reach either AppKit's fullscreen handler or the page again.
        guard lastEscapeEvent !== event else {return}
        lastEscapeEvent=event
        deliveringEscape=true
        defer {deliveringEscape=false}
        guard let responder=firstResponder, responder !== self else { return }
        responder.keyDown(with:event)
    }

    override func toggleFullScreen(_ sender: Any?) {
        // A focused AppKit/SwiftUI responder can request the transition itself,
        // bypassing the window's cancelOperation/keyDown fallback.
        trace("fullscreen-request")
        guard !deliveringEscape, !(NSApp.currentEvent.map(Self.isEscape) ?? false) else {return}
        performFullscreenTransition(sender)
    }

    func performFullscreenTransition(_ sender:Any?) {super.toggleFullScreen(sender)}

    override func cancelOperation(_ sender: Any?) {}

    override func keyDown(with event: NSEvent) {
        if Self.isEscape(event) { return }
        super.keyDown(with:event)
    }
}
