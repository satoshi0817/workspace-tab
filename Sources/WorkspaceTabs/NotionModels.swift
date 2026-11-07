import Foundation

struct LVError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Category: Codable, Hashable, Identifiable {
    var id: String?
    var name: String
    var workspaceID: String?
    var color: String = "default"
    var order: Double?
    var key: String { id ?? "select:\(name)" }
}
struct Tag: Codable, Hashable { var name: String; var color: String }
struct Link: Codable, Identifiable {
    var id: String
    var sourceId: String
    var name: String
    var url: String
    var category: Category?
    var tags: [Tag]
    var app: String
    var description: String
    var pinned: Bool
    var order: Double?
    var emoji: String?
    var iconPath: String?
    var iconError: String?
    var notionUrl: String
    var connection: String?
    var editedTime:String?
    var workspaceLinkID:String?
    var workspaceRef:String?
    var workspaceName:String?
    var key: String { sourceId + ":" + id }
}
struct LVSource: Codable, Identifiable {
    var id: String
    var title: String
    var emoji: String?
    var databaseUrl: String?
    var tokenId: String
}
struct LVToken: Codable, Identifiable {
    var id: String
    var label: String
    var token: String
}
struct TokenInfo: Codable, Identifiable { var id: String; var label: String }
struct SourceMeta: Codable {
    var id: String
    var categories: [Category]
    var tags: [Tag]
    var categoryDatabaseUrl: String?
    var error: String?
}
struct LinkData: Codable { var syncedAt: String; var sources: [SourceMeta]; var links: [Link] }

struct DiskState: Codable {
    var sources:[LVSource]=[]
    var tokens:[TokenInfo]=[]
    var data:LinkData?
}
func sortedCategories(_ list: [Category]) -> [Category] {
    var seen = Set<String>()
    return list.filter { seen.insert($0.key).inserted }.enumerated().sorted { a, b in
        if a.element.id == nil && b.element.id == nil { return a.offset < b.offset }
        if (a.element.id == nil) != (b.element.id == nil) { return a.element.id != nil }
        if (a.element.order ?? .infinity) != (b.element.order ?? .infinity) { return (a.element.order ?? .infinity) < (b.element.order ?? .infinity) }
        return a.element.name.localizedStandardCompare(b.element.name) == .orderedAscending
    }.map(\.element)
}
func sortLinks(_ list: [Link]) -> [Link] {
    list.sorted {
        if $0.pinned != $1.pinned { return $0.pinned }
        if ($0.order ?? .infinity) != ($1.order ?? .infinity) { return ($0.order ?? .infinity) < ($1.order ?? .infinity) }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}
