import SwiftUI
import WorkspaceCore

extension BrowserStore {
    @discardableResult func routeLink(_ url:URL,from:PageReference?=nil,newTab:Bool=false)->Bool {
        let matches=BrowserLinkRule.candidates(for:url,rules:session.linkRules ?? [])
        guard !matches.isEmpty else{return false}
        guard matches.count == 1,let rule=matches.first,let destination=workspace(rule.workspaceID),
              rule.groupID == nil || destination.resolvedTabGroups.contains(where:{$0.id == rule.groupID}) else {
            notify(L("リンクの振り分け先を特定できません。設定の自動振り分けを確認してください。"),isError:true)
            return true // Fail closed: never load in a different login profile.
        }
        let group=rule.groupID ?? destination.id
        if let from,from.workspaceID == destination.id,let page=page(from),destination.groupID(for:page) == group,!newTab {return false}
        if !newTab,let existing=destination.pages.first(where:{Self.pageKey($0.url) == Self.pageKey(url.absoluteString) && destination.groupID(for:$0) == group}) {
            activatePage(PageReference(workspaceID:destination.id,pageID:existing.id))
        } else {
            selectWorkspace(destination.id)
            if let engine=addPage(to:destination.id,url:url.absoluteString,groupID:group) {focusedPage=PageReference(workspaceID:destination.id,pageID:engine.pageID)}
        }
        notify(L("「\(destination.name)」で開きました"));return true
    }
}
struct LinkRuleSettings:View {
    @ObservedObject var store:BrowserStore
    @State private var editing:BrowserLinkRule?
    var body:some View {
        Section(L("リンクの自動振り分け")) {
            Text(L("指定したドメインのリンクを、アプリタブとグループへ振り分けます。NotionはWorkspace IDによる判定を優先します。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.session.linkRules ?? []) {rule in
                HStack {
                    Toggle("",isOn:Binding(get:{store.session.linkRules?.first(where:{$0.id == rule.id})?.enabled ?? false},set:{enabled in
                        if let i=store.session.linkRules?.firstIndex(where:{$0.id == rule.id}) {store.session.linkRules![i].enabled=enabled;store.changed()}
                    })).labelsHidden()
                    VStack(alignment:.leading,spacing:3) {
                        Text(rule.domain)
                        Text(destination(rule)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("編集…")){editing=rule}
                    Button(L("削除")){store.session.linkRules?.removeAll{$0.id == rule.id};store.changed()}
                }
            }
            Button(L("ルールを追加…")){if let id=store.session.selectedWorkspaceID {editing=BrowserLinkRule(workspaceID:id)}}.disabled(store.session.workspaces.isEmpty)
        }.sheet(item:$editing){LinkRuleEditor(store:store,draft:$0)}
    }
    private func destination(_ rule:BrowserLinkRule)->String {
        guard let workspace=store.workspace(rule.workspaceID),let group=workspace.resolvedTabGroups.first(where:{$0.id == (rule.groupID ?? workspace.id)}) else{return L("移動先がありません")}
        return workspace.name+" · "+group.name
    }
}
private struct LinkRuleEditor:View {
    @ObservedObject var store:BrowserStore
    @State var draft:BrowserLinkRule
    @Environment(\.dismiss) private var dismiss
    private var domain:String? {BrowserLinkRule.normalizedDomain(draft.domain)}
    private var conflict:Bool {(store.session.linkRules ?? []).contains{$0.id != draft.id && BrowserLinkRule.normalizedDomain($0.domain) == domain}}
    private var notion:Bool {domain.flatMap{URL(string:"https://"+$0)}.map(BrowserAddress.isNotion) == true}
    private var validGroup:Bool {store.workspace(draft.workspaceID)?.resolvedTabGroups.contains(where:{$0.id == (draft.groupID ?? draft.workspaceID)}) == true}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("リンクのルール")).font(.title2.bold())
            Form {
                TextField(L("ドメイン（例：github.com）"),text:$draft.domain)
                Toggle(L("サブドメインも含める"),isOn:$draft.includeSubdomains)
                Picker(L("アプリタブ"),selection:$draft.workspaceID){ForEach(store.session.workspaces){Text($0.name).tag($0.id)}}
                    .onChange(of:draft.workspaceID){_,_ in draft.groupID=nil}
                Picker(L("タブグループ"),selection:Binding(get:{draft.groupID ?? draft.workspaceID},set:{draft.groupID=$0})) {
                    ForEach(store.workspace(draft.workspaceID)?.resolvedTabGroups ?? []) {Text($0.name).tag($0.id)}
                }
            }
            if conflict {Text(L("同じドメインのルールがすでにあります。")).foregroundStyle(.orange)}
            if notion {Text(L("Notionの振り分けはアプリタブのWorkspace IDで設定してください。")).foregroundStyle(.orange)}
            HStack {Spacer();Button(L("キャンセル")){dismiss()}.keyboardShortcut(.cancelAction);Button(L("保存")) {
                guard let domain else{return};draft.domain=domain
                var values=store.session.linkRules ?? []
                if let i=values.firstIndex(where:{$0.id == draft.id}){values[i]=draft}else{values.append(draft)}
                store.session.linkRules=values;store.changed();dismiss()
            }.keyboardShortcut(.defaultAction).disabled(domain == nil || conflict || notion || !validGroup)}
        }.padding(24).frame(width:500)
    }
}
