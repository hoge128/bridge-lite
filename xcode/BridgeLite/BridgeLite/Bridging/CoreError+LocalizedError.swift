import Foundation

// BridgeFfiError is a swift-bridge opaque class. Make it throwable.
extension BridgeFfiError: Swift.Error {}

enum BridgeCoreError: Error, LocalizedError {
    case io(path: String, message: String)
    case unsupportedFormat(path: String)
    case xmpParse(path: String, message: String)
    case xmpWrite(path: String, message: String)
    case db(message: String)
    case thumbnailDecode(path: String)
    case notFound(path: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .io(let path, let msg):        return String(localized: "IO error: \(msg) (\(path))")
        case .unsupportedFormat(let path):  return String(localized: "Unsupported format: \(path)")
        case .xmpParse(_, let msg):         return String(localized: "XMP error: \(msg)")
        case .xmpWrite(_, let msg):         return String(localized: "Write failed: \(msg)")
        case .db(let msg):                  return String(localized: "Database error: \(msg)")
        case .thumbnailDecode(let path):    return String(localized: "Cannot load: \(path)")
        case .notFound(let path):           return String(localized: "Not found: \(path)")
        case .cancelled:                    return String(localized: "Cancelled")
        }
    }
}
