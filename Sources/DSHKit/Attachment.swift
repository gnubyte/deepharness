import Foundation
import UniformTypeIdentifiers

/// One image staged for a prompt.
///
/// Nothing is durable until the prompt is submitted — the harness commits the
/// batch before the user event, so a staged attachment the user removes never
/// reaches storage.
public struct Attachment: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let mediaType: String
    public let data: Data

    public init(name: String, mediaType: String, data: Data) {
        self.name = name
        self.mediaType = mediaType
        self.data = data
    }

    /// The raster vocabulary shared by the harness attachment store and ACP.
    public static let supportedMediaTypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp", "image/gif",
    ]

    public static let supportedContentTypes: [UTType] = [.png, .jpeg, .webP, .gif]

    /// Load a file from disk, rejecting anything outside the supported rasters.
    public static func load(from url: URL) throws -> Attachment {
        let data = try Data(contentsOf: url)
        guard let mediaType = mediaType(for: url) else {
            throw AttachmentError.unsupportedType(url.pathExtension)
        }
        return Attachment(name: url.lastPathComponent, mediaType: mediaType, data: data)
    }

    /// Resolve a media type, preferring the file's declared UTType and falling
    /// back to its extension.
    public static func mediaType(for url: URL) -> String? {
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .png) { return "image/png" }
            if type.conforms(to: .jpeg) { return "image/jpeg" }
            if type.conforms(to: .webP) { return "image/webp" }
            if type.conforms(to: .gif) { return "image/gif" }
        }
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return nil
        }
    }

    /// Human-readable size for the composer chip.
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

public enum AttachmentError: Error, LocalizedError {
    case unsupportedType(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            let supported = "PNG, JPEG, WebP, GIF"
            return ext.isEmpty
                ? "That file has no extension — attachments must be \(supported)."
                : "‘.\(ext)’ files can’t be attached — attachments must be \(supported)."
        }
    }
}
