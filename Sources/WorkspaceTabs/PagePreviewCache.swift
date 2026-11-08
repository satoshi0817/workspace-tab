import AppKit
import WorkspaceCore

/// Local, disposable screenshots. Identity includes the login profile and exact
/// saved URL; a preview can never stand in for another account or another page.
@MainActor final class PagePreviewCache {
    private struct Record:Codable {
        let profileID:UUID
        let pageID:UUID
        let url:String
        let capturedAt:Date
        let jpeg:Data
    }
    private let directory:URL
    private let memory=NSCache<NSString,NSData>()
    private let io=DispatchQueue(label:"WorkspaceTabs.page-previews",qos:.utility)
    private var versions:[String:UUID]=[:]
    private let byteLimit=32*1024*1024
    init(directory:URL) {
        self.directory=directory.appendingPathComponent("PagePreviews",isDirectory:true)
        memory.totalCostLimit=8*1024*1024;memory.countLimit=32
        try? FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true)
        var url=self.directory
        var values=URLResourceValues();values.isExcludedFromBackup=true
        try? url.setResourceValues(values)
    }
    private func key(_ profile:UUID,_ page:UUID)->String {profile.uuidString+"-"+page.uuidString+".preview"}
    func image(profile:UUID,page:UUID,url:String)->NSImage? {
        let name=key(profile,page)
        let data:Data
        if let cached=memory.object(forKey:name as NSString) {data=cached as Data}
        else {
            // Serialize with pending writes/deletes. Reads occur only on recovery,
            // never during ordinary live-tab switching.
            guard let stored=io.sync(execute:{try? Data(contentsOf:directory.appendingPathComponent(name))}) else{return nil}
            data=stored;memory.setObject(data as NSData,forKey:name as NSString,cost:data.count)
        }
        guard let record=try? PropertyListDecoder().decode(Record.self,from:data),
              record.profileID == profile,record.pageID == page,record.url == url,
              Date().timeIntervalSince(record.capturedAt)<7*24*3600 else{return nil}
        return NSImage(data:record.jpeg)
    }
    func save(_ image:NSImage,profile:UUID,page:UUID,url:String) {
        guard let target=BrowserAddress.url(url),["https","http"].contains(target.scheme),
              let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{return}
        let name=key(profile,page),directory=self.directory,limit=byteLimit
        let version=UUID();versions[name]=version
        io.async { [weak self] in
            let bitmap=NSBitmapImageRep(cgImage:cg)
            guard let jpeg=bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.65]) else{return}
            let existing=directory.appendingPathComponent(name)
            if let data=try? Data(contentsOf:existing),let old=try? PropertyListDecoder().decode(Record.self,from:data),
               old.profileID == profile,old.pageID == page,old.url == url,old.jpeg == jpeg {return}
            let record=Record(profileID:profile,pageID:page,url:url,capturedAt:Date(),jpeg:jpeg)
            let encoder=PropertyListEncoder();encoder.outputFormat = .binary
            guard let data=try? encoder.encode(record) else{return}
            let file=directory.appendingPathComponent(name)
            do {
                try data.write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? []
                let entries=files.filter{$0.pathExtension == "preview"}.compactMap { url -> (URL,Int,Date)? in
                    guard let value=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else{return nil}
                    return (url,value.fileSize ?? 0,value.contentModificationDate ?? .distantPast)
                }.sorted{$0.2 > $1.2}
                var bytes=0
                for (index,entry) in entries.enumerated() {
                    bytes += entry.1
                    if index>=32 || bytes>limit {try? FileManager.default.removeItem(at:entry.0)}
                }
                DispatchQueue.main.async {
                    guard let self,self.versions[name] == version else{return}
                    self.memory.setObject(data as NSData,forKey:name as NSString,cost:data.count)
                }
            } catch { /* An unavailable preview must never break the live page. */ }
        }
    }
    func remove(profile:UUID,page:UUID) {
        let name=key(profile,page),file=directory.appendingPathComponent(key(profile,page))
        versions.removeValue(forKey:name)
        memory.removeObject(forKey:name as NSString)
        io.async {try? FileManager.default.removeItem(at:file)}
    }
    func capturedAt(profile:UUID,page:UUID,url:String)->Date? {
        let file=directory.appendingPathComponent(key(profile,page))
        guard let data=io.sync(execute:{try? Data(contentsOf:file)}),let record=try? PropertyListDecoder().decode(Record.self,from:data),
              record.profileID == profile,record.pageID == page,record.url == url else{return nil}
        return record.capturedAt
    }
    func removeAll() {
        versions.removeAll();memory.removeAllObjects()
        let directory=self.directory
        io.async {
            for url in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where url.pathExtension == "preview" {try? FileManager.default.removeItem(at:url)}
        }
    }
    // Tests and orderly shutdown can drain writes without network access.
    func flush(){io.sync {}}
}
