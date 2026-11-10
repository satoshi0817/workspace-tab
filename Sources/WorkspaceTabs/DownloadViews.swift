import SwiftUI
import AppKit
import WorkspaceCore

struct DownloadsButton:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var downloads:BrowserDownloads
    var compact:Bool
    var body:some View {
        Button {store.downloadsPresented.toggle()} label:{
            HStack(spacing:8) {
                Image(systemName:"arrow.down.circle").font(.system(size:16))
                    .overlay(alignment:.topTrailing) {
                        if compact,downloads.runningCount > 0 {Circle().fill(.primary).frame(width:5,height:5).offset(x:3,y:-2)}
                    }
                if !compact {
                    Text(L("ダウンロード")).font(.system(size:12,weight:.medium))
                    Spacer(minLength:0)
                    if downloads.runningCount > 0 {Text("\(downloads.runningCount)").font(.caption.monospacedDigit()).padding(.horizontal,6).padding(.vertical,2).background(.primary.opacity(0.1),in:Capsule())}
                }
            }.padding(.horizontal,compact ? 0:10)
                .frame(width:compact ? BrowserLayout.control:nil,height:BrowserLayout.control)
                .frame(maxWidth:compact ? nil:.infinity)
                .contentShape(RoundedRectangle(cornerRadius:10))
        }.buttonStyle(.plain).help(L("ダウンロードしたファイルを表示"))
            .accessibilityLabel(L("ダウンロード"))
            .popover(isPresented:$store.downloadsPresented,arrowEdge:compact ? .bottom:.trailing) {
                DownloadsPanel(store:store,downloads:downloads)
            }
            .onChange(of:store.downloadsPresented) {_,shown in if !shown {store.restorePanelFocus()}}
    }
}

struct DownloadsPanel:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var downloads:BrowserDownloads
    @State private var fileRevision=0
    @FocusState private var listFocused:Bool
    private func selectedFile()->DownloadRecord? {downloads.records.first{$0.id == downloads.selection}}
    var body:some View {
        VStack(spacing:12) {
            HStack {
                Text(L("ダウンロード")).font(.headline)
                Spacer()
                if downloads.records.contains(where:{!$0.isActive}) {
                    Button(L("履歴を消去")){downloads.clearHistory()}.font(.caption).buttonStyle(.borderless)
                }
                Button {store.downloadsPresented=false} label:{Image(systemName:"xmark").frame(width:24,height:24)}
                    .buttonStyle(.plain).help(L("閉じる")).accessibilityLabel(L("閉じる"))
            }
            if downloads.records.isEmpty {
                VStack(spacing:10) {
                    Image(systemName:"arrow.down.circle").font(.system(size:30,weight:.light)).foregroundStyle(.secondary)
                    Text(L("ダウンロードはまだありません")).font(.callout.weight(.medium))
                    Text(L("保存したファイルがここに表示されます。")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity).frame(height:150)
            } else {
                List(selection:$downloads.selection) {
                        ForEach(downloads.records) {record in
                            DownloadRow(record:record,downloads:downloads,fileRevision:fileRevision) {
                                store.downloadsPresented=false
                            } preview:{store.previewDownload(record)}
                                .tag(record.id).listRowSeparator(.hidden)
                        }
                }.listStyle(.plain).scrollContentBackground(.hidden).frame(height: min(340,CGFloat(downloads.records.count)*80))
                    .focused($listFocused)
                    .onKeyPress(.return,phases:.down) {press in
                        guard let record=selectedFile(),downloads.file(for:record) != nil else{return .handled}
                        store.downloadsPresented=false
                        if press.modifiers.contains(.command) {downloads.reveal(record)} else {downloads.open(record)}
                        return .handled
                    }
                    .onKeyPress(.space) {if let record=selectedFile(){store.previewDownload(record)};return .handled}
                Text(L("↑↓ 選択 · Space プレビュー · Enter 開く · ⌘Enter Finder"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(L("履歴を消してもファイルは削除されません。"))
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(16).frame(width:376).foregroundStyle(Color.primary)
            .onExitCommand {store.downloadsPresented=false}
            .onAppear {downloads.selection=downloads.records.first?.id;DispatchQueue.main.async{listFocused=true}}
            .onChange(of:downloads.records.map(\.id)) {_,ids in if downloads.selection == nil || !ids.contains(downloads.selection!) {downloads.selection=ids.first}}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in fileRevision += 1}
    }
}

private struct DownloadRow:View {
    let record:DownloadRecord
    @ObservedObject var downloads:BrowserDownloads
    let fileRevision:Int
    let dismiss:()->Void
    let preview:()->Void
    private var available:URL? {downloads.file(for:record)}
    private var name:String {record.name.isEmpty ? L("ファイル"):record.name}
    private var status:String {
        switch record.state {
        case .choosing:return L("保存先を選択中…")
        case .transferring:return L("ダウンロード中…")
        case .completed:return available == nil ? L("ファイルが見つかりません"):record.byteCount.map{ByteCountFormatter.string(fromByteCount:$0,countStyle:.file)} ?? L("完了")
        case .failed:return L("ダウンロードに失敗しました")
        case .cancelled:return L("キャンセル済み")
        case .interrupted:return L("中断されました")
        }
    }
    var body:some View {
        HStack(spacing:10) {
            Button {dismiss();downloads.open(record)} label:{
                HStack(spacing:10) {
                    if let file=available {
                        Image(nsImage:NSWorkspace.shared.icon(forFile:file.path)).resizable().scaledToFit().frame(width:32,height:32)
                    } else {
                        Image(systemName:record.state == .failed || record.state == .interrupted ? "exclamationmark.document":"doc")
                            .font(.system(size:24,weight:.light)).foregroundStyle(.secondary).frame(width:32,height:32)
                    }
                    VStack(alignment:.leading,spacing:4) {
                        Text(name).font(.system(size:12,weight:.medium)).lineLimit(1).truncationMode(.middle)
                        HStack(spacing:5) {
                            Text(status).lineLimit(1)
                            if !record.isActive {Text("·");Text(record.created,style:.relative).lineLimit(1)}
                        }.font(.caption2).foregroundStyle(.secondary)
                        if record.state == .transferring,let progress=downloads.progress(for:record) {
                            ProgressView(progress).labelsHidden().progressViewStyle(.linear).frame(maxWidth:.infinity)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(available == nil)
                .accessibilityLabel(available == nil ? name+"、"+status:L("ファイルを開く：\(name)"))
                .help(record.error ?? record.fileURL?.path ?? status)
            if available != nil {
                Button {dismiss();downloads.reveal(record)} label:{Image(systemName:"folder").frame(width:28,height:28)}
                    .buttonStyle(.borderless).help(L("Finderで表示")).accessibilityLabel(L("Finderで表示：\(name)"))
            }
        }.padding(8).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            .modifier(DownloadFileDrag(url:available))
            .contextMenu {
                if available != nil {
                    Button(L("プレビュー"),action:preview)
                    Button(L("開く")){dismiss();downloads.open(record)}
                    Button(L("Finderで表示")){dismiss();downloads.reveal(record)}
                    Divider()
                }
                if !record.isActive {Button(L("履歴から削除")){downloads.removeFromHistory(record.id)}}
            }
    }
}

private struct DownloadFileDrag:ViewModifier {
    let url:URL?
    @ViewBuilder func body(content:Content)->some View {
        if let url {content.onDrag{NSItemProvider(object:url as NSURL)}} else {content}
    }
}
