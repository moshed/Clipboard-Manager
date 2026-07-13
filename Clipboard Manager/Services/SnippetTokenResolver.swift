import AppKit
import Foundation
import CoreLocation

/// Keeps the device's most recent coordinate cached so the synchronous token
/// resolver can read it without blocking. Requests permission on first `start()`.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private(set) var lastCoordinate: CLLocationCoordinate2D?
    private var started = false

    /// Published so Settings can show the live authorization state.
    @Published private(set) var authStatus: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authStatus = manager.authorizationStatus
    }

    /// Warm-up only: start caching location IF already authorized. Never prompts.
    /// Safe to call during a paste or at launch.
    func start() {
        guard !started else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            started = true
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    /// Explicit user-initiated permission request. Must be called from an active
    /// (frontmost) app context — macOS won't present the location prompt to a
    /// background agent app. Brings the app forward first.
    @MainActor
    func requestAccess() {
        let status = manager.authorizationStatus
        NSApp.activate(ignoringOtherApps: true)
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            started = true
            manager.startUpdatingLocation()
        case .denied, .restricted:
            // Already decided against — send the user to the System Settings pane.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    /// Warm up location caching only if the user has already granted access —
    /// never prompts. Call at launch so paste-time has a fresh fix ready.
    func startIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            start()
        default:
            break
        }
    }

    /// "lat, lon" to 6 decimals, or nil if there's no fix yet / access denied.
    func formattedLatLon() -> String? {
        guard let c = lastCoordinate else { return nil }
        return String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last { lastCoordinate = loc.coordinate }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            started = true
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known coordinate; ignore transient errors.
    }
}

enum SnippetTokenResolver {
    static func resolve(_ content: String, clipboardText: String? = nil) -> String {
        var result = content

        // {{clipboard}} — current pasteboard text (use pre-captured value if provided)
        if result.contains("{{clipboard}}") {
            let clipText = clipboardText ?? NSPasteboard.general.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{{clipboard}}", with: clipText)
        }

        // {{date}} — locale short date
        if result.contains("{{date}}") {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .none
            result = result.replacingOccurrences(of: "{{date}}", with: fmt.string(from: Date()))
        }

        // {{time}} — locale short time
        if result.contains("{{time}}") {
            let fmt = DateFormatter()
            fmt.dateStyle = .none
            fmt.timeStyle = .short
            result = result.replacingOccurrences(of: "{{time}}", with: fmt.string(from: Date()))
        }

        // {{datetime}} — locale short date+time
        if result.contains("{{datetime}}") {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            result = result.replacingOccurrences(of: "{{datetime}}", with: fmt.string(from: Date()))
        }

        // {{timestamp}} — ISO 8601
        if result.contains("{{timestamp}}") {
            result = result.replacingOccurrences(of: "{{timestamp}}", with: ISO8601DateFormatter().string(from: Date()))
        }

        // {{latlon}} — current device coordinates as "lat, lon"
        if result.contains("{{latlon}}") {
            LocationProvider.shared.start()
            let value = LocationProvider.shared.formattedLatLon() ?? ""
            result = result.replacingOccurrences(of: "{{latlon}}", with: value)
        }

        // {{date:FORMAT}} — custom date format, e.g. {{date:yyyy/MM/dd}}, {{date:MMM d, yyyy}}
        if let regex = try? NSRegularExpression(pattern: #"\{\{date:([^}]+)\}\}"#) {
            while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
                guard let formatRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { break }
                let fmt = DateFormatter()
                fmt.dateFormat = String(result[formatRange])
                result = result.replacingCharacters(in: fullRange, with: fmt.string(from: Date()))
            }
        }

        return result
    }

    /// Returns true if the content is entirely composed of tokens (e.g. "{{date}}") with no other text.
    /// Used to force plain-text paste so the result adapts to the destination's formatting.
    static func isTokenOnly(_ content: String) -> Bool {
        var stripped = content
        // Remove custom date format tokens first
        if let regex = try? NSRegularExpression(pattern: #"\{\{date:([^}]+)\}\}"#) {
            stripped = regex.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "")
        }
        for token in ["{{clipboard}}", "{{date}}", "{{time}}", "{{datetime}}", "{{timestamp}}", "{{latlon}}"] {
            stripped = stripped.replacingOccurrences(of: token, with: "")
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns array of (NSRange, replacement) pairs for all tokens in the string, ordered by position
    static func findTokenRanges(in content: String, clipboardText: String? = nil) -> [(NSRange, String)] {
        var results: [(NSRange, String)] = []
        let nsContent = content as NSString

        let now = Date()
        let clipText = clipboardText ?? NSPasteboard.general.string(forType: .string) ?? ""

        // Fixed tokens
        let fixedTokens: [(String, () -> String)] = [
            ("{{clipboard}}", { clipText }),
            ("{{date}}", {
                let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .none
                return fmt.string(from: now)
            }),
            ("{{time}}", {
                let fmt = DateFormatter(); fmt.dateStyle = .none; fmt.timeStyle = .short
                return fmt.string(from: now)
            }),
            ("{{datetime}}", {
                let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
                return fmt.string(from: now)
            }),
            ("{{timestamp}}", { ISO8601DateFormatter().string(from: now) }),
            ("{{latlon}}", {
                LocationProvider.shared.start()
                return LocationProvider.shared.formattedLatLon() ?? ""
            }),
        ]

        for (token, resolver) in fixedTokens {
            var searchRange = NSRange(location: 0, length: nsContent.length)
            while true {
                let range = nsContent.range(of: token, range: searchRange)
                if range.location == NSNotFound { break }
                results.append((range, resolver()))
                searchRange = NSRange(location: range.upperBound, length: nsContent.length - range.upperBound)
            }
        }

        // Custom date format: {{date:FORMAT}}
        if let regex = try? NSRegularExpression(pattern: #"\{\{date:([^}]+)\}\}"#) {
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for match in matches {
                guard let formatRange = Range(match.range(at: 1), in: content) else { continue }
                let fmt = DateFormatter()
                fmt.dateFormat = String(content[formatRange])
                results.append((match.range, fmt.string(from: now)))
            }
        }

        // Sort by location
        results.sort { $0.0.location < $1.0.location }
        return results
    }
}
