import Foundation

/// A candidate must remain unchanged while the mouse is down. Commit only on release.
public struct DragDwell {
    public private(set) var candidate: UUID?
    public private(set) var ready = false
    private var enteredAt: TimeInterval = 0
    public init() {}
    public mutating func reset() { candidate = nil; ready = false; enteredAt = 0 }
    public mutating func update(target: UUID?, holding: Bool, now: TimeInterval, delay: TimeInterval) -> UUID? {
        if !holding {
            let result = ready && candidate == target ? candidate : nil
            reset(); return result
        }
        guard let target else { reset(); return nil }
        if candidate != target { candidate = target; enteredAt = now; ready = false }
        ready = now - enteredAt >= max(0.5, delay)
        return nil
    }
}
