import AppKit
import SwiftUI
import WorkspaceCore

/// The shortcut list shown while ⌘ is held. Pressing ↑ or ↓ with ⌘ still down keeps it
/// open, after which the arrows choose an entry and Return runs it.
@MainActor enum ShortcutCheatSheet {
    static let groups:[(title:String,ids:[String])]=[
        ("タブ",["new","close","reopen","previousPage","nextPage","recentTabs","home","toggleSplit","focusSplit"]),
        ("移動・検索",["location","reload","commands","search","favorites","addFavorite","copyURL","copyTitleLink","lastWorkspace","previousWorkspace","nextWorkspace"]),
        ("Notion",["notionCreateMenu","notionChat","notionPage","notionMeeting","notionDatabase","notionCustomPage","notionSearch","notionSettings","notionSwitchAccount","agentChats"]),
        ("表示",["zoomIn","zoomOut","zoomReset","fullscreen","settings"])
    ]
    /// Three columns; the short Notion and view groups share the last one.
    static let columnGroups=[[0],[1],[2,3]]
    static func columns(_ preferences:ShortcutPreferences = .shared)->[[ShortcutAction]] {
        columnGroups.map{$0.flatMap{actions(inGroup:$0,preferences)}}
    }
    static func actions(inGroup index:Int,_ preferences:ShortcutPreferences = .shared)->[ShortcutAction] {
        groups[index].ids.compactMap{id in ShortcutPreferences.actions.first{$0.id == id}}.filter{
            let binding=preferences.binding($0);return binding.sequence != nil || !binding.key.isEmpty
        }
    }
    /// The selection after an arrow key: ↑↓ walk every entry in reading order, ←→ keep the row.
    static func move(_ selection:(column:Int,row:Int),keyCode:UInt16,counts:[Int])->(column:Int,row:Int) {
        guard counts.contains(where:{$0 > 0}) else{return selection}
        var column=min(max(selection.column,0),counts.count-1),row=selection.row
        let step={(delta:Int) in
            repeat {column=(column+delta+counts.count)%counts.count} while counts[column] == 0
        }
        switch keyCode {
        case 125:
            if row+1 < counts[column] {row += 1} else {step(1);row=0}
        case 126:
            if row > 0 {row -= 1} else {step(-1);row=counts[column]-1}
        case 124:step(1);row=min(row,counts[column]-1)
        case 123:step(-1);row=min(row,counts[column]-1)
        default:break
        }
        return (column,max(row,0))
    }
}

extension BrowserStore {
    var cheatSheetVisible:Bool {cheatSheetPinned || cheatSheetHeld}
    func dismissCheatSheet() {
        guard cheatSheetPinned else{return}
        cheatSheetPinned=false
    }
    /// ⌘↑ / ⌘↓ while the held list is showing: keep it open instead of scrolling the page.
    func cheatSheetWantsPin(_ event:NSEvent)->Bool {
        event.type == .keyDown && !cheatSheetPinned && cheatSheetHeld && [125,126].contains(event.keyCode) &&
        event.modifierFlags.intersection([.command,.control,.option,.shift]) == .command
    }
    /// Returns true when the key belonged to the list and must not reach the page.
    func handleCheatSheetKey(_ event:NSEvent)->Bool {
        guard event.type == .keyDown else{return false}
        let columns=ShortcutCheatSheet.columns(),counts=columns.map(\.count)
        if cheatSheetWantsPin(event) {
            let first=counts.firstIndex{$0 > 0} ?? 0,last=counts.lastIndex{$0 > 0} ?? 0
            cheatSheetSelection=event.keyCode == 125 ? (first,0):(last,max(counts[last]-1,0))
            cheatSheetPinned=true;cheatSheetHeld=false
            resetWorkspaceHints()
            return true
        }
        guard cheatSheetPinned else{return false}
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        switch event.keyCode {
        case 53:dismissCheatSheet();return true
        case 123...126 where flags.isEmpty || flags == .command:
            cheatSheetSelection=ShortcutCheatSheet.move(cheatSheetSelection,keyCode:event.keyCode,counts:counts);return true
        case 36,76:
            let (column,row)=cheatSheetSelection
            dismissCheatSheet()
            if columns.indices.contains(column),columns[column].indices.contains(row) {runCheatSheetAction(columns[column][row])}
            return true
        default:
            // Any other key ends the list and goes on to do what it normally does.
            dismissCheatSheet();return false
        }
    }
    func runCheatSheetAction(_ action:ShortcutAction) {
        dismissCheatSheet()
        DispatchQueue.main.async { [weak self] in self?.runShortcutAction?(action) }
    }
}

struct ShortcutCheatSheetOverlay:View {
    @ObservedObject var store:BrowserStore
    var body:some View {
        // Once it is kept open, a click anywhere else closes the list instead of reaching the page.
        if store.cheatSheetPinned {Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture {store.dismissCheatSheet()}}
    }
}

/// The list itself. It is laid over the page area only, so the app tabs stay visible.
struct ShortcutCheatSheetCard:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject private var shortcuts=ShortcutPreferences.shared
    private static let margin:CGFloat=32,inset:CGFloat=24,columnGap:CGFloat=28
    var body:some View {
        if store.cheatSheetVisible {
            GeometryReader {proxy in
                let count=CGFloat(ShortcutCheatSheet.columnGroups.count)
                let room=proxy.size.width-Self.margin*2-Self.inset*2
                let width=(room-Self.columnGap*(count-1))/count
                // Three columns need room to breathe. A narrow window stacks them instead of squeezing.
                let stacked=width < 220
                card(columnWidth:stacked ? min(max(room,220),360):min(width,270),stacked:stacked)
                    .frame(maxHeight:max(proxy.size.height-Self.margin*2,200))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }.allowsHitTesting(store.cheatSheetPinned).transition(.opacity)
        }
    }
    private var selectedID:String? {
        let selection=store.cheatSheetSelection
        guard store.cheatSheetPinned,ShortcutCheatSheet.columnGroups.indices.contains(selection.column) else{return nil}
        let actions=ShortcutCheatSheet.columnGroups[selection.column].flatMap{ShortcutCheatSheet.actions(inGroup:$0,shortcuts)}
        return actions.indices.contains(selection.row) ? actions[selection.row].id:nil
    }
    private func card(columnWidth:CGFloat,stacked:Bool)->some View {
        let pinned=store.cheatSheetPinned
        return VStack(alignment:.leading,spacing:16) {
            ViewThatFits(in:.vertical) {
                columns(width:columnWidth,stacked:stacked)
                ScrollViewReader {reader in
                    ScrollView(.vertical,showsIndicators:true) {columns(width:columnWidth,stacked:stacked)}
                        .onChange(of:selectedID) {_,id in if let id {withAnimation(.easeOut(duration:0.12)) {reader.scrollTo(id,anchor:.center)}}}
                }
            }
            Divider()
            Label(pinned ? L("↑↓←→ で選択・Enterで実行・Escで閉じる"):L("⌘を押したまま ↑ か ↓ を押すと、選んで実行できます"),systemImage:pinned ? "arrow.up.arrow.down":"command")
                .font(.system(size:12,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,10)
        }
        .padding(Self.inset)
        .fixedSize(horizontal:true,vertical:false)
        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(.primary.opacity(0.12)))
        .shadow(color:.black.opacity(0.25),radius:18,y:6)
        .accessibilityElement(children:.contain).accessibilityLabel(L("ショートカット一覧"))
    }
    private func columns(width:CGFloat,stacked:Bool)->some View {
        let pinned=store.cheatSheetPinned
        let layout=stacked ? AnyLayout(VStackLayout(alignment:.leading,spacing:20)):AnyLayout(HStackLayout(alignment:.top,spacing:Self.columnGap))
        return layout {
            ForEach(Array(ShortcutCheatSheet.columnGroups.enumerated()),id:\.offset) {column,groups in
                VStack(alignment:.leading,spacing:20) {
                    ForEach(groups,id:\.self) {group in
                        let offset=groups.prefix{$0 != group}.reduce(0){$0+ShortcutCheatSheet.actions(inGroup:$1,shortcuts).count}
                        VStack(alignment:.leading,spacing:4) {
                            Text(Localization.text(ShortcutCheatSheet.groups[group].title)).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,10).padding(.bottom,6)
                            ForEach(Array(ShortcutCheatSheet.actions(inGroup:group,shortcuts).enumerated()),id:\.element.id) {index,action in
                                row(action,selected:pinned && store.cheatSheetSelection == (column,offset+index)).id(action.id)
                            }
                        }
                    }
                }.frame(width:width,alignment:.topLeading)
            }
        }
    }
    private func row(_ action:ShortcutAction,selected:Bool)->some View {
        Button {store.runCheatSheetAction(action)} label:{
            HStack(spacing:12) {
                Text(action.title).font(.system(size:13)).lineLimit(1)
                Spacer(minLength:12)
                Text(shortcuts.binding(action).label).font(.system(size:11,weight:.semibold,design:.monospaced)).lineLimit(1).fixedSize()
                    .padding(.horizontal,7).padding(.vertical,3)
                    .background(selected ? Color.white.opacity(0.22):Color.primary.opacity(0.08),in:RoundedRectangle(cornerRadius:5,style:.continuous))
            }
            .padding(.horizontal,10).frame(height:30)
            .foregroundStyle(selected ? Color.white:Color.primary)
            .background(selected ? Color.accentColor:Color.clear,in:RoundedRectangle(cornerRadius:7,style:.continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(action.title+" "+shortcuts.binding(action).label).accessibilityAddTraits(selected ? .isSelected:[])
    }
}
