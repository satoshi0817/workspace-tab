import AppKit
import SwiftUI

/// Input-only state: a held modifier may reveal hints, but a real chord never does.
struct WorkspaceShortcutHold {
    enum Change {case unchanged, begin, clear}
    static let delay:TimeInterval=0.45
    private(set) var startedAt:TimeInterval?
    private var held:NSEvent.ModifierFlags=[]
    private var blocked=false
    mutating func consume(_ type:NSEvent.EventType,flags:NSEvent.ModifierFlags,time:TimeInterval,
                          allowed:[NSEvent.ModifierFlags])->Change {
        let flags=flags.intersection([.command,.control,.option,.shift])
        if type == .flagsChanged {
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

extension BrowserStore {
    func resetWorkspaceHints() {
        workspaceHintHold=WorkspaceShortcutHold()
        workspaceHintTask?.cancel();workspaceHintTask=nil
        if workspaceHintsVisible {workspaceHintsVisible=false}
    }
    func handleWorkspaceHintEvent(_ event:NSEvent) {
        guard !workspaceHintsSuspended,NSApp.isActive,(event.window ?? NSApp.keyWindow) === window,
              !anyPanelPresented,error == nil,recentCandidates.isEmpty else {resetWorkspaceHints();return}
        let preferences=ShortcutPreferences.shared
        let configured=ShortcutPreferences.numberedActions.map{preferences.binding($0)}
            .filter{$0.sequence == nil}.map(\.flags)
        switch workspaceHintHold.consume(event.type,flags:event.modifierFlags,time:ProcessInfo.processInfo.systemUptime,
                                         allowed:[.command]+configured) {
        case .unchanged:break
        case .clear:
            workspaceHintTask?.cancel();workspaceHintTask=nil
            if workspaceHintsVisible {workspaceHintsVisible=false}
        case .begin:
            workspaceHintTask?.cancel()
            if workspaceHintsVisible {workspaceHintsVisible=false}
            workspaceHintTask=Task { @MainActor [weak self] in
                try? await Task.sleep(for:.milliseconds(460))
                guard !Task.isCancelled,let self,self.workspaceHintHold.ready(at:ProcessInfo.processInfo.systemUptime),
                      NSApp.isActive,NSApp.keyWindow === self.window,!self.anyPanelPresented,
                      self.error == nil,self.recentCandidates.isEmpty else{return}
                self.workspaceHintsVisible=true
            }
        }
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
