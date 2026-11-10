import SwiftUI
import AppKit
import WorkspaceCore

struct BrowserSplit: NSViewRepresentable {
    @ObservedObject var store:BrowserStore
    let left:PageReference
    let right:PageReference
    func makeNSView(context:Context)->PersistentSplitView {
        let view=PersistentSplitView()
        view.dividerStyle = .thin;view.delegate=context.coordinator
        view.addArrangedSubview(NSHostingView(rootView:AnyView(EmptyView())))
        view.addArrangedSubview(NSHostingView(rootView:AnyView(EmptyView())))
        return view
    }
    func updateNSView(_ view:PersistentSplitView,context:Context) {
        context.coordinator.store=store
        view.applying=true
        view.isVertical=store.session.splitOrientation != "vertical"
        view.fraction=store.session.splitFraction ?? 0.5
        let refs=[left,right]
        for (i,ref) in refs.enumerated() {
            (view.arrangedSubviews[i] as? NSHostingView<AnyView>)?.rootView=AnyView(BrowserPane(store:store,workspaceID:ref.workspaceID,pageID:ref.pageID,isRight:i == 1))
        }
        view.applyFraction();view.applying=false
    }
    func makeCoordinator()->Coordinator {Coordinator(store:store)}
    @MainActor final class Coordinator:NSObject,NSSplitViewDelegate {
        weak var store:BrowserStore?
        init(store:BrowserStore){self.store=store}
        func splitViewDidResizeSubviews(_ notification:Notification) {
            guard let view=notification.object as? PersistentSplitView,!view.applying,view.trackingDivider,view.arrangedSubviews.count == 2 else{return}
            let length=view.axisLength-view.dividerThickness
            guard length>0 else{return}
            let first=view.arrangedSubviews[0].frame
            let ratio=Double((view.isVertical ? first.width:first.height)/length)
            guard ratio.isFinite else{return}
            let clamped=min(0.85,max(0.15,ratio));view.fraction=clamped
            if abs((store?.session.splitFraction ?? 0.5)-clamped)>0.001 {store?.session.splitFraction=clamped;store?.changed()}
        }
        func splitView(_ splitView:NSSplitView,constrainSplitPosition proposedPosition:CGFloat,ofSubviewAt dividerIndex:Int)->CGFloat {
            guard let view=splitView as? PersistentSplitView else{return proposedPosition}
            let length=view.axisLength-view.dividerThickness
            let minimum=min(length/2,view.isVertical ? 200:140)
            return min(length-minimum,max(minimum,proposedPosition))
        }
    }
}
@MainActor final class PersistentSplitView:NSSplitView {
    var fraction=0.5
    var applying=false
    var trackingDivider=false
    private var lastSize=NSSize.zero
    var axisLength:CGFloat {isVertical ? bounds.width:bounds.height}
    override func mouseDown(with event:NSEvent) {
        trackingDivider=true
        defer {trackingDivider=false}
        super.mouseDown(with:event)
    }
    override func resizeSubviews(withOldSize oldSize:NSSize) {
        let old=applying;applying=true
        super.resizeSubviews(withOldSize:oldSize);applyFraction();applying=old
    }
    override var isFlipped:Bool {true}
    override func layout() {
        super.layout()
        if bounds.size != lastSize {
            lastSize=bounds.size
            let old=applying;applying=true;applyFraction();applying=old
        }
    }
    func applyFraction() {
        guard arrangedSubviews.count == 2,axisLength>dividerThickness else{return}
        let length=axisLength-dividerThickness
        let minimum=min(length/2,isVertical ? 200:140)
        let position=min(length-minimum,max(minimum,length*min(0.85,max(0.15,fraction))))
        let current=isVertical ? arrangedSubviews[0].frame.width:arrangedSubviews[0].frame.height
        if abs(current-position)>0.5 {setPosition(position,ofDividerAt:0)}
    }
}
