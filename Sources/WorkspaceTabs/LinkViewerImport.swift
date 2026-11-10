import Foundation
import AppKit
import WorkspaceCore

private struct LinkViewerState:Decodable {
    struct DataSet:Decodable {var links:[Link]}
    struct Link:Decodable {
        struct Category:Decodable {var name:String}
        var id:String;var sourceId:String;var name:String;var url:String;var app:String
        var category:Category?;var pinned:Bool;var emoji:String?;var iconPath:String?;var order:Double?
    }
    var data:DataSet?
}
extension BrowserStore {
    func importLinkViewerOnce(){
        let marker=directory.appendingPathComponent("link-viewer-import-v1.done")
        guard !FileManager.default.fileExists(atPath:marker.path) else{return}
        let source=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Link Viewer/state.json")
        guard FileManager.default.fileExists(atPath:source.path) else{return}
        let result=importLinkViewer()
        if result.hasPrefix(L("移行しました")),saveBeforeExit() {try? Data().write(to:marker,options:.atomic)}
    }
    @discardableResult func importLinkViewer(source:URL? = nil)->String {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Link Viewer")
        do {
            let data=try Data(contentsOf:source ?? root.appendingPathComponent("state.json"))
            guard data.count<30_000_000 else {throw BrowserSessionError.invalid}
            let state=try JSONDecoder().decode(LinkViewerState.self,from:data)
            var links=favorites,added=0,unassigned=0,skipped=0
            let iconDir=directory.appendingPathComponent("Icons")
            try FileManager.default.createDirectory(at:iconDir,withIntermediateDirectories:true)
            for entry in (state.data?.links ?? []).sorted(by:{($0.order ?? .infinity)<($1.order ?? .infinity)}) {
                let key="link-viewer:"+entry.sourceId+":"+entry.id
                guard !links.contains(where:{$0.importKey == key}) else{continue}
                guard !entry.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let url=BrowserAddress.url(entry.url) else {skipped += 1;continue}
                // Only an exact app-name match is safe across independent login environments.
                let matches=session.workspaces.filter{$0.name.caseInsensitiveCompare(entry.app) == .orderedSame}
                let destination=matches.count == 1 ? matches[0].id:UUID()
                var link=FavoriteLink(title:entry.name,url:BrowserAddress.savedURL(url),workspaceID:destination)
                link.importKey=key;link.order=entry.order;link.category=entry.category?.name ?? "";link.pinned=entry.pinned;link.emoji=entry.emoji ?? ""
                if let path=entry.iconPath {
                    let file=URL(fileURLWithPath:path).resolvingSymlinksInPath()
                    let allowed=root.appendingPathComponent("icons").resolvingSymlinksInPath().path+"/"
                    if file.path.hasPrefix(allowed),let bytes=try? Data(contentsOf:file),bytes.count<2_000_000,NSImage(data:bytes) != nil {
                        let name=UUID().uuidString+"."+file.pathExtension
                        try bytes.write(to:iconDir.appendingPathComponent(name),options:.atomic);link.iconFile=name
                    }
                }
                links.append(link);added += 1;if matches.count != 1 {unassigned += 1}
            }
            session.favorites=links;changed()
            return L("移行しました：\(added)件（開く先の未設定：\(unassigned)件、無効なURL等：\(skipped)件）")
        } catch {return L("移行できませんでした：")+error.localizedDescription}
    }
}
