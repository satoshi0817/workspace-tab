import SwiftUI
import AppKit
import WorkspaceCore
import CryptoKit

@MainActor final class NotionLibrary:ObservableObject {
    @Published var state=NotionLibraryState()
    @Published var busy=false
    @Published var message=""
    @Published var snapshots:[NotionSnapshotRow]=[]
    weak var store:BrowserStore?
    let client:NotionClient
    private let credentials:((String)throws->String)?
    let file:URL
    let setup:DatabaseSetup
    private var timer:Timer?
    private var writable=true
    init(store:BrowserStore,client:NotionClient = NotionClient(),credentials:((String)throws->String)? = nil){
        self.client=client;self.credentials=credentials;self.store=store;file=store.directory.appendingPathComponent("notion-library.json")
        setup=DatabaseSetup(api:client,journal:CreationJournal(url:store.directory.appendingPathComponent("database-creations.json")))
        if FileManager.default.fileExists(atPath:file.path) {
            do {state=try JSONDecoder().decode(NotionLibraryState.self,from:Data(contentsOf:file))}
            catch {writable=false;message=L("Notion設定が読めません。元ファイルを保持しています。");return}
        }
    }
    func persist()throws {
        guard writable else{throw LVError(L("Notion設定を読めないため保存を停止しています。元ファイルを確認してください。")) }
        try JSONEncoder().encode(state).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func save(){do{try persist()}catch{message=L("Notion設定を保存できません：")+error.localizedDescription}}
    func start(){
        guard writable else{return}
        timer?.invalidate()
        migrateLinkViewer()
        timer=Timer.scheduledTimer(withTimeInterval:3600,repeats:true){[weak self] _ in Task{@MainActor in await self?.sync()}}
        timer?.tolerance=60
        if state.enabled {Task{await sync()}}
    }
    func stop(){timer?.invalidate()}
    private func migrateLinkViewer(){
        guard state.linkViewerMigrationComplete != true else{return}
        do {
            let source=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Link Viewer/state.json")
            guard let data=try? Data(contentsOf:source) else{return}
            let incoming=try JSONDecoder().decode(DiskState.self,from:data)
            if !state.migrated {
                for item in incoming.sources where !state.sources.contains(where:{$0.id == item.id}) {state.sources.append(item)}
                for token in incoming.tokens where !state.tokens.contains(where:{$0.id == token.id}) {state.tokens.append(token)}
                state.cache=incoming.data;state.migrated=true
            }
            var missing=0
            for token in incoming.tokens where NotionVault.read(token.id,interactive:false) == nil {
                if let secret=NotionVault.read(token.id,legacy:true,interactive:false) {try NotionVault.write(token.id,secret:secret)} else {missing += 1}
            }
            state.linkViewerMigrationComplete = missing == 0
            try persist()
            if missing > 0 {message=L("PATにアクセスできません。「PATを更新」から設定してください。")}
        }catch{message=error.localizedDescription}
    }
    func token(_ id:String)throws->String {
        if let credentials {return try credentials(id)}
        guard let token=NotionVault.read(id,interactive:false),!token.isEmpty else{throw LVError(L("PATがありません。設定の「PATを更新」から保存してください。"))}
        return token
    }
    func checkConnection(_ source:LVSource)async throws->Int {
        let secret=try token(source.tokenId)
        let ds=try await client.request(token:secret,endpoint:"/data_sources/\(source.id)")
        guard object(object(ds,"properties"),"URL")["type"] as? String == "url" else{throw LVError(L("URL型のURLプロパティがありません"))}
        return try await client.pages(token:secret,id:source.id).count
    }
    func register(label:String,secret:String,input:String) async throws {
        let secret=secret.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !secret.isEmpty else{throw LVError(L("PATを入力してください"))}
        let id=UUID().uuidString
        let source=try await client.resolveSource(input,token:LVToken(id:id,label:label,token:secret))
        try NotionVault.write(id,secret:secret)
        state.tokens.append(TokenInfo(id:id,label:label.isEmpty ? source.title:label))
        state.sources.removeAll{$0.id == source.id};state.sources.append(source);try persist()
    }
    func replaceToken(id:String,secret:String)async throws {
        _=try await client.checkToken(secret);try NotionVault.write(id,secret:secret)
    }
    func pendingCreations()->[DatabaseCreation] {
        (try? CreationJournal(url:file.deletingLastPathComponent().appendingPathComponent("database-creations.json")).load().filter{!$0.registered}) ?? []
    }
    func create(secret:String,title:String)async throws {
        let identity=try await setup.inspect(token:secret)
        let id=UUID().uuidString;try NotionVault.write(id,secret:secret)
        state.tokens.append(TokenInfo(id:id,label:identity.workspaceName));try persist()
        let draft=DatabaseCreation(tokenId:id,identity:identity,title:title.isEmpty ? "Workspace Tabs":title)
        try await resume(draft)
    }
    func resume(_ draft:DatabaseCreation)async throws {
        let result=try await setup.create(draft,token:token(draft.tokenId))
        if let source=result.source,!state.sources.contains(where:{$0.id == source.id}) {state.sources.append(source)}
        state.tabSourceID=result.tabsSourceId;state.tabTokenID=result.tokenId;state.tabDatabaseURL=result.tabsURL
        try persist()
        var done=result;done.registered=true
        try CreationJournal(url:file.deletingLastPathComponent().appendingPathComponent("database-creations.json")).save(done)
        message=L("プライベートにLinks・Categories・Tabsを作成しました。Notion保存をオンにして使えます。")
    }
    func enqueue(_ value:FavoriteLink,delete:Bool=false)throws {
        guard state.enabled,value.notionSourceID != nil else{throw LVError(L("Notion保存をオンにしてください。"))}
        // Keep the oldest observed remote revision until the queued edit succeeds.
        let previous=state.edits
        let old=state.edits.first{$0.id == value.id}
        var copy=value;if let old {copy.notionEditedTime=old.value.notionEditedTime;copy.notionPageID=old.value.notionPageID}
        state.edits.removeAll{$0.id == value.id}
        state.edits.append(NotionEdit(value:copy,delete:delete,failure:old?.failure,uncertain:old?.uncertain ?? false))
        do {try persist()}catch{state.edits=previous;throw error}
    }
    func retry(){for i in state.edits.indices {state.edits[i].failure=nil};save();Task{await sync()}}
    func discard(_ id:UUID){
        if let edit=state.edits.first(where:{$0.id == id}),edit.value.notionPageID == nil,!edit.uncertain,
           let index=store?.session.favorites?.firstIndex(where:{$0.id == id}) {
            store?.session.favorites?[index].notionSourceID=nil;store?.changed()
        }
        state.edits.removeAll{$0.id == id};save();Task{await sync()}
    }
    func sync()async {
        guard writable,state.enabled,!busy,let store else{return}
        busy=true;defer{busy=false}
        do {
            for edit in state.edits where edit.failure == nil {
                do {
                    let result=try await push(edit)
                    if let i=state.edits.firstIndex(where:{$0.id == edit.id}) {
                        // An editor may have queued a newer change while the request was in flight.
                        if state.edits[i].value == edit.value && state.edits[i].delete == edit.delete {state.edits.remove(at:i)}
                        else {state.edits[i].value.notionPageID=result?.0;state.edits[i].value.notionEditedTime=result?.1}
                    }
                    if let result,let i=store.session.favorites?.firstIndex(where:{$0.id == edit.id}) {
                        store.session.favorites?[i].notionPageID=result.0;store.session.favorites?[i].notionEditedTime=result.1
                    }
                    try persist();store.changed()
                } catch {
                    if let i=state.edits.firstIndex(where:{$0.id == edit.id}) {state.edits[i].failure=error.localizedDescription}
                    try persist()
                }
            }
            let tokens=try state.tokens.map{LVToken(id:$0.id,label:$0.label,token:try token($0.id))}
            let result=await client.sync(DiskState(sources:state.sources,tokens:state.tokens,data:state.cache),tokens:tokens)
            merge(result,into:store);state.cache=result;try persist()
            let failures=result.sources.compactMap(\.error)
            message=failures.isEmpty ? L("Notionと同期しました（\(result.links.count)件）"):failures.joined(separator:"\n")
            if state.saveTabs {try await saveTabs()}
        }catch{message=error.localizedDescription}
    }
    func merge(_ data:LinkData,into store:BrowserStore){
        var links=store.favorites
        let pending=Set(state.edits.map(\.id))
        for source in data.sources where source.error == nil {
            let incoming=data.links.filter{$0.sourceId == source.id}
            let ids=Set(incoming.map(\.id))
            links.removeAll{ $0.notionSourceID == source.id && $0.notionPageID != nil && !ids.contains($0.notionPageID!) && !pending.contains($0.id) }
            for remote in incoming {
                guard let url=BrowserAddress.url(remote.url),!remote.name.isEmpty else{continue}
                let old=links.first{$0.notionSourceID == source.id && ($0.notionPageID == remote.id || $0.id.uuidString == remote.workspaceLinkID) || $0.importKey == "link-viewer:"+remote.key}
                if let old,pending.contains(old.id){continue}
                var value=old ?? FavoriteLink(title:remote.name,url:BrowserAddress.savedURL(url),workspaceID:UUID())
                value.title=remote.name;value.url=BrowserAddress.savedURL(url);value.category=remote.category?.name ?? "";value.pinned=remote.pinned;value.order=remote.order
                value.categoryWorkspaceID=remote.category?.workspaceID
                value.notionSourceID=source.id;value.notionPageID=remote.id;value.notionEditedTime=remote.editedTime
                value.emoji=remote.emoji ?? ""
                if let path=remote.iconPath,URL(fileURLWithPath:path).deletingLastPathComponent() == Storage.icons {value.iconFile=URL(fileURLWithPath:path).lastPathComponent}
                if let ref=remote.workspaceRef,let uuid=UUID(uuidString:ref),store.workspace(uuid) != nil {value.workspaceID=uuid}
                else if let name=remote.workspaceName,!name.isEmpty {
                    let matches=store.session.workspaces.filter{$0.name == name}
                    value.workspaceID=matches.count == 1 ? matches[0].id:UUID()
                } else if old == nil || store.workspace(value.workspaceID) == nil {
                    let matches=store.session.workspaces.filter{$0.name == remote.app}
                    if matches.count == 1 {value.workspaceID=matches[0].id}
                }
                if let i=links.firstIndex(where:{$0.id == value.id}) {links[i]=value}else{links.append(value)}
            }
        }
        if store.favorites != links {store.session.favorites=links;store.changed()}
    }
    private func push(_ edit:NotionEdit)async throws->(String,String?)? {
        guard let sid=edit.value.notionSourceID,let source=state.sources.first(where:{$0.id == sid}) else{throw LVError(L("保存先のDBがありません"))}
        let secret=try token(source.tokenId),value=edit.value
        var pageID=value.notionPageID
        if pageID == nil {
            let rows=try await client.pages(token:secret,id:sid)
            let candidates=rows.filter{richText(object(object($0,"properties"),"Workspace Tabs ID")["rich_text"]) == value.id.uuidString}
            guard candidates.count <= 1 else{throw LVError(L("同じIDのリンクが複数あります。Notionで確認してください。"))}
            if let found=candidates.first {pageID=found["id"] as? String}
            else if edit.uncertain {throw LVError(L("前回の作成結果を確認できません。二重作成を防ぐため停止しています。NotionのDBを確認してください。"))}
        }
        if let pageID {
            let current=try await client.request(token:secret,endpoint:"/pages/\(pageID)")
            guard object(current,"parent")["data_source_id"] as? String == sid else{throw LVError(L("リンクの保存先が変わりました。同期し直してください。"))}
            if edit.delete,current["in_trash"] as? Bool == true {return nil}
            if let expected=value.notionEditedTime,current["last_edited_time"] as? String != expected {
                throw LVError(L("Notion側でも変更されています。「Notionの内容を採用」してから編集し直してください。"))
            }
        }
        if edit.delete {
            if let pageID {_=try await client.request(token:secret,method:"PATCH",endpoint:"/pages/\(pageID)",body:["in_trash":true])}
            return nil
        }
        var schema=object(try await client.request(token:secret,endpoint:"/data_sources/\(sid)"),"properties")
        var additions:JSONObject=[:]
        for name in ["Workspace Tabs ID","Workspace Tab","Workspace Tab Name"] {
            if schema[name] == nil {additions[name]=["rich_text":[:]]}
            else if object(schema,name)["type"] as? String != "rich_text" {throw LVError(L("\(name)はテキスト型が必要です。"))}
        }
        if !additions.isEmpty {schema=object(try await client.request(token:secret,method:"PATCH",endpoint:"/data_sources/\(sid)",body:["properties":additions]),"properties")}
        guard let title=schema.first(where:{($0.value as? JSONObject)?["type"] as? String == "title"})?.key else{throw LVError(L("タイトルプロパティがありません"))}
        var properties:JSONObject=[title:["title":Self.text(value.title)],"URL":["url":value.url],"Workspace Tabs ID":["rich_text":Self.text(value.id.uuidString)],"Workspace Tab":["rich_text":Self.text(value.workspaceID.uuidString)],"Workspace Tab Name":["rich_text":Self.text(store?.workspace(value.workspaceID)?.name ?? "")]]
        if object(schema,"Pinned")["type"] as? String == "checkbox" {properties["Pinned"]=["checkbox":value.pinned]}
        let cat=object(schema,"Category")
        if cat["type"] as? String == "select" {properties["Category"]=["select":value.category.isEmpty ? NSNull():["name":value.category] as Any]}
        else if cat["type"] as? String == "relation",let catID=object(cat,"relation")["data_source_id"] as? String {
            var relation:[JSONObject]=[]
            if !value.category.isEmpty {
                let categories=try await client.pages(token:secret,id:catID)
                let matches=categories.filter{titleOf(object($0,"properties")) == value.category}
                guard matches.count <= 1 else{throw LVError(L("同名カテゴリが複数あります。Notionで整理してください。"))}
                let category:JSONObject
                if let found=matches.first {category=found}
                else {
                    let catSchema=object(try await client.request(token:secret,endpoint:"/data_sources/\(catID)"),"properties")
                    guard let title=catSchema.first(where:{($0.value as? JSONObject)?["type"] as? String == "title"})?.key else{throw LVError(L("カテゴリのタイトルがありません"))}
                    category=try await client.request(token:secret,method:"POST",endpoint:"/pages",body:["parent":["data_source_id":catID],"properties":[title:["title":Self.text(value.category)]]])
                }
                if let id=category["id"] as? String {relation=[["id":id]]}
            }
            properties["Category"]=["relation":relation]
        }
        var body:JSONObject=["properties":properties]
        if value.emoji.count == 1 {body["icon"]=["type":"emoji","emoji":value.emoji]}
        if pageID == nil {
            body["parent"]=["data_source_id":sid]
            if let i=state.edits.firstIndex(where:{$0.id == edit.id}) {state.edits[i].uncertain=true;try persist()}
        }
        let response:JSONObject
        do {response=try await client.request(token:secret,method:pageID == nil ? "POST":"PATCH",endpoint:pageID.map{"/pages/\($0)"} ?? "/pages",body:body)}
        catch {
            if let error=error as? NotionAPIError,[400,401,403,404,409,422,429].contains(error.status),let i=state.edits.firstIndex(where:{$0.id == edit.id}) {state.edits[i].uncertain=false;try persist()}
            throw error
        }
        guard let id=response["id"] as? String else{throw LVError(L("保存結果を確認できませんでした"))}
        return (id,response["last_edited_time"] as? String)
    }
    static func text(_ text:String)->[JSONObject] {text.isEmpty ? []:[["type":"text","text":["content":String(text.prefix(2000))]]]}
}
