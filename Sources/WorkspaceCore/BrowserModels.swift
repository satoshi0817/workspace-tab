import Foundation

public struct LoginProfile: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var name: String
    public var accountNote: String = ""
    public init(name: String) { self.name = name }
}
public struct BrowserPage: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var url: String
    // An empty title is an app placeholder, not a site-provided or user-defined name.
    public var title: String = ""
    public var isStartPage: Bool?
    public var pinned: Bool?
    public var pinnedDisplay: String?
    /// The page a pinned tab opens when the app starts. nil restores the last page shown.
    public var pinnedURL: String?
    public var tabName: String?
    public var tabEmoji: String?
    public var tabIconFile: String?
    public var groupID: UUID?
    /// Large account email over this tab's page. nil follows the app tab's setting.
    public var showAccountEmail: Bool?
    public var displayTitle: String {tabName?.isEmpty == false ? tabName! : (title.isEmpty ? L("新しいタブ") : title)}
    public var iconOnly: Bool {pinned == true && pinnedDisplay != "name"}
    public init(url: String) { self.url = url }
}
public struct BrowserTabGroup: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var iconFile: String?
    public var profileID:UUID?
    public init(id:UUID = UUID(),name:String,iconFile:String?=nil,profileID:UUID?=nil) {self.id=id;self.name=name;self.iconFile=iconFile;self.profileID=profileID}
}
public struct BrowserWorkspace: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var profileID: UUID
    public var name: String
    public var emoji: String = ""
    public var iconFile: String?
    public var color: String = "gray"
    public var textColor: String?
    public var pinned: Bool = false
    public var homeURL: String = "https://app.notion.com"
    public var notionSpaceID: String?
    public var notionAutoRoute: Bool?
    public var cssEnabled = false
    /// Default for every browser tab in this app tab; a tab's own choice wins.
    public var showAccountEmail: Bool?
    public func showsAccountEmail(for page:BrowserPage)->Bool {page.showAccountEmail ?? showAccountEmail ?? false}
    /// Look of the account email over the page, per app tab. nil uses the default.
    public var accountEmailOpacity: Double?
    public var accountEmailSize: Double?
    public var accountEmailPosition: String?
    public var accountEmailStyle:AccountEmailStyle {
        AccountEmailStyle(opacity:min(1,max(0.01,accountEmailOpacity ?? 0.1)),size:min(200,max(8,accountEmailSize ?? 96)),centered:accountEmailPosition == "center")
    }
    public var cssStrength: Double = 0.18
    public var pages: [BrowserPage]
    public var selectedPageID: UUID?
    public var tabGroups: [BrowserTabGroup]?
    public var visibleTabGroupID: UUID?
    public var resolvedTabGroups: [BrowserTabGroup] {
        let groups=tabGroups ?? []
        return groups.contains(where:{$0.id == id}) ? groups:[BrowserTabGroup(id:id,name:L("メイン"))]+groups
    }
    public func groupID(for page:BrowserPage)->UUID {
        guard let group=page.groupID,resolvedTabGroups.contains(where:{$0.id == group}) else{return id}
        return group
    }
    public func profileID(for page:BrowserPage)->UUID {profileID(forGroup:groupID(for:page))}
    public func profileID(forGroup groupID:UUID)->UUID {resolvedTabGroups.first{$0.id == groupID}?.profileID ?? profileID}
    public var visibleGroupID:UUID {
        guard let group=visibleTabGroupID,resolvedTabGroups.contains(where:{$0.id == group}) else{return id}
        return group
    }
    public init(name: String, profileID: UUID, url: String = "https://app.notion.com") {
        self.name = name; self.profileID = profileID; self.homeURL = url
        let page = BrowserPage(url: url); pages = [page]; selectedPageID = page.id
    }
}
public struct FavoriteLink: Codable, Identifiable, Equatable {
    public var order:Double?
    public var importKey: String?
    public var notionSourceID:String?
    public var notionPageID:String?
    public var notionEditedTime:String?
    public var id = UUID()
    public var title: String
    public var url: String
    public var workspaceID: UUID
    public var emoji = ""
    public var iconFile: String?
    public var categoryWorkspaceID: String?
    public var category = ""
    public var pinned = false
    public init(title: String, url: String, workspaceID: UUID) {
        self.title = title; self.url = url; self.workspaceID = workspaceID
    }
}
public struct BrowserSession: Codable, Equatable {
    public var linkRules:[BrowserLinkRule]?
    public var favorites: [FavoriteLink]?
    public var splitWorkspaceID: UUID?
    public var splitPageID: UUID?
    public var splitStateRecorded: Bool?
    public var splitOrientation:String?
    public var splitFraction:Double?
    /// Tabs shown in the second pane's strip while both panes show the same app tab.
    public var splitSidePageIDs:[UUID]?
    public var version = 1
    public var profiles: [LoginProfile] = []
    public var workspaces: [BrowserWorkspace] = []
    public var selectedWorkspaceID: UUID?
    public var theme = "system"
    public var sidebarMode = "full"
    public var sidebarPosition = "left"
    public var windowFrame: WindowRect?
    public var migratedFromNative = false
    public init() {}
    public func validated() throws -> BrowserSession {
        guard version == 1 else { throw BrowserSessionError.invalid }
        guard splitOrientation == nil || ["horizontal","vertical"].contains(splitOrientation!),
              splitFraction == nil || (splitFraction!.isFinite && (0.15...0.85).contains(splitFraction!)) else {throw BrowserSessionError.invalid}
        let profileIDs = Set(profiles.map(\.id)), workspaceIDs = Set(workspaces.map(\.id))
        let pageIDs = workspaces.flatMap { $0.pages.map(\.id) }
        guard profileIDs.count == profiles.count, workspaceIDs.count == workspaces.count,
              Set(pageIDs).count == pageIDs.count,
              selectedWorkspaceID == nil || workspaceIDs.contains(selectedWorkspaceID!),
              ["system","light","dark"].contains(theme), ["full","icons","hover"].contains(sidebarMode),
              ["left","top"].contains(sidebarPosition) else { throw BrowserSessionError.invalid }
        let links = favorites ?? []
        guard Set(links.map(\.id)).count == links.count,
              links.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && BrowserAddress.url($0.url) != nil }) else { throw BrowserSessionError.invalid }
        // Missing destinations remain editable; never silently use a different login environment.
        for w in workspaces {
            let groups=w.resolvedTabGroups,groupIDs=Set(groups.map(\.id))
            guard groupIDs.count == groups.count,groups.allSatisfy({$0.profileID.map{profileIDs.contains($0)} ?? true}),
                  profileIDs.contains(w.profileID), !w.pages.isEmpty,
                  w.selectedPageID.map({ id in w.pages.contains { $0.id == id } }) ?? false,
                  w.cssStrength.isFinite, (0...1).contains(w.cssStrength),
                  BrowserAddress.url(w.homeURL) != nil,
                  w.pages.allSatisfy({ BrowserAddress.url($0.url) != nil && ($0.groupID.map{groupIDs.contains($0)} ?? true) }) else { throw BrowserSessionError.invalid }
        }
        if splitStateRecorded == true, splitWorkspaceID != nil || splitPageID != nil {
            guard let wid=splitWorkspaceID, let pid=splitPageID, workspaces.contains(where: {$0.id == wid && $0.pages.contains(where: {$0.id == pid})}) else {throw BrowserSessionError.invalid}
        }
        return self
    }
    public static func migrate(_ native: SavedState) -> BrowserSession {
        var session = BrowserSession(); session.migratedFromNative = true
        for group in native.groups {
            for tab in group.tabs {
                let baseName = tab.name + L(" のログイン環境")
                let count = session.profiles.filter { $0.name == baseName || $0.name.hasPrefix(baseName + " (") }.count
                let profile = LoginProfile(name: count == 0 ? baseName : baseName + " (\(count + 1))")
                session.profiles.append(profile)
                let defaultURL = tab.bundleID.lowercased().contains("dev") ? "https://app.dev.notion.com" : "https://app.notion.com"
                let document = tab.windowIdentity?.document.flatMap { BrowserAddress.url($0) }
                let destination = document.flatMap { BrowserAddress.isNotion($0) ? BrowserAddress.savedURL($0) : nil } ?? defaultURL
                var workspace = BrowserWorkspace(name: tab.name, profileID: profile.id, url: destination)
                workspace.id = tab.id; workspace.emoji = tab.emoji; workspace.iconFile = tab.iconFile
                workspace.color = tab.color; workspace.textColor = tab.textColor; workspace.pinned = tab.pinned
                session.workspaces.append(workspace)
                if native.selectedGroupID == group.id && group.selectedTabID == tab.id { session.selectedWorkspaceID = workspace.id }
            }
        }
        if session.selectedWorkspaceID == nil { session.selectedWorkspaceID = session.workspaces.first?.id }
        return session
    }
}
public enum BrowserSessionError: Error { case invalid }
public enum BrowserAddress {
    public static func searchOrURL(_ input: String) -> URL? {
        let value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty else{return nil}
        if !value.contains(where:{$0.isWhitespace}) {
            if value.contains("://") {return url(value)}
            if let candidate=url(value),let host=candidate.host,
               host.contains(".") || host == "localhost" || host.contains(":") {return candidate}
        }
        var parts=URLComponents(string:"https://www.google.com/search")!
        parts.queryItems=[URLQueryItem(name:"q",value:value)]
        return parts.url
    }

    public static func url(_ input: String) -> URL? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "about:blank" { return URL(string: raw) }
        let value = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !raw.contains(where: { $0.isWhitespace }) else { return nil }
        return url
    }
    public static func isNotion(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["app.notion.com", "app.dev.notion.com", "www.notion.so", "notion.so", "www.notion.com"].contains(host)
    }
    public static func savedURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "about:blank" }
        parts.user = nil; parts.password = nil
        let secrets: Set<String> = ["code", "access_token", "id_token", "refresh_token", "token", "state", "session_token"]
        parts.queryItems = parts.queryItems?.filter { !secrets.contains($0.name.lowercased()) }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        if let fragment = parts.fragment, fragment.lowercased().contains("token=") { parts.fragment = nil }
        return parts.url?.absoluteString ?? "about:blank"
    }
}

public struct AccountEmailStyle:Equatable {
    public let opacity:Double
    public let size:Double
    /// false places it at the bottom right of the page.
    public let centered:Bool
}
