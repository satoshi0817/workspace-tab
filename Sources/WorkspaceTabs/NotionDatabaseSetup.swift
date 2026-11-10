import WorkspaceCore
import Foundation

struct CreationRequest: Identifiable {
    var id = UUID()
    var creationId: String?
}

struct ConnectionIdentity: Codable, Equatable, Sendable {
    var workspaceId: String
    var workspaceName: String
    var ownerId: String
    var ownerName: String
    var botId: String
}
enum SetupStep: String, Codable, Sendable {
    case root, categories, links, categoryPage, settingsLink, tabs
    var title: String {
        switch self {
        case .tabs: return L("タブ保存DB")
        case .root: return L("プライベートの親ページ")
        case .categories: return L("カテゴリDB")
        case .links: return L("リンクDBとカテゴリリレーション")
        case .categoryPage: return L("設定用カテゴリ")
        case .settingsLink: return L("設定ページへのリンク")
        }
    }
}
struct DatabaseCreation: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var tokenId: String
    var identity: ConnectionIdentity
    var title: String
    var startedAt = Date()
    var rootCandidatesBefore: [String]?
    var pendingStep: SetupStep?
    var rootPageId: String?
    var rootURL: String?
    var categoriesDatabaseId: String?
    var categoriesSourceId: String?
    var categoriesURL: String?
    var linksDatabaseId: String?
    var linksSourceId: String?
    var linksURL: String?
    var categoryPageId: String?
    var settingsLinkId: String?
    var tabsDatabaseId:String?
    var tabsSourceId:String?
    var tabsURL:String?
    var completed = false
    var registered = false
    var status: String {
        if registered { return L("作成完了") }
        if completed { return L("DBの作成完了・アプリへの登録を確認中") }
        if let pendingStep { return L("\(pendingStep.title)の作成結果を確認中") }
        if rootPageId == nil { return L("親ページを作成します") }
        if categoriesSourceId == nil { return L("カテゴリDBを作成します") }
        if linksSourceId == nil { return L("リンクDBを作成します") }
        if categoryPageId == nil { return L("設定用カテゴリを作成します") }
        if settingsLinkId == nil { return L("設定用リンクを作成します") }
        if tabsSourceId == nil {return L("タブ保存DBを作成します")}
        return L("DBとリレーションを確認します")
    }
    var source: LVSource? {
        guard let id = linksSourceId, let url = linksURL else { return nil }
        return LVSource(id: id, title: title, emoji: "🔗", databaseUrl: url, tokenId: tokenId)
    }
}

struct CreationJournal {
    var url = Storage.root.appendingPathComponent("database-creations.json")
    func load() throws -> [DatabaseCreation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([DatabaseCreation].self, from: Data(contentsOf: url))
    }
    func save(_ creation: DatabaseCreation) throws {
        var all = try load()
        all.removeAll { $0.id == creation.id }; all.append(creation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

actor DatabaseSetup {
    static let introduction = "Workspace Tabsで管理するリンクとカテゴリの設定ページです。"
    let api: any NotionRequesting
    let journal: CreationJournal
    private var running = Set<String>()
    init(api: any NotionRequesting, journal: CreationJournal = CreationJournal()) { self.api = api; self.journal = journal }

    func inspect(token: String) async throws -> ConnectionIdentity {
        let me = try await call(token, "GET", "/users/me")
        let bot = object(me, "bot"), owner = object(object(me, "bot"), "owner")
        guard owner["type"] as? String == "user", let ownerId = object(owner, "user")["id"] as? String else {
            throw LVError(L("プライベートへの自動作成にはPATが必要です。内部インテグレーションのトークンでは作成できません。"))
        }
        guard let workspaceId = bot["workspace_id"] as? String, !workspaceId.isEmpty, let botId = me["id"] as? String else {
            throw LVError(L("PATのワークスペースを確認できませんでした。Notion APIが有効なPATを使用してください。"))
        }
        var ownerName = object(owner, "user")["name"] as? String
        if ownerName == nil, let person = try? await call(token, "GET", "/users/\(ownerId)") { ownerName = person["name"] as? String }
        let name = bot["workspace_name"] as? String
        return ConnectionIdentity(workspaceId: workspaceId, workspaceName: name.flatMap { $0.isEmpty ? nil : $0 } ?? L("ワークスペース（\(workspaceId.prefix(8))）"), ownerId: ownerId, ownerName: ownerName ?? L("PATの所有者"), botId: botId)
    }

    func create(_ initial: DatabaseCreation, token: String, onProgress: @Sendable (DatabaseCreation) -> Void = { _ in }) async throws -> DatabaseCreation {
        guard running.insert(initial.id).inserted else { throw LVError(L("このデータベースは作成中です")) }
        defer { running.remove(initial.id) }
        var progress = try journal.load().first { $0.id == initial.id } ?? initial
        let identity = try await inspect(token: token)
        guard identity.workspaceId == progress.identity.workspaceId, identity.ownerId == progress.identity.ownerId else {
            throw LVError(L("PATのワークスペースまたは所有者が、確認した作成先と一致しません。作成を中止しました。"))
        }
        guard !progress.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, progress.title.count <= 100 else { throw LVError(L("ページ名は1〜100文字で入力してください")) }
        func checkpoint() throws { try journal.save(progress); onProgress(progress) }
        try checkpoint()

        // An interrupted POST may already have succeeded. Reconcile its result before any new write.
        if let pending = progress.pendingStep {
            let result = try await recover(pending, creation: progress, token: token)
            try Self.record(result, step: pending, into: &progress)
            progress.pendingStep = nil; try checkpoint()
        }
        if progress.rootPageId == nil, progress.rootCandidatesBefore == nil {
            progress.rootCandidatesBefore = try await searchRoots(title: progress.title, token: token).compactMap { $0["id"] as? String }
            try checkpoint()
        }
        for step in [SetupStep.root, .categories, .links, .categoryPage, .settingsLink, .tabs] {
            if Self.hasResult(step, in: progress) { continue }
            // Validate acknowledged dependencies before adding anything beneath them.
            if let root = progress.rootPageId { try Self.verifyPrivateRoot(try await call(token, "GET", "/pages/\(root)"), creation: progress) }
            if step == .links || step == .categoryPage, let ds = progress.categoriesSourceId {
                try Self.verifyCategories(try await call(token, "GET", "/data_sources/\(ds)"))
            }
            if step == .settingsLink { try Self.verifyLinks(try await call(token, "GET", "/data_sources/\(progress.linksSourceId!)"), creation: progress) }
            progress.pendingStep = step; try checkpoint()
            do {
                let (endpoint, body) = Self.creationRequest(step, progress: progress)
                let result = try await call(token, "POST", endpoint, body)
                try Self.record(result, step: step, into: &progress)
                progress.pendingStep = nil; try checkpoint()
            } catch {
                // Validation/authorization errors are known rejections. Timeouts and 5xx are ambiguous.
                if let failure = error as? NotionAPIError, [400, 401, 403, 404, 409, 422, 429].contains(failure.status) {
                    progress.pendingStep = nil; try checkpoint()
                }
                throw LVError(L("\(step.title)の作成を完了できませんでした。作成済みの内容は保存されています。\n\(error.localizedDescription.replacingOccurrences(of: token, with: "[redacted]"))"))
            }
        }
        try await verify(progress, token: token)
        progress.completed = true; try checkpoint()
        return progress
    }

    private func call(_ token: String, _ method: String, _ endpoint: String, _ body: JSONObject? = nil) async throws -> JSONObject {
        try await api.request(token: token, method: method, endpoint: endpoint, body: body)
    }
    private static func hasResult(_ step: SetupStep, in p: DatabaseCreation) -> Bool {
        switch step {
        case .tabs: return p.tabsSourceId != nil
        case .root: return p.rootPageId != nil
        case .categories: return p.categoriesSourceId != nil
        case .links: return p.linksSourceId != nil
        case .categoryPage: return p.categoryPageId != nil
        case .settingsLink: return p.settingsLinkId != nil
        }
    }
    static func creationRequest(_ step: SetupStep, progress p: DatabaseCreation) -> (String, JSONObject) {
        let text: (String) -> [JSONObject] = { [["type": "text", "text": ["content": $0]]] }
        switch step {
        case .root:
            let paragraphs = [introduction,
                "Linksにリンクを追加し、Categoriesでカテゴリを管理します。Categoryは1件選択してください。",
                "CategoriesのOrderがカテゴリ順、LinksのOrderがカテゴリ内のリンク順です。Pinnedをオンにすると先頭に表示します。",
                "Connectionにはアプリに登録した接続名を指定できます。PAT本体はこのページやDBには保存しません。"]
            return ("/pages", ["parent": ["type": "workspace", "workspace": true], "icon": ["type": "emoji", "emoji": "🔗"],
                "properties": ["title": ["type": "title", "title": text(p.title)]],
                "children": paragraphs.map { ["object": "block", "type": "paragraph", "paragraph": ["rich_text": text($0)]] as JSONObject }])
        case .tabs:
            return ("/databases", ["parent":["type":"page_id","page_id":p.rootPageId!],"title":text("Tabs"),"is_inline":true,"initial_data_source":["properties":["Name":["title":[:]],"Device":["rich_text":[:]],"Snapshot":["rich_text":[:]],"Updated":["date":[:]]]]])
        case .categories:
            return ("/databases", ["parent": ["type": "page_id", "page_id": p.rootPageId!], "title": text("Categories"), "is_inline": true,
                "icon": ["type": "emoji", "emoji": "🗂️"], "initial_data_source": ["properties": ["Name": ["title": [:]], "Order": ["number": ["format": "number"]]]]])
        case .links:
            let apps = ["Default", "Notion", "Notion Dev", "Chrome", "Arc"]
            let properties: JSONObject = [
                "Name": ["title": [:]], "URL": ["url": [:]],
                "Category": ["relation": ["data_source_id": p.categoriesSourceId!, "type": "single_property", "single_property": [:]]],
                "Tags": ["multi_select": ["options": []]], "App": ["select": ["options": apps.map { ["name": $0] }]],
                "Description": ["rich_text": [:]], "Pinned": ["checkbox": [:]], "Order": ["number": ["format": "number"]],
                "Connection": ["rich_text": [:]]
            ]
            return ("/databases", ["parent": ["type": "page_id", "page_id": p.rootPageId!], "title": text("Links"), "is_inline": true,
                "icon": ["type": "emoji", "emoji": "🔗"], "initial_data_source": ["properties": properties]])
        case .categoryPage:
            return ("/pages", ["parent": ["type": "data_source_id", "data_source_id": p.categoriesSourceId!],
                "properties": ["Name": ["title": text("設定")], "Order": ["number": 10]]])
        case .settingsLink:
            let app = URL(string: p.rootURL!)?.host == "app.dev.notion.com" ? "Notion Dev" : "Notion"
            return ("/pages", ["parent": ["type": "data_source_id", "data_source_id": p.linksSourceId!], "icon": ["type": "emoji", "emoji": "⚙️"],
                "properties": ["Name": ["title": text("Workspace Tabs Settings")], "URL": ["url": p.rootURL!],
                    "Category": ["relation": [["id": p.categoryPageId!]]], "App": ["select": ["name": app]],
                    "Description": ["rich_text": text("リンクとカテゴリを管理するページです。")], "Pinned": ["checkbox": true], "Order": ["number": 0]]])
        }
    }
    private static func record(_ response: JSONObject, step: SetupStep, into p: inout DatabaseCreation) throws {
        guard let id = response["id"] as? String, UUID(uuidString: id) != nil else { throw LVError(L("作成結果のIDを確認できませんでした")) }
        let url = response["url"] as? String ?? "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))"
        switch step {
        case .root:
            try verifyPrivateRoot(response, creation: p); p.rootPageId = id; p.rootURL = url
        case .categories, .links, .tabs:
            let sources = response["data_sources"] as? [JSONObject] ?? []
            guard sources.count == 1, let ds = sources[0]["id"] as? String, UUID(uuidString: ds) != nil else { throw LVError(L("作成したDBのデータソースを確認できませんでした")) }
            guard object(response, "parent")["page_id"] as? String == p.rootPageId else { throw LVError(L("DBの作成先が一致しません")) }
            if step == .categories { p.categoriesDatabaseId = id; p.categoriesSourceId = ds; p.categoriesURL = url }
            else if step == .tabs {p.tabsDatabaseId=id;p.tabsSourceId=ds;p.tabsURL=url}
            else { p.linksDatabaseId = id; p.linksSourceId = ds; p.linksURL = url }
        case .categoryPage: p.categoryPageId = id
        case .settingsLink: p.settingsLinkId = id
        }
    }
    private static func verifyPrivateRoot(_ page: JSONObject, creation p: DatabaseCreation) throws {
        let parent = object(page, "parent")
        guard page["object"] as? String == "page", parent["type"] as? String == "workspace", parent["workspace"] as? Bool == true,
              !(page["public_url"] is String), page["in_trash"] as? Bool != true,
              p.rootPageId == nil || page["id"] as? String == p.rootPageId else { throw LVError(L("作成先のプライベートページを確認できませんでした")) }
    }
    private static func verifyCategories(_ dataSource: JSONObject) throws {
        let p = object(dataSource, "properties")
        guard object(p, "Name")["type"] as? String == "title", object(p, "Order")["type"] as? String == "number" else { throw LVError(L("カテゴリDBのName・Orderを確認できませんでした")) }
    }
    private static func verifyLinks(_ dataSource: JSONObject, creation p: DatabaseCreation) throws {
        let props = object(dataSource, "properties")
        for (name, type) in ["Name": "title", "URL": "url", "Category": "relation", "Tags": "multi_select", "App": "select", "Description": "rich_text", "Pinned": "checkbox", "Order": "number", "Connection": "rich_text"] {
            guard object(props, name)["type"] as? String == type else { throw LVError(L("リンクDBの\(name)を確認できませんでした")) }
        }
        let relation = object(object(props, "Category"), "relation")
        guard relation["data_source_id"] as? String == p.categoriesSourceId, relation["type"] as? String == "single_property" else { throw LVError(L("Categoryのリレーション先が作成したカテゴリDBと一致しません")) }
    }
    private func verify(_ p: DatabaseCreation, token: String) async throws {
        try Self.verifyPrivateRoot(try await call(token, "GET", "/pages/\(p.rootPageId!)"), creation: p)
        for (database, source) in [(p.categoriesDatabaseId!, p.categoriesSourceId!), (p.linksDatabaseId!, p.linksSourceId!), (p.tabsDatabaseId!,p.tabsSourceId!)] {
            let db = try await call(token, "GET", "/databases/\(database)")
            guard object(db, "parent")["page_id"] as? String == p.rootPageId,
                  (db["data_sources"] as? [JSONObject] ?? []).contains(where: { $0["id"] as? String == source }) else { throw LVError(L("DBの親ページまたはデータソースが一致しません")) }
        }
        let tabProperties=object(try await call(token,"GET","/data_sources/\(p.tabsSourceId!)"),"properties")
        for (name,type) in ["Name":"title","Device":"rich_text","Snapshot":"rich_text","Updated":"date"] {
            guard object(tabProperties,name)["type"] as? String == type else{throw LVError(L("タブDBの\(name)を確認できませんでした"))}
        }
        try Self.verifyCategories(try await call(token, "GET", "/data_sources/\(p.categoriesSourceId!)"))
        try Self.verifyLinks(try await call(token, "GET", "/data_sources/\(p.linksSourceId!)"), creation: p)
        let category = try await call(token, "GET", "/pages/\(p.categoryPageId!)")
        guard object(category, "parent")["data_source_id"] as? String == p.categoriesSourceId,
              titleOf(object(category, "properties")) == "設定", object(object(category, "properties"), "Order")["number"] as? Int == 10 else { throw LVError(L("設定用カテゴリを確認できませんでした")) }
        let settings = try await call(token, "GET", "/pages/\(p.settingsLinkId!)")
        let values = object(settings, "properties"), relations = object(values, "Category")["relation"] as? [JSONObject] ?? []
        guard object(settings, "parent")["data_source_id"] as? String == p.linksSourceId,
              object(values, "URL")["url"] as? String == p.rootURL, object(values, "Pinned")["checkbox"] as? Bool == true,
              relations.count == 1, relations[0]["id"] as? String == p.categoryPageId else { throw LVError(L("設定用リンクとカテゴリの紐付けを確認できませんでした")) }
    }
    private func list(_ token: String, endpoint: String, method: String = "GET", body: JSONObject = [:]) async throws -> [JSONObject] {
        var result: [JSONObject] = [];var pagination=NotionPagination()
        repeat {
            try Task.checkCancellation()
            let cursor=pagination.cursor
            var requestBody = body; var path = endpoint
            if method == "GET" {
                path += "?page_size=100"
                if let cursor { path += "&start_cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)" }
            } else { requestBody["page_size"] = 100; if let cursor { requestBody["start_cursor"] = cursor } }
            let response = try await call(token, method, path, method == "GET" ? nil : requestBody)
            result += try pagination.consume(response)
        } while pagination.cursor != nil
        return result.filter { $0["in_trash"] as? Bool != true && $0["archived"] as? Bool != true }
    }
    private func searchRoots(title: String, token: String) async throws -> [JSONObject] {
        try await list(token, endpoint: "/search", method: "POST", body: ["query": title, "filter": ["property": "object", "value": "page"]]).filter {
            titleOf(object($0, "properties")) == title && object($0, "parent")["workspace"] as? Bool == true
        }
    }
    private func recover(_ step: SetupStep, creation p: DatabaseCreation, token: String) async throws -> JSONObject {
        var candidates: [JSONObject] = []
        switch step {
        case .root:
            var baseline = Set(p.rootCandidatesBefore ?? [])
            baseline.formUnion(try journal.load().filter { $0.id != p.id }.compactMap(\.rootPageId))
            for page in try await searchRoots(title: p.title, token: token) {
                guard let id = page["id"] as? String, !baseline.contains(id),
                      [p.identity.ownerId, p.identity.botId].contains(object(page, "created_by")["id"] as? String ?? "") else { continue }
                let blocks = try await list(token, endpoint: "/blocks/\(id)/children")
                if blocks.contains(where: { richText(object($0, "paragraph")["rich_text"]) == Self.introduction }) { candidates.append(page) }
            }
        case .categories, .links, .tabs:
            guard let root = p.rootPageId else { throw LVError(L("親ページの作成記録がありません")) }
            let expected = step == .categories ? "Categories" : step == .tabs ? "Tabs":"Links"
            for block in try await list(token, endpoint: "/blocks/\(root)/children") where object(block, "child_database")["title"] as? String == expected {
                if let id = block["id"] as? String { candidates.append(try await call(token, "GET", "/databases/\(id)")) }
            }
        case .categoryPage, .settingsLink:
            let source = step == .categoryPage ? p.categoriesSourceId : p.linksSourceId
            guard let source else { throw LVError(L("DBの作成記録がありません")) }
            let expected = step == .categoryPage ? "設定" : "Workspace Tabs Settings"
            candidates = try await list(token, endpoint: "/data_sources/\(source)/query", method: "POST").filter {
                titleOf(object($0, "properties")) == expected && (step != .settingsLink || object(object($0, "properties"), "URL")["url"] as? String == p.rootURL)
            }
        }
        guard candidates.count == 1 else {
            throw LVError(L("\(step.title)の作成結果を一意に確認できません。重複作成を避けるため停止しています。少し待って再開してください。"))
        }
        return candidates[0]
    }
}
