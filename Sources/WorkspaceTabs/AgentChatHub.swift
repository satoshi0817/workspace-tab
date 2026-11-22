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
    var vaultID:String {"agentchat-"+id.uuidString}
    var title:String {workspaceName.isEmpty ? L("Notionワークスペース"):workspaceName}
    var person:String {userName.isEmpty ? email:userName}
}

struct AgentChatRow:Identifiable,Equatable {
    let account:AgentChatAccount
    let session:AgentChat.Session
    var id:String {account.id.uuidString+"/"+session.id}
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
    @Published var selection:String?
    @Published private(set) var events:[AgentChat.Event]=[]
    @Published private(set) var eventsLoading=false
    @Published private(set) var eventsFailure:String?
    @Published private(set) var sending=false
    @Published var sendFailure:String?
    /// Where each account's two lists continue: every session, and Notion AI chats only.
    private var cursors:[UUID:[Bool:String]]=[:]
    private var listTask:Task<Void,Never>?
    private var refreshAgain=false
    private var watchTask:Task<Void,Never>?
    private var pollTask:Task<Void,Never>?
    private let client:any NotionRequesting
    private let credentials:(String)->String?
    private let storeSecret:(String,String)throws->Void
    private let file:URL?
    static let pageSize=50

    init(client:any NotionRequesting=NotionClient(apiVersion:"2026-03-11"),file:URL?=Storage.root.appendingPathComponent("agent-chats.json"),credentials:@escaping(String)->String?={NotionVault.read($0)},storeSecret:@escaping(String,String)throws->Void={try NotionVault.write($0,secret:$1)}) {
        self.client=client;self.file=file;self.credentials=credentials;self.storeSecret=storeSecret
        if let file,let data=try? Data(contentsOf:file),let saved=try? JSONDecoder().decode([AgentChatAccount].self,from:data) {accounts=saved}
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
    var selectedRow:AgentChatRow? {selection.flatMap {id in rows.first{$0.id == id}}}
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
        sessions[id]=nil;agents[id]=nil;failures[id]=nil;cursors[id]=nil
        if selectedRow == nil {select(nil)}
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
    private func merge(_ new:[AgentChat.Session],into id:UUID,replacingHead:Bool) {
        var byID:[String:AgentChat.Session]=[:]
        for session in sessions[id] ?? [] {byID[session.id]=session}
        for session in new {byID[session.id]=session}
        _=replacingHead
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
                            let first=self.sessions[account.id] == nil
                            let page=try await self.page(account,cursor:nil)
                            guard self.accounts.contains(where:{$0.id == account.id}) else{return}
                            self.merge(page.sessions,into:account.id,replacingHead:true)
                            if first {self.cursors[account.id]=page.cursor.map {[true:$0]}}
                            self.failures[account.id]=nil
                        } catch {
                            if !(error is CancellationError) {self.failures[account.id]=self.message(error)}
                        }
                    }
                }
            }
            guard let self else{return}
            self.loading=false;self.refreshedAt=Date();self.listTask=nil
            if self.refreshAgain {self.refresh()}
        }
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
                    self.merge(page.sessions,into:account.id,replacingHead:false)
                    self.cursors[account.id]?[personal]=page.cursor
                    if self.cursors[account.id]?.isEmpty == true {self.cursors[account.id]=nil}
                } catch {self.failures[account.id]=self.message(error)}
            }
            self?.loading=false;self?.listTask=nil
        }
    }
    /// While the page is showing, the list is reloaded every half minute.
    func startPolling() {
        guard pollTask == nil else{return}
        refresh()
        pollTask=Task {[weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30))
                guard !Task.isCancelled else{return}
                self?.refresh()
            }
        }
    }
    func stopPolling() {pollTask?.cancel();pollTask=nil;watchTask?.cancel();watchTask=nil}

    // MARK: One chat
    func select(_ id:String?) {
        guard selection != id else{return}
        selection=id;events=[];eventsFailure=nil;sendFailure=nil
        watchTask?.cancel();watchTask=nil
        guard let row=selectedRow else{return}
        eventsLoading=true
        watch(row)
    }
    private func loadEvents(_ row:AgentChatRow) async throws->[AgentChat.Event] {
        let token=try token(row.account)
        // The newest 100 events, shown oldest first.
        let body:JSONObject=["page_size":100,"sorts":[["property":"sequence","direction":"descending"]]]
        let json=try await client.request(token:token,method:"POST",endpoint:"/sessions/\(row.session.id)/events/query",body:body)
        return (json["results"] as? [JSONObject] ?? []).compactMap(AgentChat.event).sorted {$0.sequence<$1.sequence}
    }
    private func reloadSession(_ row:AgentChatRow) async throws->AgentChat.Session? {
        let json=try await client.request(token:try token(row.account),method:"GET",endpoint:"/sessions/\(row.session.id)",body:nil)
        guard let session=AgentChat.session(json) else{return nil}
        merge([session],into:row.account.id,replacingHead:false)
        return session
    }
    /// Loads a chat's messages, and keeps reloading them while the agent is still working.
    private func watch(_ row:AgentChatRow) {
        watchTask?.cancel()
        watchTask=Task {[weak self] in
            var active=row.session.active
            repeat {
                guard let self,self.selection == row.id else{return}
                do {
                    let loaded=try await self.loadEvents(row)
                    guard !Task.isCancelled,self.selection == row.id else{return}
                    if loaded != self.events {self.events=loaded}
                    self.eventsFailure=nil;self.eventsLoading=false
                    if active {active=(try await self.reloadSession(row))?.active ?? false;if !active {self.events=(try? await self.loadEvents(row)) ?? self.events}}
                } catch {
                    if error is CancellationError {return}
                    self.eventsFailure=self.message(error);self.eventsLoading=false;return
                }
                if active {try? await Task.sleep(for:.seconds(2.5))}
            } while active && !Task.isCancelled
        }
    }
    private func post(_ row:AgentChatRow,body:JSONObject) async {
        guard !sending else{return}
        sending=true;sendFailure=nil
        defer {sending=false}
        do {
            let json=try await client.request(token:try token(row.account),method:"POST",endpoint:"/sessions",body:body)
            if let session=AgentChat.session(json) {
                // The short response omits who created it; keep what the list already knows.
                let known=AgentChat.Session(id:session.id,agentID:session.agentID,title:session.title,status:session.status,createdByID:row.session.createdByID,createdByUser:row.session.createdByUser,createdAt:session.createdAt,updatedAt:session.updatedAt,actions:session.actions,error:session.error,trigger:row.session.trigger)
                merge([known],into:row.account.id,replacingHead:false)
            }
            if let fresh=selectedRow,fresh.id == row.id {
                watch(AgentChatRow(account:fresh.account,session:AgentChat.Session(id:fresh.session.id,agentID:fresh.session.agentID,title:fresh.session.title,status:"in_progress",createdByID:fresh.session.createdByID,createdByUser:fresh.session.createdByUser,createdAt:fresh.session.createdAt,updatedAt:fresh.session.updatedAt,actions:[],error:nil,trigger:fresh.session.trigger)))
            }
        } catch {sendFailure=message(error)}
    }
    func send(_ text:String,to row:AgentChatRow) async->Bool {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else{return false}
        guard text.count<=10000 else{sendFailure=L("メッセージは10,000文字以内にしてください");return false}
        await post(row,body:["session_id":row.session.id,"message":text])
        return sendFailure == nil
    }
    func answer(_ action:AgentChat.Action,option:String,in row:AgentChatRow) async {
        await post(row,body:["session_id":row.session.id,"actions":[["action_id":action.id,"option_id":option]]])
    }
    func cancel(_ row:AgentChatRow) async {
        do {
            _=try await client.request(token:try token(row.account),method:"POST",endpoint:"/sessions/\(row.session.id)/cancel",body:[:])
            _=try await reloadSession(row)
        } catch {sendFailure=message(error)}
    }
    /// Starts a chat with the account's own Notion AI and selects it.
    func start(_ text:String,in account:AgentChatAccount) async->Bool {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.count<=10000,!sending else{return false}
        sending=true;sendFailure=nil
        defer {sending=false}
        do {
            let json=try await client.request(token:try token(account),method:"POST",endpoint:"/sessions",body:["agent_id":"notion_ai","message":text])
            guard let session=AgentChat.session(json) else{throw LVError(L("Notionから予期しない応答が返されました"))}
            let mine=AgentChat.Session(id:session.id,agentID:session.agentID,title:session.title,status:session.status,createdByID:account.userID,createdByUser:true,createdAt:session.createdAt,updatedAt:session.updatedAt,actions:session.actions,error:session.error,trigger:nil)
            merge([mine],into:account.id,replacingHead:false)
            select(AgentChatRow(account:account,session:mine).id)
            return true
        } catch {sendFailure=message(error);return false}
    }
}
