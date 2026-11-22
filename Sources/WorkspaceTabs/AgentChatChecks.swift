import Foundation
import WorkspaceCore

/// Stands in for Notion's Agent API: one workspace per token.
private actor AgentChatFixture:NotionRequesting {
    var sent:[JSONObject]=[]
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
        case ("POST","/sessions/s2/events/query"),("POST","/sessions/s1/events/query"):
            return ["results":[["id":"e2","type":"agent.message","sequence":2,"content":[["type":"text","text":"Done"]]],["id":"e1","type":"user.message","sequence":1,"content":[["type":"text","text":"Hello"]]]],"has_more":false]
        case ("GET","/sessions/s2"):return session("s2",agent:"notion_ai",user:true,minute:30)
        case ("GET","/sessions/s1"):return session("s1",agent:"notion_ai",user:true,minute:31)
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
        hub.removeAccount(hub.accounts[0].id)
        try expect(hub.accounts.map(\.workspaceName) == ["Beta"] && !hub.rows.contains{$0.account.workspaceName == "Alpha"} && vault.values.filter{!$0.isEmpty}.count == 1,"Removing an account drops its chats and erases its token")
        hub.stopPolling()
    }
}
