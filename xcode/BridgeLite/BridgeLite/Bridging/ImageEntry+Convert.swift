import Foundation

extension PhotoEntry {
    /// Construct a PhotoEntry from a swift-bridge FfiImageEntry opaque ref.
    init(ffiEntry: FfiImageEntry) {
        let path = ffi_image_entry_path(ffiEntry).toString()
        let modUnix = ffi_image_entry_modified_unix(ffiEntry)
        let creUnix = ffi_image_entry_created_unix(ffiEntry)
        self.init(
            id:             ffi_image_entry_id(ffiEntry),
            url:            URL(fileURLWithPath: path),
            filename:       ffi_image_entry_filename(ffiEntry).toString(),
            isRaw:          ffi_image_entry_is_raw(ffiEntry),
            fileSize:       ffi_image_entry_file_size(ffiEntry),
            modifiedDate:   modUnix >= 0 ? Date(timeIntervalSince1970: TimeInterval(modUnix)) : nil,
            createdDate:    creUnix >= 0 ? Date(timeIntervalSince1970: TimeInterval(creUnix)) : nil,
            hasJpgPartner:  ffi_image_entry_has_jpg_partner(ffiEntry),
            shotId:         ffi_image_entry_shot_id(ffiEntry)
        )
    }
}
