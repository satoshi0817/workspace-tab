import AppKit

/// Native menu tracking provides cursor placement, screen-edge adjustment and keyboard navigation.
@MainActor final class NotionCreationMenu:NSObject {
    let source:PageReference
    private let perform:(String,PageReference)->Void
    private var chosen=false
    static let choices:[(id:String,title:String,symbol:String)]=[
        ("notionPage","新規ページ","doc.badge.plus"),
        ("notionChat","AIチャット","bubble.left.and.bubble.right"),
        ("notionMeeting","ミーティングノート","calendar.badge.plus")
    ]
    init(source:PageReference,perform:@escaping(String,PageReference)->Void) {
        self.source=source;self.perform=perform
    }
    lazy var menu:NSMenu = {
        let menu=NSMenu(title:"Notionで作成");menu.autoenablesItems=false
        let heading=NSMenuItem(title:"Notionで作成",action:nil,keyEquivalent:"");heading.isEnabled=false
        menu.addItem(heading);menu.addItem(.separator())
        for (index,choice) in Self.choices.enumerated() {
            let item=NSMenuItem(title:choice.title,action:#selector(select(_:)),keyEquivalent:String(index+1))
            item.keyEquivalentModifierMask=[];item.target=self;item.representedObject=choice.id
            item.image=NSImage(systemSymbolName:choice.symbol,accessibilityDescription:nil)
            item.toolTip="現在の環境の新しいタブで開きます"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let footer=NSMenuItem(title:"新しいタブで開きます",action:nil,keyEquivalent:"");footer.isEnabled=false;menu.addItem(footer)
        return menu
    }()
    func show(at point:NSPoint = NSEvent.mouseLocation) {
        guard let window=NSApp.keyWindow,let view=window.contentView else{return}
        let local=view.convert(window.convertPoint(fromScreen:point),from:nil)
        menu.popUp(positioning:nil,at:local,in:view)
    }
    @objc private func select(_ item:NSMenuItem) {
        guard !chosen,let id=item.representedObject as? String,
              Self.choices.contains(where:{$0.id == id}) else{return}
        chosen=true
        // Finish native menu tracking before navigating or creating a WebKit view.
        let source=source,perform=perform
        DispatchQueue.main.async {perform(id,source)}
    }
}

extension BrowserStore {
    func openNotionCreationMenu() {
        guard !anyPanelPresented,let source=commandPage else{return}
        let popup=NotionCreationMenu(source:source) { [weak self] action,target in
            self?.runCommand(action,target:target)
        }
        notionCreationMenu=popup
        let point=NSEvent.mouseLocation
        // Enter tracking after the initiating key/menu event has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self,self.notionCreationMenu === popup else{return}
            popup.show(at:point)
            self.notionCreationMenu=nil
        }
    }
}
