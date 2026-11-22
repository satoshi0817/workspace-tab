import AppKit
import SwiftUI
import WorkspaceCore

extension BrowserStore {
    func toggleAgentChats() {
        agentChatsPresented.toggle()
        if agentChatsPresented {window?.makeKeyAndOrderFront(nil)} else {restorePanelFocus()}
    }
    /// Opens a chat in the app tab set up for the same Notion workspace.
    func openAgentChat(_ row:AgentChatRow) {
        let target=AgentChat.compact(row.account.workspaceID)
        guard let workspace=session.workspaces.first(where:{AgentChat.compact($0.notionSpaceID) == target}) else {
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

struct AgentChatStatusBadge:View {
    let status:String
    private var look:(String,Color,String) {
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
        Label(title,systemImage:symbol).font(.system(size:11,weight:.medium)).labelStyle(.titleAndIcon)
            .padding(.horizontal,8).padding(.vertical,3).foregroundStyle(color)
            .background(color.opacity(0.14),in:Capsule()).fixedSize()
    }
}

private struct AgentChatAvatar:View {
    let account:AgentChatAccount
    var size:CGFloat=22
    var body:some View {
        let initial=Text(String(account.person.prefix(1)).uppercased()).font(.system(size:size*0.48,weight:.semibold))
            .frame(width:size,height:size).background(.primary.opacity(0.16))
        Group {
            if let url=account.avatarURL.flatMap(URL.init(string:)),url.scheme == "https" {
                AsyncImage(url:url) {phase in
                    if let image=phase.image {image.resizable().aspectRatio(contentMode:.fill)} else {initial}
                }
            } else {initial}
        }.frame(width:size,height:size).clipShape(Circle()).overlay(Circle().strokeBorder(.primary.opacity(0.18)))
    }
}

struct AgentChatPage:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    @State private var filter=AgentChatFilter.all
    @State private var accountFilter:UUID?
    @State private var query=""
    @State private var managing=false
    @State private var composing=false
    private static let relative:RelativeDateTimeFormatter = {let f=RelativeDateTimeFormatter();f.unitsStyle = .short;return f}()

    private var rows:[AgentChatRow] {
        let needle=query.trimmingCharacters(in:.whitespaces).lowercased()
        return hub.rows.filter {row in
            if let accountFilter,row.account.id != accountFilter {return false}
            switch filter {
            case .all:break
            case .waiting:if !row.session.needsAction {return false}
            case .running:if !row.session.active {return false}
            }
            return needle.isEmpty || row.session.title.lowercased().contains(needle) || hub.agentName(row).lowercased().contains(needle)
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
                    list.frame(minWidth:320,idealWidth:400,maxWidth:560)
                    detail.frame(minWidth:360,maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .onAppear {hub.startPolling()}
        .onDisappear {hub.stopPolling()}
        .sheet(isPresented:$managing) {AgentChatAccounts(hub:hub)}
        .sheet(isPresented:$composing) {AgentChatComposer(hub:hub,initial:accountFilter)}
    }
    private var header:some View {
        HStack(spacing:12) {
            Label(L("Notion AIのチャット"),systemImage:"bubble.left.and.bubble.right").font(.title3.weight(.semibold))
            if hub.loading {ProgressView().controlSize(.small)}
            else if let at=hub.refreshedAt {Text(L("更新: ")+Self.relative.localizedString(for:at,relativeTo:Date())).font(.caption).foregroundStyle(.secondary)}
            Spacer(minLength:12)
            Button {composing=true} label:{Label(L("新しいチャット"),systemImage:"square.and.pencil")}.disabled(hub.accounts.isEmpty)
            Button {hub.refresh()} label:{Image(systemName:"arrow.clockwise")}.help(L("再読み込み")).accessibilityLabel(L("再読み込み")).disabled(hub.loading || hub.accounts.isEmpty)
            Button {managing=true} label:{Label(L("アカウント"),systemImage:"person.2")}
            Button {store.toggleAgentChats()} label:{Image(systemName:"xmark")}.help(L("閉じる")).accessibilityLabel(L("閉じる")).keyboardShortcut(.cancelAction)
        }.padding(.horizontal,20).padding(.vertical,14)
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
        VStack(spacing:0) {
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
                HStack(spacing:12) {
                    Picker(L("アカウント"),selection:$accountFilter) {
                        Text(L("すべてのワークスペース")).tag(UUID?.none)
                        ForEach(hub.accounts) {account in Text(account.title+" · "+account.person).tag(UUID?.some(account.id))}
                    }.labelsHidden().fixedSize()
                }.font(.callout)
            }.padding(16)
            Divider()
            ForEach(hub.accounts.filter{hub.failures[$0.id] != nil}) {account in
                Label(account.title+": "+(hub.failures[account.id] ?? ""),systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16).padding(.vertical,8).background(Color.red.opacity(0.08))
            }
            ScrollView {
                LazyVStack(spacing:4) {
                    ForEach(rows) {row in rowView(row)}
                    if rows.isEmpty {
                        Text(hub.loading ? L("読み込んでいます…"):L("該当するチャットはありません")).font(.callout).foregroundStyle(.secondary).padding(.vertical,40)
                    }
                    if hub.hasMore {Button(L("さらに読み込む")) {hub.loadMore()}.disabled(hub.loading).padding(.vertical,12)}
                }.padding(10)
            }
        }
    }
    private func rowView(_ row:AgentChatRow)->some View {
        let selected=hub.selection == row.id
        return Button {hub.select(row.id)} label:{
            VStack(alignment:.leading,spacing:8) {
                HStack(alignment:.top,spacing:8) {
                    Text(row.session.title).font(.system(size:13,weight:.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength:8)
                    AgentChatStatusBadge(status:row.session.status)
                }
                HStack(spacing:6) {
                    AgentChatAvatar(account:row.account,size:16)
                    Text(row.account.title).lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(row.account.person).lineLimit(1)
                    Spacer(minLength:8)
                    Text(Self.relative.localizedString(for:row.session.updatedAt,relativeTo:Date())).monospacedDigit().fixedSize()
                }.font(.system(size:11)).foregroundStyle(.secondary)
            }.padding(.horizontal,12).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                .background(selected ? Color.accentColor.opacity(0.16):Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:10,style:.continuous).strokeBorder(selected ? Color.accentColor.opacity(0.6):.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected:[])
    }
    @ViewBuilder private var detail:some View {
        if let row=hub.selectedRow {AgentChatDetail(store:store,hub:hub,row:row).id(row.id)}
        else {
            Text(L("チャットを選ぶと、ここに内容が表示されます")).font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
}

private struct AgentChatDetail:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var hub:AgentChatHub
    let row:AgentChatRow
    @State private var draft=""
    @FocusState private var typing:Bool
    private func submit() {
        let text=draft
        Task {if await hub.send(text,to:row) {draft=""}}
    }
    var body:some View {
        VStack(spacing:0) {
            HStack(alignment:.top,spacing:12) {
                VStack(alignment:.leading,spacing:6) {
                    Text(row.session.title).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing:6) {
                        AgentChatAvatar(account:row.account,size:18)
                        Text(row.account.title+" · "+row.account.person).lineLimit(1)
                    }.font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength:12)
                AgentChatStatusBadge(status:row.session.status)
                if row.session.active,hub.canReply(row) {Button(L("停止")) {Task {await hub.cancel(row)}}}
                Button {store.openAgentChat(row)} label:{Label(L("Notionで開く"),systemImage:"arrow.up.right.square")}
            }.padding(.horizontal,20).padding(.vertical,14)
            Divider()
            ScrollViewReader {reader in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        if hub.eventsLoading {ProgressView().frame(maxWidth:.infinity).padding(.vertical,40)}
                        if let failure=hub.eventsFailure {Label(failure,systemImage:"exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)}
                        ForEach(hub.events) {event in AgentChatEventView(event:event).id(event.id)}
                        if row.session.active {
                            HStack(spacing:8) {ProgressView().controlSize(.small);Text(L("エージェントが作業しています…")).font(.callout).foregroundStyle(.secondary)}
                        }
                        if let error=row.session.error {Label(error,systemImage:"xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)}
                        Color.clear.frame(height:1).id("end")
                    }.padding(20).frame(maxWidth:820,alignment:.leading).frame(maxWidth:.infinity)
                }
                .onChange(of:hub.events.last?.id) {_,_ in reader.scrollTo("end",anchor:.bottom)}
                .onChange(of:hub.eventsLoading) {_,loading in if !loading {reader.scrollTo("end",anchor:.bottom)}}
            }
            Divider()
            footer
        }
    }
    @ViewBuilder private var footer:some View {
        VStack(alignment:.leading,spacing:10) {
            if hub.canReply(row) {
                ForEach(row.session.actions) {action in
                    HStack(spacing:10) {
                        Label(action.title.isEmpty ? L("エージェントが確認を求めています"):action.title,systemImage:"exclamationmark.circle.fill").foregroundStyle(.orange).lineLimit(3)
                        Spacer(minLength:8)
                        ForEach(action.options) {option in
                            if option.id == "approve" {Button(option.label) {Task {await hub.answer(action,option:option.id,in:row)}}.buttonStyle(.borderedProminent)}
                            else {Button(option.label) {Task {await hub.answer(action,option:option.id,in:row)}}}
                        }
                    }.padding(12).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:10,style:.continuous)).disabled(hub.sending)
                }
                HStack(alignment:.bottom,spacing:10) {
                    TextField(L("追加の指示を入力（⌘Enterで送信）"),text:$draft,axis:.vertical).lineLimit(1...8).textFieldStyle(.plain).focused($typing)
                        .padding(.horizontal,12).padding(.vertical,9).background(.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                    Button {submit()} label:{
                        if hub.sending {ProgressView().controlSize(.small).frame(width:22,height:22)}
                        else {Image(systemName:"arrow.up.circle.fill").font(.system(size:24))}
                    }.buttonStyle(.plain).keyboardShortcut(.return,modifiers:.command).help(L("送信"))
                        .accessibilityLabel(L("送信")).disabled(hub.sending || row.session.active || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                if row.session.active {Text(L("エージェントの作業が終わると、追加の指示を送れます。")).font(.caption).foregroundStyle(.secondary)}
            } else {
                Label(L("このチャットは自分が始めたものではないため、ここからは返信できません。"),systemImage:"lock").font(.callout).foregroundStyle(.secondary)
            }
            if let failure=hub.sendFailure {Label(failure,systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)}
        }.padding(.horizontal,20).padding(.vertical,14).frame(maxWidth:860,alignment:.leading).frame(maxWidth:.infinity)
            .onAppear {typing=true}
    }
}

private struct AgentChatEventView:View {
    let event:AgentChat.Event
    private var rendered:AttributedString {
        (try? AttributedString(markdown:event.text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(event.text)
    }
    var body:some View {
        switch event.type {
        case "user.message":
            HStack {
                Spacer(minLength:60)
                bubble.background(Color.accentColor.opacity(0.18),in:RoundedRectangle(cornerRadius:14,style:.continuous))
            }
        case "agent.message":
            HStack {
                bubble.background(.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:14,style:.continuous))
                Spacer(minLength:60)
            }
        case "agent.tool_use":
            Label(event.toolName ?? L("ツール"),systemImage:"wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary).padding(.leading,4)
        case "session.status":
            if let status=event.status,status != "completed" {AgentChatStatusBadge(status:status)}
        default:EmptyView()
        }
    }
    private var bubble:some View {
        VStack(alignment:.leading,spacing:8) {
            if !event.text.isEmpty {Text(rendered).font(.system(size:13)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
            ForEach(event.files,id:\.url) {file in
                if let url=URL(string:file.url),url.scheme == "https" {SwiftUI.Link(destination:url) {Label(file.name,systemImage:"paperclip")}.font(.callout)}
            }
        }.padding(.horizontal,14).padding(.vertical,10)
    }
}

private struct AgentChatComposer:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var hub:AgentChatHub
    let initial:UUID?
    @State private var accountID:UUID?
    @State private var text=""
    @Environment(\.dismiss) private var dismiss
    private var account:AgentChatAccount? {hub.accounts.first{$0.id == accountID} ?? hub.accounts.first}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("新しいチャット")).font(.title2.weight(.semibold))
            Picker(L("ワークスペース"),selection:Binding(get:{account?.id},set:{accountID=$0})) {
                ForEach(hub.accounts) {account in Text(account.title+" · "+account.person).tag(UUID?.some(account.id))}
            }
            TextField(L("Notion AIへの指示"),text:$text,axis:.vertical).lineLimit(4...12).textFieldStyle(.roundedBorder)
            if let failure=hub.sendFailure {Label(failure,systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)}
            HStack {
                Text(L("そのアカウントのNotion AIとのチャットを始めます。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(L("送信")) {
                    guard let account else{return}
                    Task {if await hub.start(text,in:account) {dismiss()}}
                }.keyboardShortcut(.return,modifiers:.command).buttonStyle(.borderedProminent)
                    .disabled(hub.sending || account == nil || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:540).onAppear {accountID=initial}
    }
}

private struct AgentChatAccounts:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var hub:AgentChatHub
    @State private var token=""
    @State private var failure:String?
    @State private var busy=false
    @State private var removing:AgentChatAccount?
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("チャットを表示するアカウント")).font(.title2.weight(.semibold))
            Text(L("ワークスペースごとに、Notionの個人アクセストークン（「Notion API」の権限付き）を登録します。トークンはこのMacのキーチェーンにだけ保存します。")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !hub.accounts.isEmpty {
                VStack(spacing:6) {
                    ForEach(hub.accounts) {account in
                        HStack(spacing:12) {
                            AgentChatAvatar(account:account,size:28)
                            VStack(alignment:.leading,spacing:2) {
                                Text(account.title).font(.system(size:13,weight:.medium)).lineLimit(1)
                                Text(account.email.isEmpty ? account.person:account.person+" · "+account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let problem=hub.failures[account.id] {Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)}
                            }
                            Spacer(minLength:12)
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
