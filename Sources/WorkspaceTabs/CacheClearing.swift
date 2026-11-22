import AppKit
import SwiftUI
import WebKit
import WorkspaceCore

extension BrowserStore {
    /// What "clear the cache" removes: stored copies of pages, scripts and images, and the
    /// service workers that serve them. Cookies, local storage and databases stay, so every
    /// site remains signed in.
    static let cacheDataTypes:Set<String>=[WKWebsiteDataTypeDiskCache,WKWebsiteDataTypeMemoryCache,WKWebsiteDataTypeFetchCache,
                                           WKWebsiteDataTypeOfflineWebApplicationCache,WKWebsiteDataTypeServiceWorkerRegistrations]
    /// Every login environment the app tab's groups use, since each keeps its own cache.
    func cacheProfileIDs(_ workspaceID:UUID)->[UUID] {
        guard let workspace=workspace(workspaceID) else{return []}
        var ids=[workspace.profileID]
        for group in workspace.resolvedTabGroups {
            let id=workspace.profileID(forGroup:group.id)
            if !ids.contains(id) {ids.append(id)}
        }
        return ids.filter{profile($0) != nil}
    }
    /// Other app tabs that share a login environment with this one, and so lose their cache too.
    func cacheSharingWorkspaces(_ workspaceID:UUID)->[BrowserWorkspace] {
        let ids=Set(cacheProfileIDs(workspaceID))
        return session.workspaces.filter{$0.id != workspaceID && !ids.isDisjoint(with:cacheProfileIDs($0.id))}
    }
    func clearCache(_ workspaceID:UUID,reload:Bool) {
        let profiles=cacheProfileIDs(workspaceID)
        guard !profiles.isEmpty,let name=workspace(workspaceID)?.name else{return}
        let group=DispatchGroup()
        for id in profiles {
            group.enter()
            dataStore(id).removeData(ofTypes:Self.cacheDataTypes,modifiedSince:.distantPast) {group.leave()}
        }
        group.notify(queue:.main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else{return}
                self.notify(L("「\(name)」のキャッシュを消去しました"))
                guard reload,let workspace=self.workspace(workspaceID),let pageID=workspace.selectedPageID,
                      let engine=self.engineIfLoaded(pageID),engine.workspaceID == workspaceID else{return}
                engine.webView.reloadFromOrigin()
            }
        }
    }
}

struct CacheClearDialog:ViewModifier {
    @ObservedObject var store:BrowserStore
    func body(content:Content)->some View {
        let workspace=store.cacheClearWorkspace.flatMap{store.workspace($0)}
        content.confirmationDialog(L("「\(workspace?.name ?? "")」のキャッシュを消去しますか？"),
                                   isPresented:Binding(get:{store.cacheClearWorkspace != nil},set:{if !$0 {store.cacheClearWorkspace=nil}}),titleVisibility:.visible) {
            if let workspace {
                Button(L("消去して再読み込み")) {store.clearCache(workspace.id,reload:true)}
                Button(L("消去のみ")) {store.clearCache(workspace.id,reload:false)}
                Button(L("キャンセル"),role:.cancel) {}
            }
        } message: {
            let shared=workspace.map{store.cacheSharingWorkspaces($0.id).map(\.name)} ?? []
            Text(L("保存済みのページ・画像・スクリプトを消去します。ログイン状態は残ります。")+(shared.isEmpty ? "":"\n"+L("同じログイン環境を使う「\(shared.joined(separator:"、"))」のキャッシュも消去されます。")))
        }
    }
}
