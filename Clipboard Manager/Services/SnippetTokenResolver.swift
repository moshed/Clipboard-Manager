import AppKit
import Foundation

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
