import SwiftUI
import AppKit
import WebKit
import WorkspaceCore

struct BrowserRoot: View {
    @ObservedObject var store: BrowserStore
    @State private var query = ""
    @ObservedObject private var shortcuts=ShortcutPreferences.shared
    var body: some View {
        Group {
            if store.session.sidebarPosition == "top" {
                VStack(spacing: 0) { appTabs(horizontal: true); content }
            } else {
                HStack(spacing: 0) {
                    if store.session.sidebarMode == "hover" {
                        Rectangle().fill(activeColor).frame(width: 8).contentShape(Rectangle()).onHover { if $0 { store.hovered = true } }
                    } else { appTabs(horizontal: false).frame(width: store.session.sidebarMode == "icons" ? BrowserLayout.iconSidebar : BrowserLayout.sidebar) }
                    content
                }.overlay(alignment: .leading) {
                    if store.session.sidebarMode == "hover" && (store.hovered || store.workspaceHintsVisible) {
                        appTabs(horizontal: false).frame(width:BrowserLayout.sidebar).clipShape(RoundedRectangle(cornerRadius:BrowserLayout.pageRadius,style:.continuous)).shadow(color:.black.opacity(0.15),radius:10,x:3,y:2)
                            .onHover { inside in
                                if inside { store.hovered = true }
                                else { DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { store.hovered = false } }
                            }
                    }
                }
            }
        }.background(activeColor).frame(minWidth: 800, minHeight: 520)
            .overlay {RecentTabsOverlay(store:store)}
            .overlay(alignment:.topTrailing) {if store.networkOffline {Label("オフライン",systemImage:"wifi.slash").font(.caption).padding(8).background(.regularMaterial,in:Capsule()).padding(8).allowsHitTesting(false)}}
            .overlay(alignment: .bottom) {
                if store.workspaceHintsVisible {
                    Label(shortcuts.workspaceModifiers.map{ShortcutBinding(key:"1〜9",code:0,modifiers:$0.rawValue).label+" で切り替え"} ?? "各アプリタブのキーで切り替え",systemImage:"keyboard")
                        .font(.callout.weight(.medium)).padding(.horizontal,16).padding(.vertical,10)
                        .background(.regularMaterial,in:Capsule()).shadow(radius:4,y:2)
                        .padding(.bottom,20).allowsHitTesting(false)
                } else if let notice=store.notice {
                    Label(notice,systemImage:store.noticeIsError ? "exclamationmark.circle.fill":"checkmark.circle.fill").font(.callout)
                        .padding(.horizontal,16).padding(.vertical,10).background(.regularMaterial,in:Capsule())
                        .shadow(radius:4,y:2).padding(.bottom,20).allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $store.favoritesPresented,onDismiss:store.restorePanelFocus) { FavoritesLauncher(store: store) }
            .sheet(item: $store.favoriteDraft,onDismiss:store.restorePanelFocus) { draft in FavoriteEditor(store: store, draft: draft) }
            .sheet(item:$store.editingBrowserTab,onDismiss:store.restorePanelFocus) {ref in
                if let page=store.page(ref) {BrowserTabEditor(store:store,workspaceID:ref.workspaceID,draft:page)}
            }
            .sheet(isPresented:Binding(get:{store.pendingExternalURL != nil},set:{if !$0 {store.pendingExternalURL=nil}}),onDismiss:store.restorePanelFocus) {ExternalLinkPicker(store:store)}
            .sheet(isPresented:$store.onboardingPresented,onDismiss:store.restorePanelFocus) {BrowserOnboarding(store:store,firstRun:true)}
            .sheet(isPresented: $store.helpPresented,onDismiss:store.restorePanelFocus) { BrowserHelp(store:store) }
            .sheet(isPresented: $store.showSettings,onDismiss:store.restorePanelFocus) { BrowserSettings(store: store) }
            .sheet(item: Binding(get: { store.editingWorkspace.flatMap { store.workspace($0) } }, set: { if $0 == nil { store.editingWorkspace = nil } }),onDismiss:store.restorePanelFocus) { workspace in
                WorkspaceEditor(store: store, draft: workspace)
            }
            .sheet(isPresented: $store.searchPresented,onDismiss:store.restorePanelFocus) { AllTabsPicker(store:store) }
            .sheet(isPresented: $store.commandsPresented,onDismiss:store.restorePanelFocus) { CommandPicker(store:store) }
            .alert("Workspace Tabs",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) {
                Button("閉じる") {store.error=nil}
            } message: {Text(store.error ?? "")}
            .alert("内蔵ブラウザへ移行しました",isPresented:$store.migrationNotice) {
                Button("OK") {}
            } message: {Text("タブの名前・アイコン・色を引き継ぎました。ログイン環境はタブごとに新しく作成しています。各サイトでログインしてください。元アプリのCookieやパスワードは取り込みません。旧設定ファイルも残しています。")}
    }
    private var activeColor: Color { Palette.color(store.selected?.color ?? "violet") }
    private var activeInk: Color { Palette.ink(store.selected?.color ?? "violet", preference:store.selected?.textColor) }
    private var icons: Bool { store.session.sidebarMode == "icons" && store.session.sidebarPosition == "left" }
    @ViewBuilder private var content: some View {
        if let workspace = store.selected, let page = store.selectedPage {
            if store.detachedWorkspaceIDs.contains(workspace.id) {
                VStack(spacing:12) {
                    Image(systemName:"macwindow.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("「\(workspace.name)」は別ウインドウで開いています")
                    HStack {
                        Button("ウインドウを表示") {store.detachedControllers[workspace.id]?.window.makeKeyAndOrderFront(nil)}
                        Button("ここに戻す") {store.reattachWorkspace(workspace.id)}
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if let split = store.split, store.page(split) != nil, split.pageID != page.id {
                HSplitView {
                    BrowserPane(store:store,workspaceID:workspace.id,pageID:page.id,isRight:false).frame(minWidth:320)
                    BrowserPane(store:store,workspaceID:split.workspaceID,pageID:split.pageID,isRight:true).frame(minWidth:320)
                }
            } else { BrowserPane(store:store,workspaceID:workspace.id,pageID:page.id,isRight:false) }
        } else {
            VStack(spacing:16) { Text("アプリタブを追加").font(.title2); Button("Notionを追加") {store.addWorkspace(name:"Notion")} }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private func appTabs(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing:BrowserLayout.gap)) : AnyLayout(VStackLayout(spacing:BrowserLayout.gap))
        return layout {
            if !horizontal {
                HStack { if !icons {Text("アプリ").font(.caption.weight(.semibold)); Spacer()}; appMenu.frame(width:BrowserLayout.control,height:BrowserLayout.control) }.frame(height:BrowserLayout.control)
            }
            ScrollView(horizontal ? .horizontal : .vertical,showsIndicators:false) {
                let tabs = horizontal ? AnyLayout(HStackLayout(spacing:BrowserLayout.gap)) : AnyLayout(VStackLayout(spacing:BrowserLayout.gap))
                tabs {
                    ForEach(Array(store.session.workspaces.enumerated()),id:\.element.id) { index,workspace in
                        appTabLabel(workspace,index:index,horizontal:horizontal)
                                .contentShape(Rectangle())
                                .overlay(TabDragHandle(payload:TabDragPayload(workspaceID:workspace.id),title:workspace.name,horizontal:horizontal,drop:{payload,after in if payload.pageID == nil {store.moveWorkspace(payload.workspaceID,before:workspace.id,after:after)}},click:{store.selectWorkspace(workspace.id)}))
                            .accessibilityElement(children:.ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {store.selectWorkspace(workspace.id)}
                            .help(workspace.name+" · "+(store.profile(workspace.profileID)?.name ?? ""))
                            .accessibilityLabel(workspace.name).accessibilityAddTraits(workspace.id == store.session.selectedWorkspaceID ? .isSelected:[])
                            .contextMenu {
                                Button(store.detachedWorkspaceIDs.contains(workspace.id) ? "元のウインドウに戻す":"別ウインドウに切り離す") {
                                    if store.detachedWorkspaceIDs.contains(workspace.id) {store.reattachWorkspace(workspace.id)} else {store.detachWorkspace(workspace.id)}
                                }
                                Button("名前・色・ログイン環境…") {store.editingWorkspace=workspace.id}
                                if let pageID=workspace.selectedPageID { Button("右側に並べて表示") {store.setSplit(PageReference(workspaceID:workspace.id,pageID:pageID))}.disabled(pageID == store.selectedPage?.id) }
                                Button(workspace.pinned ? "固定を解除":"タブを固定") {var w=workspace;w.pinned.toggle();store.updateWorkspace(w)}
                                Divider(); Button("アプリタブを閉じる…",role:.destructive) {store.removeWorkspace(workspace.id)}.disabled(workspace.pinned)
                            }

                    }
                }
            }.frame(maxHeight:horizontal ? nil:.infinity)
            if !horizontal {WindowDragArea().frame(height:BrowserLayout.gap * 2)}
            let buttons=icons ? AnyLayout(VStackLayout(spacing:BrowserLayout.small)):AnyLayout(HStackLayout(spacing:BrowserLayout.small))
            buttons {
                Button {let id=store.addWorkspace();store.editingWorkspace=id} label:{Image(systemName:"plus").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("アプリタブを追加")
                Button {store.favoritesPresented=true} label:{Image(systemName:"star").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("お気に入りランチャー").accessibilityLabel("お気に入り")
                Button {store.searchForSplit=false;store.searchPresented=true} label:{Image(systemName:"magnifyingglass").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("タブを検索")
                Button {store.helpPresented=true} label:{Image(systemName:"questionmark.circle").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("使い方とショートカット").accessibilityLabel("使い方とショートカット")
                if !icons && !horizontal {Spacer()}
                if horizontal {appMenu} else {Button {store.showSettings=true} label:{Image(systemName:"gearshape").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("設定")}
            }.buttonStyle(.plain).padding(BrowserLayout.small).settingsGlass()
        }.padding(BrowserLayout.inset).foregroundStyle(activeInk).background(activeColor)
            .frame(height:horizontal ? BrowserLayout.appTab + BrowserLayout.inset * 2:nil)
    }
    private func appTabLabel(_ workspace:BrowserWorkspace,index:Int,horizontal:Bool)->some View {
        AnyView(HStack(spacing:BrowserLayout.gap) {
                                WorkspaceIcon(store:store,workspace:workspace,size:24)
                                if !icons {Text(workspace.name).font(.system(size:12,weight:workspace.id == store.session.selectedWorkspaceID ? .bold:.regular)).lineLimit(horizontal ? 1:2); if !horizontal {Spacer(minLength:0)}; if store.workspaceHintsVisible,index<9 {WorkspaceShortcutKeycap(binding:shortcuts.binding(ShortcutPreferences.numberedActions[index]),compact:false,ink:Palette.ink(workspace.color,preference:workspace.textColor),color:Palette.color(workspace.color))}}
                            }.padding(.horizontal,icons ? 0:BrowserLayout.gap).frame(height:BrowserLayout.appTab)
                                .frame(width:horizontal ? nil:icons ? BrowserLayout.appTab:BrowserLayout.sidebar - BrowserLayout.inset * 2,alignment:icons ? .center:.leading)
                                .foregroundStyle(Palette.ink(workspace.color,preference:workspace.textColor))
                                .background(Palette.color(workspace.color),in:RoundedRectangle(cornerRadius:BrowserLayout.appRadius,style:.continuous))
                                .overlay {RoundedRectangle(cornerRadius:BrowserLayout.appRadius,style:.continuous).strokeBorder(workspace.id == store.session.selectedWorkspaceID ? activeInk:.clear,lineWidth:2)}
                                .overlay(alignment:.bottomTrailing) {
                                    if icons,store.workspaceHintsVisible,index<9 {
                                        WorkspaceShortcutKeycap(binding:shortcuts.binding(ShortcutPreferences.numberedActions[index]),compact:true,
                                                                ink:Palette.ink(workspace.color,preference:workspace.textColor),color:Palette.color(workspace.color))
                                            .padding(2)
                                    }
                                }
                                .opacity(store.workspaceHintsVisible || workspace.id == store.session.selectedWorkspaceID ? 1:0.6))
    }
    private var appMenu: some View {
        Menu {
            Button("すべてのタブ…") {store.searchForSplit=false;store.searchPresented=true}
            Button("コマンド…") {store.openCommands()}
            Button("お気に入り…") {store.favoritesPresented=true}
            Button("使い方とショートカット…") {store.helpPresented=true}
            Button("設定…") {store.showSettings=true}
            Button("ウインドウを全画面表示") {store.window?.toggleFullScreen(nil)}
            Divider();Button("Workspace Tabsを終了…") {NSApp.terminate(nil)}
        } label:{Image(nsImage:Palette.menuGlyph(activeInk)).renderingMode(.original)}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("アプリのメニュー")
    }
}

struct BrowserPane: View {
    @ObservedObject var store:BrowserStore
    let workspaceID:UUID
    let pageID:UUID
    let isRight:Bool
    var detached=false
    private var pageInsets:EdgeInsets {
        // Adjacent chrome already supplies 8pt. Do not double it at shared edges.
        let splitPane = !detached && store.split != nil && store.split?.pageID != store.selectedPage?.id
        let leading:CGFloat = isRight ? BrowserLayout.small :
            (detached || store.session.sidebarPosition == "top" ? BrowserLayout.inset:0)
        return EdgeInsets(top:0,leading:leading,bottom:BrowserLayout.inset,
                          trailing:splitPane && !isRight ? BrowserLayout.small:BrowserLayout.inset)
    }
    var body:some View {
        if let engine=store.engine(workspaceID,pageID),let workspace=store.workspace(workspaceID) {
            VStack(spacing:0) {
                HStack(spacing:BrowserLayout.gap) {
                    BrowserGroupPicker(store:store,workspace:workspace)
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:BrowserLayout.small) {
                            ForEach(store.visibleGroupPages(in:workspaceID)) {page in
                                BrowserTabButton(store:store,workspace:workspace,page:page,selected:page.id == pageID,isRight:isRight,detached:detached)
                            }
                            Button {
                                store.newTabRequest=PageReference(workspaceID:workspaceID,pageID:pageID)
                            } label:{Image(systemName:"plus").frame(width:BrowserLayout.control,height:BrowserLayout.control)}
                                .help("この環境にブラウザタブを追加").accessibilityLabel("ブラウザタブを追加")
                        }.padding(.vertical,BrowserLayout.gap)
                    }.frame(maxWidth:.infinity).layoutPriority(-1)
                    WorkspaceIdentityBadge(engine:engine)
                    Button {store.focusedPage=PageReference(workspaceID:workspaceID,pageID:pageID);store.addressFocus=UUID()} label:{Image(systemName:"link").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("URLを表示").accessibilityLabel("URLを表示")
                    if detached {Button("元に戻す") {store.reattachWorkspace(workspaceID)}.help("アプリタブを元のウインドウに戻す")}
                    else if isRight {
                        Button {store.swapSplit()} label:{Image(systemName:"arrow.left.arrow.right").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("左右を入れ替え")
                        Button {store.setSplit(nil)} label:{Image(systemName:"rectangle").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.help("Split Viewを解除")
                    } else {SplitPicker(store:store)}
                }.frame(height:BrowserLayout.tabBar)
                    .padding(.horizontal,BrowserLayout.inset)
                    .background(TabGroupScrollArea(enabled:workspace.resolvedTabGroups.count>1) {offset in store.cycleTabGroup(offset,in:workspaceID)}.frame(height:BrowserLayout.tabBar))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink(workspace.color)).background(Palette.color(workspace.color))
                VStack(spacing:0) {
                    BrowserNavigation(store:store,engine:engine,isRight:isRight)
                    if workspace.pages.first(where:{$0.id == pageID})?.isStartPage == true {
                        NewBrowserTab(store:store,engine:engine).id(pageID)
                    } else {
                        BrowserSurface(store:store,engine:engine,detached:detached).id(pageID)
                    }
                }
                .background(Color(nsColor:.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius:BrowserLayout.pageRadius,style:.continuous))
                .padding(pageInsets)
                .background(Palette.color(workspace.color))
            }.simultaneousGesture(TapGesture().onEnded {store.focusedPage=PageReference(workspaceID:workspaceID,pageID:pageID)})
                .sheet(isPresented:Binding(get:{store.newTabRequest == PageReference(workspaceID:workspaceID,pageID:pageID)},set:{if !$0 {store.newTabRequest=nil}})) {
                    NewTabChoice { web in
                        store.newTabRequest=nil
                        if let child=store.addPage(to:workspaceID,startPage:web) {
                            let ref=PageReference(workspaceID:workspaceID,pageID:child.pageID)
                            if isRight {store.setSplit(ref)}
                            store.focusedPage=ref
                        }
                    } cancel:{store.newTabRequest=nil}
                }
        }
    }
}
struct BrowserNavigation:View {
    @ObservedObject var store:BrowserStore
    @ObservedObject var engine:BrowserEngine
    let isRight:Bool
    @State private var address=""
    @State private var expanded=false
    @FocusState private var editing:Bool
    var body:some View {
        VStack(spacing:0) {
            if expanded || editing {
            HStack(spacing:BrowserLayout.gap) {
                Button {engine.webView.goBack()} label:{Image(systemName:"chevron.left")}.disabled(!engine.canBack)
                Button {engine.webView.goForward()} label:{Image(systemName:"chevron.right")}.disabled(!engine.canForward)
                Button {if engine.loading {engine.stopLoading()} else {engine.webView.reload()}} label:{Image(systemName:engine.loading ? "xmark":"arrow.clockwise")}
                TextField("URL",text:$address).textFieldStyle(.roundedBorder).focused($editing).onSubmit {engine.navigate(address);editing=false;expanded=false}
                    .onExitCommand {editing=false;expanded=false;store.window?.makeFirstResponder(engine.webView)}
                Button {store.prepareFavorite(workspaceID: engine.workspaceID, pageID: engine.pageID)} label:{Image(systemName:"star")}.help("このページをお気に入りに追加").accessibilityLabel("このページをお気に入りに追加")
                if let workspace=store.workspace(engine.workspaceID) {
                    Menu {
                        Toggle("Notionのサイドバーを着色",isOn:Binding(get:{store.workspace(workspace.id)?.cssEnabled ?? false},set:{var w=store.workspace(workspace.id)!;w.cssEnabled=$0;store.updateWorkspace(w)}))
                        Button("色・濃さを調整…") {store.window?.makeKeyAndOrderFront(nil);store.editingWorkspace=workspace.id}
                        Button("標準ブラウザで開く") {if let url=engine.webView.url {NSWorkspace.shared.open(url)}}
                    } label:{Image(systemName:workspace.cssEnabled ? "paintpalette.fill":"paintpalette")}.menuStyle(.borderlessButton).fixedSize().help("ページの色")
                }
            }.buttonStyle(.plain).padding(BrowserLayout.inset)
            }
            if engine.loading {ProgressView(value:engine.progress).progressViewStyle(.linear).frame(height:2)} else {Divider()}
        }.onAppear {address=engine.address}
            .onChange(of:editing) {_,value in if !value {expanded=false}}
            .onChange(of:engine.address) {_,value in if !editing {address=value}}
            .onChange(of:store.addressFocus) {_,_ in if store.commandPage?.pageID == engine.pageID {expanded=true;DispatchQueue.main.async {editing=true}}}
    }
}
struct SplitPicker:View {
    @ObservedObject var store:BrowserStore
    var body:some View {
        Menu {
            ForEach(store.session.workspaces) {workspace in
                Menu(workspace.name) {
                    ForEach(workspace.pages) {page in
                        Button(page.title) {store.setSplit(PageReference(workspaceID:workspace.id,pageID:page.id))}.disabled(page.id == store.selectedPage?.id)
                    }
                }
            }
            if store.split != nil {Divider();Button("左右を入れ替え") {store.swapSplit()};Button("Split Viewを解除") {store.setSplit(nil)}}
        } label:{Image(systemName:"rectangle.split.2x1").frame(width:BrowserLayout.control,height:BrowserLayout.control)}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("別の環境のページを並べて表示")
    }
}
struct WorkspaceIcon:View {
    let store:BrowserStore
    let workspace:BrowserWorkspace
    let size:CGFloat
    var body:some View {
        Group {
            if let file=workspace.iconFile,file == URL(fileURLWithPath:file).lastPathComponent,let image=store.iconCache.image(directory:store.directory,name:file) {Image(nsImage:image).renderingMode(image.isTemplate ? .template:.original).resizable().scaledToFit()}
            else if !workspace.emoji.isEmpty {Text(workspace.emoji).font(.system(size:size*0.85))}
            else {Image(systemName:"globe").resizable().scaledToFit().padding(2)}
        }.frame(width:size,height:size)
    }
}
struct WindowDragArea:NSViewRepresentable {
    func makeNSView(context:Context)->NSView {DragAreaView()}
    func updateNSView(_ view:NSView,context:Context) {}
}
private final class DragAreaView:NSView {
    override func mouseDown(with event:NSEvent) {window?.performDrag(with:event)}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func resetCursorRects() {addCursorRect(bounds,cursor:.openHand)}
}

struct BrowserFailure:View {
    @ObservedObject var engine:BrowserEngine
    var body:some View {
        if let failure=engine.failure,engine.loadingState != .failed {
            HStack {Text(failure).font(.caption).lineLimit(3);Spacer();Button("再読み込み") {engine.retryLoading()}}.padding(8).background(Color.orange.opacity(0.12))
        }
    }
}

struct BrowserSurface:View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store:BrowserStore
    @ObservedObject var engine:BrowserEngine
    let detached:Bool
    var body:some View {
        VStack(spacing:0) {
            if engine.workspaceMismatch {
                HStack(spacing:8) {
                    Image(systemName:"exclamationmark.triangle")
                    Text("設定と異なるワークスペースを表示しています").font(.caption)
                    Spacer()
                    Button("一致する環境で開く"){engine.openMatchingWorkspace()}
                    Button("設定"){store.editingWorkspace=engine.workspaceID}
                }.padding(8).background(Color.orange.opacity(0.15))
            }
            BrowserFailure(engine:engine)
            ZStack(alignment:.bottom) {
                WebContent(webView:engine.webView,store:store,workspaceID:engine.workspaceID,detached:detached)
                    .allowsHitTesting(engine.loadingState == .none)
                    .accessibilityHidden(engine.loadingState != .none)
                if engine.loadingState == .loading {
                    if !engine.nativeLoadingPlaceholderVisible {
                        PageLoadingSkeleton(notion:BrowserAddress.url(engine.address).map(BrowserAddress.isNotion) ?? false,
                                            workspace:store.workspace(engine.workspaceID))
                            .allowsHitTesting(false)
                    }
                    HStack(spacing:8) {
                        ProgressView().controlSize(.small)
                        Text("読み込み直しています")
                    }.font(.caption).padding(.horizontal,16).padding(.vertical,10)
                        .background(.regularMaterial,in:Capsule()).shadow(color:.black.opacity(0.08),radius:8,y:2)
                        .padding(.bottom,24).allowsHitTesting(false)
                        .transition(.move(edge:.bottom).combined(with:.opacity))
                } else if engine.loadingState == .failed {
                    VStack(spacing:12) {
                        Image(systemName:"wifi.exclamationmark").font(.title).foregroundStyle(.secondary)
                        Text("読み込めませんでした").font(.headline)
                        if let failure=engine.failure {Text(failure).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:360)}
                        Button("再試行") {engine.retryLoading()}.buttonStyle(.bordered)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.textBackgroundColor))
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.animation(reduceMotion ? nil:.easeOut(duration:0.18),value:engine.loadingState)
            .onAppear {engine.prepareForDisplay()}
    }
}

struct WorkspaceIdentityBadge:View {
    @ObservedObject var engine:BrowserEngine
    var body:some View {
        if let label=engine.workspaceIdentityLabel {
            Image(systemName:engine.workspaceMismatch ? "exclamationmark.shield" : engine.detectedNotionSpaceID == nil ? "questionmark.circle" : "checkmark.shield")
                .help(label).accessibilityLabel(label)
        }
    }
}

struct NewBrowserTab:View {
    @ObservedObject var store:BrowserStore
    let engine:BrowserEngine
    @State private var query=""
    @State private var invalid=false
    @FocusState private var focused:Bool
    var body:some View {
        VStack(spacing:24) {
            Spacer()
                HStack(spacing:12) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("Googleで検索、またはURLを入力",text:$query)
                        .textFieldStyle(.plain).focused($focused).onSubmit(open)
                        .accessibilityLabel("検索キーワードまたはURL")
                    Button(action:open) {Image(systemName:"arrow.right.circle.fill").font(.title2)}
                        .buttonStyle(.plain).disabled(query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("開く")
                }.padding(16).background(.quaternary.opacity(0.45),in:Capsule())
                    .frame(maxWidth:540).padding(.horizontal,24)
                if invalid {Text("http / httpsのURLを入力してください。").font(.caption).foregroundStyle(.secondary)}
            Spacer()
            Spacer().frame(height:40)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(Color(nsColor:.textBackgroundColor))
            .task {
                try? await Task.sleep(for:.milliseconds(300))
                guard !Task.isCancelled else{return}
                focused=false
                focused=true
            }
    }
    private func open() {
        guard let url=BrowserAddress.searchOrURL(query) else {invalid=true;return}
        invalid=false;engine.navigate(url.absoluteString)
    }
}

struct NewTabChoice:View {
    let open:(Bool)->Void
    let cancel:()->Void
    @State private var submitted=false
    @FocusState private var focused:Bool
    private static let notionLogo=Bundle.main.url(forResource:"NotionLogo",withExtension:"png").flatMap{NSImage(contentsOf:$0)}
    var body:some View {
        VStack(spacing:20) {
            Text("新しいタブ").font(.headline)
            HStack(spacing:12) {
                choice("Notion",description:"この環境のNotionを開く\n設定したホームページに移動",key:"←",web:false)
                choice("URL・検索",description:"URLを入力してサイトを開く\nキーワードならGoogleで検索",key:"→",web:true)
            }
            HStack {
                Button("キャンセル",action:cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Text("クリック、または矢印キーですぐに開く").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width:480)
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.leftArrow) {submit(false);return .handled}
            .onKeyPress(.rightArrow) {submit(true);return .handled}
            .onAppear {focused=true}
    }
    private func submit(_ web:Bool) {
        guard !submitted else{return}
        submitted=true;open(web)
    }
    private func choice(_ title:String,description:String,key:String,web:Bool)->some View {
        Button {submit(web)} label:{
            VStack(spacing:12) {
                Group {
                    if !web,let logo=Self.notionLogo {
                        Image(nsImage:logo).resizable().scaledToFit().padding(3)
                            .background(.white,in:RoundedRectangle(cornerRadius:6))
                    } else {Image(systemName:"magnifyingglass").font(.system(size:28))}
                }.frame(width:38,height:38)
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                Text(key).font(.body.monospaced()).padding(.horizontal,9).padding(.vertical,3)
                    .background(.quaternary,in:RoundedRectangle(cornerRadius:5))
            }.frame(maxWidth:.infinity).padding(.vertical,18)
                .background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
                .contentShape(RoundedRectangle(cornerRadius:12))
        }.buttonStyle(.plain)
    }
}
