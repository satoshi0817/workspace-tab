import AppKit
import WebKit
import WorkspaceCore
import Combine

/// Downloads outlive their originating tab. WebKit keeps the original request,
/// cookies, POST body and blob data; we never fetch the URL a second time.
@MainActor final class BrowserDownloads:NSObject,ObservableObject,WKDownloadDelegate {
    private weak var store:BrowserStore?
    @Published private(set) var records:[DownloadRecord]=[]
    @Published var selection:UUID?
    private let historyURL:URL
    @MainActor private final class Job {
        let recordID=UUID()
        let download:WKDownload
        let webView:WKWebView?
        weak var window:NSWindow?
        var destination:URL?
        var temporaryDirectory:URL?
        var existingVersion:FileVersion?
        var suggestedName="download"
        var completion:((URL?)->Void)?
        init(_ download:WKDownload,window:NSWindow?) {
            self.download=download;self.webView=download.webView;self.window=window
        }
    }
    private struct FileVersion:Equatable {
        let inode:UInt64
        let size:UInt64
        let modified:Date
        static func read(_ url:URL)throws->FileVersion? {
            let fm=FileManager.default
            guard fm.fileExists(atPath:url.path) else{return nil}
            let attributes=try fm.attributesOfItem(atPath:url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let inode=attributes[.systemFileNumber] as? NSNumber,
                  let size=attributes[.size] as? NSNumber,let modified=attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileWriteFileExists)
            }
            return FileVersion(inode:inode.uint64Value,size:size.uint64Value,modified:modified)
        }
    }
    private var jobs:[ObjectIdentifier:Job]=[:]
    private var queue:[ObjectIdentifier]=[]
    private var choosing:ObjectIdentifier?
    private var panel:NSSavePanel?
    private var stopped=false
    var activeCount:Int {jobs.count}
    init(store:BrowserStore) {
        self.store=store
        historyURL=store.directory.appendingPathComponent("download-history.json")
        records=DownloadHistory.read(historyURL)
        super.init()
    }
    var runningCount:Int {records.filter(\.isActive).count}
    func progress(for record:DownloadRecord)->Progress? {jobs.values.first{$0.recordID == record.id}?.download.progress}
    func file(for record:DownloadRecord)->URL? {
        guard record.state == .completed,let url=record.fileURL,url.isFileURL,
              (try? FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType) == .typeRegular else{return nil}
        return url
    }
    func open(_ record:DownloadRecord) {
        guard let url=file(for:record) else{store?.notify(L("ファイルが見つかりません。移動または削除された可能性があります。"),isError:true);return}
        if !NSWorkspace.shared.open(url) {store?.notify(L("ファイルを開けませんでした。Finderから確認してください。"),isError:true)}
    }
    func reveal(_ record:DownloadRecord) {
        guard let url=file(for:record) else{store?.notify(L("ファイルが見つかりません。移動または削除された可能性があります。"),isError:true);return}
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func clearHistory() {records.removeAll{!$0.isActive};saveHistory()}
    func removeFromHistory(_ id:UUID) {records.removeAll{$0.id == id && !$0.isActive};saveHistory()}
    private func update(_ job:Job,_ change:(inout DownloadRecord)->Void) {
        guard let index=records.firstIndex(where:{$0.id == job.recordID}) else{return}
        change(&records[index]);records=DownloadHistory.retained(records);saveHistory()
    }
    private func saveHistory() {
        do {try DownloadHistory.write(records,to:historyURL)}
        catch {store?.notify(L("ダウンロード履歴を保存できませんでした。"),isError:true)}
    }
    func adopt(_ download:WKDownload) {
        guard !stopped else{download.cancel(nil);return}
        let job=Job(download,window:download.webView?.window ?? store?.window)
        jobs[ObjectIdentifier(download)]=job
        records.insert(DownloadRecord(id:job.recordID),at:0)
        download.delegate=self
    }
    func download(_ download:WKDownload,decideDestinationUsing response:URLResponse,suggestedFilename:String,completionHandler:@escaping(URL?)->Void) {
        let id=ObjectIdentifier(download)
        guard let job=jobs[id],!stopped else{completionHandler(nil);return}
        let name=(suggestedFilename as NSString).lastPathComponent
        job.suggestedName=name.isEmpty || name == "." || name == ".." ? "download" : name
        update(job){$0.name=job.suggestedName}
        job.completion=completionHandler;queue.append(id);chooseNext()
    }
    private func chooseNext() {
        guard !stopped,choosing == nil else{return}
        while !queue.isEmpty {
            let id=queue.removeFirst()
            guard let job=jobs[id],job.completion != nil else{continue}
            choosing=id
            let finish:(URL?)->Void = { [weak self] url in self?.selected(url,for:id) }
            if let chooser=store?.downloadDestinationChooser {chooser(job.suggestedName,finish)}
            else {
                let panel=NSSavePanel();self.panel=panel
                panel.nameFieldStringValue=job.suggestedName
                panel.canCreateDirectories=true
                panel.directoryURL=FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
                let completion:(NSApplication.ModalResponse)->Void={response in finish(response == .OK ? panel.url:nil)}
                if let window=job.window,window.isVisible,window.attachedSheet == nil {panel.beginSheetModal(for:window,completionHandler:completion)}
                else {panel.begin(completionHandler:completion)}
            }
            return
        }
    }
    private func selected(_ url:URL?,for id:ObjectIdentifier) {
        guard choosing == id else{return}
        choosing=nil;panel=nil
        defer {DispatchQueue.main.async{[weak self] in self?.chooseNext()}}
        guard let job=jobs[id],let completion=job.completion else{return}
        job.completion=nil
        guard let url else{update(job){$0.state = .cancelled};remove(id);completion(nil);return}
        do {
            guard url.isFileURL else{throw CocoaError(.fileWriteUnsupportedScheme)}
            job.existingVersion=try FileVersion.read(url)
            job.destination=url
            // WKDownload requires a non-existent file. Download to an OS-managed
            // replacement directory on the same volume, then atomically publish it.
            let temporary=try FileManager.default.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:url,create:true)
            job.temporaryDirectory=temporary
            update(job){$0.name=url.lastPathComponent;$0.fileURL=url;$0.state = .transferring}
            completion(temporary.appendingPathComponent("download"))
        } catch {update(job){$0.state = .failed;$0.error=error.localizedDescription};remove(id);completion(nil);report(error)}
    }
    func downloadDidFinish(_ download:WKDownload) {
        let id=ObjectIdentifier(download)
        guard let job=jobs[id],let target=job.destination,let temporary=job.temporaryDirectory else{return}
        defer {remove(id)}
        do {
            // A second download or another app may have written to this path while
            // the transfer was running. Never silently overwrite that newer file.
            guard try FileVersion.read(target) == job.existingVersion else{throw CocoaError(.fileWriteFileExists)}
            let file=temporary.appendingPathComponent("download")
            if job.existingVersion != nil {_ = try FileManager.default.replaceItemAt(target,withItemAt:file)}
            else {try FileManager.default.moveItem(at:file,to:target)}
            let size=(try? target.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(Int64.init)
            update(job){$0.state = .completed;$0.byteCount=size}
            store?.notify(L("保存しました：\(target.lastPathComponent)"))
        } catch {update(job){$0.state = .failed;$0.error=error.localizedDescription};report(error)}
    }
    func download(_ download:WKDownload,didFailWithError error:Error,resumeData:Data?) {
        let id=ObjectIdentifier(download)
        guard let job=jobs[id] else{return}
        let cancelled=(error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
        update(job){$0.state = cancelled ? .cancelled:.failed;$0.error=cancelled ? nil:error.localizedDescription}
        remove(id)
        if !cancelled {report(error)}
    }
    func download(_ download:WKDownload,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        // Use normal certificate and authentication handling; never bypass TLS trust.
        completionHandler(.performDefaultHandling,nil)
    }
    private func report(_ error:Error) {store?.notify(L("ダウンロードできませんでした：\(error.localizedDescription)"),isError:true)}
    private func remove(_ id:ObjectIdentifier) {
        guard let job=jobs.removeValue(forKey:id) else{return}
        job.download.delegate=nil
        queue.removeAll{$0 == id}
        if choosing == id {
            choosing=nil
            let activePanel=panel;panel=nil;activePanel?.cancel(nil)
            let completion=job.completion;job.completion=nil;completion?(nil)
            DispatchQueue.main.async{[weak self] in self?.chooseNext()}
        }
        if let directory=job.temporaryDirectory {try? FileManager.default.removeItem(at:directory)}
    }
    func shutdown() {
        guard !stopped else{return};stopped=true
        let pending=Array(jobs.values)
        for job in pending {update(job){$0.state = .interrupted}}
        jobs.removeAll();queue.removeAll();choosing=nil
        panel?.cancel(nil);panel=nil
        for job in pending {
            job.completion?(nil);job.completion=nil;job.download.delegate=nil
            job.download.cancel {_ in
                if let directory=job.temporaryDirectory {try? FileManager.default.removeItem(at:directory)}
            }
        }
    }
}
