import SwiftUI
import WebKit
import WorkspaceCore

/// Verification only: tries each way JavaScript alone can open Notion's search and
/// settings on the current tab, and reports which one opened a new panel. Nothing is
/// kept beyond the result list; no page text, URL or account is recorded.
@MainActor final class NotionActionProbe:ObservableObject {
    struct Result:Identifiable {let id=UUID();let action:String;let method:String;let opened:Bool;let note:String}
    @Published var results:[Result]=[]
    @Published var running=false
    @Published var message:String?

    static let script = #"""
    const sleep=ms=>new Promise(r=>setTimeout(r,ms));
    const visible=e=>e.getClientRects().length>0 && getComputedStyle(e).visibility!=='hidden';
    const panels=()=>[...document.querySelectorAll('[role=dialog],.notion-overlay-container > *')].filter(visible).length;
    const norm=s=>(s||'').replace(/\s+/g,' ').trim();
    const names={search:['Search or ask','Search','検索する・質問する','検索'],settings:['Settings','Settings & members','設定','設定とメンバー','設定・メンバー']};
    const button=action=>[...document.querySelectorAll('[role=button],button,a')].filter(visible).find(e=>[e.getAttribute('aria-label'),e.textContent].map(norm).some(t=>names[action].includes(t)));
    const key=(target,k,code)=>{const o={key:k,code,keyCode:k.toUpperCase().charCodeAt(0),metaKey:true,bubbles:true,cancelable:true,composed:true,view:window};const d=new KeyboardEvent('keydown',o);const handled=!target.dispatchEvent(d);target.dispatchEvent(new KeyboardEvent('keyup',o));return handled?'preventDefault された（ページが受け取った）':'preventDefault なし'};
    const reactHandler=(el,names)=>{for(let n=el;n && n!==document.body;n=n.parentElement){const k=Object.keys(n).find(k=>k.startsWith('__reactProps$'));const p=k&&n[k];if(p){for(const name of names){if(typeof p[name]==='function')return [n,p[name],name]}}}return null};
    const fake=(el,type)=>({type,target:el,currentTarget:el,button:0,buttons:1,detail:1,metaKey:false,ctrlKey:false,shiftKey:false,altKey:false,clientX:0,clientY:0,isTrusted:true,nativeEvent:new MouseEvent(type),preventDefault(){},stopPropagation(){},isDefaultPrevented(){return false},isPropagationStopped(){return false},persist(){}});
    const close=async()=>{for(let i=0;i<3 && panels()>0;i++){const t=document.activeElement||document.body;t.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',keyCode:27,bubbles:true,cancelable:true}));await sleep(300)}return panels()};
    const methods={
      search:[
        ['KeyboardEvent ⌘P → document',()=>key(document,'p','KeyP')],
        ['KeyboardEvent ⌘P → window',()=>key(window,'p','KeyP')],
        ['KeyboardEvent ⌘P → 選択中の要素',()=>key(document.activeElement||document.body,'p','KeyP')],
        ['KeyboardEvent ⌘K → document',()=>key(document,'k','KeyK')],
        ['Reactのハンドラを直接呼ぶ',()=>{const b=button('search');if(!b)return 'ボタンなし';const h=reactHandler(b,['onClick','onMouseDown','onPointerDown']);if(!h)return 'ハンドラなし';h[1](fake(h[0],h[2].slice(2).toLowerCase()));return h[2]}],
        ['ボタンへ element.click()（現在の方式）',()=>{const b=button('search');if(!b)return 'ボタンなし';b.click();return ''}]],
      settings:[
        ['KeyboardEvent ⌘, → document',()=>key(document,',','Comma')],
        ['KeyboardEvent ⌘, → 選択中の要素',()=>key(document.activeElement||document.body,',','Comma')],
        ['Reactのハンドラを直接呼ぶ',()=>{const b=button('settings');if(!b)return 'サイドバーに設定ボタンなし';const h=reactHandler(b,['onClick','onMouseDown','onPointerDown']);if(!h)return 'ハンドラなし';h[1](fake(h[0],h[2].slice(2).toLowerCase()));return h[2]}],
        ['ボタンへ element.click()（現在の方式）',()=>{const b=button('settings');if(!b)return 'サイドバーに設定ボタンなし';b.click();return ''}]]};
    if(!/notion\.(so|com)$/.test(location.hostname))return {error:'Notionのページで実行してください'};
    if(await close()>0)return {error:'開いているパネルを閉じてから実行してください'};
    const out=[];
    for(const action of ['search','settings']){for(const [label,run] of methods[action]){
      const before=panels();let note='';
      try{note=String(run()??'')}catch(e){note='エラー: '+(e&&e.name||'?')}
      await sleep(900);const opened=panels()>before;
      const left=await close();if(left>0)note+=(note?' / ':'')+'閉じられませんでした';
      out.push({action,method:label,opened,note});await sleep(300);
    }}
    return {results:out};
    """#

    func run(_ engine:BrowserEngine?) {
        guard let engine,!running else {message=L("Notionのタブを表示してから実行してください");return}
        running=true;results=[];message=nil
        engine.webView.callAsyncJavaScript(Self.script,arguments:[:],in:nil,in:.page) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else{return}
                self.running=false
                switch result {
                case .success(let value):
                    let dict=value as? [String:Any]
                    if let error=dict?["error"] as? String {self.message=error;return}
                    self.results=(dict?["results"] as? [[String:Any]] ?? []).map{
                        Result(action:($0["action"] as? String) == "search" ? L("検索"):L("設定"),method:$0["method"] as? String ?? "",opened:$0["opened"] as? Bool == true,note:$0["note"] as? String ?? "")
                    }
                case .failure(let error):self.message=error.localizedDescription
                }
            }
        }
    }
    var report:String {results.map{"\($0.action)\t\($0.opened ? "OK":"NG")\t\($0.method)\t\($0.note)"}.joined(separator:"\n")}
}

struct NotionActionProbeSettings:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @StateObject private var probe=NotionActionProbe()
    var body:some View {
        Section(L("Notion操作の検証")) {
            Text(L("表示中のNotionタブで、検索と設定をJavaScriptだけで開く方法を順に試します。パネルが開いたかだけを記録し、ページの内容やURLは記録しません。途中でパネルが一瞬開閉します。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(probe.running ? L("検証中…"):L("検証を実行")) {
                    probe.run(store.commandPage.flatMap{store.engine($0.workspaceID,$0.pageID)})
                }.disabled(probe.running)
                Button(L("結果をコピー")) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(probe.report,forType:.string)}.disabled(probe.results.isEmpty)
            }
            if let message=probe.message {Text(message).font(.caption).foregroundStyle(.red)}
            ForEach(probe.results) {r in
                HStack(alignment:.top) {
                    Image(systemName:r.opened ? "checkmark.circle.fill":"xmark.circle").foregroundStyle(r.opened ? .green:.secondary)
                    Text(r.action).frame(width:36,alignment:.leading)
                    VStack(alignment:.leading) {Text(r.method);if !r.note.isEmpty {Text(r.note).foregroundStyle(.secondary)}}
                }.font(.caption)
            }
        }
    }
}
