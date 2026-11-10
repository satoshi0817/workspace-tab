import Foundation
import CoreGraphics

public struct WindowRect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) }
}

public struct WorkspaceTab: Codable, Identifiable, Equatable {
    public var id: UUID
    public var bundleID: String
    public var windowTitle: String
    public var name: String
    public var emoji: String
    public var iconFile: String?
    public var color: String
    public var pinned: Bool
    public var windowIdentity: WindowIdentity?
    public var textColor: String? // nil means automatic; optional for existing saved files.
    public init(id: UUID = UUID(), bundleID: String, windowTitle: String, name: String? = nil,
                emoji: String = "", iconFile: String? = nil, color: String = "violet", pinned: Bool = false) {
        self.id = id; self.bundleID = bundleID; self.windowTitle = windowTitle
        self.name = name ?? windowTitle; self.emoji = emoji; self.iconFile = iconFile
        self.color = color; self.pinned = pinned
    }
}

public struct WorkspaceGroup: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var color: String
    public var tabs: [WorkspaceTab]
    public var selectedTabID: UUID?
    public var frame: WindowRect?
    public var normalFrame: WindowRect?
    public var locked: Bool
    public init(id: UUID = UUID(), name: String = "Notion ワークスペース", emoji: String = "◈",
                color: String = "violet", tabs: [WorkspaceTab] = [], selectedTabID: UUID? = nil,
                frame: WindowRect? = nil, normalFrame: WindowRect? = nil, locked: Bool = false) {
        self.id = id; self.name = name; self.emoji = emoji; self.color = color; self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs.first?.id; self.frame = frame; self.normalFrame = normalFrame; self.locked = locked
    }
}

public struct SavedState: Codable {
    public var version: Int = 1
    public var groups: [WorkspaceGroup]
    public var selectedGroupID: UUID?
    public init(groups: [WorkspaceGroup], selectedGroupID: UUID? = nil) {
        self.groups = groups; self.selectedGroupID = selectedGroupID
    }
    public func validated() throws -> SavedState {
        guard version == 1 else { throw StateError.unsupportedVersion(version) }
        let groupIDs = groups.map(\.id), tabIDs = groups.flatMap(\.tabs).map(\.id)
        guard Set(groupIDs).count == groupIDs.count, Set(tabIDs).count == tabIDs.count else {
            throw StateError.duplicateIdentity
        }
        for group in groups {
            for f in [group.frame, group.normalFrame].compactMap({ $0 }) {
                guard [f.x, f.y, f.width, f.height].allSatisfy(\.isFinite), f.width > 0, f.height > 0
                else { throw StateError.invalidGeometry }
            }
        }
        return self
    }
}

public enum StateError: Error, LocalizedError {
    case unsupportedVersion(Int), duplicateIdentity, invalidGeometry
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return L("この設定ファイルのバージョン（\(v)）には対応していません。")
        case .duplicateIdentity: return L("設定に重複したグループまたはタブがあります。")
        case .invalidGeometry: return L("設定のウインドウ座標が不正です。")
        }
    }
}

public enum WorkspaceRules {
    public static func framesNear(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX-b.minX) < tolerance && abs(a.minY-b.minY) < tolerance &&
        abs(a.width-b.width) < tolerance && abs(a.height-b.height) < tolerance
    }
    /// A title is only a reconnect hint. Never bind either side of an ambiguous match.
    public static func uniqueMatch(bundleID: String, title: String,
                                   candidates: [(bundleID: String, title: String)]) -> Int? {
        let matches = candidates.indices.filter { candidates[$0].bundleID == bundleID && candidates[$0].title == title }
        return matches.count == 1 ? matches.first : nil
    }
    public static func nextTab(in tabs: [WorkspaceTab], current: UUID?, delta: Int) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let i = tabs.firstIndex { $0.id == current } ?? 0
        return tabs[((i + delta) % tabs.count + tabs.count) % tabs.count].id
    }
    /// AX uses a top-left origin; AppKit uses a bottom-left origin on the primary display.
    public static func appKitFrame(fromAX frame: CGRect, primaryTop: Double) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
    public static func axFrame(fromAppKit frame: CGRect, primaryTop: Double) -> CGRect {
        appKitFrame(fromAX: frame, primaryTop: primaryTop)
    }
    public static func fit(_ frame: CGRect, inside visible: CGRect, barHeight: Double = 42,
                           minimum: CGSize = CGSize(width: 300, height: 200)) -> CGRect {
        let width = min(max(frame.width, minimum.width), visible.width)
        let height = min(max(frame.height, minimum.height), max(1, visible.height - barHeight))
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - barHeight - height),
                      width: width, height: height)
    }
}
