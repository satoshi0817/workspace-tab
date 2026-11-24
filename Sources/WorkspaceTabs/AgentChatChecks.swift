import Foundation
import WorkspaceCore

/// Stands in for Notion's Agent API: one workspace per token.
private actor AgentChatFixture:NotionRequesting {
    var sent:[JSONObject]=[]
    var eventQueries=0
    func queries()->Int {eventQueries}
    var status:[String:String]=["s1":"completed","s2":"requires_action","s3":"completed"]
    func bodies()->[JSONObject] {sent}
    private func session(_ id:String,agent:String,user:Bool,minute:Int,by:String="u-a")->JSONObject {
        var json:JSONObject=["object":"session","id":id,"agent_id":agent,"title":"Chat "+id,"status":status[id] ?? "completed",
            "created_by":["id":user ? by:"bot-1","type":user ? "user":"bot"],"created_at":"2026-11-20T10:00:00.000Z","updated_at":"2026-11-20T10:\(String(format:"%02d",minute)):00.000Z"]
        if status[id] == "requires_action" {json["required_actions"]=[["action_id":"act","title":"Send it?","options":[["id":"approve","label":"Approve"],["id":"reject","label":"Reject"]]]]}
        return json
    }
    func request(token:String,method:String,endpoint:String,body:JSONObject?) async throws->JSONObject {
        guard token == "pat-a" || token == "pat-b" else{throw NotionAPIError(status:401,message:"unauthorized")}
        let a=token == "pat-a"
        switch (method,endpoint) {
        case ("GET","/users/me"):
            return ["object":"user","type":"bot","bot":["workspace_id":a ? "w-a":"w-b","workspace_name":a ? "Alpha":"Beta","owner":["type":"user","user":["id":a ? "u-a":"u-b","name":a ? "Alice":"Bob","person":["email":a ? "alice@example.test":"bob@example.test"]]]]]
        case ("POST","/agents/query"):
            return ["results":[["id":"agent-1","name":"Deal Desk","agent_type":"custom_agent","icon":["type":"emoji","emoji":"🤖"]]],"has_more":false]
        case ("POST","/sessions/query"):
            // The first page is empty though more remain, as Notion may answer.
            guard ((body?["filter"] as? JSONObject)?["string"] as? [String:String])?["equals"] == "notion_ai" else{throw NotionAPIError(status:400,message:"unfiltered")}
            // The first page is empty though more remain, as Notion may answer.
            if a,body?["start_cursor"] == nil {return ["results":[],"has_more":true,"next_cursor":"c1"]}
            let list=a ? [session("s1",agent:"notion_ai",user:true,minute:5),session("s2",agent:"notion_ai",user:true,minute:1),session("s3",agent:"agent-1",user:false,minute:9)]
                :[session("s4",agent:"notion_ai",user:false,minute:7),session("s5",agent:"notion_ai",user:true,minute:8,by:"u-b")]
            return ["results":list,"has_more":false]
        case ("POST","/sessions/s2/events/query"),("POST","/sessions/s1/events/query"),("POST","/sessions/s9/events/query"):
            eventQueries += 1
            return ["results":[["id":"e2","type":"agent.message","sequence":2,"content":[["type":"text","text":"Done"]]],["id":"e1","type":"user.message","sequence":1,"content":[["type":"text","text":"Hello"]]]],"has_more":false]
        case ("GET","/sessions/s2"):return session("s2",agent:"notion_ai",user:true,minute:30)
        case ("GET","/sessions/s1"):return session("s1",agent:"notion_ai",user:true,minute:31)
        // A recent chat Notion's list leaves out, though it can be read by its ID.
        case ("GET","/sessions/s7"):return session("s7",agent:"notion_ai",user:true,minute:50)
        // A chat started here, in either workspace.
        case ("GET","/sessions/s9"):return session("s9",agent:"notion_ai",user:true,minute:45,by:a ? "u-a":"u-b")
        case ("POST","/sessions"):
            sent.append(body ?? [:])
            let id=body?["session_id"] as? String ?? "s9"
            status[id]="completed"
            return ["object":"session","id":id,"agent_id":"notion_ai","title":"Chat "+id,"status":"queued","created_at":"2026-11-20T10:00:00.000Z","updated_at":"2026-11-20T10:40:00.000Z"]
        default:throw NotionAPIError(status:404,message:"not found")
        }
    }
}

@MainActor enum AgentChatChecks {
    static func run() async throws {
        func expect(_ condition:Bool,_ name:String)throws {
            guard condition else{throw BrowserChecks.Failure.check(name)};print("PASS "+name)
        }
        func settle(_ hub:AgentChatHub,_ done:@escaping()->Bool) async {
            for _ in 0..<400 {if done() {return};try? await Task.sleep(for:.milliseconds(10))}
        }
        let fixture=AgentChatFixture()
        var vault:[String:String]=[:]
        let hub=AgentChatHub(client:fixture,file:nil,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        do {try await hub.addAccount(token:"bad");try expect(false,"An invalid token is refused")} catch {try expect(hub.accounts.isEmpty,"An invalid token is refused and nothing is stored")}
        try await hub.addAccount(token:" pat-a ")
        try await hub.addAccount(token:"pat-b")
        try await hub.addAccount(token:"pat-a")
        try expect(hub.accounts.map(\.workspaceName) == ["Alpha","Beta"] && vault.count == 2,"One account per workspace and user; registering it again replaces the token")
        var look=hub.accounts[0]
        look.nickname="  Work  ";look.emoji="🧪🧪🧪🧪🧪";look.color="violet"
        hub.customize(look)
        try await hub.addAccount(token:"pat-a")
        let alpha=hub.accounts[0]
        try expect(alpha.title == "Work" && alpha.notionTitle == "Alpha" && alpha.emoji == "🧪🧪🧪🧪" && alpha.color == "violet" && alpha.customized,"An account's own name, emoji and color replace Notion's and survive registering its token again")
        look=alpha;look.nickname="   "
        hub.customize(look)
        try expect(hub.accounts[0].title == "Alpha" && hub.accounts[0].nickname == nil,"A blank name falls back to the Notion workspace name")
        await settle(hub) {!hub.loading && hub.rows.count == 3}
        try expect(hub.rows.map(\.session.id) == ["s2","s5","s1"] && hub.failures.isEmpty,"Only the user's own Notion AI chats of every workspace are listed, waiting ones first, then the most recently updated")
        let waiting=hub.rows[0]
        try expect(hub.rows.allSatisfy(hub.canReply),"Every listed chat accepts follow-ups")
        hub.select(waiting.id)
        await settle(hub) {!hub.eventsLoading}
        try expect(hub.events.map(\.text) == ["Hello","Done"],"A chat's messages are shown oldest first")
        await hub.answer(waiting.session.actions[0],option:"approve",in:waiting)
        let approved=await fixture.bodies().last
        try expect((approved?["actions"] as? [[String:String]])?.first == ["action_id":"act","option_id":"approve"] && approved?["session_id"] as? String == "s2","Approving answers the agent's question in that chat")
        await settle(hub) {hub.selectedRow?.session.status == "completed"}
        try expect(hub.selectedRow?.session.status == "completed" && hub.selectedRow.map(hub.canReply) == true,"The chat's status is followed until the agent finishes, and it stays the user's own")
        let sentOK=await hub.send("  Add a summary  ",to:hub.rows.first{$0.session.id == "s1"}!)
        let followUp=await fixture.bodies().last
        try expect(sentOK && followUp?["message"] as? String == "Add a summary" && followUp?["session_id"] as? String == "s1","A follow-up instruction is sent to the chosen chat")
        let blank=await hub.send("   ",to:waiting)
        try expect(!blank,"An empty instruction is not sent")
        let started=await hub.start("Plan the week",in:hub.accounts[1])
        let created=await fixture.bodies().last
        try expect(started && created?["agent_id"] as? String == "notion_ai" && created?["session_id"] == nil && hub.selectedRow?.account.workspaceName == "Beta","A new chat starts with that account's Notion AI and is selected")
        hub.accountFilter=hub.accounts[0].id
        hub.removeAccount(hub.accounts[0].id)
        try expect(hub.accounts.map(\.workspaceName) == ["Beta"] && !hub.rows.contains{$0.account.workspaceName == "Alpha"} && vault.values.filter{!$0.isEmpty}.count == 1,"Removing an account drops its chats and erases its token")
        try expect(hub.accountFilter == nil,"Removing the account being shown goes back to every account")
        hub.stopPolling()

        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("agent-chat-checks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let saved=folder.appendingPathComponent("agent-chats.json")
        try Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","workspaceID":"w-a","workspaceName":"Alpha","userID":"u-a","userName":"Alice","email":"alice@example.test"}]"#.utf8).write(to:saved)
        let earlier=AgentChatHub(client:fixture,file:saved,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        try expect(earlier.accounts.count == 1 && earlier.accounts[0].title == "Alpha" && !earlier.accounts[0].customized,"Accounts saved before custom names and icons still load")
        var mine=earlier.accounts[0];mine.nickname="Lab";mine.iconFile="lab.png"
        earlier.customize(mine)
        let reopened=AgentChatHub(client:fixture,file:saved,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        try expect(reopened.accounts.first?.title == "Lab" && reopened.accounts.first?.iconFile == "lab.png" && reopened.accounts.first?.workspaceName == "Alpha","An account's own name and icon are kept on disk next to Notion's")
        try timeline(expect)
        try await savedCopy(expect)
        try await knownChats(expect)
        try await groups(expect)
    }
    /// The user's own chat names and pins, and one prompt sent to several accounts as a group.
    private static func groups(_ expect:(Bool,String)throws->Void) async throws {
        func settle(_ done:@escaping()->Bool) async {
            for _ in 0..<500 {if done() {return};try? await Task.sleep(for:.milliseconds(10))}
        }
        let fixture=AgentChatFixture()
        var vault:[String:String]=[:]
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("agent-chat-groups-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("agent-chats.json")
        let hub=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        hub.startPolling()
        try await hub.addAccount(token:"pat-a")
        try await hub.addAccount(token:"pat-b")
        await settle {!hub.loading && hub.rows.count == 3}
        let s1=hub.rows.first{$0.session.id == "s1"}!
        hub.rename(s1,to:"  Weekly plan  ")
        try expect(hub.title(s1) == "Weekly plan" && s1.session.title == "Chat s1" && hub.isRenamed(s1),"A chat can be given a name of the user's own, and Notion's title is kept")
        hub.rename(s1,to:"Chat s1")
        try expect(!hub.isRenamed(s1),"Naming a chat what Notion calls it clears the user's name")
        hub.rename(s1,to:"Weekly plan")
        hub.setPinned(s1,true)
        let reopened=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        try expect(reopened.titles[s1.id] == "Weekly plan" && reopened.pinned[s1.id] != nil,"Names and pins are kept on this Mac across launches")
        hub.rename(s1,to:"   ")
        hub.setPinned(s1,false)
        try expect(hub.title(s1) == "Chat s1" && !hub.isPinned(s1),"A blank name goes back to Notion's title, and a pin can be taken off")

        let both=hub.accounts
        let started=await hub.broadcast("  Compare the plans\nand list risks  ",to:both,name:"")
        let asked=await fixture.bodies().suffix(2)
        let group=hub.group(hub.selectedGroup)
        try expect(started && hub.groups.count == 1 && group?.name == "Compare the plans" && group?.members.count == 2 && hub.selection == nil,"One prompt starts a chat in every chosen account, and the chats open together as a group named after the prompt")
        try expect(asked.allSatisfy{$0["agent_id"] as? String == "notion_ai" && $0["message"] as? String == "Compare the plans\nand list risks"},"Every account receives the same prompt with its own Notion AI")
        let members=group.map(hub.rows) ?? []
        try expect(members.map(\.account.id) == both.map(\.id),"The group lists its chats in the order of the accounts")
        await settle {members.allSatisfy{hub.thread($0.id).events.count == 2} && hub.ready(hub.group(hub.selectedGroup).map(hub.rows) ?? []).count == 2}
        try expect(members.allSatisfy{hub.thread($0.id).events.map(\.text) == ["Hello","Done"]},"Every chat of the group is read at the same time")
        let current=hub.group(hub.selectedGroup).map(hub.rows) ?? []
        let followed=await hub.send("Shorter, please",toGroup:current)
        let replies=await fixture.bodies().suffix(2)
        try expect(followed && replies.allSatisfy{$0["session_id"] as? String == "s9" && $0["message"] as? String == "Shorter, please"},"A follow-up from the group goes to each of its chats")
        if let id=group?.id {
            hub.remove(current[1],from:id)
            try expect(hub.group(id)?.members == [current[0].id] && hub.groups(of:current[1]).isEmpty,"A chat can be taken out of a group")
            hub.add(current[1],to:id)
            hub.renameGroup(id,to:"Plan review")
            hub.showsTabs(id,true)
            let saved=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
            try expect(saved.groups.first?.name == "Plan review" && saved.groups.first?.tabs == true && saved.groups.first?.members.count == 2,"Groups, their names and how they are shown are kept on this Mac")
            hub.deleteGroup(id)
            try expect(hub.groups.isEmpty && hub.selectedGroup == nil && hub.rows.count == 5,"Ungrouping leaves the chats in the list")
        }

        let beta=both[1]
        vault[beta.vaultID]="pat-expired"
        let partial=await hub.broadcast("Status update",to:both,name:"Status")
        try expect(partial && hub.group(hub.selectedGroup)?.members.count == 1 && (hub.sendFailure ?? "").contains(beta.title),"When an account cannot start the chat, the others still form the group and the failed account is named")
        vault[beta.vaultID]="pat-b"
        hub.stopPolling()

        let alpha=both[0].id.uuidString
        let notes=folder.appendingPathComponent("agent-chat-notes.json")
        try Data(#"{"titles":{},"pinned":{"\#(alpha)/s7":0},"groups":[]}"#.utf8).write(to:notes)
        let later=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        later.startPolling()
        await settle {!later.loading && later.rows.contains{$0.session.id == "s7"}}
        try expect(later.rows.first{$0.session.id == "s7"}.map(later.isPinned) == true,"A pinned chat Notion's list leaves out is still read and listed")
        later.removeAccount(both[0].id)
        try expect(later.pinned.isEmpty && later.groups.allSatisfy{!$0.members.contains{$0.hasPrefix(alpha)}},"Removing an account forgets its names, pins and group places")
        later.stopPolling()
    }
    /// Notion's list stopped returning recent chats; chats seen in tabs are read one by one instead.
    private static func knownChats(_ expect:(Bool,String)throws->Void) async throws {
        func settle(_ done:@escaping()->Bool) async {
            for _ in 0..<400 {if done() {return};try? await Task.sleep(for:.milliseconds(10))}
        }
        let id="422b35e6e67f8157800d00a9671a5e5c"
        try expect(AgentChat.chatID(in:URL(string:"https://app.notion.com/chat?t="+id)!) == id
                   && AgentChat.chatID(in:URL(string:"https://www.notion.so/Plan-abc?pvs=1&t=422b35e6-e67f-8157-800d-00a9671a5e5c")!) == id
                   && AgentChat.chatID(in:URL(string:"https://app.dev.notion.com/chat?t="+id)!) == id
                   && AgentChat.chatID(in:URL(string:"https://www.figma.com/design/x?t="+id)!) == nil
                   && AgentChat.chatID(in:URL(string:"https://app.notion.com/p/Getting-Started?t=new")!) == nil,"A chat's ID is read from Notion addresses only")
        let fixture=AgentChatFixture()
        var vault:[String:String]=[:]
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("agent-chat-known-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("agent-chats.json")
        let hub=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        hub.startPolling()
        try await hub.addAccount(token:"pat-a")
        await settle {!hub.loading && hub.rows.count == 2}
        hub.discover([(space:"w-a",id:"s7"),(space:"w-a",id:"gone"),(space:"w-elsewhere",id:"s8")])
        await settle {!hub.loading && hub.rows.count == 3 && hub.known.values.joined().count == 1}
        try expect(hub.rows.map(\.session.id) == ["s2","s7","s1"],"A chat opened in a tab is listed by its own date though Notion's list leaves it out")
        try expect(hub.known.values.flatMap{$0} == ["s7"],"A chat Notion no longer has is forgotten, and chats of unregistered workspaces are ignored")
        hub.stopPolling();hub.saveCacheNow()
        let later=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        later.startPolling()
        await settle {!later.loading && later.refreshedAt.map{$0.timeIntervalSinceNow > -5} == true}
        try expect(later.rows.map(\.session.id) == ["s2","s7","s1"],"Chats found in tabs stay listed after the next launch's first reload")
        later.stopPolling()
    }
    /// Chats fetched once show at once next time, and Notion is asked again in the background.
    private static func savedCopy(_ expect:(Bool,String)throws->Void) async throws {
        func settle(_ done:@escaping()->Bool) async {
            for _ in 0..<400 {if done() {return};try? await Task.sleep(for:.milliseconds(10))}
        }
        let fixture=AgentChatFixture()
        var vault:[String:String]=[:]
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("agent-chat-saved-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("agent-chats.json"),copy=folder.appendingPathComponent("agent-chat-cache.json")
        let hub=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        hub.startPolling()
        try await hub.addAccount(token:"pat-a")
        await settle {!hub.loading && hub.rows.count == 2}
        hub.select(hub.rows[0].id)
        await settle {!hub.eventsLoading && hub.events.count == 2}
        let asked=await fixture.queries()
        hub.stopPolling();hub.startPolling()
        for _ in 0..<400 {if await fixture.queries()>asked {break};try? await Task.sleep(for:.milliseconds(10))}
        try expect(await fixture.queries()>asked,"Opening the page again reloads the chat that was open")
        await settle {!hub.loading}
        hub.stopPolling();hub.saveCacheNow()
        let mode=(try? FileManager.default.attributesOfItem(atPath:copy.path)[.posixPermissions] as? Int) ?? 0
        try expect(FileManager.default.fileExists(atPath:copy.path) && mode == 0o600,"Fetched chats are saved next to the accounts, readable only by this user")

        let offline=AgentChatHub(client:fixture,file:file,credentials:{_ in nil},storeSecret:{_,_ in})
        try expect(offline.rows.isEmpty,"The saved chats are not read at app launch")
        offline.startPolling()
        try expect(offline.rows.map(\.session.id) == ["s2","s1"] && offline.refreshedAt != nil,"Chats fetched before show as soon as the page opens")
        offline.select(offline.rows[0].id)
        try expect(!offline.eventsLoading && offline.events.map(\.text) == ["Hello","Done"],"A chat opened before shows its saved messages without waiting for Notion")
        await settle {!offline.loading && offline.eventsFailure != nil}
        try expect(offline.rows.count == 2 && offline.failures.count == 1 && offline.events.count == 2,"When Notion cannot be reached, the saved chats and messages stay with the error shown")
        offline.stopPolling()

        var json=try JSONSerialization.jsonObject(with:Data(contentsOf:copy)) as? [String:Any] ?? [:]
        var lists=json["sessions"] as? [String:[[String:Any]]] ?? [:]
        let key=hub.accounts[0].id.uuidString
        if var gone=lists[key]?.first(where:{$0["id"] as? String == "s1"}) {gone["id"]="gone";lists[key]?.append(gone)}
        json["sessions"]=lists
        try JSONSerialization.data(withJSONObject:json).write(to:copy)
        let later=AgentChatHub(client:fixture,file:file,credentials:{vault[$0]},storeSecret:{vault[$0]=$1})
        later.startPolling()
        let shown=later.rows.contains{$0.session.id == "gone"}
        await settle {!later.loading && later.refreshedAt.map{$0.timeIntervalSinceNow > -5} == true && !later.rows.contains{$0.session.id == "gone"}}
        try expect(shown,"A saved chat is listed before the first reload")
        try expect(later.rows.map(\.session.id) == ["s2","s1"],"A saved chat Notion no longer lists drops out on the first reload")
        later.stopPolling()
    }
    /// Shapes taken from real Notion AI chats: blank replies between tool calls, paired tool results, and Notion's reply markup.
    private static func timeline(_ expect:(Bool,String)throws->Void)throws {
        func event(_ sequence:Int,_ type:String,_ extra:JSONObject=[:])->AgentChat.Event {
            var json:JSONObject=["object":"session_event","id":"e\(sequence)","session_id":"s","sequence":sequence,"type":type,"created_at":"2026-11-20T10:00:00.000Z"]
            for (key,value) in extra {json[key]=value}
            return AgentChat.event(json)!
        }
        func text(_ value:String)->JSONObject {["content":[["type":"text","text":value]]]}
        let events=[
            event(1,"user.message",text("Find it")),event(2,"agent.message",text("")),
            event(3,"agent.tool_use",["tool_name":"connections.notion.loadPage"]),event(4,"agent.tool_result",["tool_name":"connections.notion.loadPage","tool_use_id":"e3","is_error":false]),
            event(5,"agent.message",text("  ")),event(6,"agent.tool_use",["tool_name":"connections.slack.search"]),
            event(7,"agent.tool_result",["tool_name":"connections.slack.search","tool_use_id":"e6","is_error":true]),
            event(8,"agent.message",text("Done")),event(9,"agent.tool_use",["tool_name":"connections.images.generate"]),
            event(10,"session.status",["status":"completed"]),
        ]
        let items=AgentChat.timeline(events)
        try expect(items.map(\.id) == ["e1","steps-e3","e8","steps-e9"],"Blank replies are hidden and the tool calls between two messages fold into one item")
        if case .steps(_,let steps)=items[1] {
            try expect(steps.map(\.toolName) == ["connections.notion.loadPage","connections.slack.search"] && steps.map(\.failed) == [false,true] && steps.allSatisfy(\.finished),"Each tool call carries whether its result came back and failed")
        } else {try expect(false,"Each tool call carries whether its result came back and failed")}
        if case .steps(_,let steps)=items[3] {try expect(steps.first?.finished == false,"A tool call still running shows as unfinished")}
        try expect(AgentChat.merge([event(1,"user.message",text("a")),event(2,"agent.message",text("b"))],[event(2,"agent.message",text("b2")),event(3,"agent.message",text("c"))]).map(\.text) == ["a","b2","c"],"A poll replaces the newest events and keeps older ones already loaded")
        let tools=["connections.notion.loadPage","connections.search.unifiedSearch","notion_search","connections.images.generate","connections.computer.terminal","create-pages","connections.notion.viewFileUrl","request-worker-secrets"].map(AgentChat.tool)
        try expect(tools.map(\.source) == ["notion","search","notion","images","computer","","notion",""] && tools.map(\.action) == [.read,.search,.search,.generate,.run,.create,.read,.other],"Tool names are read as where they work and what they do")

        let reply="""
        ### Status
        Planned for <mention-page url="https://www.notion.so/abc">Launch Plan</mention-page> and <b>Tokyo</b>.[^https://app.notion.com/p/1] Again[^https://app.notion.com/p/1] and[^slack://?channel_id=C1]
        - first
          - nested
        1. one
        - [x] checked

        <edit_reference variableNames="createdPage">
        Created the page
        </edit_reference>
        > quoted
        | A | B |
        |---|---|
        | 1 | <mention url="https://www.notion.so/u">Sam</mention> |
        ```
        <b>kept</b> [^x]
        ```
        <worker_reference workerId="w" icon="🎙️" capabilityKeys="x"></worker_reference>
        ---
        """
        let blocks=AgentChat.blocks(reply)
        let expected:[AgentChat.Block]=[
            .heading(level:3,text:"Status"),
            .paragraph("Planned for [Launch Plan](<https://www.notion.so/abc>) and **Tokyo**.[\\[1\\]](<https://app.notion.com/p/1>) Again[\\[1\\]](<https://app.notion.com/p/1>) and[\\[2\\]](<slack://?channel_id=C1>)"),
            .item(level:0,marker:"•",text:"first"),.item(level:1,marker:"◦",text:"nested"),.item(level:0,marker:"1.",text:"one"),.item(level:0,marker:"☑",text:"checked"),
            .note(kind:"edit",text:"Created the page"),.quote("quoted"),.table([["A","B"],["1","[Sam](<https://www.notion.so/u>)"]]),
            .code("<b>kept</b> [^x]"),.note(kind:"worker",text:"🎙️"),.rule,
        ]
        try expect(blocks == expected,"Notion's reply markup becomes headings, lists, cards, tables and numbered citation links; code stays as written")
        let rendered=try AttributedString(markdown:"See [\\[1\\]](<https://app.notion.com/p/a(b)>)",options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))
        try expect(String(rendered.characters) == "See [1]" && rendered.runs.contains{$0.link?.absoluteString == "https://app.notion.com/p/a(b)"},"A citation renders as a [1] link even when its address has parentheses")
        if case .paragraph(let line)=AgentChat.blocks("これは**「重要」**です。**Gayaさん（Yuta）**だ").first {
            let bold=try AttributedString(markdown:line,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))
            let strong=bold.runs.filter{$0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true}.map{String(bold[$0.range].characters).replacingOccurrences(of:"\u{200B}",with:"")}
            try expect(!String(bold.characters).contains("*") && strong == ["「重要」","Gayaさん（Yuta）"],"Bold text wrapped in Japanese brackets renders bold instead of showing the asterisks")
        } else {try expect(false,"Bold text wrapped in Japanese brackets renders bold instead of showing the asterisks")}
    }
}
