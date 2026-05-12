public func bridge_open_database<GenericToRustStr: ToRustStr>(_ db_path: GenericToRustStr) throws -> BridgeDatabase {
    return db_path.toRustStr({ db_pathAsRustStr in
        try { let val = __swift_bridge__$bridge_open_database(db_pathAsRustStr); if val.is_ok { return BridgeDatabase(ptr: val.ok_or_err!) } else { throw BridgeFfiError(ptr: val.ok_or_err!) } }()
    })
}
public func bridge_ffi_error_message(_ e: BridgeFfiErrorRef) -> RustString {
    RustString(ptr: __swift_bridge__$bridge_ffi_error_message(e.ptr))
}
public func bridge_scan_directory<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr) -> ImageEntryList {
    return path.toRustStr({ pathAsRustStr in
        ImageEntryList(ptr: __swift_bridge__$bridge_scan_directory(db.ptr, pathAsRustStr))
    })
}
public func image_entry_list_count(_ list: ImageEntryListRef) -> UInt {
    __swift_bridge__$image_entry_list_count(list.ptr)
}
public func image_entry_list_total_files(_ list: ImageEntryListRef) -> UInt {
    __swift_bridge__$image_entry_list_total_files(list.ptr)
}
public func image_entry_list_image_files(_ list: ImageEntryListRef) -> UInt {
    __swift_bridge__$image_entry_list_image_files(list.ptr)
}
public func image_entry_list_get(_ list: ImageEntryListRef, _ idx: UInt) -> FfiImageEntry {
    FfiImageEntry(ptr: __swift_bridge__$image_entry_list_get(list.ptr, idx))
}
public func ffi_image_entry_id(_ entry: FfiImageEntryRef) -> UInt64 {
    __swift_bridge__$ffi_image_entry_id(entry.ptr)
}
public func ffi_image_entry_path(_ entry: FfiImageEntryRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_image_entry_path(entry.ptr))
}
public func ffi_image_entry_filename(_ entry: FfiImageEntryRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_image_entry_filename(entry.ptr))
}
public func ffi_image_entry_is_raw(_ entry: FfiImageEntryRef) -> Bool {
    __swift_bridge__$ffi_image_entry_is_raw(entry.ptr)
}
public func ffi_image_entry_file_size(_ entry: FfiImageEntryRef) -> UInt64 {
    __swift_bridge__$ffi_image_entry_file_size(entry.ptr)
}
public func ffi_image_entry_modified_unix(_ entry: FfiImageEntryRef) -> Int64 {
    __swift_bridge__$ffi_image_entry_modified_unix(entry.ptr)
}
public func ffi_image_entry_created_unix(_ entry: FfiImageEntryRef) -> Int64 {
    __swift_bridge__$ffi_image_entry_created_unix(entry.ptr)
}
public func ffi_image_entry_has_jpg_partner(_ entry: FfiImageEntryRef) -> Bool {
    __swift_bridge__$ffi_image_entry_has_jpg_partner(entry.ptr)
}
public func ffi_image_entry_shot_id(_ entry: FfiImageEntryRef) -> UInt64 {
    __swift_bridge__$ffi_image_entry_shot_id(entry.ptr)
}
public func bridge_fetch_exif<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr) -> FfiExifResult {
    return path.toRustStr({ pathAsRustStr in
        FfiExifResult(ptr: __swift_bridge__$bridge_fetch_exif(db.ptr, pathAsRustStr))
    })
}
public func bridge_fetch_exif_for_entries(_ db: BridgeDatabaseRef, _ entries: ImageEntryListRef) -> FfiExifBatch {
    FfiExifBatch(ptr: __swift_bridge__$bridge_fetch_exif_for_entries(db.ptr, entries.ptr))
}
public func ffi_exif_batch_count(_ r: FfiExifBatchRef) -> UInt {
    __swift_bridge__$ffi_exif_batch_count(r.ptr)
}
public func ffi_exif_batch_exif_at(_ r: FfiExifBatchRef, _ idx: UInt) -> FfiExifResult {
    FfiExifResult(ptr: __swift_bridge__$ffi_exif_batch_exif_at(r.ptr, idx))
}
public func ffi_exif_found(_ r: FfiExifResultRef) -> Bool {
    __swift_bridge__$ffi_exif_found(r.ptr)
}
public func ffi_exif_make(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_make(r.ptr))
}
public func ffi_exif_model(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_model(r.ptr))
}
public func ffi_exif_datetime(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_datetime(r.ptr))
}
public func ffi_exif_subsec(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_subsec(r.ptr))
}
public func ffi_exif_exposure(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_exposure(r.ptr))
}
public func ffi_exif_fnumber(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_fnumber(r.ptr))
}
public func ffi_exif_iso(_ r: FfiExifResultRef) -> Int32 {
    __swift_bridge__$ffi_exif_iso(r.ptr)
}
public func ffi_exif_focal_length(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_focal_length(r.ptr))
}
public func ffi_exif_focal_length_35mm(_ r: FfiExifResultRef) -> Int32 {
    __swift_bridge__$ffi_exif_focal_length_35mm(r.ptr)
}
public func ffi_exif_lens_model(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_lens_model(r.ptr))
}
public func ffi_exif_width(_ r: FfiExifResultRef) -> Int32 {
    __swift_bridge__$ffi_exif_width(r.ptr)
}
public func ffi_exif_height(_ r: FfiExifResultRef) -> Int32 {
    __swift_bridge__$ffi_exif_height(r.ptr)
}
public func ffi_exif_software(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_software(r.ptr))
}
public func ffi_exif_artist(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_artist(r.ptr))
}
public func ffi_exif_exposure_bias(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_exposure_bias(r.ptr))
}
public func ffi_exif_flash(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_flash(r.ptr))
}
public func ffi_exif_white_balance(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_white_balance(r.ptr))
}
public func ffi_exif_image_description(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_image_description(r.ptr))
}
public func ffi_exif_user_comment(_ r: FfiExifResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_exif_user_comment(r.ptr))
}
public func bridge_read_xmp<GenericToRustStr: ToRustStr>(_ path: GenericToRustStr, _ jpg_use_sidecar: Bool) -> FfiXmpResult {
    return path.toRustStr({ pathAsRustStr in
        FfiXmpResult(ptr: __swift_bridge__$bridge_read_xmp(pathAsRustStr, jpg_use_sidecar))
    })
}
public func ffi_xmp_found(_ r: FfiXmpResultRef) -> Bool {
    __swift_bridge__$ffi_xmp_found(r.ptr)
}
public func ffi_xmp_rating(_ r: FfiXmpResultRef) -> Int32 {
    __swift_bridge__$ffi_xmp_rating(r.ptr)
}
public func ffi_xmp_label(_ r: FfiXmpResultRef) -> UInt8 {
    __swift_bridge__$ffi_xmp_label(r.ptr)
}
public func ffi_xmp_flag(_ r: FfiXmpResultRef) -> UInt8 {
    __swift_bridge__$ffi_xmp_flag(r.ptr)
}
public func ffi_xmp_developed(_ r: FfiXmpResultRef) -> Bool {
    __swift_bridge__$ffi_xmp_developed(r.ptr)
}
public func ffi_xmp_caption(_ r: FfiXmpResultRef) -> RustString {
    RustString(ptr: __swift_bridge__$ffi_xmp_caption(r.ptr))
}
public func bridge_write_xmp<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr, _ rating: Int32, _ label: UInt8, _ flag: UInt8, _ caption: GenericToRustStr, _ caption_present: Bool, _ jpg_use_sidecar: Bool) -> Bool {
    return caption.toRustStr({ captionAsRustStr in
        return path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_write_xmp(db.ptr, pathAsRustStr, rating, label, flag, captionAsRustStr, caption_present, jpg_use_sidecar)
    })
    })
}
public func bridge_jpg_has_rated_embedded_xmp<GenericToRustStr: ToRustStr>(_ path: GenericToRustStr) -> Bool {
    return path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_jpg_has_rated_embedded_xmp(pathAsRustStr)
    })
}
public func bridge_compute_phash_from_luma(_ pixels: UnsafeBufferPointer<UInt8>) -> UInt64 {
    __swift_bridge__$bridge_compute_phash_from_luma(pixels.toFfiSlice())
}
public func bridge_fetch_phash<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr) -> Int64 {
    return path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_fetch_phash(db.ptr, pathAsRustStr)
    })
}
public func bridge_store_phash<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr, _ phash: UInt64) {
    path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_store_phash(db.ptr, pathAsRustStr, phash)
    })
}
public func bridge_fetch_cached_thumbnail<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr) -> FfiOptionalBytes {
    return path.toRustStr({ pathAsRustStr in
        FfiOptionalBytes(ptr: __swift_bridge__$bridge_fetch_cached_thumbnail(db.ptr, pathAsRustStr))
    })
}
public func ffi_optional_bytes_found(_ r: FfiOptionalBytesRef) -> Bool {
    __swift_bridge__$ffi_optional_bytes_found(r.ptr)
}
public func ffi_optional_bytes_data(_ r: FfiOptionalBytesRef) -> RustVec<UInt8> {
    RustVec(ptr: __swift_bridge__$ffi_optional_bytes_data(r.ptr))
}
public func bridge_store_cached_thumbnail<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr, _ jpeg: UnsafeBufferPointer<UInt8>) {
    path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_store_cached_thumbnail(db.ptr, pathAsRustStr, jpeg.toFfiSlice())
    })
}
public func bridge_fetch_cached_thumbnails_for_entries(_ db: BridgeDatabaseRef, _ entries: ImageEntryListRef) -> FfiThumbBatch {
    FfiThumbBatch(ptr: __swift_bridge__$bridge_fetch_cached_thumbnails_for_entries(db.ptr, entries.ptr))
}
public func ffi_thumb_batch_count(_ r: FfiThumbBatchRef) -> UInt {
    __swift_bridge__$ffi_thumb_batch_count(r.ptr)
}
public func ffi_thumb_batch_jpeg_at(_ r: FfiThumbBatchRef, _ idx: UInt) -> FfiOptionalBytes {
    FfiOptionalBytes(ptr: __swift_bridge__$ffi_thumb_batch_jpeg_at(r.ptr, idx))
}
public func bridge_fetch_cached_rendered<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr, _ engine: GenericToRustStr, _ width: UInt32) -> FfiOptionalBytes {
    return engine.toRustStr({ engineAsRustStr in
        return path.toRustStr({ pathAsRustStr in
        FfiOptionalBytes(ptr: __swift_bridge__$bridge_fetch_cached_rendered(db.ptr, pathAsRustStr, engineAsRustStr, width))
    })
    })
}
public func bridge_store_cached_rendered<GenericToRustStr: ToRustStr>(_ db: BridgeDatabaseRef, _ path: GenericToRustStr, _ engine: GenericToRustStr, _ width: UInt32, _ jpeg: UnsafeBufferPointer<UInt8>) {
    engine.toRustStr({ engineAsRustStr in
        path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_store_cached_rendered(db.ptr, pathAsRustStr, engineAsRustStr, width, jpeg.toFfiSlice())
    })
    })
}
public func bridge_clear_rendered_cache(_ db: BridgeDatabaseRef) {
    __swift_bridge__$bridge_clear_rendered_cache(db.ptr)
}
public func bridge_prune_cache(_ db: BridgeDatabaseRef, _ max_age_days: UInt32) {
    __swift_bridge__$bridge_prune_cache(db.ptr, max_age_days)
}
public func bridge_extract_raw_jpeg<GenericToRustStr: ToRustStr>(_ path: GenericToRustStr, _ quality: UInt8) -> FfiOptionalBytes {
    return path.toRustStr({ pathAsRustStr in
        FfiOptionalBytes(ptr: __swift_bridge__$bridge_extract_raw_jpeg(pathAsRustStr, quality))
    })
}
public func bridge_reindex_shot_groups(_ db: BridgeDatabaseRef, _ entries: ImageEntryListRef, _ split_threshold_secs: Int64, _ phash_hamming_threshold: UInt32) -> ShotGroupsMap {
    ShotGroupsMap(ptr: __swift_bridge__$bridge_reindex_shot_groups(db.ptr, entries.ptr, split_threshold_secs, phash_hamming_threshold))
}
public func shot_groups_map_count(_ m: ShotGroupsMapRef) -> UInt {
    __swift_bridge__$shot_groups_map_count(m.ptr)
}
public func shot_groups_map_shot_id_at(_ m: ShotGroupsMapRef, _ idx: UInt) -> UInt64 {
    __swift_bridge__$shot_groups_map_shot_id_at(m.ptr, idx)
}
public func shot_groups_map_members_for(_ m: ShotGroupsMapRef, _ shot_id: UInt64) -> RustVec<UInt64> {
    RustVec(ptr: __swift_bridge__$shot_groups_map_members_for(m.ptr, shot_id))
}
public func bridge_is_raw<GenericToRustStr: ToRustStr>(_ path: GenericToRustStr) -> Bool {
    return path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_is_raw(pathAsRustStr)
    })
}
public func bridge_developed_keywords() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$bridge_developed_keywords())
}
public func bridge_has_images_beyond_scan_depth<GenericToRustStr: ToRustStr>(_ path: GenericToRustStr) -> Bool {
    return path.toRustStr({ pathAsRustStr in
        __swift_bridge__$bridge_has_images_beyond_scan_depth(pathAsRustStr)
    })
}

public class ShotGroupsMap: ShotGroupsMapRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$ShotGroupsMap$_free(ptr)
        }
    }
}
public class ShotGroupsMapRefMut: ShotGroupsMapRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class ShotGroupsMapRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension ShotGroupsMap: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_ShotGroupsMap$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_ShotGroupsMap$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: ShotGroupsMap) {
        __swift_bridge__$Vec_ShotGroupsMap$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_ShotGroupsMap$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (ShotGroupsMap(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<ShotGroupsMapRef> {
        let pointer = __swift_bridge__$Vec_ShotGroupsMap$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return ShotGroupsMapRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<ShotGroupsMapRefMut> {
        let pointer = __swift_bridge__$Vec_ShotGroupsMap$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return ShotGroupsMapRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<ShotGroupsMapRef> {
        UnsafePointer<ShotGroupsMapRef>(OpaquePointer(__swift_bridge__$Vec_ShotGroupsMap$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_ShotGroupsMap$len(vecPtr)
    }
}


public class FfiThumbBatch: FfiThumbBatchRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FfiThumbBatch$_free(ptr)
        }
    }
}
public class FfiThumbBatchRefMut: FfiThumbBatchRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FfiThumbBatchRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FfiThumbBatch: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FfiThumbBatch$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FfiThumbBatch$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FfiThumbBatch) {
        __swift_bridge__$Vec_FfiThumbBatch$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FfiThumbBatch$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FfiThumbBatch(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiThumbBatchRef> {
        let pointer = __swift_bridge__$Vec_FfiThumbBatch$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiThumbBatchRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiThumbBatchRefMut> {
        let pointer = __swift_bridge__$Vec_FfiThumbBatch$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiThumbBatchRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FfiThumbBatchRef> {
        UnsafePointer<FfiThumbBatchRef>(OpaquePointer(__swift_bridge__$Vec_FfiThumbBatch$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FfiThumbBatch$len(vecPtr)
    }
}


public class FfiOptionalBytes: FfiOptionalBytesRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FfiOptionalBytes$_free(ptr)
        }
    }
}
public class FfiOptionalBytesRefMut: FfiOptionalBytesRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FfiOptionalBytesRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FfiOptionalBytes: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FfiOptionalBytes$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FfiOptionalBytes$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FfiOptionalBytes) {
        __swift_bridge__$Vec_FfiOptionalBytes$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FfiOptionalBytes$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FfiOptionalBytes(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiOptionalBytesRef> {
        let pointer = __swift_bridge__$Vec_FfiOptionalBytes$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiOptionalBytesRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiOptionalBytesRefMut> {
        let pointer = __swift_bridge__$Vec_FfiOptionalBytes$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiOptionalBytesRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FfiOptionalBytesRef> {
        UnsafePointer<FfiOptionalBytesRef>(OpaquePointer(__swift_bridge__$Vec_FfiOptionalBytes$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FfiOptionalBytes$len(vecPtr)
    }
}


public class FfiXmpResult: FfiXmpResultRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FfiXmpResult$_free(ptr)
        }
    }
}
public class FfiXmpResultRefMut: FfiXmpResultRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FfiXmpResultRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FfiXmpResult: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FfiXmpResult$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FfiXmpResult$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FfiXmpResult) {
        __swift_bridge__$Vec_FfiXmpResult$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FfiXmpResult$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FfiXmpResult(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiXmpResultRef> {
        let pointer = __swift_bridge__$Vec_FfiXmpResult$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiXmpResultRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiXmpResultRefMut> {
        let pointer = __swift_bridge__$Vec_FfiXmpResult$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiXmpResultRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FfiXmpResultRef> {
        UnsafePointer<FfiXmpResultRef>(OpaquePointer(__swift_bridge__$Vec_FfiXmpResult$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FfiXmpResult$len(vecPtr)
    }
}


public class FfiExifBatch: FfiExifBatchRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FfiExifBatch$_free(ptr)
        }
    }
}
public class FfiExifBatchRefMut: FfiExifBatchRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FfiExifBatchRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FfiExifBatch: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FfiExifBatch$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FfiExifBatch$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FfiExifBatch) {
        __swift_bridge__$Vec_FfiExifBatch$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FfiExifBatch$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FfiExifBatch(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiExifBatchRef> {
        let pointer = __swift_bridge__$Vec_FfiExifBatch$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiExifBatchRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiExifBatchRefMut> {
        let pointer = __swift_bridge__$Vec_FfiExifBatch$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiExifBatchRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FfiExifBatchRef> {
        UnsafePointer<FfiExifBatchRef>(OpaquePointer(__swift_bridge__$Vec_FfiExifBatch$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FfiExifBatch$len(vecPtr)
    }
}


public class FfiExifResult: FfiExifResultRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FfiExifResult$_free(ptr)
        }
    }
}
public class FfiExifResultRefMut: FfiExifResultRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FfiExifResultRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FfiExifResult: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FfiExifResult$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FfiExifResult$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FfiExifResult) {
        __swift_bridge__$Vec_FfiExifResult$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FfiExifResult$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FfiExifResult(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiExifResultRef> {
        let pointer = __swift_bridge__$Vec_FfiExifResult$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiExifResultRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiExifResultRefMut> {
        let pointer = __swift_bridge__$Vec_FfiExifResult$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiExifResultRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FfiExifResultRef> {
        UnsafePointer<FfiExifResultRef>(OpaquePointer(__swift_bridge__$Vec_FfiExifResult$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FfiExifResult$len(vecPtr)
    }
}


public class FfiImageEntry: FfiImageEntryRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FfiImageEntry$_free(ptr)
        }
    }
}
public class FfiImageEntryRefMut: FfiImageEntryRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FfiImageEntryRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FfiImageEntry: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FfiImageEntry$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FfiImageEntry$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FfiImageEntry) {
        __swift_bridge__$Vec_FfiImageEntry$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FfiImageEntry$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FfiImageEntry(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiImageEntryRef> {
        let pointer = __swift_bridge__$Vec_FfiImageEntry$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiImageEntryRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FfiImageEntryRefMut> {
        let pointer = __swift_bridge__$Vec_FfiImageEntry$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FfiImageEntryRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FfiImageEntryRef> {
        UnsafePointer<FfiImageEntryRef>(OpaquePointer(__swift_bridge__$Vec_FfiImageEntry$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FfiImageEntry$len(vecPtr)
    }
}


public class ImageEntryList: ImageEntryListRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$ImageEntryList$_free(ptr)
        }
    }
}
public class ImageEntryListRefMut: ImageEntryListRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class ImageEntryListRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension ImageEntryList: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_ImageEntryList$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_ImageEntryList$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: ImageEntryList) {
        __swift_bridge__$Vec_ImageEntryList$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_ImageEntryList$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (ImageEntryList(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<ImageEntryListRef> {
        let pointer = __swift_bridge__$Vec_ImageEntryList$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return ImageEntryListRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<ImageEntryListRefMut> {
        let pointer = __swift_bridge__$Vec_ImageEntryList$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return ImageEntryListRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<ImageEntryListRef> {
        UnsafePointer<ImageEntryListRef>(OpaquePointer(__swift_bridge__$Vec_ImageEntryList$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_ImageEntryList$len(vecPtr)
    }
}


public class BridgeFfiError: BridgeFfiErrorRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$BridgeFfiError$_free(ptr)
        }
    }
}
public class BridgeFfiErrorRefMut: BridgeFfiErrorRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class BridgeFfiErrorRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension BridgeFfiError: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_BridgeFfiError$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_BridgeFfiError$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: BridgeFfiError) {
        __swift_bridge__$Vec_BridgeFfiError$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_BridgeFfiError$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (BridgeFfiError(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<BridgeFfiErrorRef> {
        let pointer = __swift_bridge__$Vec_BridgeFfiError$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return BridgeFfiErrorRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<BridgeFfiErrorRefMut> {
        let pointer = __swift_bridge__$Vec_BridgeFfiError$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return BridgeFfiErrorRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<BridgeFfiErrorRef> {
        UnsafePointer<BridgeFfiErrorRef>(OpaquePointer(__swift_bridge__$Vec_BridgeFfiError$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_BridgeFfiError$len(vecPtr)
    }
}


public class BridgeDatabase: BridgeDatabaseRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$BridgeDatabase$_free(ptr)
        }
    }
}
public class BridgeDatabaseRefMut: BridgeDatabaseRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class BridgeDatabaseRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension BridgeDatabase: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_BridgeDatabase$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_BridgeDatabase$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: BridgeDatabase) {
        __swift_bridge__$Vec_BridgeDatabase$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_BridgeDatabase$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (BridgeDatabase(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<BridgeDatabaseRef> {
        let pointer = __swift_bridge__$Vec_BridgeDatabase$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return BridgeDatabaseRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<BridgeDatabaseRefMut> {
        let pointer = __swift_bridge__$Vec_BridgeDatabase$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return BridgeDatabaseRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<BridgeDatabaseRef> {
        UnsafePointer<BridgeDatabaseRef>(OpaquePointer(__swift_bridge__$Vec_BridgeDatabase$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_BridgeDatabase$len(vecPtr)
    }
}



