import Foundation

// iOS では常に sidecar モードで XMP を書き込む（SD カード上の元ファイルを改変しない）
enum JpgWriteMode: String, CaseIterable, Identifiable {
    case embed
    case sidecar
    var id: String { rawValue }
}
