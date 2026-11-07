import AppKit
import WorkspaceCore

// Runs the actual WorkspaceStore against a deterministic AX stub.
// No user preferences, groups, or real windows are modified.
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceTabs-audit-data-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let element = AXUIElementCreateApplication(123456)
    let window = ExternalWindow(id: UUID(), element: element, pid: 123456, bundleID: "audit.fake", appName: "Audit", title: "Original page", frame: WindowAccess.observedFrame, fullScreen: false, minimized: false)
    let secondWindow = ExternalWindow(id: UUID(), element: AXUIElementCreateApplication(123457), pid: 123456, bundleID: "audit.fake", appName: "Audit", title: "Second", frame: window.frame, fullScreen: false, minimized: false)
    @MainActor func makeStore(_ name: String) -> WorkspaceStore {
        WindowAccess.roleFailure = false; WindowAccess.gone = false
        WindowAccess.activationSuccess = true; WindowAccess.focused = nil; WindowAccess.writes = []
        WindowAccess.inventory = [window]
        let store = WorkspaceStore(directory: root.appendingPathComponent(name))
        store.groups = [WorkspaceGroup(tabs: [WorkspaceTab(bundleID: window.bundleID, windowTitle: window.title)], frame: WindowRect(window.frame))]
        store.selectedGroupID = store.groups[0].id
        store.restoreOpenWindowsAtLaunch()
        return store
    }
    var result: [String: Any] = [:]
    do {
        let s = makeStore("timeout")
        WindowAccess.roleFailure = true
        var renamed = window; renamed.title = "Renamed page"; WindowAccess.inventory = [renamed]
        s.tick()
        result["connectionSurvivesTransientFailureAndTitleChange"] = s.connectedIDs.count == 1
        s.shutdown()
    }
    do {
        let s = makeStore("activation")
        WindowAccess.activationSuccess = false
        s.activate(s.groups[0].tabs[0].id)
        result["connectionSurvivesTransientActivationFailure"] = s.connectedIDs.count == 1
        s.shutdown()
    }
    do {
        let s = makeStore("closed")
        WindowAccess.gone = true; WindowAccess.inventory = []
        s.tick()
        result["closedWindowDisconnects"] = s.connectedIDs.isEmpty
        s.shutdown()
    }
    do {
        let s = makeStore("fallback")
        let first = s.groups[0].tabs[0].id
        let other = WorkspaceTab(bundleID: "audit.fake", windowTitle: "Second")
        s.groups[0].tabs.append(other)
        s.bindings[other.id] = secondWindow
        s.connectedIDs.insert(other.id)
        s.disconnect(first)
        result["disconnectedSelectionFallsBackToConnectedTab"] = s.groups[0].selectedTabID == other.id
        s.shutdown()
    }
    do {
        let s = makeStore("feedback")
        let first = s.groups[0].tabs[0].id
        let other = WorkspaceTab(bundleID: "audit.fake", windowTitle: "Second")
        s.groups[0].tabs.append(other); s.bindings[other.id] = secondWindow; s.connectedIDs.insert(other.id)
        let target = CGRect(x: 50, y: 50, width: 900, height: 600)
        s.groups[0].frame = WindowRect(target)
        s.activate(first) // AX write returns success but observed geometry is still old.
        WindowAccess.focused = (window.pid, element)
        WindowAccess.writes = []
        s.tick()
        result["intermediateFrameNotPropagatedToOtherTabs"] = WindowAccess.writes.isEmpty
        s.shutdown()
    }
    do {
        let s = makeStore("focus-race")
        let other = WorkspaceTab(bundleID: "audit.fake", windowTitle: "Second")
        s.groups[0].tabs.append(other); s.bindings[other.id] = secondWindow; s.connectedIDs.insert(other.id)
        s.activate(other.id)
        WindowAccess.focused = (window.pid, element) // OS still reports the old tab during activation.
        s.tick()
        result["oldFocusCannotUndoNewTabSelection"] = s.groups[0].selectedTabID == other.id
        s.shutdown()
    }
    do {
        let s = makeStore("session")
        var customized = s.groups[0].tabs[0]
        customized.name = "Saved workspace"; customized.emoji = "🌙"; customized.color = "#123456"; customized.textColor = "white"
        s.updateTab(customized); s.saveNow()
        WindowAccess.gone = true; WindowAccess.inventory = []
        s.watchSavedWindows()
        result["closedSourceKeepsCustomization"] = s.tab(customized.id) == customized && s.connectedIDs.isEmpty
        s.saveNow()
        let restored = WorkspaceStore(directory: s.directory)
        restored.restoreOpenWindowsAtLaunch()
        result["missingAtLaunchKeepsCustomization"] = restored.tab(customized.id) == customized
        WindowAccess.gone = false; WindowAccess.inventory = [window]
        restored.watchSavedWindows()
        result["laterWindowRestoresSavedTab"] = restored.connectedIDs.contains(customized.id) && restored.tab(customized.id)?.name == customized.name && restored.tab(customized.id)?.emoji == customized.emoji
        let absent = WorkspaceTab(bundleID: "audit.fake", windowTitle: "Duplicate", name: "Keep A")
        let absentB = WorkspaceTab(bundleID: "audit.fake", windowTitle: "Duplicate", name: "Keep B")
        restored.groups[0].tabs.append(contentsOf: [absent, absentB])
        var duplicate = window; duplicate.title = "Duplicate"
        WindowAccess.inventory = [duplicate]
        restored.watchSavedWindows()
        result["ambiguousTabsRemainSaved"] = restored.tab(absent.id) == absent && restored.tab(absentB.id) == absentB && !restored.connectedIDs.contains(absent.id)
        restored.shutdown(); s.shutdown()
    }
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
}
