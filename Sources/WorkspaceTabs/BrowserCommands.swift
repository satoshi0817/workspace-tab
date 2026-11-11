import AppKit
import WebKit
import WorkspaceCore

@MainActor enum BrowserCommands {
    static let ids:Set<String>=["notionCreateMenu","commands","recentTabs","lastWorkspace","previousPage","nextPage","home","focusSplit","toggleSplit","addFavorite","copyTitleLink","notionChat","notionPage","notionMeeting","notionDatabase","notionCustomPage","notionSearch","notionSettings"]
}
extension BrowserStore {
    func openCommands() {
        capturePanelFocus()
        commandTarget=commandPage
        window?.makeKeyAndOrderFront(nil)
        commandsPresented=true
    }
    func activatePage(_ ref:PageReference) {
        guard page(ref) != nil else {return}
        selectWorkspace(ref.workspaceID);selectPage(ref.pageID,in:ref.workspaceID)
        focusedPage=ref
        DispatchQueue.main.async { [weak self] in
            guard let self,let web=self.engine(ref.workspaceID,ref.pageID)?.webView else{return}
            web.window?.makeKeyAndOrderFront(nil);web.window?.makeFirstResponder(web)
        }
    }
    @discardableResult func openNotionActionTab(_ action:String,from source:PageReference)->BrowserEngine? {
        guard NotionActions.creationIDs.contains(action),let sourcePage=page(source),let workspace=workspace(source.workspaceID) else{return nil}
        if let engine=engine(source.workspaceID,source.pageID),engine.workspaceMismatch {
            notify(L("別のワークスペースを表示しています。正しい環境に移動してから作成してください"),isError:true);return nil
        }
        let sourceURL: String
        if NotionWorkspace.normalizedID(workspace.notionSpaceID) != nil,
           engine(source.workspaceID,source.pageID)?.detectedNotionSpaceID == nil {
            sourceURL=workspace.homeURL
        } else {sourceURL=sourcePage.url}
        let inSplit=split == source
        let leftPageID=selectedPage?.id
        guard let child=addPage(to:source.workspaceID,url:sourceURL,load:false,groupID:workspace.groupID(for:sourcePage)) else{return nil}
        child.navigate(sourceURL,notionAction:action)
        let destination=PageReference(workspaceID:child.workspaceID,pageID:child.pageID)
        if inSplit {
            if session.selectedWorkspaceID == source.workspaceID,let leftPageID {selectPage(leftPageID,in:source.workspaceID)}
            setSplit(destination)
        }
        focusedPage=destination
        notify(L("新しいタブでNotionを準備しています"))
        return child
    }
    func runCommand(_ id:String,target:PageReference? = nil) {
        let ref=target ?? commandPage
        if id == "recentTabs" {cycleRecentTabs();return}
        if id == "commands" {openCommands();return}
        if id == "notionCreateMenu" {openNotionCreationMenu();return}
        if id == "allTabs" {searchForSplit=false;searchPresented=true;return}
        if id == "lastWorkspace" {
            guard let previousWorkspaceID,workspace(previousWorkspaceID) != nil else {notify(L("直前のアプリタブはありません"));return}
            selectWorkspace(previousWorkspaceID);return
        }
        if id == "toggleSplit" {
            if split != nil {setSplit(nil)} else {searchForSplit=true;searchPresented=true}
            return
        }
        if id == "focusSplit" {
            guard let split,let left=selected,let pid=left.selectedPageID else {notify(L("Split Viewを開いてください"));return}
            let next=ref == split ? PageReference(workspaceID:left.id,pageID:pid):split
            focusedPage=next
            if let web=engine(next.workspaceID,next.pageID)?.webView {web.window?.makeFirstResponder(web)}
            return
        }
        guard let ref,let workspace=workspace(ref.workspaceID),let page=page(ref) else {notify(L("操作するタブがありません"));return}
        switch id {
        case "previousPage","nextPage":
            let pages=orderedPages(in:workspace.id)
            guard let index=pages.firstIndex(where:{$0.id == ref.pageID}),!pages.isEmpty else{return}
            let offset=id == "nextPage" ? 1:-1
            let next=pages[(index+offset+pages.count)%pages.count]
            if ref == split {setSplit(PageReference(workspaceID:workspace.id,pageID:next.id));focusedPage=split}
            else {selectPage(next.id,in:workspace.id);focusedPage=PageReference(workspaceID:workspace.id,pageID:next.id)}
        case "home":
            if let child=addPage(to:workspace.id,url:workspace.homeURL,groupID:workspace.groupID(for:page)),ref == split {setSplit(PageReference(workspaceID:workspace.id,pageID:child.pageID))}
        case "addFavorite":prepareFavorite(workspaceID:workspace.id,pageID:page.id)
        case "copyTitleLink":
            let title=page.displayTitle.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]").replacingOccurrences(of:"\n",with:" ")
            let url=page.url.replacingOccurrences(of:"(",with:"%28").replacingOccurrences(of:")",with:"%29")
            NSPasteboard.general.clearContents();NSPasteboard.general.setString("[\(title)](\(url))",forType:.string);notify(L("タイトル付きリンクをコピーしました"))
        case "notionChat","notionPage","notionMeeting","notionDatabase","notionCustomPage","notionSearch","notionSettings":
            guard let engine=engine(workspace.id,page.id),let url=engine.webView.url,NotionWorkspace.environment(url) != nil else {notify(L("Notionを表示しているタブで実行してください"),isError:true);return}
            if NotionActions.creationIDs.contains(id) {
                _=openNotionActionTab(id,from:ref)
            } else {engine.runNotionAction(id)}
        default:break
        }
    }
}
enum NotionActions {
    static let creationIDs:Set<String>=["notionChat","notionPage","notionMeeting","notionDatabase","notionCustomPage"]
    // Translate only messages returned by our action script, never DOM selectors or
    // text from the page. The web site's language remains independent of the app.
    static func localizedMessage(_ message:String)->String {
        for name in ["新規データベース","カスタムページ","新規AIチャット","新規ページ","新規ミーティングノート","Notion検索","Notion設定"] {
            let title=Localization.text(name)
            if message == name+"の作成先を確認できません。Home URLを対象ワークスペースの通常ページに設定してください" {
                return L("\(title)の作成先を確認できません。Home URLを対象ワークスペースの通常ページに設定してください")
            }
            if message == name+"のボタンが見つかりません。Notionのサイドバーを表示して再実行してください" {
                return L("\(title)のボタンが見つかりません。Notionのサイドバーを表示して再実行してください")
            }
        }
        return Localization.text(message)
    }
    // Only visible, uniquely named controls are used. No private APIs, credentials,
    // automatic recording, or generic New buttons in an unrelated database.
    static let script = "const readWorkspaceIdentity=()=>"+NotionWorkspace.detectionScript+";\n" + #"""
    if (location.protocol !== 'https:' || !['app.notion.com','app.dev.notion.com','notion.so','www.notion.so'].includes(location.hostname)) return {ok:false,message:'Notionのページで実行してください'};
    const visible=e=>e.getClientRects().length>0 && getComputedStyle(e).visibility!=='hidden' && !e.disabled && e.getAttribute('aria-disabled')!=='true';
    const normalize=s=>(s||'').replace(/\s+/g,' ').trim();
    const labels=e=>[e.getAttribute('aria-label'),e.getAttribute('title'),e.textContent].map(normalize);
    const names={notionDatabase:['New database','新規データベース','新しいデータベース'],notionCustomPage:['Custom page','カスタムページ'],notionChat:['New chat','Start new chat','新しいチャット','新規チャット'],notionPage:['New page','新規ページ','新しいページ'],notionSearch:['Search or ask','Search','検索する・質問する','検索'],notionSettings:['Settings','Settings & members','設定','設定とメンバー','設定・メンバー'],notionMeeting:['New meeting note','New meeting notes','新しいミーティングノート','新規ミーティングノート']};
    const done={notionDatabase:'データベースの作成画面を開きました',notionCustomPage:'カスタムページの作成画面を開きました',notionChat:'新しいAIチャットを開きました',notionPage:'新規ページの作成画面を開きました',notionSearch:'Notionの検索を開きました',notionSettings:'Notionの設定を開きました',notionMeeting:'ミーティングノートの作成画面を開きました'};
    if (!names[action]) return {ok:false,message:'未対応のNotion操作です'};
    const started=performance.now();
    const loadingNewTab=typeof waitForReady!=='undefined' && waitForReady;
    return await new Promise(resolve=>{
      let finished=false,sidebarOpened=false,sectionOpened=false,menuOpened=false,frame=0;
      let observer,timer,fallback;
      globalThis.__workspaceTabsCancelAction?.();
      const cancel=()=>finish({ok:false,cancelled:true,message:'操作をキャンセルしました'});
      const finish=response=>{
        if(finished)return;finished=true;
        if(globalThis.__workspaceTabsCancelAction===cancel)delete globalThis.__workspaceTabsCancelAction;
        observer?.disconnect();clearTimeout(timer);clearInterval(fallback);cancelAnimationFrame(frame);
        resolve({...response,elapsedMS:performance.now()-started});
      };
      globalThis.__workspaceTabsCancelAction=cancel;
      const step=()=>{
        cancelAnimationFrame(frame);frame=0;if(finished)return;
        if(['notionChat','notionPage','notionMeeting','notionDatabase','notionCustomPage'].includes(action) && typeof expectedSpaceID==='string' && expectedSpaceID){
          if(typeof expectedEnvironment==='string' && expectedEnvironment && (location.hostname==='app.dev.notion.com'?'dev':'production')!==expectedEnvironment){finish({ok:false,message:'Notionの本番・開発環境が設定と異なるため作成を中止しました'});return;}
          const identity=readWorkspaceIdentity();
          if(!identity)return;
          if(identity.spaceID!==expectedSpaceID){finish({ok:false,message:'設定と異なるワークスペースのため作成を中止しました'});return;}
        }
        const controls=[...document.querySelectorAll('button,[role="button"],[role="tab"],[role="menuitem"],a')];
        const indexed=controls.map(e=>({e,labels:labels(e)}));
        // Match labels before asking for layout: unrelated links need no visibility check.
        const click=values=>{
          const matches=indexed.filter(x=>values.some(n=>x.labels.includes(n)) && visible(x.e));
          for(const name of values){const found=matches.filter(x=>x.labels.includes(name));if(found.length===1){found[0].e.click();return true;}}
          return false;
        };
        if(click(names[action])){finish({ok:true,message:done[action]});return;}
        if(!sidebarOpened && click(['Open sidebar','Show sidebar','サイドバーを開く','サイドバーを表示'])){sidebarOpened=true;return;}
        if((action==='notionDatabase' || action==='notionCustomPage') && !menuOpened){
          // Open only the sidebar's explicit creation dropdown. Never click a generic
          // page-creation button or synthesize private routes before identity checks.
          const sidebar=document.querySelector('.notion-sidebar-container,[aria-label="Sidebar"],[aria-label="サイドバー"]');
          if(sidebar){
            const candidates=[...sidebar.querySelectorAll('[data-inp-target="sidebar-create-page"] button,[data-inp-target="sidebar-create-page"] [role="button"],button[aria-haspopup],[role="button"][aria-haspopup]')]
              .filter(e=>labels(e).some(n=>['More options','その他のオプション','その他のオプションを表示','New…','新規…'].includes(n)) && visible(e));
            if(candidates.length===1){menuOpened=true;candidates[0].click();return;}
          }
        }
        if(action==='notionSettings' && !menuOpened){
          const sidebar=document.querySelector('.notion-sidebar-container,[aria-label="Sidebar"],[aria-label="サイドバー"]');
          if(sidebar){
            const explicit=[...sidebar.querySelectorAll('.notion-sidebar-switcher,[data-testid="workspace-switcher"]')].filter(visible);
            const candidates=explicit.length ? explicit:[...sidebar.querySelectorAll('[aria-haspopup="menu"],[aria-haspopup="true"]')].filter(e=>! /new page|新規ページ|新しいページ|library|trash|help|more|ライブラリ|ゴミ箱|ヘルプ|その他/i.test(labels(e).join(' ')) && visible(e));
            if(candidates.length===1){menuOpened=true;candidates[0].click();return;}
          }
        }
        if(!sectionOpened && (action==='notionChat' || action==='notionMeeting')){
          const section=action==='notionChat'?['Chat','チャット']:['Meetings','ミーティング'];
          const tabs=controls.filter(e=>e.getAttribute('role')==='tab' && labels(e).some(value=>section.some(name=>value===name || (value.startsWith(name) && /^(?:[,、]?\s*\d+\s*(?:unread chats?|unread|件の未読.*|件)?|[,、]\s*未読.*)$/.test(value.slice(name.length))))) && visible(e));
          if(tabs.length===1){sectionOpened=true;tabs[0].click();}
        }
      };
      const schedule=()=>{if(!finished && !frame)frame=requestAnimationFrame(step);};
      observer=new MutationObserver(schedule);
      observer.observe(document,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['class','style','hidden','disabled','aria-disabled','aria-label','title','role','aria-haspopup']});
      timer=setTimeout(()=>finish({ok:false,message:({notionDatabase:'新規データベース',notionCustomPage:'カスタムページ',notionChat:'新規AIチャット',notionPage:'新規ページ',notionMeeting:'新規ミーティングノート',notionSearch:'Notion検索',notionSettings:'Notion設定'})[action]+(typeof expectedSpaceID==='string' && expectedSpaceID && !readWorkspaceIdentity() ? 'の作成先を確認できません。Home URLを対象ワークスペースの通常ページに設定してください':'のボタンが見つかりません。Notionのサイドバーを表示して再実行してください')}),loadingNewTab?12000:3500);
      // Covers CSS/layout changes with no DOM mutation and background-tab rAF throttling.
      fallback=setInterval(step,250);
      step();
    });
    """#
}
