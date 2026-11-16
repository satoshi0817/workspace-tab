import WorkspaceCore
import AppKit
import SwiftUI

/// A creation picker centered on the browser window. Kept separate from the browser responder chain
/// so digits, arrows and Escape never reach the page or toggle fullscreen.
@MainActor final class NotionCreationMenu:NSObject,ObservableObject,NSWindowDelegate {
    let source:PageReference
    private let perform:(String,PageReference)->Void
    var onDismiss:(()->Void)?
    @Published private(set) var selectedIndex=0
    private var finished=false
    private var panel:CreationPanel?
    private weak var owner:NSWindow?
    private weak var previousResponder:NSResponder?
    private var monitor:Any?
    private var deactivateObserver:NSObjectProtocol?
    /// Page on the left, chat on the right: the two things almost always created from here.
    /// Meeting notes, databases and custom pages stay in the command search and their own shortcuts.
    static var choices:[(id:String,title:String,symbol:String)] {
        [
            ("notionPage",L("新規ページ"),"doc.text"),
            ("notionChat",L("新規チャット"),"bubble.left.and.text.bubble.right")
        ]
    }
    init(source:PageReference,perform:@escaping(String,PageReference)->Void) {
        self.source=source;self.perform=perform
    }
    func highlight(_ index:Int) {
        guard Self.choices.indices.contains(index) else{return}
        selectedIndex=index
    }
    static let size=NSSize(width:380,height:190)
    /// Centered over the browser window, like the new tab choice.
    static func frame(centeredIn window:NSRect,inside screen:NSRect)->NSRect {
        let x=window.midX-size.width/2,y=window.midY-size.height/2+window.height*0.12
        return NSRect(x:min(max(x,screen.minX+8),screen.maxX-size.width-8),y:min(max(y,screen.minY+8),screen.maxY-size.height-8),width:size.width,height:size.height)
    }
    func show(at point:NSPoint = NSEvent.mouseLocation) {
        guard !finished,let owner=NSApp.keyWindow else {dismiss(restoreFocus:false);return}
        self.owner=owner;previousResponder=owner.firstResponder
        let screen=owner.screen ?? NSScreen.screens.first{$0.frame.contains(point)} ?? NSScreen.main
        let popup=CreationPanel(contentRect:Self.frame(centeredIn:owner.frame,inside:screen?.visibleFrame ?? owner.frame),styleMask:[.borderless],backing:.buffered,defer:false)
        popup.isReleasedWhenClosed=false;popup.isOpaque=false;popup.backgroundColor = .clear
        popup.title=L("Notionで作成");popup.hasShadow=true;popup.level = .floating;popup.hidesOnDeactivate=true
        popup.collectionBehavior=[.fullScreenAuxiliary,.transient];popup.appearance=owner.effectiveAppearance
        popup.delegate=self;popup.contentView=NSHostingView(rootView:CreationPicker(menu:self))
        panel=popup
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
            guard let self else{return event}
            if event.type == .keyDown,event.window === self.panel {
                return self.handleKey(event) ? nil:event
            }
            if event.type != .keyDown,event.window !== self.panel {self.dismiss(restoreFocus:false)}
            return event
        }
        deactivateObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.dismiss(restoreFocus:false)}
        }
        owner.addChildWindow(popup,ordered:.above);popup.makeKeyAndOrderFront(nil)
    }
    @discardableResult func handleKey(_ event:NSEvent)->Bool {
        guard !finished else{return false}
        let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if event.keyCode == 53 {dismiss();return true}
        guard modifiers.isEmpty else{return false}
        switch event.keyCode {
        case 124,125,48:highlight((selectedIndex+1)%Self.choices.count)
        case 123,126:highlight((selectedIndex+Self.choices.count-1)%Self.choices.count)
        case 36,76:select(selectedIndex)
        default:
            guard let key=event.charactersIgnoringModifiers,let number=Int(key),Self.choices.indices.contains(number-1) else{return false}
            select(number-1)
        }
        return true
    }
    func select(_ index:Int) {
        guard !finished,Self.choices.indices.contains(index) else{return}
        let action=Self.choices[index].id,source=source,perform=perform
        dismiss()
        DispatchQueue.main.async {perform(action,source)}
    }
    func dismiss(restoreFocus:Bool=true) {
        guard !finished else{return};finished=true
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
        if let deactivateObserver {NotificationCenter.default.removeObserver(deactivateObserver);self.deactivateObserver=nil}
        if let panel {owner?.removeChildWindow(panel);panel.delegate=nil;panel.orderOut(nil);panel.close();self.panel=nil}
        if restoreFocus,let owner,owner.isVisible {owner.makeKeyAndOrderFront(nil);if let previousResponder {owner.makeFirstResponder(previousResponder)}}
        onDismiss?();onDismiss=nil
    }
    func windowDidResignKey(_ notification:Notification) {dismiss(restoreFocus:false)}
}
private final class CreationPanel:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {false}
    override func cancelOperation(_ sender:Any?) {} // Escape is handled by the picker.
}
private struct CreationPicker:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var menu:NotionCreationMenu
    @Environment(\.colorScheme) private var scheme
    private var ink:Color {scheme == .dark ? Color(white:0.9):Color(white:0.2)}
    private var background:Color {scheme == .dark ? Color(white:0.15):.white}
    var body:some View {
        VStack(spacing:12) {
            Text(L("Notionで作成")).font(.headline).foregroundStyle(ink)
            HStack(spacing:12) {
                ForEach(Array(NotionCreationMenu.choices.enumerated()),id:\.element.id) { index,choice in
                    let active=menu.selectedIndex == index
                    Button {menu.select(index)} label: {
                        VStack(spacing:10) {
                            Image(systemName:choice.symbol).font(.system(size:30,weight:.regular)).frame(height:36)
                            Text(choice.title).font(.system(size:14,weight:.semibold)).lineLimit(1)
                            Text(index == 0 ? "←":"→").font(.system(size:12,weight:.medium).monospaced()).foregroundStyle(ink.opacity(0.45))
                        }
                        .foregroundStyle(ink).frame(maxWidth:.infinity).frame(height:118)
                        .background(active ? Color.accentColor.opacity(0.14):ink.opacity(0.04),in:RoundedRectangle(cornerRadius:12,style:.continuous))
                        .overlay(RoundedRectangle(cornerRadius:12,style:.continuous).strokeBorder(active ? Color.accentColor:ink.opacity(0.08),lineWidth:active ? 2:1))
                        .contentShape(RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).onHover {inside in if inside {menu.highlight(index)}}
                    .accessibilityLabel(choice.title).accessibilityAddTraits(active ? .isSelected:[])
                }
            }
            Text(L("← → で選んで ⏎、Escで閉じる")).font(.caption).foregroundStyle(ink.opacity(0.5))
        }.padding(14).frame(width:NotionCreationMenu.size.width,height:NotionCreationMenu.size.height)
        .background(background,in:RoundedRectangle(cornerRadius:16))
        .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(ink.opacity(0.1),lineWidth:0.5))
    }
}

extension BrowserStore {
    func openNotionCreationMenu() {
        guard !anyPanelPresented,let source=commandPage else{return}
        let popup=NotionCreationMenu(source:source) { [weak self] action,target in
            self?.runCommand(action,target:target)
        }
        popup.onDismiss={ [weak self,weak popup] in
            guard let self,self.notionCreationMenu === popup else{return}
            self.notionCreationMenu=nil
        }
        notionCreationMenu=popup
        let point=NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            guard self?.notionCreationMenu === popup else{return}
            popup.show(at:point)
        }
    }
}
