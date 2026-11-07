import Foundation
import CoreGraphics

public enum TabLayout: String, CaseIterable, Codable {
    case top, left, leftIcons, leftHover
    public var gap: CGFloat { 4 }
    public var topInset: CGFloat { self == .top ? 42 + gap : 0 }
    public var leftInset: CGFloat {
        switch self { case .top: return 0; case .left: return 220 + gap; case .leftIcons: return 56 + gap; case .leftHover: return 8 + gap }
    }
    public func content(in shell: CGRect) -> CGRect {
        CGRect(x: shell.minX + leftInset, y: shell.minY,
               width: max(1, shell.width - leftInset), height: max(1, shell.height - topInset))
    }
    public func shell(around content: CGRect) -> CGRect {
        CGRect(x: content.minX - leftInset, y: content.minY,
               width: content.width + leftInset, height: content.height + topInset)
    }
    public func panel(beside content: CGRect) -> CGRect {
        self != .top
            ? CGRect(x: content.minX - leftInset, y: content.minY, width: leftInset - gap, height: content.height)
            : CGRect(x: content.minX, y: content.maxY + gap, width: content.width, height: topInset - gap)
    }
}
