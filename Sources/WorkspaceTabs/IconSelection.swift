import AppKit
import SwiftUI

struct PresetIcon:Decodable,Identifiable {
    let id:String
    let title:String
    let category:String
}
@MainActor final class PresetIcons {
    static let shared=PresetIcons()
    let icons:[PresetIcon]
    private let known:Set<String>
    private let cache=NSCache<NSString,NSImage>()
    static let categories:[(id:String,title:String)]=[
        ("people","人・表情"),("animals-nature","動物・自然"),("food-drink","食べ物・飲み物"),
        ("activities","アクティビティ"),("travel-places","旅行・場所"),("objects","もの・仕事"),
        ("arrows-shapes","矢印・図形"),("symbols","記号・操作")
    ]
    private static let keywords:[String:String]=[
        "folder":"フォルダー フォルダ","document":"書類 ページ 文書","book":"本 読書","star":"星 お気に入り",
        "heart":"ハート 好き","home":"家 ホーム","house":"家 ホーム","calendar":"カレンダー 予定 日程",
        "meeting":"会議 ミーティング","chat":"チャット 会話 AI","comment":"コメント 会話","code":"コード 開発",
        "computer":"パソコン PC 開発","database":"データベース DB","table":"表 テーブル","globe":"世界 地球 web",
        "link":"リンク URL","rocket":"ロケット 開発","lightbulb":"電球 アイデア","briefcase":"仕事 ビジネス",
        "check":"チェック 完了","target":"目標 ターゲット","flag":"旗 フラグ","music":"音楽","art":"アート 絵",
        "camera":"カメラ 写真","photo":"写真 画像","cloud":"クラウド 雲","sun":"太陽","moon":"月 夜",
        "coffee":"コーヒー","cafe":"カフェ","team":"チーム","user":"ユーザー 人","people":"人 チーム",
        "settings":"設定","gear":"設定 歯車","search":"検索","tag":"タグ","pin":"ピン 固定"
    ]
    private init() {
        if let url=Bundle.main.url(forResource:"catalog",withExtension:"json",subdirectory:"NotionIcons"),
           let data=try? Data(contentsOf:url),let values=try? JSONDecoder().decode([PresetIcon].self,from:data) {icons=values}
        else {icons=[]}
        known=Set(icons.map(\.id));cache.countLimit=256;cache.totalCostLimit=8*1024*1024
    }
    func filtered(query:String,category:String)->[PresetIcon] {
        let terms=query.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().split(whereSeparator:{$0.isWhitespace})
        return icons.filter {icon in
            guard category.isEmpty || icon.category == category else{return false}
            if terms.isEmpty {return true}
            let aliases=Self.keywords.filter{icon.id.localizedCaseInsensitiveContains($0.key)}.map(\.value).joined(separator:" ")
            let haystack=icon.id+" "+icon.title+" "+aliases+" "+(Self.categories.first{$0.id == icon.category}?.title ?? "")
            return terms.allSatisfy{haystack.localizedCaseInsensitiveContains(String($0))}
        }
    }
    func image(_ id:String)->NSImage? {
        guard known.contains(id) else{return nil}
        if let cached=cache.object(forKey:id as NSString) {return cached}
        guard let url=Bundle.main.url(forResource:id,withExtension:"svg",subdirectory:"NotionIcons"),let svg=NSImage(contentsOf:url) else{return nil}
        let image=NSImage(size:NSSize(width:64,height:64))
        image.lockFocus();svg.draw(in:NSRect(x:0,y:0,width:64,height:64));image.unlockFocus();image.isTemplate=true
        cache.setObject(image,forKey:id as NSString,cost:64*64*4)
        return image
    }
}

struct IconSelectionRow:View {
    @ObservedObject var store:BrowserStore
    @Binding var file:String?
    var defaultSymbol="globe"
    @State private var picking=false
    var body:some View {
        HStack(spacing:12) {
            Group {
                if let file,let image=store.iconCache.image(directory:store.directory,name:file) {
                    Image(nsImage:image).renderingMode(image.isTemplate ? .template:.original).resizable().scaledToFit()
                } else {Image(systemName:defaultSymbol).resizable().scaledToFit().padding(3)}
            }.frame(width:24,height:24).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
            Text("アイコン")
            Spacer(minLength:4)
            Button("プリセット…") {picking=true}
                .popover(isPresented:$picking) {
                    PresetIconPicker {id in
                        if let image=PresetIcons.shared.image(id),let saved=store.saveIcon(image,template:true) {file=saved;picking=false}
                    }
                }
            Button("画像…") {if let saved=store.chooseIcon() {file=saved}}
                .help("PNG・JPEG・HEIC画像から選びます")
            if file != nil {Button("解除") {file=nil}}
        }.foregroundStyle(Color.primary)
    }
}
private struct PresetIconPicker:View {
    var choose:(String)->Void
    @State private var query=""
    @State private var category=""
    @FocusState private var searching:Bool
    private var matches:[PresetIcon] {PresetIcons.shared.filtered(query:query,category:category)}
    var body:some View {
        VStack(spacing:12) {
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("アイコンを検索",text:$query).textFieldStyle(.plain).focused($searching)
                if !query.isEmpty {Button {query=""} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).accessibilityLabel("検索をクリア")}
            }.padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
            Picker("カテゴリ",selection:$category) {
                Text("すべて").tag("")
                ForEach(PresetIcons.categories,id:\.id) {item in Text(item.title).tag(item.id)}
            }.pickerStyle(.menu)
            if matches.isEmpty {
                ContentUnavailableView.search(text:query).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns:Array(repeating:GridItem(.fixed(36),spacing:8),count:9),spacing:8) {
                        ForEach(matches) {icon in
                            Button {choose(icon.id)} label:{
                                Group {
                                    if let image=PresetIcons.shared.image(icon.id) {
                                        Image(nsImage:image).renderingMode(.template).resizable().scaledToFit().frame(width:24,height:24)
                                    } else {Image(systemName:"questionmark.square")}
                                }.frame(width:36,height:36).contentShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.borderless).help(icon.title).accessibilityLabel(icon.title)
                        }
                    }.padding(4)
                }.id(category+query)
            }
        }.foregroundStyle(Color.primary).padding(16).frame(width:430,height:390).onAppear {searching=true}
    }
}

extension BrowserStore {
    func saveIcon(_ image:NSImage,template:Bool=false)->String? {
        guard image.size.width>0,image.size.height>0 else{return nil}
        let resized=NSImage(size:NSSize(width:128,height:128));resized.lockFocus()
        let ratio=min(128/image.size.width,128/image.size.height)
        let size=NSSize(width:image.size.width*ratio,height:image.size.height*ratio)
        image.draw(in:NSRect(x:(128-size.width)/2,y:(128-size.height)/2,width:size.width,height:size.height));resized.unlockFocus()
        guard let tiff=resized.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else{return nil}
        let name=UUID().uuidString+(template ? ".template.png":".png"),dir=directory.appendingPathComponent("Icons")
        do {
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            try png.write(to:dir.appendingPathComponent(name),options:.atomic);return name
        } catch {self.error=error.localizedDescription;return nil}
    }
}
