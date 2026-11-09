import SwiftUI
import AppKit
import WorkspaceCore

/// A brief bootstrap placeholder. Once the site draws its own loader, the WebView takes over.
/// No page text, images or layout data are captured or persisted.
struct PageLoadingSkeleton:View {
    let notion:Bool
    let workspace:BrowserWorkspace?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active=NSApp.isActive
    @State private var started=Date()
    var body:some View {
        GeometryReader {geometry in
            let sidebar:CGFloat=notion && geometry.size.width>=600 ? 240:0
            TimelineView(.animation(minimumInterval:1.0/30,paused:reduceMotion || !active)) {context in
                let elapsed=context.date.timeIntervalSince(started)
                let phase=elapsed.truncatingRemainder(dividingBy:1)
                HStack(alignment:.top,spacing:0) {
                    if sidebar>0 {
                        VStack(alignment:.leading,spacing:0) {
                            HStack(spacing:8) {block(22,22,4,phase,sidebar:true);block(177,10,5,phase,sidebar:true)}.padding(.bottom,22)
                            ForEach(0..<4,id:\.self) {index in
                                block(index == 3 ? 135:78,10,5,phase,sidebar:true).padding(.bottom,index == 3 ? 36:20)
                            }
                            block(56,10,5,phase,sidebar:true).padding(.bottom,14)
                            ForEach(0..<20,id:\.self) {index in
                                HStack(spacing:8) {
                                    block(20,20,4,phase,sidebar:true)
                                    block(CGFloat([120,100,140,100,100,80,120,80][index%8]),10,5,phase,sidebar:true)
                                }.padding(.bottom,11)
                                    .opacity(index<4 || reduceMotion ? 1:min(1,max(0,elapsed-Double(index/4))))
                            }
                            Spacer(minLength:0)
                        }.padding(.horizontal,14).padding(.vertical,12)
                            .frame(width:sidebar,height:geometry.size.height,alignment:.topLeading)
                            .background(sidebarBackground)
                    }
                    VStack(alignment:.leading,spacing:32) {
                        HStack(spacing:8) {
                            block(20,20,4,phase);block(78,10,5,phase)
                            Spacer(minLength:12)
                            block(78,10,5,phase)
                        }.padding(.horizontal,16).frame(height:44)
                        if !notion {
                            VStack(alignment:.leading,spacing:16) {
                                ForEach(0..<4,id:\.self) {index in
                                    block(max(60,min(600,geometry.size.width-64))*[0.8,1,0.9,0.65][index],12,6,phase)
                                }
                            }.padding(32)
                        }
                        Spacer(minLength:0)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }.frame(width:geometry.size.width,height:geometry.size.height,alignment:.topLeading)
                    .background(Color(nsColor:.textBackgroundColor)).clipped()
            }
        }.accessibilityElement(children:.ignore).accessibilityLabel("ページを読み込み中")
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in active=true}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.willResignActiveNotification)) {_ in active=false}
    }
    private var sidebarColor:Color {
        let neutral:CGFloat=scheme == .dark ? 0.12:0.97
        guard let workspace,workspace.cssEnabled,
              let color=NSColor(Palette.color(workspace.color)).usingColorSpace(.sRGB) else {return Color(white:neutral)}
        let strength=CGFloat(min(1,max(0,workspace.cssStrength)))
        return Color(red:Double(neutral*(1-strength)+color.redComponent*strength),
                     green:Double(neutral*(1-strength)+color.greenComponent*strength),
                     blue:Double(neutral*(1-strength)+color.blueComponent*strength))
    }
    private var sidebarBackground:Color {sidebarColor}
    private func block(_ width:CGFloat,_ height:CGFloat,_ radius:CGFloat,_ phase:Double,sidebar:Bool=false)->some View {
        let shape=RoundedRectangle(cornerRadius:radius,style:.continuous)
        // Compute contrast from the actual blended sidebar, rather than the app theme:
        // a light app can still have a dark, saturated sidebar (and vice versa).
        let ink=Palette.ink(Palette.hex(sidebarColor))
        let base=sidebar ? ink.opacity(0.13):(scheme == .dark ? Color(white:47.0/255):Color(red:227.0/255,green:226.0/255,blue:224.0/255).opacity(0.5))
        let highlight=sidebar ? ink.opacity(0.09):(scheme == .dark ? Color(white:86.0/255).opacity(0.1):Color.black.opacity(0.03))
        return shape.fill(base).frame(width:width,height:height)
            .overlay {
                if !reduceMotion,active {
                    LinearGradient(colors:[.clear,highlight,.clear],startPoint:.leading,endPoint:.trailing)
                        .frame(width:width,height:height).offset(x:width*(phase*2-1))
                }
            }.clipShape(shape)
    }
}
