import Foundation

public enum NotionWorkspace {
    public static func normalizedID(_ value: String?) -> String? {
        guard let value else {return nil}
        let compact=value.replacingOccurrences(of:"-",with:"").lowercased()
        guard compact.count == 32, compact.allSatisfy({$0.isASCII && $0.isHexDigit}) else {return nil}
        return compact
    }
    public static func environment(_ url: URL) -> String? {
        guard url.scheme == "https" else {return nil}
        switch url.host?.lowercased() {
        case "app.dev.notion.com": return "dev"
        case "app.notion.com", "www.notion.so", "notion.so": return "production"
        default:return nil
        }
    }
    public static func domain(_ url: URL) -> String? {
        guard environment(url) != nil else {return nil}
        let parts=url.pathComponents.filter {$0 != "/"}
        // Only the observed canonical page route. Do not guess workspace from a page UUID.
        guard parts.count >= 3, parts[0] == "p", normalizedID(parts[1]) == nil else {return nil}
        return parts[1].lowercased()
    }
    public static func target(url: URL, detectedID: String?, workspaces: [BrowserWorkspace]) -> UUID? {
        guard let env=environment(url) else {return nil}
        let candidates=workspaces.filter { workspace in
            guard workspace.notionAutoRoute == true,
                  let id=normalizedID(workspace.notionSpaceID),
                  let home=BrowserAddress.url(workspace.homeURL),environment(home) == env else {return false}
            if let detected=normalizedID(detectedID) {return detected == id}
            if let domain=domain(url) {return domain == self.domain(home)}
            return false
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }
    // Read only two route metadata keys; never cookies, credentials or page content.
    // Internal Notion schema: fail closed on unsupported, stale, or unrelated routes.
    public static let detectionScript = #"""
    (() => {
      if (location.protocol !== 'https:' || !['app.notion.com','app.dev.notion.com','notion.so','www.notion.so'].includes(location.hostname)) return null;
      try {
        const read = key => JSON.parse(localStorage.getItem('LRU:KeyValueStore2:' + key) || 'null')?.value;
        const route = read('lastVisitedRoute');
        const space = read('lastVisitedRouteSpaceId');
        const compact = value => typeof value === 'string' ? value.replace(/-/g,'').toLowerCase() : '';
        const path = location.pathname.split('/').filter(Boolean);
        const last = path[path.length-1] || '';
        const page = last.match(/([a-f0-9]{32}|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/i)?.[1];
        if (!page || route?.name !== 'page' || compact(route.blockId) !== compact(page) || !/^[a-f0-9]{32}$/.test(compact(space))) return null;
        return {url:location.href, spaceID:compact(space)};
      } catch (_) {return null;}
    })()
    """#
}
