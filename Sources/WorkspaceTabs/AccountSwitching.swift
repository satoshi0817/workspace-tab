import AppKit
import SwiftUI
import WebKit
import WorkspaceCore

/// A request to reopen one browser tab's Notion page as another account.
struct AccountSwitchRequest:Identifiable,Equatable {
    let id=UUID()
    let ref:PageReference
    let choices:[AccountChoice]
}

extension BrowserStore {
    /// Accounts this tab's page can be reopened as: the other Notion accounts signed in to
    /// its own login environment, then the app tab's other login environments.
    func accountSwitchChoices(for ref:PageReference) async->[AccountChoice] {
        guard let w=workspace(ref.workspaceID),let page=page(ref) else{return []}
        let own=w.profileID(for:page)
        var choices=await notionAccountChoices(in:ref.workspaceID,from:ref.pageID,profileID:own)
        for choice in accountChoices(in:ref.workspaceID) {
            guard let groupID=choice.groupID,w.profileID(forGroup:groupID) != own else{continue}
            choices.append(AccountChoice(id:choice.id,title:choice.title,detail:choice.detail,current:false,groupID:groupID,notionUserID:nil))
        }
        return choices
    }
    func openAccountSwitcher(_ target:PageReference?=nil) {
        guard let ref=target ?? commandPage,let engine=engineIfLoaded(ref.pageID),let url=engine.webView.url,NotionWorkspace.environment(url) != nil else {
            notify(L("Notionを表示しているタブで実行してください"),isError:true);return
        }
        Task {@MainActor in
            let choices=await accountSwitchChoices(for:ref)
            guard choices.contains(where:{!$0.current}) else {
                notify(L("切り替えられる別のアカウントがありません。同じログイン環境に別のNotionアカウントでログインするか、別のログイン環境のグループを作成してください"),isError:true);return
            }
            window?.makeKeyAndOrderFront(nil)
            accountSwitch=AccountSwitchRequest(ref:ref,choices:choices)
        }
    }
    func switchAccount(_ choice:AccountChoice,for ref:PageReference) {
        guard let engine=engineIfLoaded(ref.pageID),let url=engine.webView.url,NotionWorkspace.environment(url) != nil else{return}
        if let userID=choice.notionUserID,let script=NotionAccount.switchScript(userID) {
            // Same login environment: only this tab's active account changes, then the page reloads.
            engine.webView.evaluateJavaScript(script) {[weak self,weak engine] result,_ in
                guard let self,let engine,engine.webView.url == url else{return}
                guard result as? Bool == true else {self.notify(L("アカウントを切り替えられませんでした"),isError:true);return}
                engine.notionAccount.invalidate()
                engine.webView.load(URLRequest(url:url))
                self.notify(L("\(choice.title) に切り替えています"))
            }
        } else if let groupID=choice.groupID {
            // A tab's login environment is fixed when it is made, so the page opens in a tab of the other one.
            guard let child=addPage(to:ref.workspaceID,url:url.absoluteString,groupID:groupID) else{return}
            showTabGroup(groupID,in:ref.workspaceID);selectPage(child.pageID,in:ref.workspaceID)
            notify(L("\(choice.title) のタブで同じページを開きました"))
        }
    }
}

struct AccountSwitchSheet:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    let request:AccountSwitchRequest
    @Environment(\.dismiss) private var dismiss
    private var first:AccountChoice? {request.choices.first{!$0.current}}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("アカウントを切り替え")).font(.title2.weight(.semibold))
            Text(L("今のページを、選んだアカウントで開き直します。入力途中の内容は失われることがあります。")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VStack(spacing:6) {
                ForEach(Array(request.choices.enumerated()),id:\.element.id) {index,choice in row(choice,index:index)}
            }
            HStack {Spacer();Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)}
        }.padding(24).frame(width:460)
    }
    private func shortcut(_ choice:AccountChoice,index:Int)->KeyboardShortcut? {
        if choice.current {return nil}
        if choice.id == first?.id {return .defaultAction}
        return index<9 ? KeyboardShortcut(KeyEquivalent(Character(String(index+1))),modifiers:[]):nil
    }
    @ViewBuilder private func avatar(_ choice:AccountChoice)->some View {
        if let data=choice.notionUserID.flatMap({id in store.notionDirectory[id]?.avatar ?? store.engineIfLoaded(request.ref.pageID)?.notionAccount.account.flatMap{$0.id == id ? $0.avatar:nil}}),let image=NSImage(data:data),image.isValid {
            Image(nsImage:image).resizable().interpolation(.high).aspectRatio(contentMode:.fill)
        } else if choice.groupID != nil {
            Image(systemName:"person.2.fill").font(.system(size:12)).frame(maxWidth:.infinity,maxHeight:.infinity).background(.primary.opacity(0.12))
        } else {
            Text(String(choice.title.prefix(1)).uppercased()).font(.system(size:13,weight:.semibold)).frame(maxWidth:.infinity,maxHeight:.infinity).background(.primary.opacity(0.18))
        }
    }
    private func row(_ choice:AccountChoice,index:Int)->some View {
        let detail=choice.groupID != nil ? L("別のログイン環境 · 新しいタブで開きます"):choice.detail
        return Button {dismiss();store.switchAccount(choice,for:request.ref)} label:{
            HStack(spacing:12) {
                avatar(choice).frame(width:28,height:28).clipShape(Circle()).overlay(Circle().strokeBorder(.primary.opacity(0.18)))
                VStack(alignment:.leading,spacing:2) {
                    Text(choice.title).font(.system(size:13,weight:.medium)).lineLimit(1)
                    if !detail.isEmpty {Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
                }
                Spacer(minLength:12)
                if choice.current {Text(L("使用中")).font(.caption.weight(.medium)).foregroundStyle(.secondary)}
                else if choice.id == first?.id {Text("↩").font(.system(size:11,weight:.semibold,design:.monospaced)).padding(.horizontal,7).padding(.vertical,3).background(.primary.opacity(0.08),in:RoundedRectangle(cornerRadius:5,style:.continuous))}
                else if index<9 {Text(String(index+1)).font(.system(size:11,weight:.semibold,design:.monospaced)).padding(.horizontal,7).padding(.vertical,3).background(.primary.opacity(0.08),in:RoundedRectangle(cornerRadius:5,style:.continuous))}
            }.padding(.horizontal,12).padding(.vertical,10)
                .background(.primary.opacity(choice.current ? 0.03:0.07),in:RoundedRectangle(cornerRadius:10,style:.continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(choice.current).keyboardShortcut(shortcut(choice,index:index))
            .accessibilityLabel(choice.title+(choice.current ? " "+L("使用中"):""))
    }
}
