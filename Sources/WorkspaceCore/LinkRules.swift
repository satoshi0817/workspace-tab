import Foundation

public struct BrowserLinkRule:Codable,Identifiable,Equatable {
    public var id=UUID()
    public var domain:String
    public var includeSubdomains=false
    public var workspaceID:UUID
    public var groupID:UUID?
    public var enabled=true
    public init(domain:String="",workspaceID:UUID,groupID:UUID?=nil) {self.domain=domain;self.workspaceID=workspaceID;self.groupID=groupID}
    public static func normalizedDomain(_ value:String)->String? {
        let raw=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty,!raw.contains(where:{$0.isWhitespace}),!raw.contains(":"),!raw.contains("/"),!raw.contains("*"),
              let url=URL(string:"https://"+raw),let host=url.host?.lowercased(),url.user == nil,url.password == nil,
              url.query == nil,url.fragment == nil else{return nil}
        let domain=host.hasSuffix(".") ? String(host.dropLast()):host
        guard !domain.isEmpty,domain.split(separator:".",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty}) else{return nil}
        return domain
    }
    public func matches(_ url:URL)->Bool {
        guard enabled,["https","http"].contains(url.scheme?.lowercased() ?? ""),url.user == nil,url.password == nil,
              let host=url.host?.lowercased(),let domain=Self.normalizedDomain(domain) else{return false}
        let normalized=host.hasSuffix(".") ? String(host.dropLast()):host
        return normalized == domain || (includeSubdomains && normalized.hasSuffix("."+domain))
    }
    public static func candidates(for url:URL,rules:[BrowserLinkRule])->[BrowserLinkRule] {
        // Notion identity routing always takes precedence over domain rules.
        guard !BrowserAddress.isNotion(url) else{return []}
        let matches=rules.filter{$0.matches(url)}
        let length=matches.compactMap{normalizedDomain($0.domain)?.count}.max()
        return matches.filter{normalizedDomain($0.domain)?.count == length}
    }
}
