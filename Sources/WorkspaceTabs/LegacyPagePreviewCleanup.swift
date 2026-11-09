import Foundation

/// Only the obsolete, disposable screenshot directory is removed. Session and login data stay intact.
enum LegacyPagePreviewCleanup {
    static func remove(in directory:URL) throws {
        let obsolete=directory.appendingPathComponent("PagePreviews",isDirectory:true)
        if FileManager.default.fileExists(atPath:obsolete.path) {try FileManager.default.removeItem(at:obsolete)}
    }
}
