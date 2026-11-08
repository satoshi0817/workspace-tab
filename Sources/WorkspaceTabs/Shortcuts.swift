import AppKit
import SwiftUI
import Carbon

struct ShortcutStroke: Codable, Equatable {
    var key:String
    var code:UInt16
    var modifiers:UInt
    var modifierOnly:Bool = false
    var label:String {ShortcutBinding(key:key,code:code,modifiers:modifiers).label}
}
struct ShortcutBinding: Codable, Equatable {
    var sequence:[ShortcutStroke]?
    var strokes:[ShortcutStroke] {sequence ?? [ShortcutStroke(key:key,code:code,modifiers:modifiers)]}

    var key: String
    var code: UInt16
    var modifiers: UInt
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var label: String {
        if let sequence {return sequence.map(\.label).joined(separator:" → ")}
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (key == "\t" ? "Tab" : key == " " ? "Space" : key == "\u{F702}" ? "←" : key == "\u{F703}" ? "→" : key.uppercased())
    }
    var carbon: UInt32 {
        UInt32((flags.contains(.command) ? cmdKey : 0) | (flags.contains(.option) ? optionKey : 0) | (flags.contains(.control) ? controlKey : 0) | (flags.contains(.shift) ? shiftKey : 0))
    }
}
struct ShortcutAction: Identifiable {
    var id: String
    var title: String
    var initial: ShortcutBinding
    var globalID: UInt32?
}
@MainActor final class ShortcutPreferences: ObservableObject {
    static let shared = ShortcutPreferences()
    static let changed = Notification.Name("WorkspaceShortcutsChanged")
    static let recording = Notification.Name("WorkspaceShortcutRecording")
    static let actions: [ShortcutAction] = {
        let local: [(String,String,String,Int,NSEvent.ModifierFlags)] = [
            ("new","新しいブラウザタブ","t",17,.command), ("close","ブラウザタブを閉じる","w",13,.command),
            ("reopen","閉じたタブを戻す","t",17,[.command,.shift]), ("location","URLを入力","l",37,.command),
            ("reload","再読み込み","r",15,.command), ("favorites","お気に入りランチャー","l",37,[.command,.shift]),
            ("copyURL","現在のURLをコピー","c",8,[.command,.shift]), ("settings","設定…",",",43,.command),
            ("show","ブラウザを表示","0",29,.command), ("fullscreen","フルスクリーンを切り替える","f",3,[.control,.command]),
            ("quit","Workspace Tabsを終了…","q",12,.command),
            ("recentTabs","最近使ったタブを切り替える","\t",48,.control),
            ("commands","コマンドを検索","p",35,[.command,.shift]),
            ("lastWorkspace","直前のアプリタブ","b",11,[.command,.option]),
            ("previousPage","前のブラウザタブ","[",33,[.command,.shift]),
            ("nextPage","次のブラウザタブ","]",30,[.command,.shift]),
            ("home","HOMEを新しいタブで開く","h",4,[.command,.shift]),
            ("focusSplit","Splitの操作対象を切り替える","j",38,[.command,.option]),
            ("toggleSplit","Split Viewを開始・解除","s",1,[.command,.option]),
            ("addFavorite","お気に入りに追加","d",2,.command),
            ("copyTitleLink","タイトル付きリンクをコピー","c",8,[.command,.option,.shift]),
            ("notionChat","Notion：新規AIチャット","a",0,[.command,.option]),
            ("notionPage","Notion：新規ページ","n",45,[.command,.option]),
            ("notionMeeting","Notion：新規ミーティングノート","m",46,[.command,.option]),
            ("notionSearch","Notion内を検索","k",40,[.command,.option]),
            ("notionSettings","Notion：設定を開く",",",43,[.command,.option])]

        var result = local.map { ShortcutAction(id:$0.0,title:$0.1,initial:ShortcutBinding(key:$0.2,code:UInt16($0.3),modifiers:$0.4.rawValue)) }
        result.append(ShortcutAction(id:"previousWorkspace",title:"前のアプリタブ",initial:ShortcutBinding(key:"\u{F702}",code:123,modifiers:NSEvent.ModifierFlags([.command,.option]).rawValue)))
        result.append(ShortcutAction(id:"nextWorkspace",title:"次のアプリタブ",initial:ShortcutBinding(key:"\u{F703}",code:124,modifiers:NSEvent.ModifierFlags([.command,.option]).rawValue)))
        result.append(ShortcutAction(id:"search",title:"すべてのタブを検索",initial:ShortcutBinding(key:" ",code:49,modifiers:NSEvent.ModifierFlags([.control,.option]).rawValue),globalID:3))
        for (index,code) in [18,19,20,21,23,22,26,28,25].enumerated() {
            result.append(ShortcutAction(id:"workspace\(index+1)",title:"アプリタブ \(index+1)",initial:ShortcutBinding(key:String(index+1),code:UInt16(code),modifiers:NSEvent.ModifierFlags([.control,.option]).rawValue),globalID:UInt32(index+11)))
        }
        return result
    }()
    @Published private(set) var overrides: [String:ShortcutBinding]
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) { self.defaults=defaults;overrides = defaults.data(forKey:"shortcutOverrides").flatMap { try? JSONDecoder().decode([String:ShortcutBinding].self,from:$0) } ?? [:] }
    func binding(_ action:ShortcutAction)->ShortcutBinding { overrides[action.id] ?? action.initial }
    func set(_ value:ShortcutBinding,for action:ShortcutAction)->String? {
        let strokes=value.strokes
        guard !strokes.isEmpty,strokes.count <= 4 else{return "1〜4ストロークを記録してください。"}
        if strokes.count == 1 && strokes[0].modifierOnly {return "修飾キー単独は2回以上の連続入力にしてください。"}
        for stroke in strokes {
            let flags=NSEvent.ModifierFlags(rawValue:stroke.modifiers)
            guard !flags.intersection([.command,.control,.option]).isEmpty else {return "Command・Control・Optionのいずれかを含めてください。"}
            if !stroke.modifierOnly && flags == .command && ["c","v","x","a","z","h"].contains(stroke.key) {return "macOS標準の編集・非表示操作に使われています。"}
        }
        if action.globalID != nil && strokes.count > 1 && strokes.contains(where:{!$0.modifierOnly}) {return "他アプリでも使う連続入力は、⌘ → ⌘など修飾キーだけで登録してください。"}
        if let other=Self.actions.first(where:{other in
            guard other.id != action.id else{return false}
            let existing=binding(other).strokes
            return Array(existing.prefix(strokes.count)) == strokes || Array(strokes.prefix(existing.count)) == existing
        }) {return "「\(other.title)」と重複するか、同じ入力で始まっています。"}
        overrides[action.id]=value; persist();return nil
    }
    static var numberedActions:[ShortcutAction] {actions.filter{$0.id.hasPrefix("workspace")}}
    var workspaceModifiers:NSEvent.ModifierFlags? {
        let values=Self.numberedActions.map{binding($0)}
        guard let first=values.first,zip(values,Self.numberedActions).allSatisfy({$0.0.sequence == nil && $0.0.code == $0.1.initial.code && $0.0.modifiers == first.modifiers}) else{return nil}
        return first.flags
    }
    func setWorkspaceModifiers(_ flags:NSEvent.ModifierFlags,reset:Bool=false)->String? {
        guard !flags.intersection([.command,.control,.option]).isEmpty else{return "⌘・⌃・⌥から1つ以上選んでください。"}
        var next=overrides
        for action in Self.numberedActions {
            var value=action.initial;value.modifiers=flags.rawValue
            for other in Self.actions where !other.id.hasPrefix("workspace") {
                if binding(other).strokes.first == value.strokes.first {return "「\(other.title)」と重複しています。変更は適用していません。"}
            }
            if reset {next.removeValue(forKey:action.id)} else {next[action.id]=value}
        }
        overrides=next;persist();return nil
    }
    func reset(_ action:ShortcutAction)->String? {
        if let error=set(action.initial,for:action) {return error}
        overrides.removeValue(forKey:action.id);persist();return nil
    }
    private func persist(){ defaults.set(try? JSONEncoder().encode(overrides),forKey:"shortcutOverrides");NotificationCenter.default.post(name:Self.changed,object:nil) }
}
// A modifier tap is emitted only on release, and never after a chord or click.
final class ShortcutStrokeRecorder {
    private var held:NSEvent.ModifierFlags=[]
    private var chord=false
    func reset(){held=[];chord=false}
    func consume(_ event:NSEvent)->ShortcutStroke? {
        let flags=event.modifierFlags.intersection([.command,.option,.control,.shift])
        if event.type == .leftMouseDown || event.type == .rightMouseDown {chord=true;return nil}
        if event.type == .flagsChanged {
            if flags.isEmpty {
                defer{reset()}
                if !chord && !held.isEmpty {return ShortcutStroke(key:"",code:0,modifiers:held.rawValue,modifierOnly:true)}
            } else if held.isEmpty {held=flags;chord=false} else if flags.rawValue != held.rawValue {chord=true}
            return nil
        }
        guard event.type == .keyDown,!event.isARepeat else{return nil}
        chord=true
        if event.keyCode == 48 {return ShortcutStroke(key:"\t",code:48,modifiers:flags.rawValue)}
        if event.keyCode == 123 || event.keyCode == 124 {return ShortcutStroke(key:event.keyCode == 123 ? "\u{F702}":"\u{F703}",code:event.keyCode,modifiers:flags.rawValue)}
        guard let key=event.characters(byApplyingModifiers: [])?.lowercased(),key.count == 1,key.unicodeScalars.allSatisfy({$0.value >= 32 && $0.value < 127}) else{return nil}
        return ShortcutStroke(key:key,code:event.keyCode,modifiers:flags.rawValue)
    }
}
@MainActor final class ShortcutSequenceMonitor {
    private var local:Any?
    private var global:Any?
    private var observer:NSObjectProtocol?
    private let recorder=ShortcutStrokeRecorder()
    private var buffer:[ShortcutStroke]=[]
    private var last=Date.distantPast
    private var suspended=false
    private let preferences:ShortcutPreferences
    init(preferences:ShortcutPreferences? = nil) {self.preferences=preferences ?? .shared}
    var action:((ShortcutAction)->Void)?
    var canHandleLocal:(()->Bool)?
    static func localAction(for event:NSEvent,preferences:ShortcutPreferences)->ShortcutAction? {
        guard event.type == .keyDown,!event.isARepeat else{return nil}
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        return ShortcutPreferences.actions.first { action in
            let binding=preferences.binding(action)
            return action.globalID == nil && binding.sequence == nil &&
                binding.code == event.keyCode && binding.flags == flags
        }
    }
    func start(){
        observer=NotificationCenter.default.addObserver(forName:ShortcutPreferences.recording,object:nil,queue:.main){[weak self] note in
            MainActor.assumeIsolated {self?.suspended=note.object as? Bool == true;self?.buffer=[];self?.recorder.reset()}
        }
        let mask:NSEvent.EventTypeMask=[.keyDown,.flagsChanged,.leftMouseDown,.rightMouseDown]
        local=NSEvent.addLocalMonitorForEvents(matching:mask){[weak self] event in
            guard let self else{return event}
            return self.handle(event,global:false) && event.type == .keyDown ? nil:event
        }
        global=NSEvent.addGlobalMonitorForEvents(matching:mask){[weak self] event in _=self?.handle(event,global:true)}
    }
    func resetInput(){buffer=[];recorder.reset()}
    func handle(_ event:NSEvent,global:Bool)->Bool {
        guard !suspended else{return false}
        if !global, canHandleLocal?() == false {buffer=[];recorder.reset();return false}
        // Resolve app commands before WebKit's asynchronous key-equivalent path.
        // Carbon continues to own global single chords, avoiding double delivery.
        if !global,let command=Self.localAction(for:event,preferences:preferences) {
            _=recorder.consume(event);buffer=[];action?(command);return true
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {buffer=[]}
        guard let stroke=recorder.consume(event) else{return false}
        if Date().timeIntervalSince(last)>1.2 {buffer=[]};last=Date()
        buffer.append(stroke);if buffer.count>4 {buffer.removeFirst()}
        let candidates=ShortcutPreferences.actions.filter{(!global || $0.globalID != nil) && preferences.binding($0).sequence != nil}
        for candidate in candidates {
            let steps=preferences.binding(candidate).strokes
            if buffer.suffix(steps.count).elementsEqual(steps) {buffer=[];action?(candidate);return true}
        }
        return candidates.contains{candidate in
            let steps=preferences.binding(candidate).strokes
            return (1..<steps.count).contains{count in buffer.suffix(count).elementsEqual(steps.prefix(count))}
        }
    }
}
struct ShortcutSettings:View {
    @ObservedObject private var preferences=ShortcutPreferences.shared
    @State private var recording:ShortcutAction?
    @State private var monitor:Any?
    @State private var message=""
    @State private var numberFlags:NSEvent.ModifierFlags=[.control,.option]
    @State private var strokes:[ShortcutStroke]=[]
    @State private var recorder=ShortcutStrokeRecorder()
    var body:some View {
        Section {
            Text("記録を押し、キーを入力して登録します。同時押し・⌘ → ⌘などの連続入力（最大4回）に対応。実行時は各入力を1.2秒以内に続けます。Escでキャンセル。").font(.caption).foregroundStyle(.secondary)
            Text("アプリタブ切替と検索は他アプリでも有効です。他アプリでの連続入力にはmacOSのアクセシビリティ許可が必要です。").font(.caption).foregroundStyle(.secondary)
            if recording != nil {
                VStack(alignment:.leading,spacing:10){
                    Text(recording!.title).font(.headline)
                    Text(strokes.isEmpty ? "キーを押してください…":strokes.map(\.label).joined(separator:" → ")).monospaced()
                    HStack {
                        Button("やり直す"){strokes=[];recorder.reset()}
                        Button("キャンセル"){stop()}
                        Spacer()
                        Button("登録") {save()}.disabled(strokes.isEmpty)
                    }
                }.padding(.vertical,6)
            }
            if !message.isEmpty {Text(message).foregroundStyle(.orange).font(.caption)}
            VStack(alignment:.leading,spacing:10) {
                Text("数字でアプリタブを開く").font(.headline)
                Text(preferences.workspaceModifiers.map{ShortcutBinding(key:"1〜9",code:0,modifiers:$0.rawValue).label} ?? "現在はタブごとに個別設定").foregroundStyle(.secondary)
                HStack {
                    modifierToggle("⌘ Command",.command)
                    modifierToggle("⌃ Control",.control)
                    modifierToggle("⌥ Option",.option)
                    modifierToggle("⇧ Shift",.shift)
                }
                HStack {
                    Button("適用") {message=preferences.setWorkspaceModifiers(numberFlags) ?? ""}.disabled(recording != nil)
                    Button("初期値に戻す") {message=preferences.setWorkspaceModifiers([.control,.option],reset:true) ?? "";if message.isEmpty {numberFlags=[.control,.option]}}.disabled(recording != nil)
                    Text("選んだキー ＋ 1〜9（並び順）").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical,8)
            ForEach(["アプリタブの切り替え","その他"],id:\.self){group in
                Text(group).font(.headline).padding(.top,8)
                ForEach(ShortcutPreferences.actions.filter{action in
                    if action.id.hasPrefix("workspace") {return false}
                    let switching=action.id == "previousWorkspace" || action.id == "nextWorkspace"
                    return group == "アプリタブの切り替え" ? switching:!switching
                }){ action in
                HStack {
                    Text(action.title);Spacer()
                    Text(preferences.binding(action).label).monospaced().foregroundStyle(.secondary)
                    Button("記録"){start(action)}.disabled(recording != nil)
                    Button {message=preferences.reset(action) ?? ""} label:{Image(systemName:"arrow.counterclockwise")}.disabled(preferences.overrides[action.id] == nil || recording != nil).help("この操作だけ初期値に戻す").accessibilityLabel(action.title+"をリセット")
                }
            }
            }
        }.onAppear{numberFlags=preferences.workspaceModifiers ?? [.control,.option]}.onDisappear{stop()}
    }
    private func modifierToggle(_ title:String,_ flag:NSEvent.ModifierFlags)->some View {
        Toggle(title,isOn:Binding(get:{numberFlags.contains(flag)},set:{if $0 {numberFlags.insert(flag)} else {numberFlags.remove(flag)}})).toggleStyle(.checkbox).disabled(recording != nil)
    }
    private func save(){
        guard let action=recording,let first=strokes.first else{return}
        let sequence=strokes.count == 1 && !first.modifierOnly ? nil:strokes
        message=preferences.set(ShortcutBinding(sequence:sequence,key:first.key,code:first.code,modifiers:first.modifiers),for:action) ?? ""
        if message.isEmpty {stop()}
    }
    private func stop(){if let monitor{NSEvent.removeMonitor(monitor)};monitor=nil;recording=nil;strokes=[];recorder.reset();NotificationCenter.default.post(name:ShortcutPreferences.recording,object:false)}
    private func start(_ action:ShortcutAction){
        stop();message="";recording=action
        NotificationCenter.default.post(name:ShortcutPreferences.recording,object:true)
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.flagsChanged,.leftMouseDown,.rightMouseDown]){event in
            if event.type == .keyDown && event.keyCode == 53 {stop();return nil}
            if let stroke=recorder.consume(event) {
                if strokes.count < 4 {strokes.append(stroke)} else {message="最大4ストロークです。「やり直す」で再記録できます。"}
            }
            return event.type == .keyDown ? nil:event
        }
    }
}

extension View {
    @ViewBuilder func settingsGlass() -> some View {
        if #available(macOS 26.0, *) {self.glassEffect(.regular,in:RoundedRectangle(cornerRadius:20))}
        else {self.background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))}
    }
}
