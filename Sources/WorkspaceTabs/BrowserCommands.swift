import AppKit
import WebKit
import WorkspaceCore

@MainActor enum BrowserCommands {
    static let ids:Set<String>=["commands","lastWorkspace","previousPage","nextPage","home","focusSplit","toggleSplit","addFavorite","copyTitleLink","notionChat","notionPage","notionMeeting","notionSearch"]
}
extension BrowserStore {
    func openCommands() {
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
    func runCommand(_ id:String,target:PageReference? = nil) {
        let ref=target ?? commandPage
        if id == "commands" {openCommands();return}
        if id == "allTabs" {searchForSplit=false;searchPresented=true;return}
        if id == "lastWorkspace" {
            guard let previousWorkspaceID,workspace(previousWorkspaceID) != nil else {notify("直前のアプリタブはありません");return}
            selectWorkspace(previousWorkspaceID);return
        }
        if id == "toggleSplit" {
            if split != nil {setSplit(nil)} else {searchForSplit=true;searchPresented=true}
            return
        }
        if id == "focusSplit" {
            guard let split,let left=selected,let pid=left.selectedPageID else {notify("Split Viewを開いてください");return}
            let next=ref == split ? PageReference(workspaceID:left.id,pageID:pid):split
            focusedPage=next
            if let web=engine(next.workspaceID,next.pageID)?.webView {web.window?.makeFirstResponder(web)}
            return
        }
        guard let ref,let workspace=workspace(ref.workspaceID),let page=page(ref) else {notify("操作するタブがありません");return}
        switch id {
        case "previousPage","nextPage":
            let pages=orderedPages(in:workspace.id)
            guard let index=pages.firstIndex(where:{$0.id == ref.pageID}),!pages.isEmpty else{return}
            let offset=id == "nextPage" ? 1:-1
            let next=pages[(index+offset+pages.count)%pages.count]
            if ref == split {setSplit(PageReference(workspaceID:workspace.id,pageID:next.id));focusedPage=split}
            else {selectPage(next.id,in:workspace.id);focusedPage=PageReference(workspaceID:workspace.id,pageID:next.id)}
        case "home":
            if let child=addPage(to:workspace.id,url:workspace.homeURL),ref == split {setSplit(PageReference(workspaceID:workspace.id,pageID:child.pageID))}
        case "addFavorite":prepareFavorite(workspaceID:workspace.id,pageID:page.id)
        case "copyTitleLink":
            let title=page.displayTitle.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]").replacingOccurrences(of:"\n",with:" ")
            let url=page.url.replacingOccurrences(of:"(",with:"%28").replacingOccurrences(of:")",with:"%29")
            NSPasteboard.general.clearContents();NSPasteboard.general.setString("[\(title)](\(url))",forType:.string);notify("タイトル付きリンクをコピーしました")
        case "notionChat","notionPage","notionMeeting","notionSearch":
            guard let engine=engine(workspace.id,page.id),let url=engine.webView.url,NotionWorkspace.environment(url) != nil else {notify("Notionを表示しているタブで実行してください");return}
            engine.webView.callAsyncJavaScript(NotionActions.script,arguments:["action":id],in:nil,in:.page) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let value):
                        let response=value as? [String:Any]
                        self?.notify(response?["message"] as? String ?? "操作対象を見つけられませんでした")
                    case .failure: self?.notify("Notionの操作を実行できませんでした。読み込み完了後にお試しください")
                    }
                }
            }
        default:break
        }
    }
}
enum NotionActions {
    // Only visible, uniquely named controls are used. No private APIs, credentials,
    // automatic recording, or generic New buttons in an unrelated database.
    static let script = #"""
    if (location.protocol !== 'https:' || !['app.notion.com','app.dev.notion.com','notion.so','www.notion.so'].includes(location.hostname)) return {message:'Notionのページで実行してください'};
    const visible=e=>e.getClientRects().length>0 && getComputedStyle(e).visibility!=='hidden' && !e.disabled && e.getAttribute('aria-disabled')!=='true';
    const find=names=>[...document.querySelectorAll('button,[role="button"],[role="tab"],a')].filter(e=>visible(e) && names.some(n=>[e.getAttribute('aria-label'),e.getAttribute('title'),e.textContent?.trim()].includes(n)));
    const click=names=>{for(const name of names){const found=find([name]);if(found.length===1){found[0].click();return true;}}return false;};
    const names={notionChat:['New chat','Start new chat','新しいチャット','新規チャット'],notionPage:['New page','新規ページ','新しいページ'],notionSearch:['Search or ask','Search','検索する・質問する','検索'],notionMeeting:['New meeting note','New meeting notes','新しいミーティングノート','新規ミーティングノート']};
    const done={notionChat:'新しいAIチャットを開きました',notionPage:'新規ページの作成画面を開きました',notionSearch:'Notionの検索を開きました',notionMeeting:'ミーティングノートの作成画面を開きました'};
    if (click(names[action] || [])) return {message:done[action]};
    if (action==='notionChat' || action==='notionMeeting') {
      const section=action==='notionChat'?['Chat','チャット']:['Meetings','ミーティング'];
      const tabs=[...document.querySelectorAll('[role="tab"]')].filter(e=>visible(e) && [e.getAttribute('aria-label'),e.textContent?.trim()].some(label=>section.includes(label)));
      if(tabs.length===1) {
        tabs[0].click();
        for(let i=0;i<15;i++){await new Promise(r=>setTimeout(r,150));if(click(names[action]))return {message:done[action]};}
      }
    }
    return {message:'対応する操作を一意に見つけられませんでした。Notionのサイドバーや権限を確認してください'};
    """#
}
