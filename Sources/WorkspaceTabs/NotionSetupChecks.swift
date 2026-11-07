import Foundation

private let workspaceId = "10000000-0000-4000-8000-000000000001"
private let ownerId = "20000000-0000-4000-8000-000000000001"
private let botId = "30000000-0000-4000-8000-000000000001"
private let testSecret = "fake-pat-for-local-tests"

actor MockNotion: NotionRequesting {
    enum Failure { case none, rejected(SetupStep), committedThenDisconnected(SetupStep), disconnectedBeforeCommit(SetupStep) }
    var failure = Failure.none
    var internalToken = false
    var changedWorkspace = false
    var corruptRelation = false
    private var sequence = 0
    private var objects: [String: JSONObject] = [:]
    private var children: [String: [JSONObject]] = [:]
    private var committed: [SetupStep] = []
    func configure(failure: Failure = .none, internalToken: Bool = false, changedWorkspace: Bool = false, corruptRelation: Bool = false) {
        self.failure = failure; self.internalToken = internalToken; self.changedWorkspace = changedWorkspace; self.corruptRelation = corruptRelation
    }
    func counts() -> [String: Int] { Dictionary(grouping: committed, by: \.rawValue).mapValues(\.count) }
    private func id() -> String { sequence += 1; return String(format: "40000000-0000-4000-8000-%012d", sequence) }
    func request(token: String, method: String, endpoint: String, body: JSONObject?) async throws -> JSONObject {
        precondition(token == testSecret)
        let path = String(endpoint.split(separator: "?")[0])
        if path == "/users/me" {
            let owner: JSONObject = internalToken ? ["type": "workspace", "workspace": true] : ["type": "user", "user": ["id": ownerId, "name": "Test Owner"]]
            return ["object": "user", "type": "bot", "id": botId, "bot": ["owner": owner, "workspace_id": changedWorkspace ? UUID().uuidString : workspaceId, "workspace_name": "Test Workspace"]]
        }
        if path == "/search" {
            let query = body?["query"] as? String ?? ""
            return list(objects.filter { $0.key.hasPrefix("/pages/") && object($0.value, "parent")["workspace"] as? Bool == true && titleOf(object($0.value, "properties")) == query }.map(\.value))
        }
        if method == "GET", path.hasPrefix("/blocks/") {
            let root = String(path.split(separator: "/")[1]); return list(children[root] ?? [])
        }
        if method == "GET", var value = objects[path] {
            if corruptRelation, path.hasPrefix("/data_sources/"), object(value, "properties")["Category"] != nil {
                var props = object(value, "properties"), category = object(props, "Category"), relation = object(category, "relation")
                relation["data_source_id"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
                category["relation"] = relation; props["Category"] = category; value["properties"] = props
            }
            return value
        }
        if method == "POST", path.hasPrefix("/data_sources/") {
            let source = String(path.split(separator: "/")[1])
            return list(objects.filter { $0.key.hasPrefix("/pages/") && object($0.value, "parent")["data_source_id"] as? String == source }.map(\.value))
        }
        guard method == "POST", let suppliedBody = body else { throw LVError("Unexpected mock API call: \(method) \(path)") }
        // Match the real transport's JSON boundary, including empty property settings and numeric values.
        let body = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: suppliedBody)) as! JSONObject
        let parent = object(body, "parent")
        let step: SetupStep
        if path == "/databases" { step = richText(body["title"]) == "Categories" ? .categories : richText(body["title"]) == "Tabs" ? .tabs:.links }
        else if parent["workspace"] as? Bool == true { step = .root }
        else { step = object(body, "properties")["URL"] != nil ? .settingsLink : .categoryPage }
        var disconnectAfterCommit = false
        switch failure {
        case .rejected(let value) where value == step:
            failure = .none; throw NotionAPIError(status: 403, message: "Simulated rejected write")
        case .disconnectedBeforeCommit(let value) where value == step:
            failure = .none; throw URLError(.networkConnectionLost)
        case .committedThenDisconnected(let value) where value == step:
            failure = .none; disconnectAfterCommit = true
        default: break
        }
        let result: JSONObject
        if path == "/databases" {
            precondition(parent["type"] as? String == "page_id" && body["is_inline"] as? Bool == true)
            let database = id(), source = id()
            let schema = object(object(body, "initial_data_source"), "properties")
            let props = typed(schema)
            if step == .links {
                let relation = object(object(props, "Category"), "relation")
                precondition(relation["type"] as? String == "single_property")
                precondition(relation["data_source_id"] != nil && relation["database_id"] == nil, "Relations must target a data source")
                precondition(object(props, "Order")["type"] as? String == "number")
            }
            result = ["object": "database", "id": database, "parent": parent, "title": body["title"]!, "url": "https://www.notion.so/\(database)", "data_sources": [["id": source]]]
            objects["/databases/\(database)"] = result
            objects["/data_sources/\(source)"] = ["object": "data_source", "id": source, "parent": ["type": "database_id", "database_id": database], "properties": props]
            let root = parent["page_id"] as! String
            children[root, default: []].append(["object": "block", "id": database, "type": "child_database", "child_database": ["title": richText(body["title"]) ]])
        } else {
            let page = id()
            if step == .root { precondition(parent["type"] as? String == "workspace" && parent["workspace"] as? Bool == true) }
            result = ["object": "page", "id": page, "parent": parent, "properties": typed(object(body, "properties")), "url": "https://www.notion.so/\(page)", "public_url": NSNull(), "created_by": ["id": ownerId]]
            objects["/pages/\(page)"] = result
            if let blocks = body["children"] as? [JSONObject] { children[page] = blocks }
            if step == .settingsLink {
                precondition(object(object(body, "properties"), "Pinned")["checkbox"] as? Bool == true)
                precondition((object(object(body, "properties"), "Category")["relation"] as? [JSONObject])?.count == 1)
            }
        }
        committed.append(step)
        if disconnectAfterCommit { throw URLError(.networkConnectionLost) }
        return result
    }
    private func list(_ result: [JSONObject]) -> JSONObject { ["results": result, "has_more": false, "next_cursor": NSNull()] }
    private func typed(_ definitions: JSONObject) -> JSONObject {
        var result: JSONObject = [:]
        for (name, value) in definitions {
            var property = value as! JSONObject
            let type = property["type"] as? String ?? property.keys.first!
            property["type"] = type; property["id"] = name == "Name" || name == "title" ? "title" : name
            result[name] = property
        }
        return result
    }
}

struct NotionSetupChecks {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        func fixture(_ name: String) async throws -> (MockNotion, DatabaseSetup, CreationJournal, DatabaseCreation) {
            let api = MockNotion(), journal = CreationJournal(url: root.appendingPathComponent("\(name)/journal.json"))
            let setup = DatabaseSetup(api: api, journal: journal)
            let identity = try await setup.inspect(token: testSecret)
            return (api, setup, journal, DatabaseCreation(tokenId: "token-reference", identity: identity, title: "Link Viewer"))
        }
        func expectFailure(_ operation: () async throws -> Void) async -> Bool {
            do { try await operation(); return false } catch { return true }
        }
        let (api, setup, journal, draft) = try await fixture("success")
        let done = try await setup.create(draft, token: testSecret)
        precondition(done.completed && !done.registered && done.source != nil)
        precondition(done.linksSourceId != done.linksDatabaseId && done.categoriesSourceId != done.categoriesDatabaseId)
        let expected = ["root": 1, "categories": 1, "links": 1, "categoryPage": 1, "settingsLink": 1,"tabs":1]
        let initialCounts = await api.counts(); precondition(initialCounts == expected)
        _ = try await setup.create(done, token: testSecret)
        let repeatedCounts = await api.counts(); precondition(repeatedCounts == expected, "Repeating a completed operation must not create duplicates")
        let journalText = String(data: try Data(contentsOf: journal.url), encoding: .utf8)!
        precondition(!journalText.contains(testSecret))

        for step in [SetupStep.root, .categories, .links, .categoryPage, .settingsLink, .tabs] {
            let (api, setup, journal, draft) = try await fixture("rejected-\(step.rawValue)")
            await api.configure(failure: .rejected(step))
            let failed = await expectFailure { _ = try await setup.create(draft, token: testSecret) }; precondition(failed)
            let pending = try journal.load().first!; precondition(pending.pendingStep == nil && !pending.completed)
            let resumed = try await setup.create(pending, token: testSecret); precondition(resumed.completed)
            let counts = await api.counts(); precondition(counts == expected, "Resume must reuse acknowledged resources")
        }
        for step in [SetupStep.root, .categories, .links, .categoryPage, .settingsLink, .tabs] {
            let (api, setup, journal, draft) = try await fixture("lost-response-\(step.rawValue)")
            await api.configure(failure: .committedThenDisconnected(step))
            let failed = await expectFailure { _ = try await setup.create(draft, token: testSecret) }; precondition(failed)
            let pending = try journal.load().first!; precondition(pending.pendingStep == step)
            let resumed = try await setup.create(pending, token: testSecret); precondition(resumed.completed)
            let counts = await api.counts(); precondition(counts == expected, "A successful POST with a lost response must be reconciled without duplication")
        }
        let (unknownAPI, unknownSetup, unknownJournal, unknownDraft) = try await fixture("unknown")
        await unknownAPI.configure(failure: .disconnectedBeforeCommit(.root))
        let unknownFailed = await expectFailure { _ = try await unknownSetup.create(unknownDraft, token: testSecret) }; precondition(unknownFailed)
        let unknownPending = try unknownJournal.load().first!
        let unknownResumeFailed = await expectFailure { _ = try await unknownSetup.create(unknownPending, token: testSecret) }; precondition(unknownResumeFailed)
        let unknownCounts = await unknownAPI.counts(); precondition(unknownCounts.isEmpty, "An unresolved create must not be blindly retried")
        let separateDraft = DatabaseCreation(tokenId: unknownDraft.tokenId, identity: unknownDraft.identity, title: unknownDraft.title)
        _ = try await unknownSetup.create(separateDraft, token: testSecret)
        let crossOperationFailed = await expectFailure { _ = try await unknownSetup.create(unknownPending, token: testSecret) }; precondition(crossOperationFailed)
        let crossOperationCounts = await unknownAPI.counts(); precondition(crossOperationCounts == expected, "An unresolved operation must not adopt another operation's root")

        let (internalAPI, internalSetup, _, internalDraft) = try await fixture("internal")
        await internalAPI.configure(internalToken: true)
        let internalFailed = await expectFailure { _ = try await internalSetup.create(internalDraft, token: testSecret) }; precondition(internalFailed)
        let internalCounts = await internalAPI.counts(); precondition(internalCounts.isEmpty)

        let (changedAPI, changedSetup, _, changedDraft) = try await fixture("workspace-change")
        await changedAPI.configure(changedWorkspace: true)
        let changedFailed = await expectFailure { _ = try await changedSetup.create(changedDraft, token: testSecret) }; precondition(changedFailed)
        let changedCounts = await changedAPI.counts(); precondition(changedCounts.isEmpty, "A different workspace must be rejected before writes")

        let (ownerAPI, ownerSetup, _, originalOwnerDraft) = try await fixture("owner-change")
        var ownerDraft = originalOwnerDraft; ownerDraft.identity.ownerId = UUID().uuidString
        let ownerFailed = await expectFailure { _ = try await ownerSetup.create(ownerDraft, token: testSecret) }; precondition(ownerFailed)
        let ownerCounts = await ownerAPI.counts(); precondition(ownerCounts.isEmpty, "A different owner must be rejected before writes")

        let (badAPI, badSetup, badJournal, badDraft) = try await fixture("bad-relation")
        await badAPI.configure(corruptRelation: true)
        let badFailed = await expectFailure { _ = try await badSetup.create(badDraft, token: testSecret) }; precondition(badFailed)
        let badProgress = try badJournal.load().first!
        precondition(!badProgress.completed, "A wrong relation must never be reported as complete")
        print("Passed: private root, both schemas, data-source relation, initial category/link, independent Order, workspace/owner guard, internal-token rejection, interrupted creation resume, all 6 lost-response reconciliations, ambiguous-result stop, and secret-free journal")
    }
}
