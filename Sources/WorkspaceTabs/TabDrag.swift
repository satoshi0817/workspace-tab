import SwiftUI
import AppKit

struct TabDragPayload {
    var workspaceID:UUID
    var pageID:UUID?
}
// Reordering is local to this window. Track mouse movement directly so tab
// gestures do not compete with SwiftUI buttons or start an external file drag.
struct TabDragHandle:NSViewRepresentable {
    let payload:TabDragPayload
    let title:String
    var horizontal:Bool = true
    var drop:((TabDragPayload,Bool)->Void)?
    let click:()->Void
    func makeNSView(context:Context)->Handle {Handle()}
    func updateNSView(_ view:Handle,context:Context) {
        view.payload=payload;view.horizontal=horizontal;view.drop=drop;view.click=click
    }
    final class Handle:NSView {
        var payload:TabDragPayload?
        var horizontal=true
        var drop:((TabDragPayload,Bool)->Void)?
        var click:(()->Void)?
        private var origin:NSPoint?
        private var moved=false
        private weak var destination:Handle?
        private weak var zone:SplitDropZone.Zone?
        private func splitZone(at point:NSPoint)->SplitDropZone.Zone? {
            guard let content=window?.contentView else{return nil}
            func find(_ view:NSView)->SplitDropZone.Zone? {
                guard !view.isHidden else{return nil}
                for child in view.subviews.reversed() {if let zone=find(child) {return zone}}
                guard let zone=view as? SplitDropZone.Zone,zone.side(at:point) != nil else{return nil}
                return zone
            }
            return find(content)
        }
        override var mouseDownCanMoveWindow:Bool {false}
        override var acceptsFirstResponder:Bool {false}
        override var isFlipped:Bool {true}
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func mouseDown(with event:NSEvent) {origin=event.locationInWindow;moved=false}
        private func target(at point:NSPoint)->Handle? {
            guard let content=window?.contentView else{return nil}
            func find(_ view:NSView)->Handle? {
                guard !view.isHidden else{return nil}
                // SwiftUI may place interactive descendants outside a layout
                // wrapper's bounds. Do not reject the whole subtree at that wrapper.
                for child in view.subviews.reversed() {if let target=find(child) {return target}}
                guard let handle=view as? Handle else{return nil}
                let local=handle.convert(point,from:nil)
                guard handle.bounds.contains(local),handle.visibleRect.contains(local) else{return nil}
                return handle
            }
            return find(content)
        }

        private func highlight(_ active:Bool) {
            wantsLayer=true;layer?.cornerRadius=6;layer?.borderWidth=active ? 2:0
            layer?.borderColor=NSColor.controlAccentColor.cgColor
        }
        override func mouseDragged(with event:NSEvent) {
            guard let origin else{return}
            if hypot(event.locationInWindow.x-origin.x,event.locationInWindow.y-origin.y)>4 {moved=true}
            guard moved else{return}
            destination?.highlight(false)
            destination=target(at:event.locationInWindow)
            if destination !== self {destination?.highlight(true)}
            // Over the page area instead of another tab: preview where a Split would open.
            let next=destination == nil ? splitZone(at:event.locationInWindow):nil
            if zone !== next {zone?.preview(nil)}
            zone=next;zone?.preview(event.locationInWindow)
        }
        override func mouseUp(with event:NSEvent) {
            defer {origin=nil;moved=false;destination?.highlight(false);destination=nil;zone?.preview(nil);zone=nil}
            guard origin != nil else{return}
            guard moved else {click?();return}
            if let payload,target(at:event.locationInWindow) == nil,let zone=splitZone(at:event.locationInWindow),let side=zone.side(at:event.locationInWindow) {zone.drop?(payload,side);return}
            guard let payload,let target=target(at:event.locationInWindow),target !== self else{return}
            let point=target.convert(event.locationInWindow,from:nil)
            target.drop?(payload,target.horizontal ? point.x>target.bounds.midX:point.y>target.bounds.midY)
        }
    }
}

enum SplitDropSide {case left,right,bottom}

// Sits over the page area. It never takes mouse events; tab drags find it by position.
struct SplitDropZone:NSViewRepresentable {
    let color:NSColor
    let drop:(TabDragPayload,SplitDropSide)->Void
    func makeNSView(context:Context)->Zone {Zone()}
    func updateNSView(_ view:Zone,context:Context) {view.drop=drop;view.color=color}
    final class Zone:NSView {
        var drop:((TabDragPayload,SplitDropSide)->Void)?
        var color=NSColor.controlAccentColor
        private let marker=CALayer()
        override var isFlipped:Bool {true}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        /// The side a drop at this window point would use, or nil outside the page area.
        func side(at windowPoint:NSPoint)->SplitDropSide? {
            let point=convert(windowPoint,from:nil)
            // The strip at the top holds the tab bar; drops there stay tab reordering.
            guard bounds.contains(point),point.y>BrowserLayout.tabBar+BrowserLayout.gap,bounds.width>200,bounds.height>200 else{return nil}
            if point.y>bounds.height*0.78 {return .bottom}
            return point.x<bounds.midX ? .left:.right
        }
        func preview(_ windowPoint:NSPoint?) {
            guard let windowPoint,let side=side(at:windowPoint) else {marker.removeFromSuperlayer();return}
            wantsLayer=true
            if marker.superlayer == nil {layer?.addSublayer(marker)}
            let top=BrowserLayout.tabBar,inset=BrowserLayout.gap
            let area:CGRect
            switch side {
            case .left:area=CGRect(x:0,y:top,width:bounds.midX,height:bounds.height-top)
            case .right:area=CGRect(x:bounds.midX,y:top,width:bounds.midX,height:bounds.height-top)
            case .bottom:area=CGRect(x:0,y:bounds.midY,width:bounds.width,height:bounds.midY)
            }
            CATransaction.begin();CATransaction.setDisableActions(true)
            marker.frame=area.insetBy(dx:inset,dy:inset)
            marker.cornerRadius=BrowserLayout.pageRadius;marker.borderWidth=2
            marker.borderColor=color.cgColor;marker.backgroundColor=color.withAlphaComponent(0.18).cgColor
            CATransaction.commit()
        }
    }
}
