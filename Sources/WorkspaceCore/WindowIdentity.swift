import Foundation

public struct WindowIdentity: Codable, Equatable {
    public var bundleID: String
    public var title: String
    public var identifier: String?
    public var document: String?
    public var session: String?
    public init(bundleID: String, title: String, identifier: String? = nil, document: String? = nil, session: String? = nil) {
        self.bundleID = bundleID; self.title = title; self.identifier = identifier
        self.document = document; self.session = session
    }
}

public enum WindowRestoration {
    /// Only one-to-one matches are accepted, strongest hints first. Never use array order.
    public static func matches(tabs: [WorkspaceTab], windows: [WindowIdentity]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var used: Set<Int> = []
        func key(_ hint: WindowIdentity, pass: Int) -> [String]? {
            switch pass {
            case 0:
                guard let id = hint.identifier, !id.isEmpty, let session = hint.session else { return nil }
                return [hint.bundleID, session, id]
            case 1:
                guard let document = hint.document, !document.isEmpty else { return nil }
                return [hint.bundleID, document]
            default: return hint.title.isEmpty ? nil : [hint.bundleID, hint.title]
            }
        }
        for pass in 0..<3 {
            var saved: [[String]: [UUID]] = [:]
            var live: [[String]: [Int]] = [:]
            for tab in tabs where result[tab.id] == nil {
                var hint = tab.windowIdentity ?? WindowIdentity(bundleID: tab.bundleID, title: tab.windowTitle)
                hint.bundleID = tab.bundleID; hint.title = tab.windowTitle
                if let k = key(hint, pass: pass) { saved[k, default: []].append(tab.id) }
            }
            for i in windows.indices where !used.contains(i) {
                if let k = key(windows[i], pass: pass) { live[k, default: []].append(i) }
            }
            for (k, ids) in saved where ids.count == 1 {
                if let candidates = live[k], candidates.count == 1 {
                    result[ids[0]] = candidates[0]; used.insert(candidates[0])
                }
            }
        }
        return result
    }
}
