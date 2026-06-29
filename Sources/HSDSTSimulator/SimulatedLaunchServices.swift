import Foundation

/// Deterministic in-memory model of the LaunchServices open-delivery decisions
/// that matter for URL and document-open tests.
public final class SimulatedLaunchServices {
    public enum Payload: Equatable {
        case url(String)
        case filePath(String)
    }

    public enum DeliveryOutcome: Equatable {
        case deliveredToURLHandler(bundleIdentifier: String)
        case deliveredToFileHandler(bundleIdentifier: String)
        case externalOpen(bundleIdentifier: String)
        case noHandler
    }

    public struct DeliveryLogEntry: Equatable {
        public let payload: Payload
        public let outcome: DeliveryOutcome

        public init(payload: Payload, outcome: DeliveryOutcome) {
            self.payload = payload
            self.outcome = outcome
        }
    }

    public typealias URLHandler = (String) -> Void
    public typealias FileHandler = (String) -> Void

    public private(set) var deliveryLog: [DeliveryLogEntry] = []

    public var urlSchemeDefaults: [String: String] = [:]
    public var fileExtensionDefaults: [String: String] = [:]
    public var contentTypeDefaults: [String: String] = [:]

    public let contentTypesByFileExtension: [String: String] = [
        "html": "public.html",
        "htm": "public.html",
        "shtml": "public.html",
        "jhtml": "public.html",
        "xhtml": "public.xhtml",
        "xht": "public.xhtml",
        "xhtm": "public.xhtml",
        "txt": "public.plain-text",
        "text": "public.plain-text",
        "url": "public.url",
    ]

    private var urlHandlers: [String: URLHandler] = [:]
    private var fileHandlers: [String: FileHandler] = [:]

    public init(seedSystemDefaults: Bool = true) {
        if seedSystemDefaults {
            seedDefaultHandlers()
        }
    }

    public func registerURLHandler(
        bundleIdentifier: String,
        handler: @escaping URLHandler
    ) {
        urlHandlers[bundleIdentifier] = handler
    }

    public func registerFileHandler(
        bundleIdentifier: String,
        handler: @escaping FileHandler
    ) {
        fileHandlers[bundleIdentifier] = handler
    }

    public func setDefaultURLHandler(_ bundleIdentifier: String, forScheme scheme: String) {
        urlSchemeDefaults[scheme.lowercased()] = bundleIdentifier
    }

    public func setDefaultDocumentHandler(
        _ bundleIdentifier: String,
        forFileExtension fileExtension: String
    ) {
        let normalizedExtension = normalizeFileExtension(fileExtension)
        if let contentType = contentTypesByFileExtension[normalizedExtension] {
            contentTypeDefaults[contentType] = bundleIdentifier
        } else {
            fileExtensionDefaults[normalizedExtension] = bundleIdentifier
        }
    }

    public func setDefaultContentTypeHandler(
        _ bundleIdentifier: String,
        forContentType contentType: String
    ) {
        contentTypeDefaults[contentType] = bundleIdentifier
    }

    @discardableResult
    public func openURL(_ urlString: String) -> Bool {
        let payload: Payload = .url(urlString)

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              let bundleIdentifier = urlSchemeDefaults[scheme] else {
            record(payload: payload, outcome: .noHandler)
            return false
        }

        if let handler = urlHandlers[bundleIdentifier] {
            handler(urlString)
            record(payload: payload, outcome: .deliveredToURLHandler(bundleIdentifier: bundleIdentifier))
        } else {
            record(payload: payload, outcome: .externalOpen(bundleIdentifier: bundleIdentifier))
        }
        return true
    }

    @discardableResult
    public func openFile(_ path: String) -> Bool {
        let payload: Payload = .filePath(path)

        guard let bundleIdentifier = defaultDocumentHandler(forPath: path) else {
            record(payload: payload, outcome: .noHandler)
            return false
        }

        if let handler = fileHandlers[bundleIdentifier] {
            handler(path)
            record(payload: payload, outcome: .deliveredToFileHandler(bundleIdentifier: bundleIdentifier))
        } else {
            record(payload: payload, outcome: .externalOpen(bundleIdentifier: bundleIdentifier))
        }
        return true
    }

    public func clearDeliveryLog() {
        deliveryLog.removeAll()
    }

    private func defaultDocumentHandler(forPath path: String) -> String? {
        let fileExtension = normalizeFileExtension((path as NSString).pathExtension)
        if let handler = fileExtensionDefaults[fileExtension] {
            return handler
        }

        guard let contentType = contentTypesByFileExtension[fileExtension] else {
            return nil
        }
        return contentTypeDefaults[contentType]
    }

    private func record(payload: Payload, outcome: DeliveryOutcome) {
        deliveryLog.append(DeliveryLogEntry(payload: payload, outcome: outcome))
    }

    private func normalizeFileExtension(_ fileExtension: String) -> String {
        fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private func seedDefaultHandlers() {
        setDefaultURLHandler("com.apple.Safari", forScheme: "http")
        setDefaultURLHandler("com.apple.Safari", forScheme: "https")
        setDefaultURLHandler("com.apple.Finder", forScheme: "file")

        setDefaultContentTypeHandler("com.apple.Safari", forContentType: "public.html")
        setDefaultContentTypeHandler("com.apple.Safari", forContentType: "public.xhtml")
        setDefaultContentTypeHandler("com.apple.TextEdit", forContentType: "public.plain-text")
        setDefaultContentTypeHandler("com.apple.Safari", forContentType: "public.url")
    }
}
