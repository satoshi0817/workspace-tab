import Foundation
import WorkspaceCore

actor CloudFixture:NotionRequesting {
    let source="10000000-0000-4000-8000-000000000099"
    var rows:[String:JSONObject]=[:]
    var props:JSONObject=["Name":["type":"title"],"URL":["type":"url"],"Pinned":["type":"checkbox"],"Category":["type":"select","select":["options":[]]]]
    var revision=0
    var writeCount=0
    var loseCreateResponse=false
    func loseNextCreate(){loseCreateResponse=true}
    func editRemotely(_ id:String){revision += 1;rows[id]?["last_edited_time"]="r\(revision)";var p=object(rows[id] ?? [:],"properties");p["Name"]=["type":"title","title":[["type":"text","text":["content":"Remote edited"]]]];rows[id]?["properties"]=p}
    func count()->Int {writeCount}
    func request(token:String,method:String,endpoint:String,body:JSONObject?) async throws->JSONObject {
        precondition(token == "test-secret")
        if endpoint == "/data_sources/\(source)" {
            if method == "PATCH" {for (key,var value) in object(body ?? [:],"properties").mapValues({$0 as! JSONObject}) {value["type"]=value.keys.first!;props[key]=value}}
            return ["id":source,"properties":props]
        }
        if endpoint == "/data_sources/\(source)/query" {return ["results":Array(rows.values).filter{$0["in_trash"] as? Bool != true},"has_more":false]}
        if method == "GET",endpoint.hasPrefix("/pages/") {return rows[String(endpoint.dropFirst(7))]!}
        if endpoint == "/pages" || (endpoint.hasPrefix("/pages/") && method == "PATCH") {
            let creating=endpoint == "/pages"
            let id=creating ? UUID().uuidString:String(endpoint.dropFirst(7))
            var row=rows[id] ?? ["id":id,"parent":["data_source_id":source]]
            var p=object(row,"properties")
            for (name,var value) in object(body ?? [:],"properties").mapValues({$0 as! JSONObject}) {value["type"]=value.keys.first!;p[name]=value}
            revision += 1;writeCount += 1;row["properties"]=p;row["last_edited_time"]="r\(revision)";row["in_trash"]=body?["in_trash"] ?? false
            rows[id]=row
            if creating && loseCreateResponse {loseCreateResponse=false;throw URLError(.networkConnectionLost)}
            return row
        }
        throw LVError("Unexpected fixture call \(method) \(endpoint)")
    }
}
@MainActor enum NotionCloudChecks {
    static func run()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=BrowserStore(directory:root)
        defer{store.shutdown()}
        let fixture=CloudFixture(),client=NotionClient(transport:fixture)
        let manager=NotionLibrary(store:store,client:client,credentials:{_ in "test-secret"})
        let sid=fixture.source
        manager.state.sources=[LVSource(id:sid,title:"Test",tokenId:"test")]
        manager.state.tokens=[TokenInfo(id:"test",label:"Test")]
        precondition(!manager.state.enabled && !manager.state.saveTabs,"Cloud storage must be opt in")
        await manager.sync();let initial=await fixture.count();precondition(initial == 0)
        manager.state.enabled=true
        var value=FavoriteLink(title:"Local",url:"https://example.com",workspaceID:store.selected!.id)
        value.notionSourceID=sid;value.category="Work"
        store.session.favorites=[value]
        try manager.enqueue(value)
        await manager.sync()
        precondition(manager.state.edits.isEmpty && store.favorites.count == 1)
        value=store.favorites[0]
        precondition(value.notionPageID != nil && value.notionEditedTime != nil)
        let afterCreate=await fixture.count();precondition(afterCreate == 1)
        await fixture.editRemotely(value.notionPageID!)
        value.title="Local competing edit";store.session.favorites=[value]
        try manager.enqueue(value);await manager.sync()
        let afterConflict=await fixture.count();precondition(afterConflict == afterCreate,"Conflict cannot overwrite remote changes")
        precondition(manager.state.edits[0].failure != nil && store.favorites[0].title == "Local competing edit")
        manager.state.edits=[];await manager.sync()
        precondition(store.favorites[0].title == "Remote edited")
        var lost=FavoriteLink(title:"Lost response",url:"https://example.org",workspaceID:store.selected!.id);lost.notionSourceID=sid
        store.session.favorites?.append(lost);try manager.enqueue(lost)
        await fixture.loseNextCreate();await manager.sync()
        precondition(manager.state.edits.first?.uncertain == true)
        precondition(store.favorites.count == 2,"A pending create must not appear twice in the launcher")
        manager.state.edits[0].failure=nil;await manager.sync()
        precondition(manager.state.edits.isEmpty)
        let rows=try await client.pages(token:"test-secret",id:sid)
        precondition(rows.filter{titleOf(object($0,"properties")) == "Lost response"}.count == 1,"A committed create with lost response must not duplicate")
        var snapshot=store.session
        snapshot.profiles[0].accountNote="private account memo"
        snapshot.workspaces[0].pages[0].url="https://example.com/?access_token=secret&view=safe"
        store.session=snapshot
        let backup=try NotionLibrary.tabBackup(store:store,includePages:true)
        let bytes=try JSONEncoder().encode(backup),json=String(data:bytes,encoding:.utf8)!
        precondition(!json.contains("private account memo") && !json.contains("access_token") && !json.contains("test-secret"))
        precondition(backup.session.favorites == nil)
        let config1=try NotionLibrary.tabBackup(store:store,includePages:false)
        let config2=try NotionLibrary.tabBackup(store:store,includePages:false)
        precondition(config1.session == config2.session,"Configuration-only snapshots must have stable identifiers")
        let disk=try Data(contentsOf:manager.file)
        precondition(!String(data:disk,encoding:.utf8)!.contains("test-secret"))
        let corrupted=Data("broken-json".utf8);try corrupted.write(to:manager.file)
        let unreadable=NotionLibrary(store:store,client:client,credentials:{_ in "test-secret"})
        unreadable.save()
        let preserved=try Data(contentsOf:manager.file);precondition(preserved == corrupted,"Unreadable configuration must never be overwritten")
        print("PASS Notion cloud: opt-in, create, conflict protection, lost-response recovery, secret-free configuration, stable snapshots")
    }
}
