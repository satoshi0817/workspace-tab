import SwiftUI
import WorkspaceCore

/// A soft veil over the page while a Notion action opens menus and panels underneath,
/// so the page does not seem to flicker on its own. It waits a moment before showing,
/// so quick actions (a key shortcut that opens search at once) never flash it.
struct NotionActionVeil:View {
    @ObservedObject private var localization = AppLocalization.shared
    let action:String?
    let tint:Color
    @State private var shown:String?
    @State private var reveal:DispatchWorkItem?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        ZStack {
            if let shown {
                Rectangle().fill(scheme == .dark ? Color.black.opacity(0.35):Color.white.opacity(0.6))
                    .background(.ultraThinMaterial.opacity(0.6))
                VStack(spacing:14) {
                    SearchingMark(symbol:Self.symbol(shown),tint:tint,animate:!reduceMotion)
                    Text(Self.label(shown)).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }.padding(.horizontal,28).padding(.vertical,22)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:18,style:.continuous))
                    .shadow(color:.black.opacity(0.08),radius:16,y:4)
                    .accessibilityElement(children:.combine)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration:0.18),value:shown)
        .onChange(of:action) {_,next in schedule(next)}
        .onAppear {schedule(action)}
    }
    private func schedule(_ next:String?) {
        reveal?.cancel();reveal=nil
        guard let next else {shown=nil;return}
        if shown != nil {shown=next;return}
        let work=DispatchWorkItem {shown=next}
        reveal=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:work)
    }
    static func symbol(_ action:String)->String {
        switch action {
        case "notionSearch":return "magnifyingglass"
        case "notionSettings":return "gearshape"
        case "notionChat":return "sparkles"
        case "notionMeeting":return "waveform"
        case "notionDatabase":return "tablecells"
        default:return "square.and.pencil"
        }
    }
    static func label(_ action:String)->String {
        switch action {
        case "notionSearch":return L("Notionの検索を開いています…")
        case "notionSettings":return L("Notionの設定を開いています…")
        default:return L("Notionで準備しています…")
        }
    }
}

/// A symbol that wanders in a small loop and tilts, like something looking around,
/// with a soft tinted halo that breathes beneath it.
private struct SearchingMark:View {
    let symbol:String
    let tint:Color
    let animate:Bool
    var body:some View {
        TimelineView(.animation(paused:!animate)) {context in
            let t=animate ? context.date.timeIntervalSinceReferenceDate:0
            let x=cos(t*2.4)*9,y=sin(t*4.8)*4
            ZStack {
                Circle().fill(tint.opacity(0.22)).frame(width:64,height:64).scaleEffect(1+0.08*sin(t*2.4))
                Image(systemName:symbol).font(.system(size:26,weight:.semibold)).foregroundStyle(tint)
                    .rotationEffect(.degrees(symbol == "gearshape" ? t*90:sin(t*2.4)*12))
                    .offset(x:symbol == "gearshape" ? 0:x,y:symbol == "gearshape" ? 0:y)
            }.frame(width:84,height:72)
        }.accessibilityHidden(true)
    }
}
