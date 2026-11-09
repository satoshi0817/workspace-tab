import Foundation

@MainActor enum LinkRoutingChecks {
    final class System:LinkRoutingSystem {
        var handlers:[String:URL]
        var calls:[(String,URL)]=[]
        var failOnce:String?
        init(_ original:URL) {handlers=["https":original,"http":original]}
        func application(for scheme:String)->URL? {handlers[scheme]}
        func setApplication(_ application:URL,for scheme:String)async throws {
            calls.append((scheme,application))
            if failOnce == scheme {failOnce=nil;throw LVError("Declined")}
            handlers[scheme]=application
        }
    }
    static func run(root:URL) async throws {
        func expect(_ value:Bool,_ name:String)throws {
            guard value else{throw BrowserChecks.Failure.check(name)}
            print("PASS "+name)
        }
        let original=root.appendingPathComponent("Original Browser.app"),other=root.appendingPathComponent("Other Browser.app"),app=root.appendingPathComponent("Workspace Tabs.app")
        try FileManager.default.createDirectory(at:original,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        let system=System(original),directory=root.appendingPathComponent("routing")
        let routing=NotionLinkRouting(directory:directory,system:system,application:app,canConfigure:true)
        try expect(!routing.enabled && system.calls.isEmpty,"Link routing defaults off and never changes macOS during initialization")
        await routing.setEnabled(true)
        try expect(routing.enabled && system.handlers.values.allSatisfy{$0.path == app.path},"Routing opt-in changes both browser schemes")
        let reopened=NotionLinkRouting(directory:directory,system:system,application:app,canConfigure:true)
        try expect(reopened.browser(for:URL(string:"https://example.test")!)?.path == original.path,"Non-Notion links retain the original browser across restart without looping")
        await reopened.setEnabled(false)
        try expect(!reopened.enabled && system.handlers.values.allSatisfy{$0.path == original.path},"Routing off restores both saved browser handlers")
        await routing.setEnabled(true)
        system.handlers["https"]=other
        await routing.setEnabled(false)
        try expect(system.handlers["https"]?.path == other.path && system.handlers["http"]?.path == original.path,"Routing off preserves a newer user choice of browser")
        let failing=System(original);failing.failOnce="http"
        let failure=NotionLinkRouting(directory:root.appendingPathComponent("routing-failure"),system:failing,application:app,canConfigure:true)
        await failure.setEnabled(true)
        try expect(!failure.enabled && failing.handlers.values.allSatisfy{$0.path == original.path} && failure.message != nil,"Declined OS changes roll back partial routing and retain a useful error")
    }
}
