import Foundation

// Generated swift-bridge types and free functions are available from:
//   Generated/SwiftBridgeCore.swift  — RustString, RustVec, etc.
//   Generated/bridge-ffi.swift       — bridge_* functions and opaque types

// MARK: - BridgeCoreDatabase

/// Wraps the Rust BridgeDatabase opaque handle (thread-safe via Rust Mutex).
final class BridgeCoreDatabase: @unchecked Sendable {
    let inner: BridgeDatabase

    init(_ inner: BridgeDatabase) {
        self.inner = inner
    }

    static func open(path: URL) throws -> BridgeCoreDatabase {
        let db = try bridge_open_database(path.path)
        return BridgeCoreDatabase(db)
    }
}

// MARK: - BridgeCoreImageList

/// Wraps the Rust ImageEntryList opaque handle for deferred shot-group reindexing.
final class BridgeCoreImageList: @unchecked Sendable {
    let inner: ImageEntryList
    init(_ inner: ImageEntryList) { self.inner = inner }
}

// MARK: - BridgeCore

enum BridgeCore {

    // MARK: Scan

    /// Scan a directory and return (PhotoEntry array, opaque list handle).
    /// The opaque list handle must be kept alive until reindexShotGroups is called.
    static func scanDirectory(url: URL, db: BridgeCoreDatabase) async throws -> ([PhotoEntry], BridgeCoreImageList) {
        return await Task.detached(priority: .userInitiated) {
            let rawList = bridge_scan_directory(db.inner, url.path)
            let count = image_entry_list_count(rawList)
            var entries: [PhotoEntry] = []
            entries.reserveCapacity(Int(count))
            for i in 0..<count {
                let entry = image_entry_list_get(rawList, i)
                entries.append(PhotoEntry(ffiEntry: entry))
            }
            return (entries, BridgeCoreImageList(rawList))
        }.value
    }

    // MARK: EXIF

    static func fetchExif(url: URL, db: BridgeCoreDatabase) async -> ExifData? {
        return await Task.detached(priority: .utility) {
            let r = bridge_fetch_exif(db.inner, url.path)
            guard ffi_exif_found(r) else { return nil }
            return ExifData(
                make:          ffi_exif_make(r).toString().nonEmpty,
                model:         ffi_exif_model(r).toString().nonEmpty,
                datetime:      ffi_exif_datetime(r).toString().nonEmpty,
                subsec:        ffi_exif_subsec(r).toString().nonEmpty,
                exposureTime:  ffi_exif_exposure(r).toString().nonEmpty,
                fnumber:       ffi_exif_fnumber(r).toString().nonEmpty,
                iso:           Int(ffi_exif_iso(r)).nonZero,
                focalLength:     ffi_exif_focal_length(r).toString().nonEmpty,
                focalLength35mm: Int(ffi_exif_focal_length_35mm(r)).nonNegative,
                lensName:        ffi_exif_lens_model(r).toString().nonEmpty,
                width:           Int(ffi_exif_width(r)).nonZero,
                height:        Int(ffi_exif_height(r)).nonZero,
                software:      ffi_exif_software(r).toString().nonEmpty,
                artist:        ffi_exif_artist(r).toString().nonEmpty
            )
        }.value
    }

    /// 全エントリの EXIF を 1 SQLite 接続でバッチ取得する。
    /// 個別 fetchExif × N の 6000 connection-open 問題を解消するために使用。
    static func fetchExifBatch(list: BridgeCoreImageList, db: BridgeCoreDatabase) async -> [UInt64: ExifData] {
        return await Task.detached(priority: .utility) {
            let batch = bridge_fetch_exif_for_entries(db.inner, list.inner)
            let count = Int(ffi_exif_batch_count(batch))
            var result: [UInt64: ExifData] = [:]
            result.reserveCapacity(count)
            for i in 0..<count {
                let r = ffi_exif_batch_exif_at(batch, UInt(i))
                guard ffi_exif_found(r) else { continue }
                let entry = image_entry_list_get(list.inner, UInt(i))
                let id = ffi_image_entry_id(entry)
                result[id] = ExifData(
                    make:            ffi_exif_make(r).toString().nonEmpty,
                    model:           ffi_exif_model(r).toString().nonEmpty,
                    datetime:        ffi_exif_datetime(r).toString().nonEmpty,
                    subsec:          ffi_exif_subsec(r).toString().nonEmpty,
                    exposureTime:    ffi_exif_exposure(r).toString().nonEmpty,
                    fnumber:         ffi_exif_fnumber(r).toString().nonEmpty,
                    iso:             Int(ffi_exif_iso(r)).nonZero,
                    focalLength:     ffi_exif_focal_length(r).toString().nonEmpty,
                    focalLength35mm: Int(ffi_exif_focal_length_35mm(r)).nonNegative,
                    lensName:        ffi_exif_lens_model(r).toString().nonEmpty,
                    width:           Int(ffi_exif_width(r)).nonZero,
                    height:          Int(ffi_exif_height(r)).nonZero,
                    software:        ffi_exif_software(r).toString().nonEmpty,
                    artist:          ffi_exif_artist(r).toString().nonEmpty
                )
            }
            return result
        }.value
    }

    // MARK: XMP

    static func readXmp(url: URL) async -> XmpData? {
        return await Task.detached(priority: .utility) {
            let r = bridge_read_xmp(url.path)
            guard ffi_xmp_found(r) else { return nil }
            let ratingRaw = Int(ffi_xmp_rating(r))
            return XmpData(
                rating:    ratingRaw >= 0 ? ratingRaw : nil,
                label:     XmpLabel(rawValue: ffi_xmp_label(r)),
                developed: ffi_xmp_developed(r)
            )
        }.value
    }

    static func writeXmp(url: URL, xmp: XmpData, db: BridgeCoreDatabase) async -> Bool {
        return await Task.detached(priority: .utility) {
            bridge_write_xmp(
                db.inner,
                url.path,
                Int32(xmp.rating ?? -1),
                xmp.label?.rawValue ?? 0,
                0
            )
        }.value
    }

    // MARK: pHash

    static func computePHash(luma: Data) async -> UInt64 {
        return await Task.detached(priority: .utility) {
            luma.withUnsafeBytes { raw in
                bridge_compute_phash_from_luma(raw.bindMemory(to: UInt8.self))
            }
        }.value
    }

    static func fetchCachedPhash(url: URL, db: BridgeCoreDatabase) async -> UInt64? {
        return await Task.detached(priority: .utility) {
            let v = bridge_fetch_phash(db.inner, url.path)
            return v >= 0 ? UInt64(v) : nil
        }.value
    }

    static func storeCachedPhash(url: URL, phash: UInt64, db: BridgeCoreDatabase) async {
        await Task.detached(priority: .utility) {
            bridge_store_phash(db.inner, url.path, phash)
        }.value
    }

    // MARK: Thumbnail cache

    static func fetchCachedThumbnail(url: URL, db: BridgeCoreDatabase) async -> Data? {
        return await Task.detached(priority: .utility) {
            let r = bridge_fetch_cached_thumbnail(db.inner, url.path)
            guard ffi_optional_bytes_found(r) else { return nil }
            return Data(rustVec: ffi_optional_bytes_data(r))
        }.value
    }

    static func storeCachedThumbnail(url: URL, data: Data, db: BridgeCoreDatabase) async {
        await Task.detached(priority: .utility) {
            data.withUnsafeBytes { raw in
                bridge_store_cached_thumbnail(db.inner, url.path, raw.bindMemory(to: UInt8.self))
            }
        }.value
    }

    // MARK: RAW embedded JPEG

    static func extractRawJpeg(url: URL, quality: RawJpegQuality) async -> Data? {
        return await Task.detached(priority: .userInitiated) {
            let r = bridge_extract_raw_jpeg(url.path, quality.rawValue)
            guard ffi_optional_bytes_found(r) else { return nil }
            return Data(rustVec: ffi_optional_bytes_data(r))
        }.value
    }

    // MARK: Shot grouping

    static func reindexShotGroups(list: BridgeCoreImageList, db: BridgeCoreDatabase) async -> [UInt64: [UInt64]] {
        return await Task.detached(priority: .userInitiated) {
            let map = bridge_reindex_shot_groups(db.inner, list.inner)
            let count = shot_groups_map_count(map)
            var result: [UInt64: [UInt64]] = [:]
            result.reserveCapacity(Int(count))
            for i in 0..<count {
                let shotId = shot_groups_map_shot_id_at(map, i)
                let members = shot_groups_map_members_for(map, shotId)
                var ids: [UInt64] = []
                ids.reserveCapacity(Int(members.len()))
                for j in 0..<members.len() { ids.append(members[j]) }
                result[shotId] = ids
            }
            return result
        }.value
    }

    // MARK: Utilities

    static func isRaw(url: URL) -> Bool {
        bridge_is_raw(url.path)
    }
}

// MARK: - RawJpegQuality

enum RawJpegQuality: UInt8 {
    case thumbnail = 0
    case preview   = 1
    case full      = 2
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
    var nonNegative: Int? { self < 0 ? nil : self }
}

extension Data {
    init(rustVec: RustVec<UInt8>) {
        self.init(bytes: rustVec.as_ptr(), count: rustVec.len())
    }
}
