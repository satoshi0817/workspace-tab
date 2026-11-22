import Foundation

/// Display models for Notion agent sessions (chats), read from the public Agent API.
/// Nothing here is persisted: sessions and events are fetched again on every launch.
public enum AgentChat {
    public struct Option:Equatable,Identifiable {
        public let id:String
        public let label:String
    }
    public struct Action:Equatable,Identifiable {
        public let id:String
        public let title:String
        public let options:[Option]
    }
    public struct Session:Equatable {
        public let id:String
        public let agentID:String
        public let title:String
        public let status:String
        public let createdByID:String?
        public let createdByUser:Bool
        public let createdAt:Date
        public let updatedAt:Date
        public let actions:[Action]
        public let error:String?
        public let trigger:String?
        public init(id:String,agentID:String,title:String,status:String,createdByID:String?,createdByUser:Bool,createdAt:Date,updatedAt:Date,actions:[Action],error:String?,trigger:String?) {
            self.id=id;self.agentID=agentID;self.title=title;self.status=status;self.createdByID=createdByID;self.createdByUser=createdByUser
            self.createdAt=createdAt;self.updatedAt=updatedAt;self.actions=actions;self.error=error;self.trigger=trigger
        }
        /// Still running, so its messages are worth polling.
        public var active:Bool {status == "queued" || status == "in_progress"}
        public var needsAction:Bool {status == "requires_action"}
    }
    public struct File:Equatable {
        public let name:String
        public let url:String
    }
    public struct Event:Equatable,Identifiable {
        public let id:String
        public let sequence:Int
        public let type:String
        public let text:String
        public let files:[File]
        public let toolName:String?
        public let status:String?
        public let createdAt:Date?
    }
    /// Who and where a personal access token acts as.
    public struct Identity:Equatable {
        public let workspaceID:String
        public let workspaceName:String
        public let userID:String
        public let userName:String
        public let email:String
        public let avatarURL:String?
    }
    public struct Agent:Equatable,Identifiable {
        public let id:String
        public let name:String
        public let emoji:String?
        public let personal:Bool
    }

    public static func date(_ value:Any?)->Date? {
        guard let text=value as? String else{return nil}
        let fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        if let date=fractional.date(from:text) {return date}
        return ISO8601DateFormatter().date(from:text)
    }
    /// IDs compare without dashes or case: the API mixes both spellings.
    public static func compact(_ id:String?)->String? {
        guard let id else{return nil}
        let value=id.replacingOccurrences(of:"-",with:"").lowercased()
        return value.isEmpty ? nil:value
    }
    private static func actions(_ value:Any?)->[Action] {
        (value as? [[String:Any]] ?? []).compactMap {raw in
            guard let id=raw["action_id"] as? String,!id.isEmpty else{return nil}
            let options=(raw["options"] as? [[String:Any]] ?? []).compactMap {option->Option? in
                guard let id=option["id"] as? String,id == "approve" || id == "reject" else{return nil}
                return Option(id:id,label:option["label"] as? String ?? id)
            }
            return Action(id:id,title:raw["title"] as? String ?? "",options:options)
        }
    }
    public static func session(_ json:[String:Any])->Session? {
        guard json["object"] as? String == "session",let id=json["id"] as? String,!id.isEmpty,
              let agent=json["agent_id"] as? String,let status=json["status"] as? String,
              let stamp=date(json["updated_at"]) ?? date(json["created_at"]) else{return nil}
        let creator=json["created_by"] as? [String:Any]
        let title=(json["title"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return Session(id:id,agentID:agent,title:title.isEmpty ? "Untitled":title,status:status,
            createdByID:creator?["id"] as? String,createdByUser:creator?["type"] as? String == "user",
            createdAt:date(json["created_at"]) ?? stamp,updatedAt:stamp,actions:actions(json["required_actions"]),
            error:(json["error"] as? [String:Any])?["message"] as? String,trigger:json["trigger_type"] as? String)
    }
    public static func event(_ json:[String:Any])->Event? {
        guard let id=json["id"] as? String,let type=json["type"] as? String,let sequence=json["sequence"] as? Int else{return nil}
        var text:[String]=[],files:[File]=[]
        for part in json["content"] as? [[String:Any]] ?? [] {
            if part["type"] as? String == "text",let value=part["text"] as? String {text.append(value)}
            else if part["type"] as? String == "file",let url=part["url"] as? String {files.append(File(name:part["name"] as? String ?? "file",url:url))}
        }
        return Event(id:id,sequence:sequence,type:type,text:text.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines),files:files,
            toolName:json["tool_name"] as? String,status:json["status"] as? String,createdAt:date(json["created_at"]))
    }
    /// From GET /v1/users/me. A token that is not a person's (an integration) has no owner user and is refused.
    public static func identity(_ json:[String:Any])->Identity? {
        guard let bot=json["bot"] as? [String:Any],let workspace=bot["workspace_id"] as? String,!workspace.isEmpty,
              let owner=bot["owner"] as? [String:Any],owner["type"] as? String == "user",
              let user=owner["user"] as? [String:Any],let userID=user["id"] as? String,!userID.isEmpty else{return nil}
        let email=(user["person"] as? [String:Any])?["email"] as? String ?? ""
        return Identity(workspaceID:workspace,workspaceName:bot["workspace_name"] as? String ?? "",userID:userID,
            userName:user["name"] as? String ?? "",email:email,avatarURL:user["avatar_url"] as? String)
    }
    public static func agent(_ json:[String:Any])->Agent? {
        guard let id=json["id"] as? String,!id.isEmpty else{return nil}
        let icon=json["icon"] as? [String:Any]
        let name=(json["name"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return Agent(id:id,name:name,emoji:icon?["type"] as? String == "emoji" ? icon?["emoji"] as? String:nil,
            personal:json["agent_type"] as? String == "notion_ai" || id == "notion_ai")
    }
    /// The address of a chat in the Notion web app. The API does not return one.
    public static func chatURL(host:String?,sessionID:String)->String? {
        guard let id=compact(sessionID),id.count == 32,id.allSatisfy({$0.isHexDigit}) else{return nil}
        let allowed=["app.notion.com","www.notion.so","notion.so","app.dev.notion.com"]
        let host=host.map{$0.lowercased()}.flatMap{allowed.contains($0) ? $0:nil} ?? "www.notion.so"
        return "https://\(host)/chat?t=\(id)"
    }
    /// Sessions waiting on the user come first, then running ones, then the rest.
    public static func rank(_ status:String)->Int {
        switch status {case "requires_action":return 0;case "in_progress","queued":return 1;default:return 2}
    }
}
