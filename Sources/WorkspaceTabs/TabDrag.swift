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
        override var mouseDownCanMoveWindow:Bool {false}
        override var acceptsFirstResponder:Bool {false}
        override var isFlipped:Bool {true}
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func mouseDown(with event:NSEvent) {origin=event.locationInWindow;moved=false}
        private func target(at point:NSPoint)->Handle? {
            guard let content=window?.contentView else{return nil}
            func find(_ view:NSView)->Handle? {
                guard !view.isHidden else{return nil}
                let local=view.convert(point,from:nil)
                guard view.visibleRect.contains(local) else{return nil}
                for child in view.subviews.reversed() {if let target=find(child) {return target}}
                return view as? Handle
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
        }
        override func mouseUp(with event:NSEvent) {
            defer {origin=nil;moved=false;destination?.highlight(false);destination=nil}
            guard origin != nil else{return}
            guard moved else {click?();return}
            guard let payload,let target=target(at:event.locationInWindow),target !== self else{return}
            let point=target.convert(event.locationInWindow,from:nil)
            target.drop?(payload,target.horizontal ? point.x>target.bounds.midX:point.y>target.bounds.midY)
        }
    }
}
