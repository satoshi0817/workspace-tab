import AppKit
import SwiftUI
import WorkspaceCore

extension BrowserStore {
    func toggleAgentChats() {
        agentChatsPresented.toggle()
        if agentChatsPresented {window?.makeKeyAndOrderFront(nil)} else {restorePanelFocus()}
    }
    /// Chats open in this app's Notion tabs, as (Notion workspace ID, chat ID).
    func agentChatsInTabs()->[(space:String,id:String)] {
        session.workspaces.flatMap {workspace->[(space:String,id:String)] in
            guard let space=workspace.notionSpaceID else{return []}
            return workspace.pages.compactMap {page in URL(string:page.url).flatMap(AgentChat.chatID).map{(space,$0)}}
        }
    }
    /// A Notion tab moved to a chat: Notion's list leaves recent chats out, so it is remembered here.
    func noteAgentChat(in workspaceID:UUID,url:URL) {
        guard let id=AgentChat.chatID(in:url),let space=workspace(workspaceID)?.notionSpaceID else{return}
        agentChats.discover([(space,id)])
    }
    private func agentWorkspace(_ row:AgentChatRow)->BrowserWorkspace? {
        let target=AgentChat.compact(row.account.workspaceID)
        return session.workspaces.first(where:{AgentChat.compact($0.notionSpaceID) == target})
    }
    /// Notion links in a reply open in the account's app tab; anything else goes to the system.
    func openAgentLink(_ url:URL,from row:AgentChatRow)->OpenURLAction.Result {
        let host=url.host?.lowercased() ?? ""
        let notion=["notion.so","notion.com","notion.site"].contains{host == $0 || host.hasSuffix("."+$0)}
        guard ["http","https"].contains(url.scheme?.lowercased() ?? ""),notion,let workspace=agentWorkspace(row),addPage(to:workspace.id,url:url.absoluteString) != nil else{return .systemAction}
        agentChatsPresented=false
        selectWorkspace(workspace.id)
        return .handled
    }
    /// Opens a chat in the app tab set up for the same Notion workspace.
    func openAgentChat(_ row:AgentChatRow) {
        guard let workspace=agentWorkspace(row) else {
            notify(L("「\(row.account.title)」を開くアプリタブがありません。アプリタブの設定でNotionワークスペースを指定してください"),isError:true);return
        }
        let host=BrowserAddress.url(workspace.homeURL)?.host
        guard let url=AgentChat.chatURL(host:host,sessionID:row.session.id),addPage(to:workspace.id,url:url) != nil else{return}
        agentChatsPresented=false
        selectWorkspace(workspace.id)
    }
}

private enum AgentChatFilter:String,CaseIterable {
    case all,waiting,running
    var title:String {
        switch self {case .all:return L("すべて");case .waiting:return L("対応待ち");case .running:return L("実行中")}
    }
}

/// One height for the page's buttons and status pills, so a row of them lines up.
private enum AgentChatMetrics {static let control:CGFloat=28,compact:CGFloat=20}

/// The page's buttons: one height, one corner, one font, whether they hold text or only an icon.
private struct AgentChatButtonStyle:ButtonStyle {
    var iconOnly=false
    func makeBody(configuration:Configuration)->some View {Face(configuration:configuration,iconOnly:iconOnly)}
    private struct Face:View {
        let configuration:Configuration
        let iconOnly:Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering=false
        var body:some View {
            let shape=RoundedRectangle(cornerRadius:7,style:.continuous)
            configuration.label.labelStyle(Compact()).font(.system(size:13,weight:.medium)).foregroundStyle(.primary)
                .padding(.horizontal,iconOnly ? 0:10)
                .frame(width:iconOnly ? AgentChatMetrics.control:nil,height:AgentChatMetrics.control)
                .background(Color.primary.opacity(configuration.isPressed ? 0.16:hovering && enabled ? 0.11:0.07),in:shape)
                .contentShape(shape).opacity(enabled ? 1:0.45).onHover {hovering=$0}
        }
    }
    private struct Compact:LabelStyle {
        func makeBody(configuration:Configuration)->some View {HStack(spacing:5) {configuration.icon;configuration.title}}
    }
}

struct AgentChatStatusBadge:View {
    let status:String
    /// Rows and the conversation use the small pill; next to buttons it takes their height.
    var compact=true
    private var look:(String,Color,String) {Self.look(status)}
    /// Title, color and symbol of a status.
    static func look(_ status:String)->(String,Color,String) {
        switch status {
        case "requires_action":return (L("対応待ち"),.orange,"exclamationmark.circle.fill")
        case "in_progress":return (L("実行中"),.blue,"circle.dotted")
        case "queued":return (L("待機中"),.blue,"clock")
        case "completed":return (L("完了"),.green,"checkmark.circle.fill")
        case "failed":return (L("失敗"),.red,"xmark.octagon.fill")
        case "canceled":return (L("キャンセル"),.gray,"slash.circle")
        case "terminated":return (L("中断"),.gray,"stop.circle")
        default:return (status,.gray,"questionmark.circle")
        }
    }
    var body:some View {
        let (title,color,symbol)=look
        HStack(spacing:4) {Image(systemName:symbol);Text(title)}
            .font(.system(size:compact ? 11:12,weight:.semibold)).foregroundStyle(color)
            .padding(.horizontal,compact ? 8:11).frame(height:compact ? AgentChatMetrics.compact:AgentChatMetrics.control)
            .background(color.opacity(0.14),in:Capsule()).fixedSize().accessibilityElement(children:.combine)
    }
}

/// The account's own icon, emoji or color when the user set one, otherwise Notion's photo.
private struct AgentChatAvatar:View {
    let store:BrowserStore
    let account:AgentChatAccount
    var size:CGFloat=22

    /// A centered rectangle touches the surrounding circle at all four corners when its diagonal equals the diameter.
    private func inscribedImage(_ image: Image) -> some View {
        image.resizable().scaledToFit()
            .visualEffect { [diameter = size] content, geometry in
                let bounds = geometry.size
                let diagonal = hypot(bounds.width, bounds.height)
                return content.scaleEffect(diagonal > 0 ? diameter / diagonal : 1)
            }
            .frame(width:size,height:size)
    }

    var body:some View {
        let tint=account.color.map(Palette.color)
        let ink=account.color.map{Palette.ink($0)} ?? Color.primary
        let fill=tint ?? Color.primary.opacity(0.16)
        let outline=Circle().strokeBorder(Color.primary.opacity(0.18))
        let filledCircle=Circle().fill(fill).overlay(outline)
        let letter=account.nickname.flatMap(AgentChatAccount.clean) ?? account.person
        let initial=Text(String(letter.prefix(1)).uppercased()).font(.system(size:size*0.48,weight:.semibold))
            .foregroundStyle(ink).frame(width:size,height:size).background(fill).clipShape(Circle()).overlay(outline)
        Group {
            if let file=account.iconFile,let image=store.iconCache.image(directory:store.directory,name:file) {
                inscribedImage(Image(nsImage:image).renderingMode(image.isTemplate ? .template:.original))
                    .foregroundStyle(ink)
                    .background { if image.isTemplate {filledCircle} else {outline} }
            } else if let emoji=account.emoji.flatMap(AgentChatAccount.clean) {
                Text(emoji).font(.system(size:size*0.55,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.4)
                    .foregroundStyle(ink).frame(width:size,height:size).background(fill).clipShape(Circle()).overlay(outline)
            } else if account.color == nil,let url=account.avatarURL.flatMap(URL.init(string:)),url.scheme == "https" {
                AsyncImage(url:url) {phase in
                    if let image=phase.image {inscribedImage(image).background(outline)} else {initial}
                }
            } else {initial}
        }.frame(width:size,height:size)
            .accessibilityHidden(true)
    }
}

/// What the name sheet renames: a chat or a group.
private enum AgentChatNaming:Identifiable {
    case chat(AgentChatRow)
    case group(AgentChatGroup)
    var id:String {
        switch self {
        case .chat(let row):return "chat-"+row.id
        case .group(let group):return "group-"+group.id.uuidString
        }
    }
}

struct AgentChatPage:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    @State private var filter=AgentChatFilter.all
    @State private var query=""
    @State private var managing=false
    @State private var composing=false
    @State private var editing:AgentChatAccount?
    @State private var naming:AgentChatNaming?
    fileprivate static let relative:RelativeDateTimeFormatter = {let f=RelativeDateTimeFormatter();f.unitsStyle = .short;return f}()

    /// The account sidebar appears once there is more than one account to choose from.
    private var showsAccounts:Bool {hub.accounts.count>1}
    private var accountFilter:UUID? {showsAccounts ? hub.accountFilter:nil}
    private var needle:String {query.trimmingCharacters(in:.whitespaces).lowercased()}
    private func passes(_ row:AgentChatRow)->Bool {
        if let accountFilter,row.account.id != accountFilter {return false}
        switch filter {
        case .all:return true
        case .waiting:return row.session.needsAction
        case .running:return row.session.active
        }
    }
    private func matches(_ row:AgentChatRow)->Bool {
        needle.isEmpty || [hub.title(row),row.session.title,hub.agentName(row),row.account.title,row.account.person].contains{$0.lowercased().contains(needle)}
    }
    private var rows:[AgentChatRow] {hub.rows.filter{passes($0) && matches($0)}}
    /// Groups with a chat that passes the filters, or whose name matches the search.
    private var shownGroups:[AgentChatGroup] {
        hub.groups.filter {group in
            let members=hub.rows(in:group)
            if (accountFilter != nil || filter != .all) && !members.contains(where:passes) {return false}
            return needle.isEmpty || group.name.lowercased().contains(needle) || members.contains(where:matches)
        }
    }
    private func count(_ filter:AgentChatFilter)->Int {
        hub.rows.filter {row in
            if let accountFilter,row.account.id != accountFilter {return false}
            return filter == .waiting ? row.session.needsAction:filter == .running ? row.session.active:true
        }.count
    }
    var body:some View {
        VStack(spacing:0) {
            header
            Divider()
            if hub.accounts.isEmpty {empty} else {
                HSplitView {
                    if showsAccounts {sidebar.frame(minWidth:170,idealWidth:210,maxWidth:300)}
                    list.frame(minWidth:290,idealWidth:390,maxWidth:560)
                    detail.frame(minWidth:340,maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .onAppear {hub.discover(store.agentChatsInTabs());hub.startPolling()}
        .onDisappear {hub.stopPolling()}
        .sheet(isPresented:$managing) {AgentChatAccounts(store:store,hub:hub)}
        .sheet(isPresented:$composing) {AgentChatComposer(store:store,hub:hub,initial:accountFilter)}
        .sheet(item:$editing) {AgentChatAccountEditor(store:store,hub:hub,draft:$0)}
        .sheet(item:$naming) {AgentChatNameSheet(hub:hub,target:$0)}
    }
    private var sidebar:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:2) {
                Text(L("アカウント")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,8).padding(.bottom,4)
                sidebarItem(nil)
                ForEach(hub.accounts) {sidebarItem($0)}
            }.padding(10)
        }
    }
    /// One account, or every account when nil, with how many of its chats wait for the user.
    private func sidebarItem(_ account:AgentChatAccount?)->some View {
        let id=account?.id
        let chats=hub.rows.filter {id == nil || $0.account.id == id}
        let waiting=chats.filter(\.session.needsAction).count
        let selected=accountFilter == id
        let problem=account.flatMap{hub.failures[$0.id]}
        return Button {hub.accountFilter=id} label:{
            HStack(spacing:8) {
                if let account {AgentChatAvatar(store:store,account:account,size:24)}
                else {Image(systemName:"tray.2").font(.system(size:13)).frame(width:24,height:24).background(.primary.opacity(0.08),in:Circle())}
                VStack(alignment:.leading,spacing:1) {
                    Text(account?.title ?? L("すべてのアカウント")).font(.system(size:13,weight:.medium)).lineLimit(1)
                    if let account {Text(account.person).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
                }
                Spacer(minLength:4)
                if let problem {Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.red).help(problem)}
                if waiting>0 {
                    Text("\(waiting)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal,6).padding(.vertical,1).background(Color.orange,in:Capsule()).help(L("対応待ち"))
                } else {Text("\(chats.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)}
            }.padding(.horizontal,8).padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading)
                .background(selected ? Color.accentColor.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:8,style:.continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected:[])
            .accessibilityLabel((account.map{$0.title+" "+$0.person} ?? L("すべてのアカウント"))+(waiting>0 ? " "+L("対応待ち")+" \(waiting)":""))
            .contextMenu {
                if let account {Button(L("表示を編集…")) {editing=account}}
            }
    }
    private var header:some View {
        HStack(spacing:12) {
            Label(L("Notion AIのチャット"),systemImage:"bubble.left.and.bubble.right").font(.title3.weight(.semibold))
            if hub.loading {ProgressView().controlSize(.small)}
            else if let at=hub.refreshedAt {Text(L("更新: ")+Self.relative.localizedString(for:at,relativeTo:Date())).font(.caption).foregroundStyle(.secondary)}
            Spacer(minLength:12)
            HStack(spacing:8) {
                Button {composing=true} label:{Label(L("新しいチャット"),systemImage:"square.and.pencil")}.disabled(hub.accounts.isEmpty)
                Button {hub.refresh()} label:{Image(systemName:"arrow.clockwise")}.buttonStyle(AgentChatButtonStyle(iconOnly:true))
                    .help(L("再読み込み")).accessibilityLabel(L("再読み込み")).disabled(hub.loading || hub.accounts.isEmpty)
                Button {managing=true} label:{Label(L("アカウント"),systemImage:"person.2")}
                Button {store.toggleAgentChats()} label:{Image(systemName:"xmark")}.buttonStyle(AgentChatButtonStyle(iconOnly:true))
                    .help(L("閉じる")).accessibilityLabel(L("閉じる")).keyboardShortcut(.cancelAction)
            }.buttonStyle(AgentChatButtonStyle())
        }.padding(.horizontal,20).padding(.vertical,12)
    }
    private var empty:some View {
        VStack(spacing:14) {
            Image(systemName:"bubble.left.and.bubble.right").font(.system(size:40)).foregroundStyle(.secondary)
            Text(L("Notionのアカウントを登録すると、すべてのワークスペースのチャットをここで確認できます")).font(.headline).multilineTextAlignment(.center)
            Text(L("ワークスペースごとに、Notionの個人アクセストークンを1つ登録します。")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L("アカウントを登録…")) {managing=true}.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(40).frame(maxWidth:520).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var list:some View {
        let rows=rows,groups=shownGroups
        let pinned=rows.filter(hub.isPinned).sorted{(hub.pinnedAt($0) ?? .distantPast)>(hub.pinnedAt($1) ?? .distantPast)}
        let others=rows.filter{!hub.isPinned($0)}
        return VStack(spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                HStack(spacing:8) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("タイトルで絞り込み"),text:$query).textFieldStyle(.plain)
                }.padding(.horizontal,10).frame(height:30).background(.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:8,style:.continuous))
                HStack(spacing:8) {
                    Picker("",selection:$filter) {
                        ForEach(AgentChatFilter.allCases,id:\.self) {item in Text(item == .all ? item.title:item.title+" \(count(item))").tag(item)}
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }.padding(16)
            Divider()
            ForEach(hub.accounts.filter{hub.failures[$0.id] != nil && (accountFilter == nil || accountFilter == $0.id)}) {account in
                Label(account.title+": "+(hub.failures[account.id] ?? ""),systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16).padding(.vertical,8).background(Color.red.opacity(0.08))
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:4) {
                    if !groups.isEmpty {
                        section(L("グループ"),systemImage:"square.stack")
                        ForEach(groups) {groupView($0)}
                    }
                    if !pinned.isEmpty {
                        section(L("ピン留め"),systemImage:"pin")
                        ForEach(pinned) {rowView($0)}
                    }
                    if (!groups.isEmpty || !pinned.isEmpty) && !others.isEmpty {section(L("チャット"),systemImage:"bubble.left")}
                    ForEach(others) {rowView($0)}
                    if rows.isEmpty && groups.isEmpty {
                        Text(hub.loading ? L("読み込んでいます…"):L("該当するチャットはありません")).font(.callout).foregroundStyle(.secondary).padding(.vertical,40).frame(maxWidth:.infinity)
                    }
                    if hub.hasMore {Button(L("さらに読み込む")) {hub.loadMore()}.disabled(hub.loading).padding(.vertical,12).frame(maxWidth:.infinity)}
                }.padding(10)
            }
        }
    }
    private func section(_ title:String,systemImage:String)->some View {
        Label(title,systemImage:systemImage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal,6).padding(.top,8).padding(.bottom,2).accessibilityAddTraits(.isHeader)
    }
    private func rowView(_ row:AgentChatRow)->some View {
        let selected=hub.selection == row.id
        let groups=hub.groups(of:row)
        return Button {hub.select(row.id)} label:{
            HStack(spacing:10) {
                AgentChatAvatar(store:store,account:row.account,size:40)
                VStack(alignment:.leading,spacing:6) {
                    HStack(alignment:.top,spacing:6) {
                        Text(hub.title(row)).font(.system(size:13,weight:.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth:.infinity,alignment:.leading)
                        if hub.isPinned(row) {Image(systemName:"pin.fill").font(.system(size:10)).foregroundStyle(.orange).padding(.top,3).accessibilityLabel(L("ピン留め"))}
                        AgentChatStatusBadge(status:row.session.status)
                    }
                    HStack(spacing:4) {
                        Text(row.account.title).lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                        Text(row.account.person).lineLimit(1)
                        if let group=groups.first {
                            Label(group.name+(groups.count>1 ? " +\(groups.count-1)":""),systemImage:"square.stack").lineLimit(1)
                                .padding(.horizontal,6).padding(.vertical,1).background(.primary.opacity(0.07),in:Capsule())
                        }
                        Spacer(minLength:0)
                        Text(Self.relative.localizedString(for:row.session.updatedAt,relativeTo:Date())).monospacedDigit().fixedSize()
                    }.font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                .background(selected ? Color.accentColor.opacity(0.16):Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:10,style:.continuous).strokeBorder(selected ? Color.accentColor.opacity(0.6):.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected:[])
            .contextMenu {AgentChatMenu(store:store,hub:hub,row:row,name:{naming=$0})}
    }
    private func groupView(_ group:AgentChatGroup)->some View {
        let members=hub.rows(in:group)
        let selected=hub.selectedGroup == group.id
        let status=members.map(\.session.status).min{AgentChat.rank($0)<AgentChat.rank($1)}
        let latest=members.map(\.session.updatedAt).max()
        return Button {hub.selectGroup(group.id)} label:{
            VStack(alignment:.leading,spacing:8) {
                HStack(alignment:.top,spacing:8) {
                    Image(systemName:"square.stack").font(.system(size:12)).foregroundStyle(.secondary).padding(.top,2)
                    Text(group.name).font(.system(size:13,weight:.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength:8)
                    if let status {AgentChatStatusBadge(status:status)}
                }
                HStack(spacing:6) {
                    HStack(spacing:-5) {ForEach(Array(members.prefix(5))) {AgentChatAvatar(store:store,account:$0.account,size:16)}}
                    Text(L("\(group.members.count)件のチャット")).lineLimit(1)
                    Spacer(minLength:8)
                    if let latest {Text(Self.relative.localizedString(for:latest,relativeTo:Date())).monospacedDigit().fixedSize()}
                }.font(.system(size:11)).foregroundStyle(.secondary)
            }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                .background(selected ? Color.accentColor.opacity(0.16):Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:10,style:.continuous).strokeBorder(selected ? Color.accentColor.opacity(0.6):.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected:[])
            .contextMenu {AgentChatGroupMenu(hub:hub,group:group,name:{naming=$0})}
    }
    @ViewBuilder private var detail:some View {
        if let group=hub.group(hub.selectedGroup) {AgentChatGroupView(store:store,hub:hub,group:group,name:{naming=$0}).id(group.id)}
        else if let row=hub.selectedRow {AgentChatDetail(store:store,hub:hub,thread:hub.thread(row.id),row:row,name:{naming=$0}).id(row.id)}
        else {
            Text(L("チャットを選ぶと、ここに内容が表示されます")).font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
}

/// Pin, rename and group a chat; shared by the list's context menu and the chat's own menu.
private struct AgentChatMenu:View {
    @ObservedObject private var localization=AppLocalization.shared
    let store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    let row:AgentChatRow
    let name:(AgentChatNaming)->Void
    var body:some View {
        let pinned=hub.isPinned(row)
        let others=hub.groups.filter{!$0.members.contains(row.id)},mine=hub.groups(of:row)
        Button(pinned ? L("ピン留めを外す"):L("ピン留めする")) {hub.setPinned(row,!pinned)}
        Button(L("名前を変更…")) {name(.chat(row))}
        Menu(L("グループに追加")) {
            ForEach(others) {group in Button(group.name) {hub.add(row,to:group.id)}}
            if !others.isEmpty {Divider()}
            Button(L("新しいグループ…")) {
                let id=hub.makeGroup(hub.title(row),members:[row.id])
                if let group=hub.group(id) {name(.group(group))}
            }
        }
        if !mine.isEmpty {
            Menu(L("グループから外す")) {ForEach(mine) {group in Button(group.name) {hub.remove(row,from:group.id)}}}
        }
        Divider()
        Button(L("Notionで開く")) {store.openAgentChat(row)}
    }
}

private struct AgentChatGroupMenu:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var hub:AgentChatHub
    let group:AgentChatGroup
    let name:(AgentChatNaming)->Void
    var body:some View {
        Button(L("名前を変更…")) {name(.group(group))}
        Button(group.tabs == true ? L("並べて表示"):L("タブで表示")) {hub.showsTabs(group.id,group.tabs != true)}
        Divider()
        Button(L("グループを解除"),role:.destructive) {hub.deleteGroup(group.id)}
    }
}

/// A name of the user's own for a chat (this app only) or a group.
private struct AgentChatNameSheet:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var hub:AgentChatHub
    let target:AgentChatNaming
    @State private var name=""
    @Environment(\.dismiss) private var dismiss
    private var chat:AgentChatRow? {if case .chat(let row)=target {return row};return nil}
    private var group:AgentChatGroup? {if case .group(let group)=target {return group};return nil}
    private func save() {
        if let chat {hub.rename(chat,to:name)}
        else if let group {
            guard AgentChatAccount.clean(name) != nil else{return}
            hub.renameGroup(group.id,to:name)
        }
        dismiss()
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(chat != nil ? L("チャットの名前"):L("グループの名前")).font(.title3.weight(.semibold))
            TextField(L("名前"),text:$name,prompt:chat.map{Text($0.session.title)}).textFieldStyle(.roundedBorder).onSubmit(save)
            if chat != nil {
                Text(L("この名前はこのアプリの中だけで使います。Notion側のチャット名は変わりません。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {
                if let chat,hub.isRenamed(chat) {Button(L("Notionの名前に戻す")) {hub.rename(chat,to:"");dismiss()}}
                Spacer()
                Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(L("保存")) {save()}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(group != nil && AgentChatAccount.clean(name) == nil)
            }
        }.padding(22).frame(width:440)
            .onAppear {name=chat.map(hub.title) ?? group?.name ?? ""}
    }
}

private struct AgentChatDetail:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    @ObservedObject var thread:AgentChatThread
    let row:AgentChatRow
    let name:(AgentChatNaming)->Void
    @State private var draft=""
    @FocusState private var typing:Bool
    private func submit() {
        let text=draft
        Task {if await hub.send(text,to:row) {draft=""}}
    }
    var body:some View {
        let pinned=hub.isPinned(row)
        VStack(spacing:0) {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                VStack(alignment:.leading,spacing:6) {
                    Text(hub.title(row)).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing:6) {
                        AgentChatAvatar(store:store,account:row.account,size:18)
                        Text(row.account.title+" · "+row.account.person).lineLimit(1)
                        if hub.isRenamed(row) {Text("· "+row.session.title).lineLimit(1).foregroundStyle(.tertiary).help(L("Notion側の名前"))}
                    }.font(.callout).foregroundStyle(.secondary)
                    let groups=hub.groups(of:row)
                    if !groups.isEmpty {
                        HStack(spacing:6) {
                            ForEach(groups) {group in
                                Button {hub.selectGroup(group.id)} label:{Label(group.name,systemImage:"square.stack").lineLimit(1)}
                                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal,7).padding(.vertical,2).background(.primary.opacity(0.07),in:Capsule())
                                    .help(L("グループを開く"))
                            }
                        }
                    }
                }
                Spacer(minLength:12)
                HStack(spacing:8) {
                    AgentChatStatusBadge(status:row.session.status,compact:false)
                    if row.session.active,hub.canReply(row) {Button {Task {await hub.cancel(row)}} label:{Label(L("停止"),systemImage:"stop.circle")}}
                    Button {hub.setPinned(row,!pinned)} label:{Image(systemName:pinned ? "pin.fill":"pin")}
                        .buttonStyle(AgentChatButtonStyle(iconOnly:true)).foregroundStyle(pinned ? Color.orange:Color.primary)
                        .help(pinned ? L("ピン留めを外す"):L("ピン留めする")).accessibilityLabel(pinned ? L("ピン留めを外す"):L("ピン留めする"))
                    Button {store.openAgentChat(row)} label:{Label(L("Notionで開く"),systemImage:"arrow.up.right.square")}
                    Menu {AgentChatMenu(store:store,hub:hub,row:row,name:name)} label:{Image(systemName:"ellipsis")}
                        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AgentChatButtonStyle(iconOnly:true)).fixedSize()
                        .help(L("その他の操作")).accessibilityLabel(L("その他の操作"))
                }.buttonStyle(AgentChatButtonStyle())
            }.padding(.horizontal,20).padding(.vertical,14)
            Divider()
            AgentChatConversation(store:store,row:row,thread:thread)
            Divider()
            footer
        }
    }
    @ViewBuilder private var footer:some View {
        VStack(alignment:.leading,spacing:10) {
            if hub.canReply(row) {
                AgentChatActions(hub:hub,row:row,thread:thread)
                HStack(alignment:.bottom,spacing:10) {
                    TextField(L("追加の指示を入力（⌘Enterで送信）"),text:$draft,axis:.vertical).lineLimit(1...8).textFieldStyle(.plain).focused($typing)
                        .padding(.horizontal,12).padding(.vertical,9).background(.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                    Button {submit()} label:{
                        if thread.sending {ProgressView().controlSize(.small).frame(width:22,height:22)}
                        else {Image(systemName:"arrow.up.circle.fill").font(.system(size:24))}
                    }.buttonStyle(.plain).keyboardShortcut(.return,modifiers:.command).help(L("送信"))
                        .accessibilityLabel(L("送信")).disabled(thread.sending || row.session.active || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                if row.session.active {Text(L("エージェントの作業が終わると、追加の指示を送れます。")).font(.caption).foregroundStyle(.secondary)}
            } else {
                Label(L("このチャットは自分が始めたものではないため、ここからは返信できません。"),systemImage:"lock").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(.horizontal,20).padding(.vertical,14).frame(maxWidth:860,alignment:.leading).frame(maxWidth:.infinity)
            .onAppear {typing=true}
    }
}

/// A chat's messages, with the agent's steps folded, scrolled to the newest.
private struct AgentChatConversation:View {
    @ObservedObject private var localization=AppLocalization.shared
    let store:BrowserStore
    let row:AgentChatRow
    @ObservedObject var thread:AgentChatThread
    var padding:CGFloat=20
    @State private var expanded:Set<String>=[]
    var body:some View {
        ScrollViewReader {reader in
            ScrollView {
                let items=AgentChat.timeline(thread.events)
                LazyVStack(alignment:.leading,spacing:14) {
                    if thread.loading {ProgressView().frame(maxWidth:.infinity).padding(.vertical,40)}
                    if let failure=thread.failure {Label(failure,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)}
                    if thread.truncated {
                        Label(L("それより前のやり取りは「Notionで開く」から確認できます"),systemImage:"clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(items) {item in
                        switch item {
                        case .message(let event):AgentChatMessage(event:event).id(item.id)
                        case .steps(_,let steps):
                            AgentChatSteps(steps:steps,working:row.session.active && item.id == items.last?.id,
                                           expanded:Binding(get:{expanded.contains(item.id)},set:{if $0 {expanded.insert(item.id)} else {expanded.remove(item.id)}})).id(item.id)
                        case .status(let event):if let status=event.status {AgentChatStatusBadge(status:status).id(item.id)}
                        }
                    }
                    if row.session.active,!(items.last.map{if case .steps=$0 {true} else {false}} ?? false) {
                        HStack(spacing:8) {ProgressView().controlSize(.small);Text(L("エージェントが作業しています…")).font(.callout).foregroundStyle(.secondary)}
                    }
                    if let error=row.session.error {Label(error,systemImage:"xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)}
                    Color.clear.frame(height:1).id("end")
                }.padding(padding).frame(maxWidth:820,alignment:.leading).frame(maxWidth:.infinity)
            }
            .environment(\.openURL,OpenURLAction {url in store.openAgentLink(url,from:row)})
            .onAppear {reader.scrollTo("end",anchor:.bottom)}
            .onChange(of:thread.events.last?.id) {_,_ in reader.scrollTo("end",anchor:.bottom)}
            .onChange(of:thread.loading) {_,loading in if !loading {reader.scrollTo("end",anchor:.bottom)}}
        }
    }
}

/// The agent's questions waiting for an answer, and why the last reply failed.
private struct AgentChatActions:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var hub:AgentChatHub
    let row:AgentChatRow
    @ObservedObject var thread:AgentChatThread
    var body:some View {
        if hub.canReply(row) && (!row.session.actions.isEmpty || thread.sendFailure != nil) {
            VStack(alignment:.leading,spacing:8) {
                ForEach(row.session.actions) {action in
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:10) {question(action);Spacer(minLength:8);options(action)}
                        VStack(alignment:.leading,spacing:8) {question(action);HStack {Spacer(minLength:0);options(action)}}
                    }.padding(12).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:10,style:.continuous)).disabled(thread.sending)
                }
                if let failure=thread.sendFailure {Label(failure,systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)}
            }
        }
    }
    private func question(_ action:AgentChat.Action)->some View {
        Label(action.title.isEmpty ? L("エージェントが確認を求めています"):action.title,systemImage:"exclamationmark.circle.fill").foregroundStyle(.orange).lineLimit(3)
    }
    private func options(_ action:AgentChat.Action)->some View {
        HStack(spacing:8) {
            ForEach(action.options) {option in
                if option.id == "approve" {Button(option.label) {Task {await hub.answer(action,option:option.id,in:row)}}.buttonStyle(.borderedProminent)}
                else {Button(option.label) {Task {await hub.answer(action,option:option.id,in:row)}}}
            }
        }.fixedSize()
    }
}

/// A group's chats side by side, or one at a time in tabs, with one box that instructs them all.
private struct AgentChatGroupView:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    let group:AgentChatGroup
    let name:(AgentChatNaming)->Void
    @State private var tab:String?
    @State private var draft=""
    @State private var sending=false
    @FocusState private var typing:Bool
    static let paneWidth:CGFloat=320
    var body:some View {
        let rows=hub.rows(in:group)
        VStack(spacing:0) {
            header(rows)
            Divider()
            if let failure=hub.sendFailure {
                Label(failure,systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,8).background(Color.red.opacity(0.08))
            }
            if rows.isEmpty {
                Text(group.members.isEmpty ? L("このグループにはチャットがありません。一覧のチャットを右クリックして追加できます。"):L("チャットを読み込んでいます…"))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if group.tabs == true {tabs(rows)} else {panes(rows)}
            Divider()
            footer(rows)
        }
    }
    private func header(_ rows:[AgentChatRow])->some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            VStack(alignment:.leading,spacing:6) {
                Label(group.name,systemImage:"square.stack").font(.title3.weight(.semibold)).lineLimit(2)
                Text(L("\(group.members.count)件のチャット")+" · "+rows.map(\.account.title).joined(separator:", ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength:12)
            HStack(spacing:8) {
                Picker("",selection:Binding(get:{group.tabs == true},set:{hub.showsTabs(group.id,$0)})) {
                    Label(L("並べて表示"),systemImage:"rectangle.split.3x1").tag(false)
                    Label(L("タブ"),systemImage:"rectangle.stack").tag(true)
                }.pickerStyle(.segmented).labelsHidden().controlSize(.large).fixedSize().help(L("表示方法"))
                Menu {AgentChatGroupMenu(hub:hub,group:group,name:name)} label:{Image(systemName:"ellipsis")}
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AgentChatButtonStyle(iconOnly:true)).fixedSize()
                    .help(L("その他の操作")).accessibilityLabel(L("その他の操作"))
            }
        }.padding(.horizontal,20).padding(.vertical,14)
    }
    /// Side by side, as wide as the page allows; past that, scrolled sideways.
    private func panes(_ rows:[AgentChatRow])->some View {
        GeometryReader {geo in
            let count=CGFloat(rows.count)
            let width=max(Self.paneWidth,(geo.size.width-(count-1))/count)
            ScrollView(.horizontal) {
                HStack(spacing:0) {
                    ForEach(Array(rows.enumerated()),id:\.element.id) {index,row in
                        if index>0 {Divider()}
                        AgentChatPane(store:store,hub:hub,row:row,thread:hub.thread(row.id),group:group).frame(width:width,height:geo.size.height)
                    }
                }
            }.scrollDisabled(width*count+(count-1)<=geo.size.width+1)
        }
    }
    private func tabs(_ rows:[AgentChatRow])->some View {
        let current=rows.first{$0.id == tab} ?? rows[0]
        return VStack(spacing:0) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:6) {
                    ForEach(rows) {row in
                        let selected=row.id == current.id
                        Button {tab=row.id} label:{
                            HStack(spacing:6) {
                                AgentChatAvatar(store:store,account:row.account,size:16)
                                Text(row.account.title).lineLimit(1)
                                Circle().fill(AgentChatStatusBadge.look(row.session.status).1).frame(width:7,height:7)
                            }.font(.system(size:12,weight:.medium)).padding(.horizontal,10).frame(height:26)
                                .background(selected ? Color.accentColor.opacity(0.16):Color.primary.opacity(0.05),in:Capsule())
                                .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5):.clear)).contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected:[])
                            .accessibilityLabel(row.account.title+" "+AgentChatStatusBadge.look(row.session.status).0)
                    }
                }.padding(.horizontal,16).padding(.vertical,8)
            }
            Divider()
            AgentChatPane(store:store,hub:hub,row:current,thread:hub.thread(current.id),group:group).id(current.id)
        }
    }
    private func submit(_ rows:[AgentChatRow]) {
        let text=draft
        sending=true
        Task {
            if await hub.send(text,toGroup:rows) {draft=""}
            sending=false
        }
    }
    private func footer(_ rows:[AgentChatRow])->some View {
        let ready=hub.ready(rows)
        return VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.bottom,spacing:10) {
                TextField(L("グループのすべてのチャットに送る指示（⌘Enterで送信）"),text:$draft,axis:.vertical).lineLimit(1...6).textFieldStyle(.plain).focused($typing)
                    .padding(.horizontal,12).padding(.vertical,9).background(.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                Button {submit(rows)} label:{
                    if sending {ProgressView().controlSize(.small).frame(width:22,height:22)}
                    else {Image(systemName:"arrow.up.circle.fill").font(.system(size:24))}
                }.buttonStyle(.plain).keyboardShortcut(.return,modifiers:.command).help(L("送信"))
                    .accessibilityLabel(L("送信")).disabled(sending || ready.isEmpty || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            Text(ready.isEmpty ? L("エージェントの作業が終わると、追加の指示を送れます。")
                 :ready.count == rows.count ? L("\(ready.count)件のチャットに同じ指示を送ります。")
                 :L("\(ready.count)件のチャットに同じ指示を送ります。作業中のチャットには送りません。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal,20).padding(.vertical,12).onAppear {typing=true}
    }
}

/// One chat of a group: which account it is, its messages, and its questions.
private struct AgentChatPane:View {
    @ObservedObject private var localization=AppLocalization.shared
    let store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    let row:AgentChatRow
    @ObservedObject var thread:AgentChatThread
    let group:AgentChatGroup
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                AgentChatAvatar(store:store,account:row.account,size:22)
                VStack(alignment:.leading,spacing:1) {
                    Text(row.account.title).font(.system(size:12,weight:.semibold)).lineLimit(1)
                    Text(hub.title(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength:6)
                AgentChatStatusBadge(status:row.session.status)
                if row.session.active,hub.canReply(row) {
                    Button {Task {await hub.cancel(row)}} label:{Image(systemName:"stop.circle")}.buttonStyle(AgentChatButtonStyle(iconOnly:true))
                        .help(L("停止")).accessibilityLabel(L("停止"))
                }
                Menu {
                    Button(L("このチャットだけを開く")) {hub.select(row.id)}
                    Button(L("Notionで開く")) {store.openAgentChat(row)}
                    Divider()
                    Button(L("グループから外す")) {hub.remove(row,from:group.id)}
                } label:{Image(systemName:"ellipsis")}
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(AgentChatButtonStyle(iconOnly:true)).fixedSize()
                    .help(L("その他の操作")).accessibilityLabel(L("その他の操作"))
            }.padding(.horizontal,12).padding(.vertical,8)
            Divider()
            AgentChatConversation(store:store,row:row,thread:thread,padding:14)
            AgentChatActions(hub:hub,row:row,thread:thread).padding(.horizontal,12).padding(.bottom,10)
        }
    }
}

/// A message: the user's on the right in a bubble, the agent's across the page as Notion shows it.
private struct AgentChatMessage:View {
    let event:AgentChat.Event
    var body:some View {
        let mine=event.type == "user.message"
        HStack {
            if mine {Spacer(minLength:60)}
            VStack(alignment:.leading,spacing:8) {
                if !event.text.isEmpty {AgentChatMarkup(blocks:AgentChat.blocks(event.text))}
                ForEach(event.files,id:\.url) {file in
                    if let url=URL(string:file.url),url.scheme == "https" {SwiftUI.Link(destination:url) {Label(file.name,systemImage:"paperclip")}.font(.callout)}
                }
            }
            .padding(.horizontal,mine ? 14:2).padding(.vertical,mine ? 10:2)
            .background(mine ? Color.accentColor.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:14,style:.continuous))
            if !mine {Spacer(minLength:0)}
        }
    }
}

/// The tools the agent used between two messages, folded into one line as in Notion.
private struct AgentChatSteps:View {
    @ObservedObject private var localization=AppLocalization.shared
    let steps:[AgentChat.Step]
    let working:Bool
    @Binding var expanded:Bool
    static func source(_ key:String)->String? {
        switch key {
        case "":return nil
        case "notion":return "Notion"
        case "slack":return "Slack"
        case "github":return "GitHub"
        case "web":return "Web"
        case "fs":return L("ファイル")
        case "search":return nil
        case "computer":return L("コンピューター")
        case "images":return L("画像")
        case "calendar":return L("カレンダー")
        case "skills":return L("スキル")
        case "helpdocs":return L("ヘルプ")
        default:return key.prefix(1).uppercased()+key.dropFirst()
        }
    }
    static func title(_ step:AgentChat.Step)->String {
        let (key,action)=AgentChat.tool(step.toolName)
        guard let source=source(key) else {
            switch action {
            case .read:return L("読み込み");case .search:return L("検索");case .create:return L("作成");case .update:return L("更新")
            case .delete:return L("削除");case .generate:return L("生成");case .run:return L("実行");case .upload:return L("アップロード")
            case .other:return step.toolName.isEmpty ? L("ツール"):step.toolName
            }
        }
        switch action {
        case .read:return L("\(source)を読み込み");case .search:return L("\(source)を検索");case .create:return L("\(source)に作成")
        case .update:return L("\(source)を更新");case .delete:return L("\(source)から削除");case .generate:return L("\(source)を生成")
        case .run:return L("\(source)で実行");case .upload:return L("\(source)にアップロード")
        case .other:return source+" · "+step.toolName
        }
    }
    static func symbol(_ step:AgentChat.Step)->String {
        switch AgentChat.tool(step.toolName).action {
        case .read:return "doc.text";case .search:return "magnifyingglass";case .create:return "plus.square";case .update:return "pencil"
        case .delete:return "trash";case .generate:return "sparkles";case .run:return "terminal";case .upload:return "arrow.up.doc"
        case .other:return "wrench.and.screwdriver"
        }
    }
    private var summary:String {
        var sources:[String]=[]
        for step in steps {if let name=Self.source(AgentChat.tool(step.toolName).source),!sources.contains(name) {sources.append(name)}}
        let count=L("\(steps.count)件の操作")
        return sources.isEmpty ? count:count+" · "+sources.prefix(3).joined(separator:", ")+(sources.count>3 ? "…":"")
    }
    var body:some View {
        let failed=steps.filter(\.failed).count
        VStack(alignment:.leading,spacing:6) {
            Button {withAnimation(.easeOut(duration:0.15)) {expanded.toggle()}} label:{
                HStack(spacing:6) {
                    Image(systemName:"chevron.right").font(.system(size:9,weight:.bold)).rotationEffect(.degrees(expanded ? 90:0)).frame(width:12)
                    if working,let last=steps.last {
                        ProgressView().controlSize(.mini)
                        Text(Self.title(last)+"…").lineLimit(1)
                        Text("· "+L("\(steps.count)件の操作")).foregroundStyle(.tertiary)
                    } else {Text(summary).lineLimit(1)}
                    if failed>0 {Text(L("\(failed)件失敗")).foregroundStyle(.red)}
                }.font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(working ? L("エージェントが作業しています…")+" "+summary:summary)
                .accessibilityValue(expanded ? L("展開") :L("折りたたみ"))
            if expanded {
                VStack(alignment:.leading,spacing:5) {
                    ForEach(steps) {step in
                        HStack(spacing:8) {
                            Image(systemName:Self.symbol(step)).frame(width:16).foregroundStyle(.secondary)
                            Text(Self.title(step)).lineLimit(1)
                            Text(step.toolName).font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength:4)
                            if step.failed {Image(systemName:"xmark.circle.fill").foregroundStyle(.red).accessibilityLabel(L("失敗"))}
                            else if !step.finished {ProgressView().controlSize(.mini)}
                        }.font(.caption).help(step.toolName)
                    }
                }.padding(.leading,18).padding(.vertical,4)
                    .overlay(alignment:.leading) {Rectangle().fill(.primary.opacity(0.12)).frame(width:1).padding(.leading,5)}
            }
        }
    }
}

/// A reply's Markdown and Notion cards, block by block.
private struct AgentChatMarkup:View {
    let blocks:[AgentChat.Block]
    static func inline(_ text:String)->AttributedString {
        (try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(Array(blocks.enumerated()),id:\.offset) {_,block in view(block)}
        }.font(.system(size:13)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
    }
    @ViewBuilder private func view(_ block:AgentChat.Block)->some View {
        switch block {
        case .heading(let level,let text):
            Text(Self.inline(text)).font(level<=1 ? .system(size:18,weight:.bold):level == 2 ? .system(size:16,weight:.semibold):.system(size:14,weight:.semibold)).padding(.top,4)
        case .paragraph(let text):Text(Self.inline(text))
        case .item(let level,let marker,let text):
            HStack(alignment:.firstTextBaseline,spacing:6) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth:14,alignment:.trailing)
                Text(Self.inline(text))
            }.padding(.leading,CGFloat(level)*18)
        case .quote(let text):
            Text(Self.inline(text)).foregroundStyle(.secondary).padding(.leading,10)
                .overlay(alignment:.leading) {RoundedRectangle(cornerRadius:1).fill(.secondary.opacity(0.5)).frame(width:3)}
        case .code(let text):
            ScrollView(.horizontal) {Text(text).font(.system(size:12,design:.monospaced)).padding(10)}
                .background(.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:8,style:.continuous))
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment:.leading,horizontalSpacing:14,verticalSpacing:6) {
                    ForEach(Array(rows.enumerated()),id:\.offset) {index,cells in
                        GridRow {ForEach(Array(cells.enumerated()),id:\.offset) {_,cell in Text(Self.inline(cell)).fontWeight(index == 0 ? .semibold:.regular)}}
                        if index == 0,rows.count>1 {Divider().gridCellUnsizedAxes(.horizontal)}
                    }
                }.padding(10)
            }.background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:8,style:.continuous))
        case .note(let kind,let text):
            HStack(alignment:.firstTextBaseline,spacing:8) {
                if kind == "worker" {Text(text.isEmpty ? "⚙️":text);Text(L("Notionワーカー")).foregroundStyle(.secondary)}
                else {
                    Image(systemName:kind == "edit" ? "pencil.line":"lightbulb").foregroundStyle(.secondary)
                    Text(Self.inline(text))
                }
            }.padding(.horizontal,10).padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading)
                .background(.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:8,style:.continuous))
        case .rule:Divider().padding(.vertical,4)
        }
    }
}

/// A new chat with one account's Notion AI, or the same prompt to several accounts at once as a group.
private struct AgentChatComposer:View {
    @ObservedObject private var localization=AppLocalization.shared
    let store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    let initial:UUID?
    @State private var chosen:Set<UUID>=[]
    @State private var text=""
    @State private var groupName=""
    @Environment(\.dismiss) private var dismiss
    private var targets:[AgentChatAccount] {hub.accounts.filter{chosen.contains($0.id)}}
    private func submit() {
        let targets=targets,prompt=text,name=groupName
        guard !targets.isEmpty else{return}
        Task {
            let started=targets.count>1 ? await hub.broadcast(prompt,to:targets,name:name):await hub.start(prompt,in:targets[0])
            if started {dismiss()}
        }
    }
    var body:some View {
        let targets=targets
        VStack(alignment:.leading,spacing:16) {
            Text(L("新しいチャット")).font(.title2.weight(.semibold))
            if hub.accounts.count>1 {
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Text(L("送信先")).font(.headline)
                        Spacer()
                        Button(chosen.count == hub.accounts.count ? L("選択を解除"):L("すべて選択")) {
                            chosen=chosen.count == hub.accounts.count ? []:Set(hub.accounts.map(\.id))
                        }.buttonStyle(.link)
                    }
                    ForEach(hub.accounts) {account in
                        Toggle(isOn:Binding(get:{chosen.contains(account.id)},set:{if $0 {chosen.insert(account.id)} else {chosen.remove(account.id)}})) {
                            HStack(spacing:8) {
                                AgentChatAvatar(store:store,account:account,size:20)
                                Text(account.title)
                                Text(account.person).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            TextField(L("Notion AIへの指示"),text:$text,axis:.vertical).lineLimit(4...12).textFieldStyle(.roundedBorder)
            if targets.count>1 {
                TextField(L("グループ名（空欄なら指示の1行目）"),text:$groupName).textFieldStyle(.roundedBorder)
            }
            if let failure=hub.sendFailure {Label(failure,systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
            HStack {
                Text(targets.count>1 ? L("選んだアカウントで同時にチャットを始め、1つのグループにまとめます。"):L("そのアカウントのNotion AIとのチャットを始めます。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer()
                if hub.sending {ProgressView().controlSize(.small)}
                Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(targets.count>1 ? L("\(targets.count)件に送信"):L("送信")) {submit()}
                    .keyboardShortcut(.return,modifiers:.command).buttonStyle(.borderedProminent)
                    .disabled(hub.sending || targets.isEmpty || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:560)
            .onAppear {
                hub.sendFailure=nil
                if let first=initial ?? hub.accounts.first?.id {chosen=[first]}
            }
    }
}

private struct AgentChatAccounts:View {
    @ObservedObject private var localization=AppLocalization.shared
    let store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    @State private var token=""
    @State private var failure:String?
    @State private var busy=false
    @State private var removing:AgentChatAccount?
    @State private var editing:AgentChatAccount?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("チャットを表示するアカウント")).font(.title2.weight(.semibold))
            Text(L("ワークスペースごとに、Notionの個人アクセストークン（「Notion API」の権限付き）を登録します。トークンはこのMacのキーチェーンにだけ保存します。")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !hub.accounts.isEmpty {
                VStack(spacing:6) {
                    ForEach(hub.accounts) {account in
                        HStack(spacing:12) {
                            AgentChatAvatar(store:store,account:account,size:28)
                            VStack(alignment:.leading,spacing:2) {
                                Text(account.title).font(.system(size:13,weight:.medium)).lineLimit(1)
                                Text(([account.title == account.notionTitle ? nil:account.notionTitle,account.person,account.email.isEmpty ? nil:account.email] as [String?]).compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let problem=hub.failures[account.id] {Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)}
                            }
                            Spacer(minLength:12)
                            Button(L("表示を編集…")) {editing=account}
                            Button(L("削除")) {removing=account}
                        }.padding(.horizontal,12).padding(.vertical,10).background(.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                    }
                }
            }
            VStack(alignment:.leading,spacing:8) {
                Text(L("アカウントを追加")).font(.headline)
                HStack {
                    SecureField(L("個人アクセストークン（ntn_…）"),text:$token).textFieldStyle(.roundedBorder).onSubmit {add()}
                    Button(L("追加")) {add()}.disabled(busy || token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    if busy {ProgressView().controlSize(.small)}
                }
                if let failure {Label(failure,systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
                SwiftUI.Link(L("Notionで個人アクセストークンを作成…"),destination:URL(string:"https://www.notion.so/developers/tokens")!).font(.callout)
                Text(L("作成するときに、対象のワークスペースを選んでください。ワークスペース名とユーザー名は自動で取得します。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            HStack {Spacer();Button(L("完了")) {dismiss()}.keyboardShortcut(.defaultAction)}
        }.padding(24).frame(width:560)
            .alert(L("このアカウントを削除しますか？"),isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}})) {
                Button(L("キャンセル"),role:.cancel) {}
                Button(L("削除"),role:.destructive) {if let removing {hub.removeAccount(removing.id)}}
            } message:{Text(L("保存したトークンも消去します。Notion側のチャットは消えません。"))}
            .sheet(item:$editing) {AgentChatAccountEditor(store:store,hub:hub,draft:$0)}
    }
    private func add() {
        let value=token
        guard !busy,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        busy=true;failure=nil
        Task {
            do {try await hub.addAccount(token:value);token=""}
            catch {failure=(error as? LocalizedError)?.errorDescription ?? error.localizedDescription}
            busy=false
        }
    }
}

/// The user's own name, icon and color for an account, shown instead of Notion's.
private struct AgentChatAccountEditor:View {
    @ObservedObject private var localization=AppLocalization.shared
    let store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    @State var draft:AgentChatAccount
    @Environment(\.dismiss) private var dismiss
    private func text(_ value:WritableKeyPath<AgentChatAccount,String?>)->Binding<String> {
        Binding(get:{draft[keyPath:value] ?? ""},set:{draft[keyPath:value]=$0})
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L("アカウントの表示")).font(.title2.weight(.semibold))
            HStack(spacing:12) {
                AgentChatAvatar(store:store,account:draft,size:40)
                VStack(alignment:.leading,spacing:2) {
                    Text(draft.title).font(.headline).lineLimit(1)
                    Text(draft.notionTitle+" · "+draft.person).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Form {
                Section {
                    TextField(L("表示名"),text:text(\.nickname),prompt:Text(draft.notionTitle))
                    TextField(L("絵文字・文字"),text:text(\.emoji))
                    IconSelectionRow(store:store,file:$draft.iconFile,defaultSymbol:"person.crop.circle",padsImageToSquare:false)
                    Toggle(L("色をつける"),isOn:Binding(get:{draft.color != nil},set:{draft.color=$0 ? (draft.color ?? "blue"):nil}))
                    if let color=draft.color {ColorPickerRow(selection:Binding(get:{color},set:{draft.color=$0}))}
                } footer:{
                    Text(L("アイコンは画像、絵文字・文字、色、Notionの写真の順に使います。空欄の項目はNotionの名前と写真のままです。トークンを登録し直しても、ここで変えた表示は残ります。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }.formStyle(.grouped).scrollDisabled(true)
            HStack {
                Button(L("Notionの表示に戻す")) {draft.nickname=nil;draft.emoji=nil;draft.iconFile=nil;draft.color=nil}.disabled(!draft.customized)
                Spacer()
                Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(L("保存")) {hub.customize(draft);dismiss()}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width:540)
    }
}
