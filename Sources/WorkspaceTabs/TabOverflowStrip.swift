import SwiftUI
import WorkspaceCore

private struct TabFramesKey: PreferenceKey {
    static var defaultValue:[UUID:CGRect]=[:]
    static func reduce(value:inout [UUID:CGRect],nextValue:()->[UUID:CGRect]) {value.merge(nextValue()) {$1}}
}

/// A horizontally scrolling row of browser tabs that makes overflow obvious: the cut-off
/// edge fades out, a chevron with the number of hidden tabs sits on that edge (click to
/// page over, right-click to jump to one), and the selected tab is always scrolled into view.
struct TabOverflowStrip<Item:View>: View {
    let pages:[BrowserPage]
    let selectedID:UUID
    let select:(BrowserPage)->Void
    @ViewBuilder let item:(BrowserPage)->Item
    @State private var frames:[UUID:CGRect]=[:]
    @State private var width:CGFloat=0
    private let space="TabOverflowStrip"
    private let fade:CGFloat=28

    private var hiddenLeft:[BrowserPage] {pages.filter {(frames[$0.id]?.minX ?? 0) < -2}}
    private var hiddenRight:[BrowserPage] {pages.filter {guard let f=frames[$0.id] else{return false};return width > 0 && f.maxX > width + 2}}

    /// The tabs' own width, so the strip hugs them (and the + button follows the last tab)
    /// until they no longer fit.
    private var contentWidth:CGFloat {
        let shown=pages.compactMap {frames[$0.id]}
        guard let lo=shown.map(\.minX).min(),let hi=shown.map(\.maxX).max() else{return 0}
        return ceil(hi - lo)
    }

    var body:some View {
        let left=hiddenLeft,right=hiddenRight
        ScrollViewReader {proxy in
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:BrowserLayout.small) {
                    ForEach(pages) {page in
                        item(page).id(page.id)
                            .background(GeometryReader {g in Color.clear.preference(key:TabFramesKey.self,value:[page.id:g.frame(in:.named(space))])})
                    }
                }.padding(.vertical,BrowserLayout.gap)
            }
            .coordinateSpace(name:space)
            .frame(maxWidth:contentWidth > 0 ? contentWidth:.infinity)
            .background(GeometryReader {g in Color.clear.onAppear {width=g.size.width}.onChange(of:g.size.width) {_,w in width=w}})
            .onPreferenceChange(TabFramesKey.self) {frames=$0}
            .mask(HStack(spacing:0) {
                LinearGradient(colors:[.clear,.black],startPoint:.leading,endPoint:.trailing).frame(width:left.isEmpty ? 0:fade)
                Rectangle()
                LinearGradient(colors:[.black,.clear],startPoint:.leading,endPoint:.trailing).frame(width:right.isEmpty ? 0:fade)
            })
            .overlay(alignment:.leading) {
                if let target=left.last {
                    edgeButton(systemImage:"chevron.left",count:left.count,hidden:left,proxy:proxy,help:L("前のタブを表示")) {
                        withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo(target.id,anchor:.trailing)}
                    }
                }
            }
            .overlay(alignment:.trailing) {
                if let target=right.first {
                    edgeButton(systemImage:"chevron.right",count:right.count,hidden:right,proxy:proxy,help:L("次のタブを表示")) {
                        withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo(target.id,anchor:.leading)}
                    }
                }
            }
            .onAppear {DispatchQueue.main.async {proxy.scrollTo(selectedID)}}
            .onChange(of:selectedID) {_,id in DispatchQueue.main.async {withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo(id)}}}
            .onChange(of:pages.count) {_,_ in DispatchQueue.main.async {withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo(selectedID)}}}
        }
    }

    private func edgeButton(systemImage:String,count:Int,hidden:[BrowserPage],proxy:ScrollViewProxy,help:String,action:@escaping ()->Void)->some View {
        Button(action:action) {
            HStack(spacing:2) {
                if systemImage == "chevron.left" {Image(systemName:systemImage)}
                Text("\(count)").monospacedDigit()
                if systemImage == "chevron.right" {Image(systemName:systemImage)}
            }
            .font(.system(size:10,weight:.semibold))
            .padding(.horizontal,6).frame(height:22)
            .background(.regularMaterial,in:Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
            .shadow(color:.black.opacity(0.15),radius:2,y:1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).padding(.horizontal,2)
        .help(help)
        .accessibilityLabel(help)
        .contextMenu {
            ForEach(hidden) {page in
                Button(page.displayTitle) {
                    select(page)
                    withAnimation(.easeOut(duration:0.2)) {proxy.scrollTo(page.id)}
                }
            }
        }
    }
}
