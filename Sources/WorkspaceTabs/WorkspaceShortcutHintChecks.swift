import AppKit
import CoreFoundation

/// Runs entirely inside the check process. No OS key events or global monitors.
@MainActor enum WorkspaceShortcutHintChecks {
    static func run() async throws {
        func expect(_ condition:Bool,_ message:String)throws {
            guard condition else{throw BrowserChecks.Failure.check(message)}
            print("PASS "+message)
        }
        var eligible=true,flags:NSEvent.ModifierFlags = .command
        var publications:[Bool]=[]
        let allowed:[NSEvent.ModifierFlags]=[.command,[.control,.option]]
        let hints=WorkspaceShortcutHintsController(canShow:{eligible},modifiers:{flags},publish:{publications.append($0)})
        defer {hints.reset()}
        hints.consume(.flagsChanged,flags:.command,allowed:allowed)
        try expect(!hints.visible,"Modifier hints do not appear immediately on Command press")
        try expect(waitInTrackingRunLoop{hints.visible},"Command hold displays hints in a tracking run loop without a number key or later input")
        try expect(publications == [true],"Modifier hold publishes its display update exactly once")
        hints.consume(.keyDown,flags:.command,allowed:allowed,workspaceSwitch:true)
        try expect(hints.visible && publications == [true],"Numbered app-tab switching keeps modifier hints visible without restarting the delay")
        flags=[];hints.consume(.flagsChanged,flags:[],allowed:allowed)
        try expect(!hints.visible && publications == [true,false],"Releasing Command immediately hides the numbers")

        flags = .command;hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        try await Task.sleep(for:.milliseconds(100))
        flags=[];hints.consume(.flagsChanged,flags:[],allowed:allowed)
        try await Task.sleep(for:.milliseconds(500))
        try expect(!hints.visible,"Quick modifier taps never produce delayed stale hints")

        flags = .command;hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        hints.consume(.keyDown,flags:flags,allowed:allowed)
        try await Task.sleep(for:.milliseconds(520))
        try expect(!hints.visible,"Ordinary Command chords suppress the remainder of the hold")
        flags=[];hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        flags=[.control,.option];hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        try expect(waitInTrackingRunLoop{hints.visible},"Configured multi-modifier app-tab shortcuts also reveal numbers on hold")
        flags = .control;hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        try expect(!hints.visible,"Releasing part of a modifier combination clears its hints")

        hints.reset();flags = .command
        hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        flags=[] // Simulate a lost release notification; physical state still wins.
        try await Task.sleep(for:.milliseconds(520))
        try expect(!hints.visible,"Timer checks current modifiers and never reveals numbers after a lost key release")
        flags = .command;hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        eligible=false
        try await Task.sleep(for:.milliseconds(520))
        try expect(!hints.visible,"Opening a panel or deactivating the app cancels pending hints")
        eligible=true;hints.consume(.flagsChanged,flags:flags,allowed:allowed)
        try expect(waitInTrackingRunLoop{hints.visible},"Hints can start again after focus returns")
        hints.reset()
        try expect(!hints.visible,"Controller shutdown clears visible hints and cancels its timer")
    }
    private static func waitInTrackingRunLoop(_ condition:()->Bool)->Bool {
        // AppKit's tracking loops do not necessarily service Swift concurrency's
        // main-queue continuations. Timers registered in common modes must work.
        let mode=RunLoop.Mode.eventTracking
        CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFRunLoopMode(rawValue:mode.rawValue as CFString))
        let limit=Date().addingTimeInterval(1.2)
        while !condition(),Date()<limit {_=RunLoop.main.run(mode:mode,before:Date().addingTimeInterval(0.02))}
        return condition()
    }
}
