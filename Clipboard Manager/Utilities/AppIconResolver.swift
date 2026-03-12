import AppKit

class AppIconResolver {
    static let shared = AppIconResolver()
    private var cache: [String: NSImage] = [:]

    func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID = bundleID else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }

        if let cached = cache[bundleID] {
            return cached
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            cache[bundleID] = icon
            return icon
        }

        let fallback = NSWorkspace.shared.icon(for: .applicationBundle)
        cache[bundleID] = fallback
        return fallback
    }

    func clearCache() {
        cache.removeAll()
    }
}
