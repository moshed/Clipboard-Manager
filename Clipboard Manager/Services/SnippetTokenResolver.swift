import AppKit
import Foundation

enum SnippetTokenResolver {
    static func resolve(_ content: String) -> String {
        var result = content

        // {{clipboard}} — current pasteboard text
        if result.contains("{{clipboard}}") {
            let clipText = NSPasteboard.general.string(forType: .string) ?? ""
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
}
