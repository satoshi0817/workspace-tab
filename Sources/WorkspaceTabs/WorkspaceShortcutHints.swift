import AppKit
import SwiftUI

/// A modifier hold reveals hints. Numbered app-tab switching preserves the hold;
/// unrelated chords suppress hints until the modifiers are released.
struct WorkspaceShortcutHold {
    enum Change {case unchanged, begin, clear}
    static let delay:TimeInterval=0.45
    private(set) var startedAt:TimeInterval?
    private var held:NSEvent.ModifierFlags=[]
    private var blocked=false
    mutating func consume(_ type:NSEvent.EventType,flags:NSEvent.ModifierFlags,time:TimeInterval,
                          allowed:[NSEvent.ModifierFlags],workspaceSwitch:Bool=false)->Change {
        let flags=flags.intersection([.command,.control,.option,.shift])
        if type == .flagsChanged || (type == .keyDown && workspaceSwitch) {
            if workspaceSwitch {blocked=false}
            if flags.isEmpty {blocked=false}
            guard !blocked,allowed.contains(flags),!flags.isEmpty else {
                held=flags;startedAt=nil;return .clear
            }
            guard held != flags || startedAt == nil else{return .unchanged}
            held=flags;startedAt=time;return .begin
        }
        // Suppress the remainder of a modifier hold after typing, clicking or scrolling.
        blocked = !flags.isEmpty;held=flags;startedAt=nil;return .clear
    }
    func ready(at time:TimeInterval)->Bool {startedAt.map{time-$0 >= Self.delay} ?? false}
}

/// Observes events without consuming, synthesizing or forwarding them. A common-mode
/// timer updates hints even while AppKit is in a tracking run loop; no later key is needed.
@MainActor final class WorkspaceShortcutHintsController {
    private var hold=WorkspaceShortcutHold()
    private var timer:Timer?
    private let canShow:()->Bool
    private let modifiers:()->NSEvent.ModifierFlags
    private let publish:(Bool)->Void
    private(set) var visible=false
    init(canShow:@escaping()->Bool,modifiers:@escaping()->NSEvent.ModifierFlags,publish:@escaping(Bool)->Void) {
        self.canShow=canShow;self.modifiers=modifiers;self.publish=publish
    }
    private func setVisible(_ value:Bool) {
        guard visible != value else{return};visible=value;publish(value)
    }
    func reset() {
        timer?.invalidate();timer=nil;hold=WorkspaceShortcutHold();setVisible(false)
    }
    func consume(_ type:NSEvent.EventType,flags:NSEvent.ModifierFlags,allowed:[NSEvent.ModifierFlags],workspaceSwitch:Bool=false) {
        guard canShow() else{reset();return}
        let relevant=flags.intersection([.command,.control,.option,.shift])
        switch hold.consume(type,flags:relevant,time:ProcessInfo.processInfo.systemUptime,allowed:allowed,workspaceSwitch:workspaceSwitch) {
        case .unchanged:break
        case .clear:timer?.invalidate();timer=nil;setVisible(false)
        case .begin:
            timer?.invalidate();setVisible(false)
            let timer=Timer(timeInterval:WorkspaceShortcutHold.delay+0.01,repeats:false) {[weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else{return}
                    self.timer=nil
                    guard self.canShow(),self.modifiers().intersection([.command,.control,.option,.shift]) == relevant,
                          self.hold.ready(at:ProcessInfo.processInfo.systemUptime) else {self.reset();return}
                    self.setVisible(true)
                }
            }
            self.timer=timer;RunLoop.main.add(timer,forMode:.common)
        }
    }
}

extension BrowserStore {
    var canShowWorkspaceHints:Bool {
        guard !workspaceHintsSuspended,NSApp.isActive,let window,window.isVisible,
              !anyPanelPresented,error == nil,recentCandidates.isEmpty else{return false}
        // Modifier events can be windowless or associated with a WebKit helper.
        // Use the application's actual key window rather than event.window.
        return NSApp.keyWindow === window || (NSApp.keyWindow == nil && NSApp.mainWindow === window)
    }
    func resetWorkspaceHints() {workspaceShortcutHints.reset()}
    func workspaceHintBindings()->[ShortcutBinding] {
        ShortcutPreferences.numberedActions.map{ShortcutPreferences.shared.binding($0)}.filter{$0.sequence == nil}
    }
    func handleWorkspaceHintEvent(_ event:NSEvent) {
        guard [.flagsChanged,.keyDown,.leftMouseDown,.rightMouseDown,.leftMouseDragged,.scrollWheel].contains(event.type) else{return}
        let bindings=workspaceHintBindings()
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        let switching=event.type == .keyDown && bindings.contains{$0.code == event.keyCode && $0.flags == flags}
        workspaceShortcutHints.consume(event.type,flags:flags,allowed:[.command]+bindings.map(\.flags),workspaceSwitch:switching)
    }
    func preserveWorkspaceHintsAfterSwitch() {
        let bindings=workspaceHintBindings(),flags=NSEvent.modifierFlags.intersection([.command,.control,.option,.shift])
        guard bindings.contains(where:{$0.flags == flags}) else{return}
        // Carbon owns numbered global shortcuts, so their keydown may not reach
        // NSEvent observers. Preserve the existing hold after the switch as well.
        workspaceShortcutHints.consume(.keyDown,flags:flags,allowed:[.command]+bindings.map(\.flags),workspaceSwitch:true)
    }
}

struct WorkspaceShortcutKeycap:View {
    let binding:ShortcutBinding
    let compact:Bool
    let ink:Color
    let color:Color
    var body:some View {
        Text(compact ? (binding.sequence == nil ? binding.key.uppercased():"…"):binding.label)
            .font(.system(size:compact ? 10:11,weight:.bold,design:.monospaced))
            .lineLimit(1).padding(.horizontal,4).frame(minWidth:18,minHeight:18)
            .foregroundStyle(color).background(ink,in:RoundedRectangle(cornerRadius:5,style:.continuous))
            .accessibilityLabel(binding.label).help(binding.label)
            .allowsHitTesting(false)
    }
}
