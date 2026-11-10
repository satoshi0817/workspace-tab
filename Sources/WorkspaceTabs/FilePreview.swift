import AppKit
import SwiftUI
import QuickLookUI
import WorkspaceCore

struct FilePreview:Identifiable {
    let url:URL
    var id:URL {url}
}
struct FilePreviewSheet:View {
    let file:FilePreview
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:12) {
            HStack {
                Text(file.url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button(L("開く")){NSWorkspace.shared.open(file.url)}
                Button(L("閉じる")){dismiss()}.keyboardShortcut(.cancelAction)
            }
            NativeFilePreview(url:file.url)
        }.padding(16).frame(width:700,height:540)
    }
}
private struct NativeFilePreview:NSViewRepresentable {
    let url:URL
    func makeNSView(context:Context)->QLPreviewView {
        let view=QLPreviewView(frame:.zero,style:.normal)!
        view.shouldCloseWithWindow=false;view.autostarts=false
        view.previewItem=url as NSURL
        return view
    }
    func updateNSView(_ view:QLPreviewView,context:Context) {
        if (view.previewItem as? NSURL) != url as NSURL {view.previewItem=url as NSURL}
    }
    static func dismantleNSView(_ view:QLPreviewView,coordinator:()) {view.close()}
}
extension BrowserStore {
    func previewDownload(_ record:DownloadRecord) {
        guard let url=downloads.file(for:record) else{return}
        downloadsPresented=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {[weak self] in self?.previewFile=FilePreview(url:url)}
    }
    func handleDownloadKey(_ event:NSEvent)->Bool {
        guard downloadsPresented,event.type == .keyDown,window?.attachedSheet == nil else{return false}
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        guard flags.isEmpty || (flags == .command && event.keyCode == 36) else{return false}
        let records=downloads.records
        switch event.keyCode {
        case 125,126:
            guard !records.isEmpty else{return true}
            let index=records.firstIndex{$0.id == downloads.selection} ?? 0
            downloads.selection=records[min(records.count-1,max(0,index+(event.keyCode == 125 ? 1:-1)))].id
        case 49:
            if let record=records.first(where:{$0.id == downloads.selection}) ?? records.first {previewDownload(record)}
        case 36,76:
            if let record=records.first(where:{$0.id == downloads.selection}) ?? records.first,downloads.file(for:record) != nil {
                downloadsPresented=false
                if flags == .command {downloads.reveal(record)} else {downloads.open(record)}
            }
        default:return false
        }
        return true
    }
}
