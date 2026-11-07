import Foundation

typealias JSONObject = [String: Any]
struct NotionAPIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { "Notion API \(status): \(message)" }
}
protocol NotionRequesting {
    func request(token: String, method: String, endpoint: String, body: JSONObject?) async throws -> JSONObject
}
func richText(_ value: Any?) -> String { (value as? [JSONObject] ?? []).map { $0["plain_text"] as? String ?? (($0["text"] as? JSONObject)?["content"] as? String ?? "") }.joined() }
func titleOf(_ properties: JSONObject) -> String { richText((properties.values.compactMap { $0 as? JSONObject }.first { $0["type"] as? String == "title" })?["title"]) }
func object(_ dictionary: JSONObject, _ key: String) -> JSONObject { dictionary[key] as? JSONObject ?? [:] }
func notionPageId(_ value: String) -> String? {
    guard let url = URL(string: value), url.scheme == "https", let host = url.host,
          ["notion.so", "www.notion.so", "app.notion.com", "app.dev.notion.com", "notion.site"].contains(host) || host.hasSuffix(".notion.site") else { return nil }
    return extractId(url.path)
}
func extractId(_ value: String) -> String? {
    guard let range = value.range(of: "([0-9a-f]{32}|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})/?$", options: .regularExpression) else { return nil }
    return String(value[range]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

actor NotionClient: NotionRequesting {
    private var lastRequest = Date.distantPast
    private let apiVersion: String
    private let transport:(any NotionRequesting)?
    init(apiVersion: String = "2025-09-03",transport:(any NotionRequesting)? = nil) { self.apiVersion = apiVersion;self.transport=transport }
    func request(token: String, method: String = "GET", endpoint: String, body: JSONObject? = nil) async throws -> JSONObject {
        if let transport {return try await transport.request(token:token,method:method,endpoint:endpoint,body:body)}
        for attempt in 0...3 {
            let wait = 0.35 - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            lastRequest = Date()
            var request = URLRequest(url: URL(string: "https://api.notion.com/v1" + endpoint)!)
            request.httpMethod = method; request.timeoutInterval = 20
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(apiVersion, forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LVError("Notion から応答がありません") }
            let json = try JSONSerialization.jsonObject(with: data) as? JSONObject ?? [:]
            let status = json["object"] as? String == "error" ? json["status"] as? Int ?? http.statusCode : http.statusCode
            if status == 429 && attempt < 3 {
                let delay = min(20.0, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); continue
            }
            guard (200..<300).contains(status), json["object"] as? String != "error" else {
                throw NotionAPIError(status: status, message: (json["message"] as? String ?? "取得できませんでした").replacingOccurrences(of:token,with:"[redacted]"))
            }
            return json
        }
        throw LVError("Notion のアクセス制限に達しました。少し待って再試行してください")
    }
    func pages(token: String, id: String) async throws -> [JSONObject] {
        var result: [JSONObject] = []; var cursor: String?
        repeat {
            var body: JSONObject = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let response = try await request(token: token, method: "POST", endpoint: "/data_sources/\(id)/query", body: body)
            result += (response["results"] as? [JSONObject] ?? []).filter { $0["in_trash"] as? Bool != true && $0["archived"] as? Bool != true }
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
        } while cursor != nil
        return result
    }
    func checkToken(_ token: String) async throws -> String {
        let me = try await request(token: token, endpoint: "/users/me")
        return object(me, "bot")["workspace_name"] as? String ?? me["name"] as? String ?? "Notion"
    }
    func resolveSource(_ input: String, token: LVToken) async throws -> LVSource {
        guard let id = extractId(URL(string: input)?.path ?? input) else { throw LVError("Notion のデータベース URL または ID を入力してください") }
        let database = try? await request(token: token.token, endpoint: "/databases/\(id)")
        let dataSources = database?["data_sources"] as? [JSONObject] ?? []
        if dataSources.count > 1 { throw LVError("複数のデータソースがあります。追加したいデータソースの ID を入力してください") }
        let dsId = dataSources.first?["id"] as? String ?? id
        let ds = try await request(token: token.token, endpoint: "/data_sources/\(dsId)")
        guard object(object(ds, "properties"), "URL")["type"] as? String == "url" else { throw LVError("URL 型の「URL」プロパティが必要です") }
        let dbId = object(ds, "parent")["database_id"] as? String
        let resolvedDb: JSONObject
        if let database { resolvedDb = database }
        else if let dbId { resolvedDb = try await request(token: token.token, endpoint: "/databases/\(dbId)") }
        else { resolvedDb = [:] }
        let title = richText(ds["title"])
        return LVSource(id: dsId, title: title.isEmpty ? richText(resolvedDb["title"]) : title, emoji: object(resolvedDb, "icon")["emoji"] as? String,
            databaseUrl: resolvedDb["url"] as? String, tokenId: token.id)
    }
    func sync(_ state: DiskState, tokens: [LVToken]) async -> LinkData {
        var metas: [SourceMeta] = []; var links: [Link] = []
        for source in state.sources {
            do {
                guard let token = tokens.first(where: { $0.id == source.tokenId }), !token.token.isEmpty else { throw LVError("「\(source.title)」の接続トークンを設定してください") }
                let ds = try await request(token: token.token, endpoint: "/data_sources/\(source.id)")
                let rows = try await pages(token: token.token, id: source.id)
                let props = object(ds, "properties")
                let legacy = object(props, "Category (Legacy)")
                let categoryProperty = props["Category"] as? JSONObject ?? legacy
                var categories: [Category] = []
                var categoryDatabaseUrl: String?
                if categoryProperty["type"] as? String == "relation" {
                    let relation = object(categoryProperty, "relation")
                    var categorySource = relation["data_source_id"] as? String
                    if categorySource == nil, let dbId = relation["database_id"] as? String {
                        let db = try await request(token: token.token, endpoint: "/databases/\(dbId)")
                        let sources = db["data_sources"] as? [JSONObject] ?? []
                        guard sources.count == 1 else { throw LVError("カテゴリ DB のデータソースを特定できません") }
                        categorySource = sources.first?["id"] as? String
                    }
                    guard let categorySource else { throw LVError("カテゴリ DB を取得できません") }
                    let catDs = try await request(token: token.token, endpoint: "/data_sources/\(categorySource)")
                    guard object(object(catDs, "properties"), "Order")["type"] as? String == "number" else { throw LVError("カテゴリ DB には数値型の Order が必要です") }
                    let categoryRows = try await pages(token: token.token, id: categorySource)
                    categories = sortedCategories(categoryRows.map { page in
                        let p = object(page, "properties")
                        return Category(id: page["id"] as? String, name: titleOf(p), workspaceID: richText(object(p,"Workspace ID")["rich_text"]).trimmingCharacters(in:.whitespacesAndNewlines), color: "default", order: object(p, "Order")["number"] as? Double)
                    })
                    if let dbId = object(catDs, "parent")["database_id"] as? String {
                        let db = try await request(token: token.token, endpoint: "/databases/\(dbId)")
                        categoryDatabaseUrl = db["url"] as? String
                    }
                } else {
                    categories = (object(categoryProperty, "select")["options"] as? [JSONObject] ?? []).map { Category(name: $0["name"] as? String ?? "", color: $0["color"] as? String ?? "default") }
                }
                let tags = (object(object(props, "Tags"), "multi_select")["options"] as? [JSONObject] ?? []).map { Tag(name: $0["name"] as? String ?? "", color: $0["color"] as? String ?? "default") }
                var sourceLinks: [Link] = []
                for row in rows {
                    let p = object(row, "properties")
                    guard let url = object(p, "URL")["url"] as? String, !url.isEmpty, let id = row["id"] as? String else { continue }
                    var category: Category?
                    if categoryProperty["type"] as? String == "relation" {
                        let value = object(p, "Category"); let ids = value["relation"] as? [JSONObject] ?? []
                        guard ids.count <= 1, value["has_more"] as? Bool != true else { throw LVError("「\(titleOf(p))」のカテゴリは1件にしてください") }
                        if let cid = ids.first?["id"] as? String {
                            guard let found = categories.first(where: { $0.id == cid }) else { throw LVError("カテゴリ DB のアクセス権を確認してください") }; category = found
                        }
                    } else {
                        let value = p["Category"] as? JSONObject ?? p["Category (Legacy)"] as? JSONObject ?? [:]
                        let selected = object(value, "select")
                        if let name = selected["name"] as? String { category = Category(name: name, color: selected["color"] as? String ?? "default") }
                    }
                    let connectionValue = object(p, "Connection")
                    let connection = object(connectionValue, "select")["name"] as? String ?? connectionValue["rich_text"].map { richText($0) }
                    var link = Link(id: id, sourceId: source.id, name: titleOf(p), url: url, category: category,
                        tags: (object(p, "Tags")["multi_select"] as? [JSONObject] ?? []).map { Tag(name: $0["name"] as? String ?? "", color: $0["color"] as? String ?? "default") },
                        app: object(object(p, "App"), "select")["name"] as? String ?? "Default", description: richText(object(p, "Description")["rich_text"]),
                        pinned: object(p, "Pinned")["checkbox"] as? Bool ?? false, order: object(p, "Order")["number"] as? Double,
                        notionUrl: row["url"] as? String ?? "https://notion.so/\(id)", connection: connection, editedTime:row["last_edited_time"] as? String, workspaceLinkID:richText(object(p,"Workspace Tabs ID")["rich_text"]),workspaceRef:richText(object(p,"Workspace Tab")["rich_text"]),workspaceName:richText(object(p,"Workspace Tab Name")["rich_text"]))
                    let old = state.data?.links.first { $0.key == link.key }
                    do {
                        let iconPage = try await resolveIcon(row: row, link: link, sourceToken: token, tokens: tokens)
                        let icon = object(iconPage, "icon")
                        link.emoji = icon["emoji"] as? String
                        if let imageUrl = iconURL(icon) {
                            do { link.iconPath = try await downloadIcon(imageUrl, page: iconPage) }
                            catch { link.iconPath = existingIcon(old?.iconPath); link.iconError = "画像を取得できません: \(error.localizedDescription)" }
                        }
                    } catch {
                        link.iconPath = existingIcon(old?.iconPath); link.emoji = old?.emoji
                        link.iconError = "リンク先を取得できません。接続のトークンとページの共有設定を確認してください。\n\(error.localizedDescription)"
                    }
                    sourceLinks.append(link)
                }
                links += sortLinks(sourceLinks)
                metas.append(SourceMeta(id: source.id, categories: categories, tags: tags, categoryDatabaseUrl: categoryDatabaseUrl))
            } catch {
                links += state.data?.links.filter { $0.sourceId == source.id } ?? []
                var old = state.data?.sources.first { $0.id == source.id } ?? SourceMeta(id: source.id, categories: [], tags: [])
                old.error = error.localizedDescription; metas.append(old)
            }
        }
        return LinkData(syncedAt: ISO8601DateFormatter().string(from: Date()), sources: metas, links: links)
    }
    private func resolveIcon(row: JSONObject, link: Link, sourceToken: LVToken, tokens: [LVToken]) async throws -> JSONObject {
        if row["icon"] is JSONObject { return row }
        guard let id = notionPageId(link.url), id.replacingOccurrences(of: "-", with: "") != link.id.replacingOccurrences(of: "-", with: "") else { return row }
        let candidates: [LVToken]
        if let connection = link.connection, !connection.isEmpty {
            candidates = tokens.filter { $0.id == connection || $0.label == connection }
            guard candidates.count == 1 else { throw LVError("Connection「\(connection)」に一致する接続を1件登録してください") }
        } else { candidates = [sourceToken] + tokens.filter { $0.id != sourceToken.id } }
        var lastError: Error = LVError("使用できる接続がありません")
        for token in candidates {
            do {
                let page = try await request(token: token.token, endpoint: "/pages/\(id)")
                guard page["object"] as? String == "page", (page["id"] as? String)?.replacingOccurrences(of: "-", with: "") == id.replacingOccurrences(of: "-", with: "") else { throw LVError("リンク先のページ情報がありません") }
                return page
            } catch { lastError = error }
        }
        throw lastError
    }
    private func iconURL(_ icon: JSONObject) -> URL? {
        guard let type = icon["type"] as? String, type != "emoji" else { return nil }
        if type == "icon", let name = object(icon, "icon")["name"] as? String {
            let color = object(icon, "icon")["color"] as? String ?? "gray"
            let safeName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return URL(string: "https://www.notion.so/icons/\(safeName)_\(color == "default" ? "gray" : color).svg")
        }
        return (object(icon, type)["url"] as? String).flatMap(URL.init(string:))
    }
    private func existingIcon(_ path: String?) -> String? {
        guard let path, URL(fileURLWithPath: path).deletingLastPathComponent() == Storage.icons,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
    private func downloadIcon(_ url: URL, page: JSONObject) async throws -> String {
        guard ["https", "http"].contains(url.scheme ?? "") else { throw LVError("非対応の画像 URL です") }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("NotionLinkViewer/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let types = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/svg+xml": "svg"]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let ext = types[response.mimeType?.lowercased() ?? ""], data.count <= 10_000_000 else { throw LVError("対応する画像を取得できませんでした") }
        let stamp = (page["last_edited_time"] as? String ?? "0").replacingOccurrences(of: ":", with: "-")
        let file = Storage.icons.appendingPathComponent("\(page["id"] as? String ?? UUID().uuidString)-\(stamp).\(ext)")
        try Storage.prepare(); try data.write(to: file, options: .atomic)
        return file.path
    }
}
