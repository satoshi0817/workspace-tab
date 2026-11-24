import AppKit
import SwiftUI
import WorkspaceCore

/// One Notion workspace and user whose chats are listed. The personal access token
/// itself stays in the Keychain; only these labels are written to disk.
struct AgentChatAccount:Codable,Identifiable,Equatable {
    var id=UUID()
    var workspaceID:String
    var workspaceName:String
    var userID:String
    var userName:String
    var email:String
    var avatarURL:String?
    /// The user's own name, icon and color for the account. Nil falls back to what
    /// Notion reports; registering the token again keeps them.
    var nickname:String?
    var emoji:String?
    var iconFile:String?
    var color:String?
    var vaultID:String {"agentchat-"+id.uuidString}
    var notionTitle:String {workspaceName.isEmpty ? L("Notionワークスペース"):workspaceName}
    var title:String {nickname.flatMap(Self.clean) ?? notionTitle}
    var person:String {userName.isEmpty ? email:userName}
    var customized:Bool {nickname.flatMap(Self.clean) != nil || emoji.flatMap(Self.clean) != nil || iconFile != nil || color != nil}
    static func clean(_ text:String)->String? {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty ? nil:value
    }
}

struct AgentChatRow:Identifiable,Equatable {
    let account:AgentChatAccount
    let session:AgentChat.Session
    var id:String {account.id.uuidString+"/"+session.id}
}

/// Chats started together, or put together by the user, shown side by side. Kept on this Mac only.
struct AgentChatGroup:Codable,Identifiable,Equatable {
    var id=UUID()
    var name:String
    /// Row IDs (account and chat), in the order they were added.
    var members:[String]
    var createdAt=Date()
    /// Shown one at a time in tabs instead of side by side.
    var tabs:Bool?
}

/// One chat's messages and the state of reading and answering it. Every chat on screen has one,
/// so a group's chats are followed at the same time.
@MainActor final class AgentChatThread:ObservableObject,Identifiable {
    let id:String
    @Published fileprivate(set) var events:[AgentChat.Event]=[]
    @Published fileprivate(set) var loading=false
    /// Older events than the ones loaded remain in Notion.
    @Published fileprivate(set) var truncated=false
    @Published fileprivate(set) var failure:String?
    @Published fileprivate(set) var sending=false
    @Published var sendFailure:String?
    fileprivate var task:Task<Void,Never>?
    /// Still loading, or following a running agent.
    fileprivate var watching=false
    fileprivate var generation=0
    init(id:String) {self.id=id}
}

/// Chats of every registered Notion workspace on one page: their status, their
/// messages, and follow-up instructions. Read from Notion's public Agent API.
@MainActor final class AgentChatHub:ObservableObject {
    @Published private(set) var accounts:[AgentChatAccount]=[]
    @Published private(set) var sessions:[UUID:[AgentChat.Session]]=[:]
    @Published private(set) var agents:[UUID:[String:AgentChat.Agent]]=[:]
    @Published private(set) var failures:[UUID:String]=[:]
    @Published private(set) var loading=false
    @Published private(set) var refreshedAt:Date?
    @Published private(set) var selection:String?
    /// The group whose chats are shown together; set instead of `selection`.
    @Published private(set) var selectedGroup:UUID?
    /// The account whose chats are shown; nil shows every account.
    @Published var accountFilter:UUID?
    /// Starting chats: one, or the same prompt for several accounts.
    @Published private(set) var sending=false
    @Published var sendFailure:String?
    /// The user's own names, pins and groups for chats. Notion is not changed.
    @Published private(set) var titles:[String:String]=[:]
    @Published private(set) var pinned:[String:Date]=[:]
    @Published private(set) var groups:[AgentChatGroup]=[]
    private let notesFile:URL?
    private var threads:[String:AgentChatThread]=[:]
    /// The chats on screen: the selected chat, or every chat of the selected group.
    private var visible:[String]=[]
    /// Where each account's two lists continue: every session, and Notion AI chats only.
    private var cursors:[UUID:[Bool:String]]=[:]
    private var listTask:Task<Void,Never>?
    private var refreshAgain=false
    private var pollTask:Task<Void,Never>?
    /// Accounts whose chats were fetched from Notion since launch; the rest show what was saved last time.
    private var fetched:Set<UUID>=[]
    private let cacheFile:URL?
    private var cacheTask:Task<Void,Never>?
    private var cacheWrite:Task<Void,Never>?
    /// The saved copy is read when the page first opens, not at app launch.
    private var cacheLoaded=false
    /// The open chats whose messages are kept, newest first.
    private var savedChats:[String:SavedChat]=[:]
    /// Chats Notion's list leaves out but this app has seen (opened in a tab, or started here), by account.
    /// Notion's list stopped returning recent chats, so these are read one by one.
    private(set) var known:[UUID:Set<String>]=[:]
    /// When each known chat was last read, so the half-minute reload doesn't read them all every time.
    private var readAt:[String:Date]=[:]
    static let knownLimit=300
    static let savedChatLimit=30,savedSessionLimit=200
    private let client:any NotionRequesting
    private let credentials:(String)->String?
    private let storeSecret:(String,String)throws->Void
    private let file:URL?
    static let pageSize=50

    init(client:any NotionRequesting=NotionClient(apiVersion:"2026-03-11"),file:URL?=Storage.root.appendingPathComponent("agent-chats.json"),credentials:@escaping(String)->String?={NotionVault.read($0)},storeSecret:@escaping(String,String)throws->Void={try NotionVault.write($0,secret:$1)}) {
        self.client=client;self.file=file;self.credentials=credentials;self.storeSecret=storeSecret
        cacheFile=file?.deletingLastPathComponent().appendingPathComponent("agent-chat-cache.json")
        notesFile=file?.deletingLastPathComponent().appendingPathComponent("agent-chat-notes.json")
        if let file,let data=try? Data(contentsOf:file),let saved=try? JSONDecoder().decode([AgentChatAccount].self,from:data) {accounts=saved}
        if let notesFile,let data=try? Data(contentsOf:notesFile),let notes=try? JSONDecoder().decode(Notes.self,from:data) {
            titles=notes.titles;pinned=notes.pinned;groups=notes.groups
        }
    }

    // MARK: Saved copy
    /// What was last fetched, shown at once on the next launch while Notion is asked again.
    struct SavedChat:Codable {var events:[AgentChat.Event];var truncated:Bool;var openedAt:Date}
    private struct Cache:Codable {
        var savedAt:Date
        var sessions:[String:[AgentChat.Session]]
        var chats:[String:SavedChat]
        var known:[String:[String]]?
    }
    func loadCache() {
        guard !cacheLoaded else{return}
        cacheLoaded=true
        guard let cacheFile,let data=try? Data(contentsOf:cacheFile),let cache=try? JSONDecoder().decode(Cache.self,from:data) else{return}
        let known=Set(accounts.map(\.id.uuidString))
        for (key,list) in cache.sessions where known.contains(key) && sessions[UUID(uuidString:key) ?? UUID()] == nil {if let id=UUID(uuidString:key) {sessions[id]=list}}
        savedChats=cache.chats.filter {known.contains(String($0.key.prefix(36)))}.merging(savedChats) {$1}
        for (key,ids) in cache.known ?? [:] where known.contains(key) {if let id=UUID(uuidString:key) {self.known[id,default:[]].formUnion(ids)}}
        if !sessions.isEmpty {refreshedAt=cache.savedAt}
    }
    /// Writes are gathered for a moment so a burst of updates is saved once.
    private func saveCache() {
        guard cacheFile != nil,cacheLoaded else{return}
        cacheTask?.cancel()
        cacheTask=Task {[weak self] in
            try? await Task.sleep(for:.milliseconds(800))
            guard !Task.isCancelled,let self,let cacheFile=self.cacheFile else{return}
            // Encoding and writing happen off the main thread, one write after another.
            let cache=self.snapshot(),previous=self.cacheWrite
            self.cacheWrite=Task.detached(priority:.utility) {
                await previous?.value
                Self.write(cache,to:cacheFile)
            }
        }
    }
    /// Saves at once, for removing an account and for checks.
    func saveCacheNow() {
        guard let cacheFile,cacheLoaded else{return}
        cacheTask?.cancel();cacheTask=nil
        Self.write(snapshot(),to:cacheFile)
    }
    private func snapshot()->Cache {
        let kept=savedChats.sorted {$0.value.openedAt>$1.value.openedAt}.prefix(Self.savedChatLimit)
        savedChats=Dictionary(uniqueKeysWithValues:kept.map{($0.key,$0.value)})
        var lists:[String:[AgentChat.Session]]=[:]
        for account in accounts {if let list=sessions[account.id] {lists[account.id.uuidString]=Array(list.prefix(Self.savedSessionLimit))}}
        var ids:[String:[String]]=[:]
        for account in accounts {
            guard let set=known[account.id],!set.isEmpty else{continue}
            // Past the limit, the chats touched longest ago are forgotten first.
            var stamp:[String:Date]=[:]
            for session in sessions[account.id] ?? [] {if let id=AgentChat.compact(session.id) {stamp[id]=session.updatedAt}}
            ids[account.id.uuidString]=Array(set.sorted{(stamp[$0] ?? .distantFuture)>(stamp[$1] ?? .distantFuture)}.prefix(Self.knownLimit))
        }
        return Cache(savedAt:refreshedAt ?? Date(),sessions:lists,chats:savedChats,known:ids)
    }
    private nonisolated static func write(_ cache:Cache,to file:URL) {
        guard let data=try? JSONEncoder().encode(cache) else{return}
        try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        // Chat text stays readable only by this user.
        if (try? data.write(to:file,options:.atomic)) != nil {try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
    }
    private func remember(_ id:String,_ thread:AgentChatThread,changed:Bool) {
        if changed || savedChats[id] == nil {
            savedChats[id]=SavedChat(events:thread.events,truncated:thread.truncated,openedAt:Date())
            saveCache()
        } else {savedChats[id]?.openedAt=Date()}
    }
    private func save() {
        guard let file else{return}
        try? Storage.prepare()
        if let data=try? JSONEncoder().encode(accounts) {try? data.write(to:file,options:.atomic)}
    }
    var hasMore:Bool {!cursors.isEmpty}
    /// Only the user's own chats with their personal agent (Notion AI) are listed.
    var rows:[AgentChatRow] {
        accounts.flatMap {account in (sessions[account.id] ?? []).map {AgentChatRow(account:account,session:$0)}}
            .filter {$0.session.agentID == "notion_ai" && canReply($0)}
            .sorted {a,b in
                let ra=AgentChat.rank(a.session.status),rb=AgentChat.rank(b.session.status)
                return ra != rb ? ra<rb:a.session.updatedAt>b.session.updatedAt
            }
    }
    var selectedRow:AgentChatRow? {selection.flatMap(listedRow)}
    /// A chat as listed: the user's own Notion AI chat.
    private func listedRow(_ id:String)->AgentChatRow? {
        guard let row=findRow(id),row.session.agentID == "notion_ai",canReply(row) else{return nil}
        return row
    }
    private func findRow(_ id:String)->AgentChatRow? {
        guard let slash=id.firstIndex(of:"/"),let accountID=UUID(uuidString:String(id[..<slash])),
              let account=accounts.first(where:{$0.id == accountID}) else{return nil}
        let sessionID=String(id[id.index(after:slash)...])
        guard let session=sessions[accountID]?.first(where:{$0.id == sessionID}) else{return nil}
        return AgentChatRow(account:account,session:session)
    }
    private var selectedThread:AgentChatThread? {selection.flatMap{threads[$0]}}
    /// The selected chat's messages; views read its thread directly.
    var events:[AgentChat.Event] {selectedThread?.events ?? []}
    var eventsLoading:Bool {selectedThread?.loading ?? false}
    var eventsTruncated:Bool {selectedThread?.truncated ?? false}
    var eventsFailure:String? {selectedThread?.failure}
    func agentName(_ row:AgentChatRow)->String {
        if row.session.agentID == "notion_ai" {return "Notion AI"}
        let name=agents[row.account.id]?[row.session.agentID]?.name ?? ""
        return name.isEmpty ? L("カスタムエージェント"):name
    }
    func agentEmoji(_ row:AgentChatRow)->String? {agents[row.account.id]?[row.session.agentID]?.emoji}
    /// Follow-ups are accepted by Notion only for chats this user started.
    func canReply(_ row:AgentChatRow)->Bool {
        row.session.createdByUser && AgentChat.compact(row.session.createdByID) == AgentChat.compact(row.account.userID)
    }
    private func message(_ error:Error)->String {
        if let api=error as? NotionAPIError {
            if api.status == 401 {return L("トークンが無効か期限切れです。新しい個人アクセストークンを登録してください")}
            return api.message
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Accounts
    /// Checks the token with Notion, then stores it. A token for an already listed
    /// workspace and user replaces the old one.
    func addAccount(token raw:String) async throws {
        let token=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !token.isEmpty else{throw LVError(L("個人アクセストークンを入力してください"))}
        let me=try await client.request(token:token,method:"GET",endpoint:"/users/me",body:nil)
        guard let identity=AgentChat.identity(me) else{throw LVError(L("個人アクセストークンではありません。Notionの開発者ポータルで「個人アクセストークン」を作成してください"))}
        var account=accounts.first {AgentChat.compact($0.workspaceID) == AgentChat.compact(identity.workspaceID) && AgentChat.compact($0.userID) == AgentChat.compact(identity.userID)}
            ?? AgentChatAccount(workspaceID:identity.workspaceID,workspaceName:identity.workspaceName,userID:identity.userID,userName:identity.userName,email:identity.email,avatarURL:identity.avatarURL)
        account.workspaceName=identity.workspaceName;account.userName=identity.userName;account.email=identity.email;account.avatarURL=identity.avatarURL
        try storeSecret(account.vaultID,token)
        if let index=accounts.firstIndex(where:{$0.id == account.id}) {accounts[index]=account} else {accounts.append(account)}
        save();refresh()
    }
    func removeAccount(_ id:UUID) {
        guard let account=accounts.first(where:{$0.id == id}) else{return}
        // The Keychain entry is emptied rather than left readable.
        try? storeSecret(account.vaultID,"")
        accounts.removeAll {$0.id == id}
        sessions[id]=nil;agents[id]=nil;failures[id]=nil;cursors[id]=nil;fetched.remove(id);known[id]=nil
        savedChats=savedChats.filter {!$0.key.hasPrefix(id.uuidString)}
        if accountFilter == id || accounts.count<2 {accountFilter=nil}
        let prefix=id.uuidString+"/"
        titles=titles.filter{!$0.key.hasPrefix(prefix)};pinned=pinned.filter{!$0.key.hasPrefix(prefix)}
        for index in groups.indices {groups[index].members.removeAll{$0.hasPrefix(prefix)}}
        groups.removeAll{$0.members.isEmpty}
        saveNotes()
        if let open=selectedGroup {if let group=group(open) {show(group.members)} else {selectGroup(nil)}}
        else if selectedRow == nil {select(nil)}
        save();saveCacheNow()
    }
    /// Stores the user's own name, icon and color for an account. Notion's names are left untouched.
    func customize(_ draft:AgentChatAccount) {
        guard let index=accounts.firstIndex(where:{$0.id == draft.id}) else{return}
        accounts[index].nickname=draft.nickname.flatMap(AgentChatAccount.clean)
        accounts[index].emoji=draft.emoji.flatMap(AgentChatAccount.clean).map{String($0.prefix(4))}
        accounts[index].iconFile=draft.iconFile
        accounts[index].color=draft.color
        save()
    }
    private func token(_ account:AgentChatAccount)throws->String {
        guard let token=credentials(account.vaultID),!token.isEmpty else{throw LVError(L("トークンをキーチェーンから読み取れません。もう一度登録してください"))}
        return token
    }

    // MARK: List
    private struct Page {var sessions:[AgentChat.Session];var cursor:String?}
    /// Automated runs can fill a whole page, so the user's Notion AI chats are also asked for on their own.
    private func page(_ account:AgentChatAccount,cursor:String?,personal:Bool=true) async throws->Page {
        let token=try token(account)
        var found:[AgentChat.Session]=[],next=cursor
        // Notion may return an empty page while more remain, so a few are followed.
        for _ in 0..<4 {
            var body:JSONObject=["page_size":Self.pageSize]
            if personal {body["filter"]=["property":"agent_id","string":["equals":"notion_ai"]]}
            if let next {body["start_cursor"]=next}
            let json=try await client.request(token:token,method:"POST",endpoint:"/sessions/query",body:body)
            found += (json["results"] as? [JSONObject] ?? []).compactMap(AgentChat.session)
            next=json["has_more"] as? Bool == true ? json["next_cursor"] as? String:nil
            if next == nil || !found.isEmpty {break}
        }
        return Page(sessions:found,cursor:next)
    }
    private func agentNames(_ account:AgentChatAccount) async->[String:AgentChat.Agent] {
        guard let token=try? token(account),
              let json=try? await client.request(token:token,method:"POST",endpoint:"/agents/query",body:["page_size":100]) else{return agents[account.id] ?? [:]}
        var map:[String:AgentChat.Agent]=[:]
        for agent in (json["results"] as? [JSONObject] ?? []).compactMap(AgentChat.agent) {map[agent.id]=agent}
        return map
    }
    /// With `complete`, `new` is everything from the newest down to its oldest chat (or to the end
    /// when `reachesEnd`), so saved chats in that range Notion no longer lists are dropped.
    private func merge(_ new:[AgentChat.Session],into id:UUID,complete:Bool=false,reachesEnd:Bool=false) {
        var byID:[String:AgentChat.Session]=[:]
        let oldest=new.map(\.updatedAt).min()
        let kept=(known[id] ?? []).union(noted(id))
        for session in sessions[id] ?? [] {
            // An empty first page while more remain says nothing about the saved chats, so they stay.
            // Known chats are missing from Notion's list on purpose; they are checked one by one instead.
            if complete,!kept.contains(AgentChat.compact(session.id) ?? ""),reachesEnd || (oldest.map{session.updatedAt>=$0} ?? false) {continue}
            byID[session.id]=session
        }
        for session in new {byID[session.id]=session}
        sessions[id]=byID.values.sorted {$0.updatedAt>$1.updatedAt}
    }
    /// Reloads the newest chats of every account. Older pages already loaded are kept.
    func refresh() {
        // A reload asked for while one is running (an account was just added) runs right after it.
        guard listTask == nil else{refreshAgain=true;return}
        refreshAgain=false
        let targets=accounts
        guard !targets.isEmpty else{sessions=[:];return}
        loading=true
        listTask=Task {[weak self] in
            await withTaskGroup(of:Void.self) {group in
                for account in targets {
                    group.addTask {@MainActor [weak self] in
                        guard let self else{return}
                        do {
                            let first=self.fetched.contains(account.id) == false
                            let page=try await self.page(account,cursor:nil)
                            guard self.accounts.contains(where:{$0.id == account.id}) else{return}
                            let before=self.visibleSessions()
                            self.merge(page.sessions,into:account.id,complete:first,reachesEnd:page.cursor == nil)
                            if first {self.cursors[account.id]=page.cursor.map {[true:$0]};self.fetched.insert(account.id)}
                            self.failures[account.id]=nil
                            await self.readKnown(account,listed:page.sessions,all:first)
                            self.follow(since:before)
                        } catch {
                            if !(error is CancellationError) {self.failures[account.id]=self.message(error)}
                        }
                    }
                }
            }
            guard let self else{return}
            self.loading=false;self.refreshedAt=Date();self.listTask=nil
            self.saveCache()
            if self.refreshAgain {self.refresh()}
        }
    }
    /// Chats seen outside Notion's list, as (Notion workspace ID, chat ID). New ones are read on the next reload,
    /// or at once while the page is open.
    func discover(_ chats:[(space:String,id:String)]) {
        var added=false
        for chat in chats {
            guard let id=AgentChat.compact(chat.id),
                  let account=accounts.first(where:{AgentChat.compact($0.workspaceID) == AgentChat.compact(chat.space)}) else{continue}
            if !cacheLoaded {loadCache()}
            if known[account.id,default:[]].insert(id).inserted {added=true}
        }
        guard added else{return}
        saveCache()
        if pollTask != nil {refresh()}
    }
    /// Reads known chats Notion's list left out: all of them after launch, then the ones still
    /// running or touched in the last two days.
    private func readKnown(_ account:AgentChatAccount,listed:[AgentChat.Session],all:Bool) async {
        let skip=Set(listed.compactMap{AgentChat.compact($0.id)})
        var current:[String:AgentChat.Session]=[:]
        for session in sessions[account.id] ?? [] {if let id=AgentChat.compact(session.id) {current[id]=session}}
        let now=Date()
        let due=(known[account.id] ?? []).union(noted(account.id)).filter {id in
            guard !skip.contains(id) else{return false}
            guard let seen=current[id] else{return true}
            if all || seen.active || seen.needsAction {return true}
            return now.timeIntervalSince(seen.updatedAt)<2*86400 && now.timeIntervalSince(readAt[id] ?? .distantPast)>25
        }.sorted {(current[$0]?.updatedAt ?? .distantFuture)>(current[$1]?.updatedAt ?? .distantFuture)}
        guard !due.isEmpty,let token=try? token(account) else{return}
        var found:[AgentChat.Session]=[],gone:[String]=[]
        // A few at a time, to stay inside Notion's request rate.
        for batch in stride(from:0,to:min(due.count,all ? 60:12),by:4).map({Array(due[$0..<min($0+4,due.count,all ? 60:12)])}) {
            await withTaskGroup(of:(String,AgentChat.Session?,Bool).self) {group in
                for id in batch {
                    group.addTask {@MainActor [weak self] in
                        guard let self else{return (id,nil,false)}
                        do {
                            let json=try await self.client.request(token:token,method:"GET",endpoint:"/sessions/"+id,body:nil)
                            return (id,AgentChat.session(json),false)
                        } catch let error as NotionAPIError {return (id,nil,error.status == 404)}
                        catch {return (id,nil,false)}
                    }
                }
                for await (id,session,missing) in group {
                    readAt[id]=Date()
                    if let session {found.append(session)} else if missing {gone.append(id)}
                }
            }
        }
        guard accounts.contains(where:{$0.id == account.id}) else{return}
        let before=visibleSessions()
        if !found.isEmpty {merge(found,into:account.id)}
        if !gone.isEmpty {
            known[account.id]?.subtract(gone)
            sessions[account.id]?.removeAll{gone.contains(AgentChat.compact($0.id) ?? "")}
            // Names, pins and group places of chats Notion no longer has go too.
            let prefix=account.id.uuidString+"/"
            let lost:(String)->Bool={key in key.hasPrefix(prefix) && gone.contains(AgentChat.compact(String(key.dropFirst(prefix.count))) ?? "")}
            titles=titles.filter{!lost($0.key)};pinned=pinned.filter{!lost($0.key)}
            for index in groups.indices {groups[index].members.removeAll(where:lost)}
            saveNotes()
        }
        follow(since:before)
    }
    func loadMore() {
        guard listTask == nil,!cursors.isEmpty else{return}
        let pending=accounts.flatMap {account in (cursors[account.id] ?? [:]).map {(account,$0.key,$0.value)}}
        loading=true
        listTask=Task {[weak self] in
            for (account,personal,cursor) in pending {
                guard let self else{return}
                do {
                    let page=try await self.page(account,cursor:cursor,personal:personal)
                    self.merge(page.sessions,into:account.id)
                    self.cursors[account.id]?[personal]=page.cursor
                    if self.cursors[account.id]?.isEmpty == true {self.cursors[account.id]=nil}
                } catch {self.failures[account.id]=self.message(error)}
            }
            self?.loading=false;self?.listTask=nil
            self?.saveCache()
        }
    }
    /// While the page is showing, the list is reloaded every half minute.
    func startPolling() {
        guard pollTask == nil else{return}
        loadCache()
        refresh()
        // Closing the page stopped the open chats' updates; catch up on what was missed.
        for id in visible {if let row=findRow(id) {watch(row)}}
        pollTask=Task {[weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30))
                guard !Task.isCancelled else{return}
                self?.refresh()
            }
        }
    }
    func stopPolling() {
        pollTask?.cancel();pollTask=nil
        for thread in threads.values {thread.task?.cancel();thread.task=nil;thread.watching=false}
    }

    // MARK: Open chats
    func thread(_ id:String)->AgentChatThread {
        if let thread=threads[id] {return thread}
        let thread=AgentChatThread(id:id)
        if let saved=savedChats[id] {thread.events=saved.events;thread.truncated=saved.truncated}
        threads[id]=thread
        return thread
    }
    func select(_ id:String?) {
        guard selection != id || selectedGroup != nil else{return}
        selection=id;selectedGroup=nil;sendFailure=nil
        show(id.map{[$0]} ?? [])
    }
    func selectGroup(_ id:UUID?) {
        guard selectedGroup != id || selection != nil else{return}
        selectedGroup=id;selection=nil;sendFailure=nil
        show(group(id)?.members ?? [])
    }
    /// Starts reading the chats now on screen, showing what was saved first, and stops reading the others.
    private func show(_ ids:[String]) {
        let before=Set(visible)
        visible=ids
        for id in before.subtracting(ids) {
            guard let thread=threads[id] else{continue}
            thread.task?.cancel();thread.task=nil;thread.watching=false
        }
        if threads.count>40 {for id in threads.keys where !ids.contains(id) {threads[id]=nil}}
        for id in ids where !before.contains(id) {
            let open=thread(id)
            open.failure=nil;open.sendFailure=nil
            open.loading=open.events.isEmpty
            // A chat not listed yet is read once the list has it.
            if let row=findRow(id) {watch(row)} else {open.loading=false}
        }
    }
    private func visibleSessions()->[String:AgentChat.Session] {
        var map:[String:AgentChat.Session]=[:]
        for id in visible {if let row=findRow(id) {map[id]=row.session}}
        return map
    }
    /// Reads again the chats on screen that moved on in Notion (a reply, a run that finished) or just appeared.
    private func follow(since before:[String:AgentChat.Session]) {
        for id in visible {
            guard let row=findRow(id),threads[id]?.watching != true else{continue}
            if let old=before[id],old.updatedAt == row.session.updatedAt,old.status == row.session.status {continue}
            watch(row)
        }
    }
    /// The newest events, shown oldest first. Every tool call is two events, so one reply
    /// can take more than a page; the first load reads up to `pages` pages back.
    /// With `after`, reading stops once it reaches the events already shown.
    private func loadEvents(_ row:AgentChatRow,pages:Int=1,after:Int?=nil) async throws->(events:[AgentChat.Event],more:Bool) {
        let token=try token(row.account)
        var found:[AgentChat.Event]=[],cursor:String?,more=false
        for _ in 0..<max(1,pages) {
            var body:JSONObject=["page_size":100,"sorts":[["property":"sequence","direction":"descending"]]]
            if let cursor {body["start_cursor"]=cursor}
            let json=try await client.request(token:token,method:"POST",endpoint:"/sessions/\(row.session.id)/events/query",body:body)
            found += (json["results"] as? [JSONObject] ?? []).compactMap(AgentChat.event)
            cursor=json["has_more"] as? Bool == true ? json["next_cursor"] as? String:nil
            more=cursor != nil
            if cursor == nil {break}
            if let after,found.contains(where:{$0.sequence<=after}) {break}
        }
        return (found.sorted {$0.sequence<$1.sequence},more)
    }
    static let eventPages=5
    private func reloadSession(_ row:AgentChatRow) async throws->AgentChat.Session? {
        let json=try await client.request(token:try token(row.account),method:"GET",endpoint:"/sessions/\(row.session.id)",body:nil)
        guard let session=AgentChat.session(json) else{return nil}
        merge([session],into:row.account.id)
        return session
    }
    /// Loads a chat's messages, and keeps reloading them while the agent is still working.
    private func watch(_ row:AgentChatRow) {
        let open=thread(row.id)
        open.task?.cancel()
        open.generation += 1
        let generation=open.generation
        open.watching=true
        open.task=Task {[weak self,weak open] in
            defer {if let open,open.generation == generation {open.watching=false}}
            var active=row.session.active
            repeat {
                guard let self,let open,self.visible.contains(row.id) else{return}
                do {
                    try await self.catchUp(row,into:open)
                    guard !Task.isCancelled,self.visible.contains(row.id) else{return}
                    if active {
                        active=(try await self.reloadSession(row))?.active ?? false
                        if !active {try? await self.catchUp(row,into:open)}
                    }
                } catch {
                    if error is CancellationError {return}
                    open.failure=self.message(error);open.loading=false;return
                }
                if active {try? await Task.sleep(for:.seconds(2.5))}
            } while active && !Task.isCancelled
        }
    }
    /// Reads the events newer than the ones shown, or the latest pages when nothing is shown or too much was missed.
    private func catchUp(_ row:AgentChatRow,into open:AgentChatThread) async throws {
        let last=open.events.last?.sequence
        let loaded=try await loadEvents(row,pages:Self.eventPages,after:last)
        guard !Task.isCancelled,visible.contains(row.id) else{return}
        let missed=last.map {last in loaded.more && (loaded.events.first?.sequence ?? 0)>last+1} ?? true
        let merged=missed ? loaded.events:AgentChat.merge(open.events,loaded.events)
        let changed=merged != open.events || (missed && open.truncated != loaded.more)
        if merged != open.events {open.events=merged}
        if missed {open.truncated=loaded.more}
        open.failure=nil;open.loading=false
        remember(row.id,open,changed:changed)
    }
    /// The chat as running, so its watch keeps reading until the agent is done.
    private func running(_ row:AgentChatRow)->AgentChatRow {
        let s=row.session
        return AgentChatRow(account:row.account,session:AgentChat.Session(id:s.id,agentID:s.agentID,title:s.title,status:"in_progress",createdByID:s.createdByID,createdByUser:s.createdByUser,createdAt:s.createdAt,updatedAt:s.updatedAt,actions:[],error:nil,trigger:s.trigger))
    }
    @discardableResult private func post(_ row:AgentChatRow,body:JSONObject) async->Bool {
        let open=thread(row.id)
        guard !open.sending else{return false}
        open.sending=true;open.sendFailure=nil
        defer {open.sending=false}
        do {
            let json=try await client.request(token:try token(row.account),method:"POST",endpoint:"/sessions",body:body)
            if let session=AgentChat.session(json) {
                // The short response omits who created it; keep what the list already knows.
                let known=AgentChat.Session(id:session.id,agentID:session.agentID,title:session.title,status:session.status,createdByID:row.session.createdByID,createdByUser:row.session.createdByUser,createdAt:session.createdAt,updatedAt:session.updatedAt,actions:session.actions,error:session.error,trigger:row.session.trigger)
                merge([known],into:row.account.id)
            }
            if visible.contains(row.id),let fresh=findRow(row.id) {watch(running(fresh))}
            return true
        } catch {open.sendFailure=message(error);return false}
    }
    private func prompt(_ text:String)->String? {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        return text.isEmpty ? nil:text
    }
    static let tooLong=10000
    func send(_ text:String,to row:AgentChatRow) async->Bool {
        guard let text=prompt(text) else{return false}
        guard text.count<=Self.tooLong else{thread(row.id).sendFailure=L("メッセージは10,000文字以内にしてください");return false}
        return await post(row,body:["session_id":row.session.id,"message":text])
    }
    /// The chats of a group that can take a follow-up now: the user's own, with the agent not working.
    func ready(_ rows:[AgentChatRow])->[AgentChatRow] {rows.filter{canReply($0) && !$0.session.active}}
    /// Sends the same follow-up to every chat of a group that can take one. True when at least one was sent.
    func send(_ text:String,toGroup rows:[AgentChatRow]) async->Bool {
        guard let text=prompt(text) else{return false}
        guard text.count<=Self.tooLong else{sendFailure=L("メッセージは10,000文字以内にしてください");return false}
        sendFailure=nil
        var sent=0
        await withTaskGroup(of:Bool.self) {group in
            for row in ready(rows) {
                group.addTask {@MainActor [weak self] in await self?.post(row,body:["session_id":row.session.id,"message":text]) ?? false}
            }
            for await ok in group where ok {sent += 1}
        }
        return sent>0
    }
    func answer(_ action:AgentChat.Action,option:String,in row:AgentChatRow) async {
        await post(row,body:["session_id":row.session.id,"actions":[["action_id":action.id,"option_id":option]]])
    }
    func cancel(_ row:AgentChatRow) async {
        do {
            _=try await client.request(token:try token(row.account),method:"POST",endpoint:"/sessions/\(row.session.id)/cancel",body:[:])
            _=try await reloadSession(row)
        } catch {thread(row.id).sendFailure=message(error)}
    }
    private func create(_ text:String,in account:AgentChatAccount) async throws->AgentChatRow {
        let json=try await client.request(token:try token(account),method:"POST",endpoint:"/sessions",body:["agent_id":"notion_ai","message":text])
        guard let session=AgentChat.session(json) else{throw LVError(L("Notionから予期しない応答が返されました"))}
        let mine=AgentChat.Session(id:session.id,agentID:session.agentID,title:session.title,status:session.status,createdByID:account.userID,createdByUser:true,createdAt:session.createdAt,updatedAt:session.updatedAt,actions:session.actions,error:session.error,trigger:nil)
        merge([mine],into:account.id)
        if let id=AgentChat.compact(mine.id) {known[account.id,default:[]].insert(id)}
        saveCache()
        return AgentChatRow(account:account,session:mine)
    }
    /// Starts a chat with the account's own Notion AI and selects it.
    func start(_ text:String,in account:AgentChatAccount) async->Bool {
        guard let text=prompt(text),text.count<=Self.tooLong,!sending else{return false}
        sending=true;sendFailure=nil
        defer {sending=false}
        do {
            let row=try await create(text,in:account)
            select(row.id)
            return true
        } catch {sendFailure=message(error);return false}
    }
    /// Starts the same prompt with the Notion AI of several accounts at once. The chats form a group,
    /// which is selected. True when at least one chat started; the accounts that failed are reported.
    func broadcast(_ text:String,to targets:[AgentChatAccount],name:String?) async->Bool {
        guard targets.count>1 else{
            guard let only=targets.first else{return false}
            return await start(text,in:only)
        }
        guard let text=prompt(text),text.count<=Self.tooLong,!sending else{return false}
        sending=true;sendFailure=nil
        defer {sending=false}
        var started:[UUID:String]=[:],failed:[UUID:String]=[:]
        await withTaskGroup(of:(UUID,String?,String?).self) {group in
            for account in targets {
                group.addTask {@MainActor [weak self] in
                    guard let self else{return (account.id,nil,nil)}
                    do {return (account.id,try await self.create(text,in:account).id,nil)}
                    catch {return (account.id,nil,self.message(error))}
                }
            }
            for await (account,row,problem) in group {
                if let row {started[account]=row}
                if let problem {failed[account]=problem}
            }
        }
        let members=targets.compactMap{started[$0.id]}
        let problems=targets.compactMap {account in failed[account.id].map{account.title+": "+$0}}.joined(separator:"\n")
        guard !members.isEmpty else{sendFailure=problems;return false}
        let title=AgentChatAccount.clean(name ?? "") ?? String(text.split(whereSeparator:\.isNewline).first?.prefix(40) ?? "")
        let id=makeGroup(title,members:members)
        selectGroup(id)
        if !problems.isEmpty {sendFailure=L("一部のアカウントでチャットを始められませんでした")+"\n"+problems}
        return true
    }

    // MARK: Names, pins and groups
    private struct Notes:Codable {
        var titles:[String:String]=[:]
        var pinned:[String:Date]=[:]
        var groups:[AgentChatGroup]=[]
    }
    private func saveNotes() {
        guard let notesFile,let data=try? JSONEncoder().encode(Notes(titles:titles,pinned:pinned,groups:groups)) else{return}
        try? FileManager.default.createDirectory(at:notesFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? data.write(to:notesFile,options:.atomic)
    }
    /// Chats the user named, pinned or grouped are read by ID even when Notion's list leaves them out.
    private func noted(_ account:UUID)->Set<String> {
        let prefix=account.uuidString+"/"
        let keys=Array(titles.keys)+Array(pinned.keys)+groups.flatMap(\.members)
        return Set(keys.filter{$0.hasPrefix(prefix)}.compactMap{AgentChat.compact(String($0.dropFirst(prefix.count)))})
    }
    func title(_ row:AgentChatRow)->String {titles[row.id] ?? row.session.title}
    func isRenamed(_ row:AgentChatRow)->Bool {titles[row.id] != nil}
    /// The name shown in this app. A blank name, or Notion's own, goes back to Notion's title.
    func rename(_ row:AgentChatRow,to name:String) {
        let value=AgentChatAccount.clean(name)
        titles[row.id]=value == row.session.title ? nil:value
        saveNotes()
    }
    func isPinned(_ row:AgentChatRow)->Bool {pinned[row.id] != nil}
    func pinnedAt(_ row:AgentChatRow)->Date? {pinned[row.id]}
    func setPinned(_ row:AgentChatRow,_ on:Bool) {
        pinned[row.id]=on ? (pinned[row.id] ?? Date()):nil
        saveNotes()
    }
    func group(_ id:UUID?)->AgentChatGroup? {id.flatMap{id in groups.first{$0.id == id}}}
    func groups(of row:AgentChatRow)->[AgentChatGroup] {groups.filter{$0.members.contains(row.id)}}
    /// The group's chats in the order they were added. Chats not loaded yet are left out.
    func rows(in group:AgentChatGroup)->[AgentChatRow] {group.members.compactMap(listedRow)}
    @discardableResult func makeGroup(_ name:String,members:[String])->UUID {
        var seen=Set<String>()
        let group=AgentChatGroup(name:AgentChatAccount.clean(name) ?? L("新しいグループ"),members:members.filter{seen.insert($0).inserted})
        groups.insert(group,at:0)
        saveNotes()
        return group.id
    }
    func add(_ row:AgentChatRow,to id:UUID) {
        guard let index=groups.firstIndex(where:{$0.id == id}),!groups[index].members.contains(row.id) else{return}
        groups[index].members.append(row.id)
        saveNotes()
        if selectedGroup == id {show(groups[index].members)}
    }
    func remove(_ row:AgentChatRow,from id:UUID) {
        guard let index=groups.firstIndex(where:{$0.id == id}) else{return}
        groups[index].members.removeAll{$0 == row.id}
        saveNotes()
        if selectedGroup == id {show(groups[index].members)}
    }
    func renameGroup(_ id:UUID,to name:String) {
        guard let index=groups.firstIndex(where:{$0.id == id}),let value=AgentChatAccount.clean(name) else{return}
        groups[index].name=value
        saveNotes()
    }
    func showsTabs(_ id:UUID,_ tabs:Bool) {
        guard let index=groups.firstIndex(where:{$0.id == id}) else{return}
        groups[index].tabs=tabs ? true:nil
        saveNotes()
    }
    /// Ungroups the chats. The chats themselves stay, in this app and in Notion.
    func deleteGroup(_ id:UUID) {
        groups.removeAll{$0.id == id}
        saveNotes()
        if selectedGroup == id {selectGroup(nil)}
    }
}
