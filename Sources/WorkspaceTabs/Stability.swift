import AppKit
import SwiftUI
import WebKit
import Network
import WorkspaceCore

enum SessionRecovery {
    struct Result {let session:BrowserSession;let recovered:Bool}
    static func load(directory:URL)throws->Result? {
        let file=directory.appendingPathComponent("browser-session.json")
        var original:Data?
        if FileManager.default.fileExists(atPath:file.path) {
            original=try Data(contentsOf:file)
            if let value=try? JSONDecoder().decode(BrowserSession.self,from:original!),let valid=try? value.validated() {return Result(session:valid,recovered:false)}
            // Never silently downgrade a session written by a different version.
            if let json=try? JSONSerialization.jsonObject(with:original!) as? [String:Any],let version=json["version"] as? Int,version != 1 {throw BrowserSessionError.invalid}
        }
        let backupDir=directory.appendingPathComponent("BrowserBackups")
        let files=((try? FileManager.default.contentsOfDirectory(at:backupDir,includingPropertiesForKeys:nil)) ?? [])
            .filter{$0.pathExtension == "json"}.sorted{$0.lastPathComponent>$1.lastPathComponent}
        for candidate in files {
            guard let data=try? Data(contentsOf:candidate),let value=try? JSONDecoder().decode(BrowserSession.self,from:data),
                  let valid=try? value.validated() else{continue}
            if let original {
                let archive=directory.appendingPathComponent("Recovery")
                try FileManager.default.createDirectory(at:archive,withIntermediateDirectories:true)
                let copy=archive.appendingPathComponent(UUID().uuidString+".json")
                try original.write(to:copy,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:copy.path)
            }
            try data.write(to:file,options:.atomic)
            return Result(session:valid,recovered:true)
        }
        if original != nil || !files.isEmpty {throw BrowserSessionError.invalid}
        return nil
    }
}

/// One outstanding probe at most; a blocked main queue cannot accumulate probes.
// outstanding is confined to queue; timer is managed on the main actor.
final class MainThreadProbe: @unchecked Sendable {
    private let queue=DispatchQueue(label:"WorkspaceTabs.responsiveness",qos:.utility)
    private var timer:DispatchSourceTimer?
    private var outstanding=false
    private let report:@MainActor (Double)->Void
    init(report:@escaping @MainActor (Double)->Void){self.report=report}
    @MainActor func start() {
        let timer=DispatchSource.makeTimerSource(queue:queue)
        self.timer=timer
        timer.schedule(deadline:.now()+1,repeating:1,leeway:.milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self,!self.outstanding else{return}
            self.outstanding=true
            let start=ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self else{return}
                let delay=ProcessInfo.processInfo.systemUptime-start
                self.queue.async { [weak self] in self?.outstanding=false }
                // Exclude wake/suspension gaps and routine scheduling jitter.
                if NSApp.isActive,delay>=0.1,delay<10 {self.report(delay*1000)}
            }
        }
        timer.resume()
    }
    @MainActor func stop(){timer?.cancel();timer=nil}
    deinit {timer?.cancel()}
}

@MainActor final class PanelFocus {
    let page:PageReference?
    weak var responder:NSResponder?
    let selection:UInt
    init(page:PageReference?,responder:NSResponder?,selection:UInt){self.page=page;self.responder=responder;self.selection=selection}
}
extension BrowserStore {
    var previewsMayCapture:Bool {ProcessInfo.processInfo.systemUptime-lastInteraction>2}
    func noteInteraction(){lastInteraction=ProcessInfo.processInfo.systemUptime}
    func capturePanelFocus() {
        guard panelFocus == nil else{return}
        let ref=commandPage
        let responder=ref.flatMap{engineIfLoaded($0.pageID)?.webView.window?.firstResponder}
        panelFocus=PanelFocus(page:ref,responder:responder,selection:selectionRevision)
    }
    func restorePanelFocus() {
        guard !anyPanelPresented,let saved=panelFocus else{return}
        panelFocus=nil
        DispatchQueue.main.async { [weak self] in
            guard let self,NSApp.isActive,!self.anyPanelPresented else{return}
            let ref=self.selectionRevision == saved.selection ? saved.page:self.commandPage
            guard let ref,self.visiblePageIDs.contains(ref.pageID),let engine=self.engineIfLoaded(ref.pageID),
                  let window=engine.webView.window,window.attachedSheet == nil else{return}
            self.focusedPage=ref
            window.makeKeyAndOrderFront(nil)
            if let responder=saved.responder as? NSView,ref == saved.page,
               responder === engine.webView || responder.isDescendant(of:engine.webView) {window.makeFirstResponder(responder)}
            else {window.makeFirstResponder(engine.webView)}
        }
    }
    var anyPanelPresented:Bool {
        onboardingPresented || favoritesPresented || favoriteDraft != nil || editingBrowserTab != nil || editingWorkspace != nil ||
        pendingExternalURL != nil || helpPresented || showSettings || searchPresented || commandsPresented
    }
    func selectionChanged() {
        selectionRevision &+= 1
        guard !selectionWorkQueued else{return}
        selectionWorkQueued=true
        DispatchQueue.main.async { [weak self] in
            guard let self else{return};self.selectionWorkQueued=false
            if let ref=self.commandPage {
                self.recentPages.removeAll{$0 == ref || self.page($0) == nil}
                self.recentPages.insert(ref,at:0)
                self.recentPages=Array(self.recentPages.prefix(200))
            }
            self.cancelHiddenActions()
        }
    }
    func cancelHiddenActions() {
        for engine in loadedEngines where !visiblePageIDs.contains(engine.pageID) {engine.cancelNotionAction()}
    }
    func startRuntimeMonitoring() {
        guard networkMonitor == nil else{return}
        let monitor=NWPathMonitor();networkMonitor=monitor
        monitor.pathUpdateHandler={ [weak self] path in
            let online=path.status == .satisfied
            Task { @MainActor [weak self] in guard let self,self.networkMonitor != nil else{return};self.connectionChanged(online:online) }
        }
        monitor.start(queue:DispatchQueue(label:"WorkspaceTabs.network",qos:.utility))
        let probe=MainThreadProbe { [weak self] delay in self?.timings.add("メインスレッドの応答待ち",milliseconds:delay) }
        responsivenessProbe=probe;probe.start()
    }
    func connectionChanged(online:Bool) {
        let wasOffline=networkOffline
        networkOffline = !online
        if wasOffline && online {
            for engine in loadedEngines where visiblePageIDs.contains(engine.pageID) {engine.prepareForDisplay()}
        }
    }
    func stopRuntimeMonitoring() {
        networkMonitor?.cancel();networkMonitor=nil;responsivenessProbe?.stop();responsivenessProbe=nil
    }
    func cycleRecentTabs(backward:Bool=false) {
        if recentCandidates.isEmpty {
            let current=commandPage
            let all=session.workspaces.flatMap {workspace in workspace.pages.map{PageReference(workspaceID:workspace.id,pageID:$0.id)}}
            var seen=Set<UUID>()
            recentCandidates=([current].compactMap{$0}+recentPages+all).filter{page($0) != nil && seen.insert($0.pageID).inserted}
            guard recentCandidates.count>1 else{recentCandidates=[];notify("切り替え先のタブはありません");return}
            recentIndex=0
        }
        recentIndex=(recentIndex+(backward ? -1:1)+recentCandidates.count)%recentCandidates.count
    }
    func finishRecentTabs(commit:Bool) {
        let target=recentCandidates.indices.contains(recentIndex) ? recentCandidates[recentIndex]:nil
        recentCandidates=[];recentIndex=0
        if commit,let target,page(target) != nil {activatePage(target)}
    }
    func handleRecentEvent(_ event:NSEvent)->Bool {
        guard !recentCandidates.isEmpty else{return false}
        if event.type == .keyDown {
            if event.keyCode == 53 {finishRecentTabs(commit:false);return true}
            if event.keyCode == 36 {finishRecentTabs(commit:true);return true}
            if [48,125,126].contains(event.keyCode) {cycleRecentTabs(backward:event.keyCode == 126 || event.modifierFlags.contains(.shift));return true}
            finishRecentTabs(commit:false);return false
        }
        if event.type == .flagsChanged,let action=ShortcutPreferences.actions.first(where:{$0.id == "recentTabs"}) {
            let binding=ShortcutPreferences.shared.binding(action)
            if binding.sequence == nil,event.modifierFlags.intersection(binding.flags).isEmpty {finishRecentTabs(commit:true);return true}
        }
        return false
    }
}
struct RecentTabsOverlay:View {
    @ObservedObject var store:BrowserStore
    var body:some View {
        if !store.recentCandidates.isEmpty {
            VStack(alignment:.leading,spacing:8) {
                Text("最近使ったタブ").font(.headline)
                ScrollViewReader {proxy in
                    ScrollView {
                        VStack(spacing:4) {
                            ForEach(Array(store.recentCandidates.enumerated()),id:\.element.pageID) {index,ref in
                                Button {store.recentIndex=index;store.finishRecentTabs(commit:true)} label:{
                                    HStack {
                                        Text(store.workspace(ref.workspaceID)?.emoji ?? "")
                                        VStack(alignment:.leading) {
                                            Text(store.page(ref)?.displayTitle ?? "").lineLimit(1)
                                            Text(store.workspace(ref.workspaceID)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                                        .background(index == store.recentIndex ? Color.accentColor.opacity(0.2):Color.clear,in:RoundedRectangle(cornerRadius:8))
                                }.buttonStyle(.plain).id(index)
                            }
                        }
                    }.frame(height:min(300,CGFloat(store.recentCandidates.count)*62))
                        .onChange(of:store.recentIndex){_,value in proxy.scrollTo(value)}
                }
                Text("Tab / ↑↓で選択・修飾キーを離すかEnterで移動・Escでキャンセル").font(.caption).foregroundStyle(.primary)
            }.padding(16).frame(width:440).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)).shadow(radius:15)
        }
    }
}
