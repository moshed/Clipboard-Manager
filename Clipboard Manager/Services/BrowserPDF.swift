import AppKit

/// Gets the PDF shown in a browser's front tab and saves it as a real file.
///
/// A PDF open in Safari or Chrome has no file on disk, so Copy File Path used to beep there.
/// This downloads the PDF from the tab's URL, keeps it under Application Support, and gives
/// back a file URL that goes on the clipboard exactly like a Finder copy of the file.
///
/// Limit: the download does not carry the browser's login cookies. A PDF that needs a
/// sign-in (SharePoint, webmail attachments) comes back as an HTML login page, which the
/// `%PDF-` check rejects, so the caller beeps instead of copying the wrong thing.
enum BrowserPDF {
    /// Browsers we can ask for the front tab's URL: bundle ID -> AppleScript app name.
    static let browsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
    ]

    /// Newest downloaded PDFs to keep. History entries point at these files.
    static let keepCount = 50

    enum Failure: Error {
        case noTabURL
        case notPDF
        case download(String)
    }

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browsers[bundleID] != nil
    }

    static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("ClipboardManager", isDirectory: true)
            .appendingPathComponent("Browser PDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Find the front tab's PDF, download it when it is remote, and save it.
    /// The completion runs on the main queue.
    static func fetchFrontPDF(bundleID: String, completion: @escaping (Result<URL, Failure>) -> Void) {
        let finish: (Result<URL, Failure>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let tabURL = frontTabURL(bundleID: bundleID) else {
                finish(.failure(.noTabURL))
                return
            }

            // A local PDF opened in the browser is already a real file.
            if tabURL.isFileURL {
                let isPDF = (try? Data(contentsOf: tabURL, options: .mappedIfSafe)).map(hasPDFSignature) ?? false
                finish(isPDF ? .success(tabURL) : .failure(.notPDF))
                return
            }

            var request = URLRequest(url: tabURL, timeoutInterval: 30)
            request.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    finish(.failure(.download(error.localizedDescription)))
                    return
                }
                // Trust the bytes, not the URL or the MIME type: many PDF links have no
                // ".pdf", and a login page can arrive on a URL that ends in ".pdf".
                guard let data, hasPDFSignature(data) else {
                    finish(.failure(.notPDF))
                    return
                }
                let name = fileName(suggested: response?.suggestedFilename, url: tabURL)
                guard let saved = save(data, named: name) else {
                    finish(.failure(.download("could not write \(name)")))
                    return
                }
                finish(.success(saved))
            }.resume()
        }
    }

    // MARK: - Private

    /// URL of the front tab. Safari calls the tab a "document"; Chromium browsers use tabs.
    private static func frontTabURL(bundleID: String) -> URL? {
        guard let appName = browsers[bundleID] else { return nil }
        let script = bundleID.hasPrefix("com.apple.Safari")
            ? "tell application \"\(appName)\" to get URL of front document"
            : "tell application \"\(appName)\" to get URL of active tab of front window"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : URL(string: raw)
    }

    /// Every PDF file starts with the bytes "%PDF-".
    private static func hasPDFSignature(_ data: Data) -> Bool {
        data.prefix(5) == Data("%PDF-".utf8)
    }

    private static func fileName(suggested: String?, url: URL) -> String {
        var name = suggested ?? ""
        if name.isEmpty || name.lowercased() == "unknown" {
            name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name == "-" { name = "Document" }
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        return name
    }

    /// Save the bytes. Reuses an identical earlier download instead of making a duplicate.
    private static func save(_ data: Data, named name: String) -> URL? {
        let fm = FileManager.default
        let dir = directory
        let base = (name as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            if let existing = try? Data(contentsOf: candidate, options: .mappedIfSafe), existing == data {
                return candidate
            }
            candidate = dir.appendingPathComponent("\(base) \(n).pdf")
            n += 1
            if n > 99 { return nil }
        }
        guard (try? data.write(to: candidate)) != nil else { return nil }
        prune()
        return candidate
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(keepCount) { try? fm.removeItem(at: old) }
    }
}
