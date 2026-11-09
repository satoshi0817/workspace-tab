import Foundation
import WorkspaceCore

private actor PaginationFixture:NotionRequesting {
    let missing:Bool
    private(set) var count=0
    init(missing:Bool){self.missing=missing}
    func request(token:String,method:String,endpoint:String,body:JSONObject?) async throws->JSONObject {
        count += 1
        return missing ? ["results":[],"has_more":true]:["results":[],"has_more":true,"next_cursor":"same"]
    }
}

private actor MalformedListFixture:NotionRequesting {
    func request(token:String,method:String,endpoint:String,body:JSONObject?) async throws->JSONObject {[: ]}
}

@MainActor enum StartupSafetyChecks {
    static func run(root:URL) async throws {
        func expect(_ condition:Bool,_ name:String)throws {
            guard condition else{throw BrowserChecks.Failure.check(name)}
            print("PASS "+name)
        }
        for status in [429,500,502,503,504] {
            let response=HTTPURLResponse(url:URL(string:"https://api.notion.com")!,statusCode:status,httpVersion:nil,headerFields:nil)!
            var caught:NotionAPIError?
            do {_=try NotionClient.decodeResponse(Data("<html>private proxy response</html>".utf8),http:response,token:"test-secret")}
            catch let error as NotionAPIError {caught=error}
            try expect(caught?.status == status && caught?.message.contains("private") == false,"HTML API error preserves HTTP \(status) without exposing the response body")
        }
        let success=HTTPURLResponse(url:URL(string:"https://api.notion.com")!,statusCode:200,httpVersion:nil,headerFields:nil)!
        var refusedHTML=false
        do {_=try NotionClient.decodeResponse(Data("<html>proxy login</html>".utf8),http:success,token:"test-secret")}
        catch {refusedHTML=true}
        try expect(refusedHTML,"A proxy login page cannot be mistaken for a successful empty API result")
        try expect(["nan","inf","-inf","broken"].allSatisfy{NotionClient.retryDelay($0) == 1} && NotionClient.retryDelay("9999") == 20,"Malformed Retry-After headers cannot crash numeric conversion or cause an unbounded wait")
        for missing in [false,true] {
            let fixture=PaginationFixture(missing:missing)
            let client=NotionClient(transport:fixture)
            var refused=false
            do {_=try await client.pages(token:"test-secret",id:"fixture")}
            catch {refused=true}
            let count=await fixture.count
            try expect(refused && count == (missing ? 1:2),"\(missing ? "Missing":"Repeated") pagination cursor stops sync instead of looping or accepting partial data")
        }
        for response:JSONObject in [[:],["results":[]],["has_more":false],["results":"invalid","has_more":false]] {
            var paging=NotionPagination(),rejected=false
            do {_=try paging.consume(response)}catch{rejected=true}
            try expect(rejected,"Incomplete list responses cannot be interpreted as an empty successful sync")
        }
        let protectedStore=BrowserStore(directory:root.appendingPathComponent("malformed-sync"))
        let sourceID="test-source",remoteID="test-page"
        var saved=FavoriteLink(title:"Keep this favorite",url:"https://example.com",workspaceID:protectedStore.selected!.id)
        saved.notionSourceID=sourceID;saved.notionPageID=remoteID
        protectedStore.session.favorites=[saved]
        let library=NotionLibrary(store:protectedStore,client:NotionClient(transport:MalformedListFixture()),credentials:{_ in "test-secret"})
        library.state.enabled=true;library.state.sources=[LVSource(id:sourceID,title:"Fixture",tokenId:"test")]
        library.state.tokens=[TokenInfo(id:"test",label:"Test")]
        await library.sync()
        try expect(protectedStore.favorites == [saved] && library.state.cache?.sources.first?.error != nil,"A malformed API sync preserves existing remote favorites and reports failure")
        protectedStore.shutdown()
        let directory=root.appendingPathComponent("persistent-favicons"),profile=UUID()
        let page="http://127.0.0.1:48761/cache-test",source="http://127.0.0.1:48761/icon.png"
        let original=FaviconCache(directory:directory)
        await original.load(profile:profile,pageURL:page,declared:source)
        try expect(original.image(profile:profile,pageURL:page) != nil && original.networkFetches == 1,"A declared favicon is fetched and stored locally")
        let restarted=FaviconCache(directory:directory)
        await restarted.load(profile:profile,pageURL:page,declared:source)
        try expect(restarted.image(profile:profile,pageURL:page) != nil && restarted.networkFetches == 0,"Restart reuses the declared favicon without network traffic")
        let changed=FaviconCache(directory:directory)
        await changed.load(profile:profile,pageURL:page,declared:source+"?changed=1")
        try expect(changed.networkFetches>0,"A changed favicon source never reuses mismatched cached bytes")
    }
}
