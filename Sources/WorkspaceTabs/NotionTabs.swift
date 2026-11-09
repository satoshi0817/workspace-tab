import Foundation
import AppKit
import CryptoKit
import WorkspaceCore

struct NotionSnapshotRow:Identifiable {
    var id:String
    var name:String
    var updated:String
}
extension NotionLibrary {
    func connectTabDatabase(input:String,tokenID:String)async throws {
        guard let id=extractId(URL(string:input)?.path ?? input) else{throw LVError("TabsデータベースのURLを入力してください")}
        let secret=try token(tokenID)
        let database=try? await client.request(token:secret,endpoint:"/databases/\(id)")
        let sources=database?["data_sources"] as? [JSONObject] ?? []
        guard sources.count <= 1 else{throw LVError("データソースIDを直接入力してください")}
        let sid=sources.first?["id"] as? String ?? id
        let ds=try await client.request(token:secret,endpoint:"/data_sources/\(sid)")
        try Self.validateTabSchema(ds)
        state.tabSourceID=sid;state.tabTokenID=tokenID;state.tabDatabaseURL=database?["url"] as? String ?? input
        state.tabPageID=nil;state.lastTabDigest=nil;state.tabWriteUncertain=false;try persist()
    }
    static func validateTabSchema(_ ds:JSONObject)throws {
        let props=object(ds,"properties")
        for (name,type) in ["Name":"title","Device":"rich_text","Snapshot":"rich_text","Updated":"date"] {
            guard object(props,name)["type"] as? String == type else{throw LVError("Tabs DBには\(type)型の「\(name)」が必要です。新規セットアップで自動作成できます。")}
        }
    }
    static func tabBackup(store:BrowserStore,includePages:Bool)throws->BrowserBackup {
        var session=store.session
        session.favorites=nil;session.windowFrame=nil
        session.splitStateRecorded=true;session.splitWorkspaceID=nil;session.splitPageID=nil
        var icons:[String:Data]=[:]
        for i in session.profiles.indices {session.profiles[i].accountNote=""}
        for i in session.workspaces.indices {
            session.workspaces[i].homeURL=BrowserAddress.url(session.workspaces[i].homeURL).map(BrowserAddress.savedURL) ?? "about:blank"
            if !includePages {
                var page=BrowserPage(url:session.workspaces[i].homeURL);page.id=session.workspaces[i].id
                session.workspaces[i].pages=[page];session.workspaces[i].selectedPageID=page.id
            } else {
                for j in session.workspaces[i].pages.indices {
                    session.workspaces[i].pages[j].url=BrowserAddress.url(session.workspaces[i].pages[j].url).map(BrowserAddress.savedURL) ?? "about:blank"
                }
            }
            let iconNames=[session.workspaces[i].iconFile].compactMap{$0}+session.workspaces[i].pages.compactMap(\.tabIconFile)+session.workspaces[i].resolvedTabGroups.compactMap(\.iconFile)
            for name in Set(iconNames) {
                guard name == URL(fileURLWithPath:name).lastPathComponent,
                      let image=store.iconCache.image(directory:store.directory,name:name) else{continue}
                let small=NSImage(size:NSSize(width:48,height:48));small.lockFocus();image.draw(in:NSRect(x:0,y:0,width:48,height:48));small.unlockFocus()
                if let data=small.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data),let png=bitmap.representation(using:.png,properties:[:]) {icons[name]=png}
            }
        }
        return BrowserBackup(session:try session.validated(),icons:icons)
    }
    func saveTabs()async throws {
        guard let store,let sid=state.tabSourceID,let tokenID=state.tabTokenID else{throw LVError("タブ保存用のDBを設定してください")}
        let secret=try token(tokenID)
        try Self.validateTabSchema(try await client.request(token:secret,endpoint:"/data_sources/\(sid)"))
        let backup=try Self.tabBackup(store:store,includePages:state.includePages)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(backup)
        guard data.count<=160_000,let payload=String(data:data,encoding:.utf8) else{throw LVError("タブ情報が保存上限160KBを超えました。画像やタブを減らしてください。")}
        let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        if state.lastTabDigest == digest {return}
        if state.tabPageID == nil {
            let rows=try await client.pages(token:secret,id:sid)
            let matches=rows.filter{richText(object(object($0,"properties"),"Device")["rich_text"]) == state.deviceID}
            guard matches.count<=1 else{throw LVError("同じMacの保存行が複数あります。Notionで確認してください。")}
            state.tabPageID=matches.first?["id"] as? String
            if state.tabPageID == nil && state.tabWriteUncertain {throw LVError("タブ保存行の作成結果が不明です。重複作成を避けて停止しました。")}
        }
        if let pageID=state.tabPageID {
            let row=try await client.request(token:secret,endpoint:"/pages/\(pageID)")
            guard object(row,"parent")["data_source_id"] as? String == sid,richText(object(object(row,"properties"),"Device")["rich_text"]) == state.deviceID,row["in_trash"] as? Bool != true else{throw LVError("タブの保存行が移動・削除されています。DBを接続し直してください。")}
        }
        var chunks:[JSONObject]=[];var remaining=payload[...]
        while !remaining.isEmpty {let part=String(remaining.prefix(1800));chunks += Self.text(part);remaining=remaining.dropFirst(part.count)}
        guard chunks.count <= 100 else{throw LVError("タブ情報がNotionの保存上限を超えました。")}
        var body:JSONObject=["properties":["Name":["title":Self.text(state.deviceName)],"Device":["rich_text":Self.text(state.deviceID)],"Snapshot":["rich_text":chunks],"Updated":["date":["start":ISO8601DateFormatter().string(from:Date())]]]]
        if state.tabPageID == nil {body["parent"]=["data_source_id":sid];state.tabWriteUncertain=true;try persist()}
        let result=try await client.request(token:secret,method:state.tabPageID == nil ? "POST":"PATCH",endpoint:state.tabPageID.map{"/pages/\($0)"} ?? "/pages",body:body)
        guard let id=result["id"] as? String else{throw LVError("タブの保存結果が確認できません")}
        state.tabPageID=id;state.tabWriteUncertain=false;state.lastTabDigest=digest;try persist()
    }
    func listSnapshots()async throws {
        guard let sid=state.tabSourceID,let tid=state.tabTokenID else{throw LVError("Tabs DBを接続してください")}
        let rows=try await client.pages(token:token(tid),id:sid)
        snapshots=rows.compactMap {row in
            guard let id=row["id"] as? String else{return nil}
            let props=object(row,"properties")
            return NotionSnapshotRow(id:id,name:titleOf(props),updated:object(object(props,"Updated"),"date")["start"] as? String ?? "")
        }
    }
    func readSnapshot(_ id:String)async throws->BrowserBackup {
        guard let tid=state.tabTokenID,let sid=state.tabSourceID else{throw LVError("Tabs DBを接続してください")}
        let row=try await client.request(token:token(tid),endpoint:"/pages/\(id)")
        guard object(row,"parent")["data_source_id"] as? String == sid else{throw LVError("保存先が一致しません")}
        let property=object(object(row,"properties"),"Snapshot")
        var payload=richText(property["rich_text"])
        if (property["rich_text"] as? [JSONObject] ?? []).count >= 25,let propertyID=property["id"] as? String {
            var pieces:[JSONObject]=[],cursor:String?
            repeat {
                var endpoint="/pages/\(id)/properties/\(propertyID)?page_size=100"
                if let cursor {endpoint += "&start_cursor="+cursor}
                let page=try await client.request(token:token(tid),endpoint:endpoint)
                pieces += (page["results"] as? [JSONObject] ?? []).map{object($0,"rich_text")}
                cursor=page["has_more"] as? Bool == true ? page["next_cursor"] as? String:nil
            } while cursor != nil
            payload=richText(pieces)
        }
        guard let data=payload.data(using:.utf8),data.count<=160_000 else{throw LVError("保存データが不正です")}
        let backup=try JSONDecoder().decode(BrowserBackup.self,from:data);_=try backup.session.validated()
        return backup
    }
}
