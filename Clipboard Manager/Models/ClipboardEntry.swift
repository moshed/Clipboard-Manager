import SwiftData
import Foundation

enum ContentType: String, Codable, CaseIterable {
    case text
    case rtf
    case image
    case screenshot
    case file
    case url

    var label: String {
        switch self {
        case .text: return "Text"
        case .rtf: return "Rich Text"
        case .image: return "Image"
        case .screenshot: return "Screenshot"
        case .file: return "File"
        case .url: return "URL"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "doc.text"
        case .rtf: return "doc.richtext"
        case .image: return "photo"
        case .screenshot: return "camera.viewfinder"
        case .file: return "doc"
        case .url: return "link"
        }
    }
}

@Model
final class ClipboardEntry {
    var id: UUID
    var timestamp: Date
    var textContent: String?
    var rtfData: Data?
    var rtfdData: Data?
    var imageData: Data?
    var filePaths: [String]?
    var contentTypeRaw: String
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var firstLine: String?
    var isPinned: Bool
    var ocrText: String?
    var sourceURL: String?

    var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .text }
        set { contentTypeRaw = newValue.rawValue }
    }

    init(
        textContent: String? = nil,
        rtfData: Data? = nil,
        rtfdData: Data? = nil,
        imageData: Data? = nil,
        filePaths: [String]? = nil,
        contentType: ContentType,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.textContent = textContent
        self.rtfData = rtfData
        self.rtfdData = rtfdData
        self.imageData = imageData
        self.filePaths = filePaths
        self.contentTypeRaw = contentType.rawValue
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.isPinned = false

        if let text = textContent {
            self.firstLine = String(text.prefix(200)).components(separatedBy: .newlines).first ?? ""
        } else if contentType == .screenshot {
            self.firstLine = "Screenshot"
        } else if contentType == .image {
            self.firstLine = "Image"
        } else if let paths = filePaths, !paths.isEmpty {
            self.firstLine = paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File"
        }
    }
}
