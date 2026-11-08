import AppKit
import SwiftUI
import CryptoKit
import ImageIO
import WorkspaceCore

@MainActor final class FaviconCache:ObservableObject {
    @Published private var revision=0
    private let images=NSCache<NSString,NSImage>()
    private let directory:URL
    private let session:URLSession
    private var sources:[String:String]=[:]
    private var pending:[String:Task<Void,Never>]=[:]
    private var attempted=Set<String>()
    init(directory:URL) {
        self.directory=directory.appendingPathComponent("Favicons",isDirectory:true)
        images.countLimit=256;images.totalCostLimit=4*1024*1024
        let config=URLSessionConfiguration.ephemeral
        config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.httpShouldSetCookies=false
        config.timeoutIntervalForRequest=8;config.timeoutIntervalForResource=12
        config.urlCache=URLCache(memoryCapacity:4*1024*1024,diskCapacity:0)
        session=URLSession(configuration:config)
    }
    private func key(profile:UUID,pageURL:String)->String {
        SHA256.hash(data:Data((profile.uuidString+"|"+pageURL).utf8)).map{String(format:"%02x",$0)}.joined()
    }
    func image(profile:UUID,pageURL:String)->NSImage? {
        _=revision
        return images.object(forKey:key(profile:profile,pageURL:pageURL) as NSString)
    }
    static func fallback(_ pageURL:String)->URL? {
        guard let url=BrowserAddress.url(pageURL),["https","http"].contains(url.scheme),
              var parts=URLComponents(url:url,resolvingAgainstBaseURL:false) else{return nil}
        parts.path="/favicon.ico";parts.query=nil;parts.fragment=nil
        return parts.url
    }
    func load(profile:UUID,pageURL:String,declared:String?=nil) async {
        guard let fallback=Self.fallback(pageURL) else{return}
        let key=key(profile:profile,pageURL:pageURL)
        let source=declared ?? sources[key] ?? fallback.absoluteString
        if let task=pending[key],declared == nil || sources[key] == source {await task.value;return}
        if sources[key] == source {
            if images.object(forKey:key as NSString) != nil {return}
            if declared == nil && attempted.contains(key) {return}
        }
        let changed=sources[key] != nil && sources[key] != source
        if sources.count>512 {
            let victims=Array(sources.keys.filter{$0 != key && pending[$0] == nil}.prefix(sources.count-256))
            for victim in victims {sources[victim]=nil;attempted.remove(victim)}
        }
        sources[key]=source;attempted.insert(key)
        pending[key]?.cancel()
        let file=directory.appendingPathComponent(key+".png")
        let task=Task { [weak self] in
            guard let self else{return}
            var data:Data?
            if !changed,declared == nil {
                data=await Task.detached(priority:.utility) {
                    guard let attrs=try? file.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey]),
                          (attrs.fileSize ?? 0)<=256*1024,
                          Date().timeIntervalSince(attrs.contentModificationDate ?? .distantPast)<7*86400 else{return nil as Data?}
                    return try? Data(contentsOf:file)
                }.value
            }
            var decoded=data.flatMap(Self.decode)
            if decoded == nil {
                for attempt in 0..<2 {
                    guard !Task.isCancelled else{return}
                    data=await Self.fetch(source,using:self.session)
                    decoded=data.flatMap(Self.decode)
                    if decoded == nil,source != fallback.absoluteString {
                        decoded=await Self.fetch(fallback.absoluteString,using:self.session).flatMap(Self.decode)
                    }
                    if decoded != nil {break}
                    if attempt == 0 {try? await Task.sleep(for:.milliseconds(300))}
                }
            }
            guard !Task.isCancelled,self.sources[key] == source,let icon=decoded else{return}
            self.images.setObject(icon,forKey:key as NSString,cost:64*64*4);self.attempted.remove(key);self.revision &+= 1
            if let tiff=icon.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) {
                let directory=self.directory
                await Task.detached(priority:.utility) {
                    try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    try? png.write(to:file,options:.atomic)
                    try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                    let files=((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [])
                        .filter{$0.pathExtension == "png"}.sorted {
                            ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                            ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        }
                    for old in files.dropFirst(256) {try? FileManager.default.removeItem(at:old)}
                }.value
            }
        }
        pending[key]=task;await task.value
        if sources[key] == source {pending[key]=nil}
    }
    nonisolated private static func fetch(_ source:String,using session:URLSession) async -> Data? {
        if source.hasPrefix("data:image/"),source.utf8.count<350_000,let comma=source.firstIndex(of:",") {
            let header=source[..<comma],payload=String(source[source.index(after:comma)...])
            return header.hasSuffix(";base64") ? Data(base64Encoded:payload):payload.removingPercentEncoding?.data(using:.utf8)
        }
        guard let url=BrowserAddress.url(source),["http","https"].contains(url.scheme) else{return nil}
        do {
            let (bytes,response)=try await session.bytes(from:url)
            guard let response=response as? HTTPURLResponse,(200...299).contains(response.statusCode),
                  response.expectedContentLength<=256*1024 else{return nil}
            var data=Data()
            for try await byte in bytes {
                guard !Task.isCancelled,data.count<256*1024 else{return nil}
                data.append(byte)
            }
            return data
        } catch {return nil}
    }
    static func decode(_ data:Data)->NSImage? {
        guard data.count<=256*1024 else{return nil}
        if let source=CGImageSourceCreateWithData(data as CFData,nil),
           let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:64] as CFDictionary) {
            return NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
        }
        guard let original=NSImage(data:data),original.size.width>0,original.size.height>0 else{return nil}
        let image=NSImage(size:NSSize(width:32,height:32));image.lockFocus()
        original.draw(in:NSRect(x:0,y:0,width:32,height:32));image.unlockFocus()
        return image
    }
}
struct BrowserFavicon:View {
    @ObservedObject var cache:FaviconCache
    let profile:UUID
    let pageURL:String
    var body:some View {
        Group {
            if let icon=cache.image(profile:profile,pageURL:pageURL) {Image(nsImage:icon).resizable().scaledToFit()}
            else {Image(systemName:"globe").resizable().scaledToFit().padding(1)}
        }.frame(width:18,height:18)
            .task(id:profile.uuidString+pageURL) {await cache.load(profile:profile,pageURL:pageURL)}
    }
}
