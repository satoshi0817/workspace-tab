import AppKit
import SwiftUI
import WebKit
import WorkspaceCore

@MainActor final class NotionAccountMonitor:ObservableObject {
    @Published private(set) var account:NotionAccount?
    @Published private(set) var checking=false
    @Published private(set) var supported=false
    /// True when the tab names its active user, even if the profile lookup then failed.
    @Published private(set) var identified=false
    private var request:UUID?
    private var lastProbe:TimeInterval = -.infinity
    private var cached:NotionAccount?
    private var cachedAt:TimeInterval = -.infinity
    private var attemptedID:String?
    private var attemptedAt:TimeInterval = -.infinity
    private var hasProbed=false
    private var observedID:String?
    var isRefreshing:Bool {request != nil}
    func invalidate() {
        request=nil;lastProbe = -.infinity;cached=nil;cachedAt = -.infinity
        attemptedID=nil;attemptedAt = -.infinity
        hasProbed=false;observedID=nil
        if account != nil {account=nil}
        if checking {checking=false}
        if supported {supported=false}
        if identified {identified=false}
    }
    func refresh(in webView:WKWebView,force:Bool=false) {
        guard let url=webView.url,NotionWorkspace.environment(url) != nil else{invalidate();return}
        if !supported {supported=true}
        guard request == nil,force || ProcessInfo.processInfo.systemUptime-lastProbe>=4.5 else{return}
        lastProbe=ProcessInfo.processInfo.systemUptime
        let token=UUID();request=token
        if account == nil && !hasProbed {checking=true}
        webView.callAsyncJavaScript(NotionAccount.probeScript,arguments:[:],in:nil,in:.defaultClient) { [weak self,weak webView] result in
            guard let self,let webView,self.request == token else{return}
            guard webView.url == url,case .success(let raw)=result,
                  let value=raw as? [String:Any],value["url"] as? String == url.absoluteString,
                  let userID=NotionWorkspace.normalizedID(value["userID"] as? String) else{self.observedID=nil;self.finish(nil,token:token);return}
            let changed=self.observedID != userID;self.observedID=userID
            if self.account?.id != userID,self.account != nil {self.account=nil}
            if !force,let cached=self.cached,cached.id == userID,ProcessInfo.processInfo.systemUptime-self.cachedAt<300 {
                self.finish(cached,token:token,cache:false);return
            }
            // Continue checking the lightweight tab identity, but do not hammer
            // Notion when its private read API is unavailable or denies access.
            if !force,self.attemptedID == userID,ProcessInfo.processInfo.systemUptime-self.attemptedAt<60 {
                self.finish(nil,token:token,cache:false);return
            }
            if self.account == nil && (changed || !self.hasProbed) {self.checking=true}
            self.attemptedID=userID;self.attemptedAt=ProcessInfo.processInfo.systemUptime
            webView.callAsyncJavaScript(NotionAccount.fetchScript,arguments:["userID":userID,"expectedURL":url.absoluteString],in:nil,in:.defaultClient) { [weak self,weak webView] response in
                guard let self,let webView,self.request == token else{return}
                guard webView.url == url,case .success(let raw)=response,
                      let value=raw as? [String:Any],value["url"] as? String == url.absoluteString,
                      value["userID"] as? String == userID,let fields=value["account"] as? [String:Any] else {
                    self.finish(nil,token:token);return
                }
                self.finish(NotionAccount.decode(fields,matching:userID),token:token)
            }
        }
    }
    private func finish(_ value:NotionAccount?,token:UUID,cache:Bool=true) {
        guard request == token else{return}
        request=nil
        hasProbed=true
        if identified != (observedID != nil) {identified=observedID != nil}
        if account != value {account=value}
        if cache {cached=value;cachedAt=ProcessInfo.processInfo.systemUptime}
        if checking {checking=false}
    }
}

struct NotionAccountPill:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var monitor:NotionAccountMonitor
    var recheck:(()->Void)?=nil
    private var label:String {monitor.account?.displayName ?? (monitor.checking ? L("確認中…"):L("アカウント未確認"))}
    private var detail:String {
        guard let account=monitor.account else {
            if monitor.checking {return L("このタブで使用中のNotionアカウントを確認できると、ユーザー名を表示します。")}
            return monitor.identified ? L("Notionからユーザー情報を取得できませんでした。クリックすると再確認します。"):L("このタブでログイン中のNotionアカウントを特定できません。Notionにログインしてからクリックすると再確認します。")
        }
        return (account.name.isEmpty ? account.email:account.name+"\n"+account.email)+"\n"+L("クリックすると再確認します。")
    }
    @ViewBuilder private var avatar:some View {
        if let account=monitor.account {
            if let data=account.avatar,let image=NSImage(data:data),image.isValid {
                Image(nsImage:image).resizable().interpolation(.high).aspectRatio(contentMode:.fill)
            } else {
                // No photo available: initial on a tinted disc, like Notion's own fallback.
                Text(String(account.displayName.prefix(1)).uppercased()).font(.system(size:10,weight:.semibold))
                    .frame(maxWidth:.infinity,maxHeight:.infinity).background(.primary.opacity(0.18))
            }
        } else {
            Image(systemName:"person.crop.circle.badge.questionmark").font(.system(size:13))
        }
    }
    var body:some View {
        if monitor.supported {
            Button {recheck?()} label:{
                HStack(spacing:6) {
                    avatar.frame(width:18,height:18).clipShape(Circle())
                        .overlay(Circle().strokeBorder(.primary.opacity(monitor.account == nil ? 0:0.18)))
                    Text(label).font(.system(size:12,weight:.medium)).lineLimit(1).truncationMode(.tail)
                    if monitor.account == nil && !monitor.checking {Image(systemName:"arrow.clockwise").font(.system(size:10,weight:.semibold))}
                }.padding(.leading,4).padding(.trailing,10).padding(.vertical,4)
                    .background(.primary.opacity(0.08),in:Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain)
                .frame(maxWidth:190,alignment:.trailing).fixedSize(horizontal:false,vertical:true)
                .help(detail).accessibilityElement(children:.ignore).accessibilityAddTraits(.isButton)
                .accessibilityLabel(L("Notionアカウント：\(label)"))
        }
    }
}

/// One-click switch for the large email over this browser tab's page. Only on Notion tabs.
struct NotionAccountWatermarkToggle:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var monitor:NotionAccountMonitor
    let enabled:Bool
    let toggle:()->Void
    var body:some View {
        if monitor.supported {
            let hint=enabled ? L("クリックすると、ページ上のメールアドレス表示を消します。"):L("クリックすると、このタブのメールアドレスをページ上に大きく表示します。")
            Button {toggle()} label:{
                Image(systemName:"at").font(.system(size:11,weight:.semibold))
                    .frame(width:22,height:22)
                    .background(.primary.opacity(enabled ? 0.18:0.08),in:Circle())
                    .opacity(enabled ? 1:0.6).contentShape(Circle())
            }.buttonStyle(.plain).help(hint).accessibilityLabel(L("メールアドレスをページ上に大きく表示")).accessibilityHint(hint)
                .accessibilityAddTraits(enabled ? .isSelected:[])
        }
    }
}

/// Click-through account email over the page, for telling logins apart at a glance.
struct NotionAccountWatermark:View {
    @ObservedObject var monitor:NotionAccountMonitor
    let enabled:Bool
    /// The app tab colour, so the text matches the tab it belongs to.
    let color:Color
    let style:AccountEmailStyle
    var body:some View {
        if enabled,let account=monitor.account {
            Text(account.email).font(.system(size:style.size,weight:.bold)).lineLimit(1).minimumScaleFactor(0.2)
                .foregroundStyle(color.opacity(style.opacity))
                .padding(.horizontal,style.centered ? 32:20).padding(.bottom,style.centered ? 0:14)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:style.centered ? .center:.bottomTrailing)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
