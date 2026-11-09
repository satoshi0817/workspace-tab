import Foundation

/// Recovery history is sampled independently of the frequently saved current session.
final class SessionHistoryArchive {
    static let interval:TimeInterval=5*60
    private let directory:URL
    private var loaded=false
    private var lastDate:Date?
    private var lastData:Data?
    init(directory:URL) {self.directory=directory.appendingPathComponent("BrowserBackups")}
    private func entries()throws->[URL] {
        guard FileManager.default.fileExists(atPath:directory.path) else{return []}
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
            .filter{$0.pathExtension == "json"}.sorted{$0.lastPathComponent>$1.lastPathComponent}
    }
    @discardableResult func record(_ data:Data,force:Bool=false,now:Date=Date())throws->Bool {
        if !loaded {
            if let latest=try entries().first {
                if let prefix=latest.lastPathComponent.split(separator:"-").first,let milliseconds=Double(prefix),milliseconds.isFinite {
                    lastDate=Date(timeIntervalSince1970:milliseconds/1000)
                }
                lastData=try Data(contentsOf:latest)
            }
            loaded=true
        }
        guard data != lastData else{return false}
        if !force,let lastDate {
            let elapsed=now.timeIntervalSince(lastDate)
            // A clock correction must not suppress backups indefinitely.
            if elapsed>=0 && elapsed<Self.interval {return false}
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let name="\(Int64(now.timeIntervalSince1970*1000))-\(UUID()).json"
        try data.write(to:directory.appendingPathComponent(name),options:.atomic)
        lastDate=now;lastData=data
        for old in try entries().dropFirst(20) {try FileManager.default.removeItem(at:old)}
        return true
    }
}
