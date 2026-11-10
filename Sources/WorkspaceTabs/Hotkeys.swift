import WorkspaceCore
import AppKit
import Carbon

@MainActor final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var navigationRefs: [EventHotKeyRef] = []
    private var navigationActive = false
    var action: ((UInt32) -> Void)?
    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) };refs.removeAll()
        if let handler {RemoveEventHandler(handler)};handler=nil
    }
    func register() -> [String] {
        unregister()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x57535442 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<Hotkeys>.fromOpaque(pointer).takeUnretainedValue()
            owner.action?(id.id)
            return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else { return [L("ショートカットのイベントを登録できませんでした。")] }
        var failures: [String] = []
        for action in ShortcutPreferences.actions where action.globalID != nil {
            let binding=ShortcutPreferences.shared.binding(action)
            guard binding.sequence == nil else{continue}
            let key=binding.code, id=action.globalID!, name=binding.label
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), binding.carbon, EventHotKeyID(signature: 0x57535442, id: UInt32(id)),
                                            GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) }
            else { failures.append(L("\(name) は他のアプリと競合しているため使用できません（\(result)）。")) }
        }
        return failures
    }
    func setNavigationActive(_ active: Bool) -> [String] {
        guard active != navigationActive else { return [] }
        navigationActive = active
        for ref in navigationRefs { UnregisterEventHotKey(ref) }
        navigationRefs.removeAll()
        guard active else { return [] }
        var failures: [String] = []
        let shortcuts = [(kVK_LeftArrow, 1, "⌃⌥←"), (kVK_RightArrow, 2, "⌃⌥→"), (kVK_Tab, 4, "⌃⌥Tab")]
        for (key, id, name) in shortcuts {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x57535442, id: UInt32(id)), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { navigationRefs.append(ref) }
            else { failures.append(L("\(name) は他のアプリと競合しているため使用できません（\(result)）。")) }
        }
        return failures
    }
    deinit {
        for ref in refs { UnregisterEventHotKey(ref) }
        for ref in navigationRefs { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
