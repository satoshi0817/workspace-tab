import Foundation

struct DownloadRecord:Codable,Identifiable {
    enum State:String,Codable {case choosing,transferring,completed,failed,cancelled,interrupted}
    var id=UUID()
    var name=""
    var created=Date()
    var state:State = .choosing
    var fileURL:URL?
    var byteCount:Int64?
    // Runtime-only detail: network errors can contain private source URLs.
    var error:String?=nil
    var isActive:Bool {state == .choosing || state == .transferring}
    private enum CodingKeys:String,CodingKey {case id,name,created,state,fileURL,byteCount}
}

/// Local metadata only: never persist signed source URLs, cookies or file contents.
enum DownloadHistory {
    static let limit=100
    static func retained(_ records:[DownloadRecord])->[DownloadRecord] {
        var finished=0
        return records.filter {record in
            if record.isActive {return true}
            finished += 1;return finished <= limit
        }
    }
    static func read(_ url:URL)->[DownloadRecord] {
        guard let data=try? Data(contentsOf:url),let records=try? JSONDecoder().decode([DownloadRecord].self,from:data) else{return []}
        var seen=Set<UUID>()
        return retained(records.filter{seen.insert($0.id).inserted}.map {record in
            var record=record
            if record.isActive {record.state = .interrupted}
            if record.fileURL?.isFileURL != true {record.fileURL=nil}
            return record
        })
    }
    static func write(_ records:[DownloadRecord],to url:URL)throws {
        try JSONEncoder().encode(retained(records)).write(to:url,options:.atomic)
    }
}
