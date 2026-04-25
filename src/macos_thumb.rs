//! macOS-native fast thumbnail/preview generation via CGImageSource.
// Rust 2024: explicit unsafe{} inside unsafe fn – suppressed for this raw FFI module.
#![allow(unsafe_op_in_unsafe_fn)]
//!
//! CGImageSourceCreateThumbnailAtIndex() leverages JPEG subsampling and
//! embedded camera previews → ~16ms per image (vs 100–300ms full decode).
//! EXIF orientation is auto-applied via kCGImageSourceCreateThumbnailWithTransform.

#![cfg(target_os = "macos")]

use std::ffi::c_void;
use std::path::Path;

// ── Type aliases ────────────────────────────────────────────────────────────

type CFTypeRef       = *const c_void;
type CFAllocatorRef  = *const c_void;
type CFStringRef     = *const c_void;
type CFNumberRef     = *const c_void;
type CFDictionaryRef = *const c_void;
type CFURLRef        = *const c_void;
type CgiSourceRef    = *const c_void;
type CgiRef          = *const c_void;
type CGContextRef    = *const c_void;
type CGColorSpaceRef = *const c_void;
type CGFloat         = f64;

#[repr(C)] struct CGPoint  { x: CGFloat, y: CGFloat }
#[repr(C)] struct CGSize   { width: CGFloat, height: CGFloat }
#[repr(C)] struct CGRect   { origin: CGPoint, size: CGSize }

// ── CF constants ────────────────────────────────────────────────────────────

const CF_STRING_ENC_UTF8: u32   = 0x0800_0100;
const CFURL_POSIX_STYLE: i64    = 0;
const CF_NUMBER_SINT32: i64     = 3;

// CGBitmapInfo: kCGBitmapByteOrder32Big(4<<12) | kCGImageAlphaPremultipliedLast(1)
// → R,G,B,A byte order in memory on little-endian macOS (Apple Silicon & Intel)
const BITMAP_RGBA: u32 = (4 << 12) | 1;

// ── CoreFoundation ──────────────────────────────────────────────────────────

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFStringCreateWithBytes(
        alloc:   CFAllocatorRef,
        bytes:   *const u8,
        len:     isize,
        enc:     u32,
        is_ext:  u8,
    ) -> CFStringRef;
    fn CFURLCreateWithFileSystemPath(
        alloc:    CFAllocatorRef,
        path:     CFStringRef,
        style:    i64,
        is_dir:   u8,
    ) -> CFURLRef;
    fn CFDictionaryCreate(
        alloc:        CFAllocatorRef,
        keys:         *const CFTypeRef,
        values:       *const CFTypeRef,
        num:          isize,
        key_cbs:      *const c_void,
        val_cbs:      *const c_void,
    ) -> CFDictionaryRef;
    fn CFNumberCreate(
        alloc:      CFAllocatorRef,
        the_type:   i64,
        value_ptr:  *const c_void,
    ) -> CFNumberRef;
    static kCFBooleanTrue:  CFTypeRef;
    static kCFBooleanFalse: CFTypeRef;
    static kCFTypeDictionaryKeyCallBacks:   c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
}

// ── ImageIO ─────────────────────────────────────────────────────────────────

#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    static kCGImageSourceThumbnailMaxPixelSize:            CFStringRef;
    static kCGImageSourceCreateThumbnailFromImageIfAbsent: CFStringRef;
    static kCGImageSourceCreateThumbnailWithTransform:     CFStringRef;
    static kCGImageSourceShouldCache:                      CFStringRef;
    fn CGImageSourceCreateWithURL(
        url:     CFURLRef,
        options: CFDictionaryRef,
    ) -> CgiSourceRef;
    fn CGImageSourceCreateThumbnailAtIndex(
        src:     CgiSourceRef,
        index:   usize,
        options: CFDictionaryRef,
    ) -> CgiRef;
    fn CGImageSourceCreateImageAtIndex(
        src:     CgiSourceRef,
        index:   usize,
        options: CFDictionaryRef,
    ) -> CgiRef;
}

// ── CoreGraphics ────────────────────────────────────────────────────────────

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGImageGetWidth(img: CgiRef) -> usize;
    fn CGImageGetHeight(img: CgiRef) -> usize;
    fn CGImageRelease(img: CgiRef);
    fn CGColorSpaceCreateDeviceRGB() -> CGColorSpaceRef;
    fn CGColorSpaceRelease(cs: CGColorSpaceRef);
    fn CGBitmapContextCreate(
        data:              *mut c_void,
        width:             usize,
        height:            usize,
        bits_per_comp:     usize,
        bytes_per_row:     usize,
        space:             CGColorSpaceRef,
        bitmap_info:       u32,
    ) -> CGContextRef;
    fn CGContextDrawImage(ctx: CGContextRef, rect: CGRect, img: CgiRef);
    fn CGContextRelease(ctx: CGContextRef);
}

// ── Public API ──────────────────────────────────────────────────────────────

/// Generate a thumbnail via CGImageSource (EXIF rotation included).
/// `max_px` caps the long edge; aspect ratio is preserved (no center-crop).
/// Returns `(width, height, rgba_bytes)` or `None` on failure.
pub fn create_thumbnail(path: &Path, max_px: u32) -> Option<(u32, u32, Vec<u8>)> {
    unsafe { thumbnail_impl(path, max_px) }
}

/// Load a full-resolution image via CGImageSource (EXIF rotation included).
/// `max_px` = 0 means no size limit (use full file resolution).
pub fn load_image(path: &Path, max_px: u32) -> Option<(u32, u32, Vec<u8>)> {
    unsafe { image_impl(path, max_px) }
}

// ── Path → CFURL ────────────────────────────────────────────────────────────

unsafe fn path_to_cfurl(path: &Path) -> Option<CFURLRef> {
    let s = path.to_str()?;
    let bytes = s.as_bytes();
    let cf_str = CFStringCreateWithBytes(
        std::ptr::null(),
        bytes.as_ptr(),
        bytes.len() as isize,
        CF_STRING_ENC_UTF8,
        0,
    );
    if cf_str.is_null() { return None; }
    let url = CFURLCreateWithFileSystemPath(
        std::ptr::null(), cf_str, CFURL_POSIX_STYLE, 0,
    );
    CFRelease(cf_str);
    if url.is_null() { None } else { Some(url) }
}

// ── Thumbnail options dict ──────────────────────────────────────────────────

unsafe fn make_thumb_options(max_px: u32) -> CFDictionaryRef {
    let max = max_px as i32;
    let size_num = CFNumberCreate(
        std::ptr::null(), CF_NUMBER_SINT32,
        &max as *const i32 as *const c_void,
    );
    // Prefer embedded previews (640×480 for most cameras) over a full decode.
    // Full decode of a 6240×4160 JPEG uses ~104 MB; with 16 concurrent tasks
    // that exceeds 1.6 GB and causes CGImageSource to return null under pressure.
    // kCGImageSourceCreateThumbnailFromImageIfAbsent falls back to full decode
    // only when no embedded thumbnail exists (e.g. DxO-output DNG).
    let keys:   [CFTypeRef; 4] = [
        kCGImageSourceThumbnailMaxPixelSize,
        kCGImageSourceCreateThumbnailFromImageIfAbsent,
        kCGImageSourceCreateThumbnailWithTransform,
        kCGImageSourceShouldCache,
    ];
    let values: [CFTypeRef; 4] = [
        size_num as CFTypeRef,
        kCFBooleanTrue,
        kCFBooleanTrue,  // auto-applies EXIF orientation
        kCFBooleanFalse, // don't cache; we handle caching ourselves
    ];
    let dict = CFDictionaryCreate(
        std::ptr::null(),
        keys.as_ptr(),
        values.as_ptr(),
        4,
        &kCFTypeDictionaryKeyCallBacks as *const c_void,
        &kCFTypeDictionaryValueCallBacks as *const c_void,
    );
    CFRelease(size_num as CFTypeRef);
    dict
}

// ── CGImage → RGBA bytes ────────────────────────────────────────────────────

unsafe fn cg_image_to_rgba(cg_image: CgiRef) -> Option<(u32, u32, Vec<u8>)> {
    let w = CGImageGetWidth(cg_image);
    let h = CGImageGetHeight(cg_image);
    if w == 0 || h == 0 { return None; }

    let bpr = w * 4;
    let mut pixels = vec![0u8; h * bpr];

    let cs = CGColorSpaceCreateDeviceRGB();
    let ctx = CGBitmapContextCreate(
        pixels.as_mut_ptr() as *mut c_void,
        w, h, 8, bpr, cs, BITMAP_RGBA,
    );
    CGColorSpaceRelease(cs);
    if ctx.is_null() { return None; }

    // No Y-flip: CGImageSource (with kCGImageSourceCreateThumbnailWithTransform)
    // yields a top-down CGImage, and CGContextDrawImage into this CGBitmapContext
    // preserves that row order. A translate+scale flip here would v-flip the output.
    CGContextDrawImage(ctx, CGRect {
        origin: CGPoint { x: 0.0, y: 0.0 },
        size:   CGSize  { width: w as CGFloat, height: h as CGFloat },
    }, cg_image);

    CGContextRelease(ctx);
    Some((w as u32, h as u32, pixels))
}

// ── Implementations ─────────────────────────────────────────────────────────

unsafe fn thumbnail_impl(path: &Path, max_px: u32) -> Option<(u32, u32, Vec<u8>)> {
    let url = path_to_cfurl(path)?;
    let src = CGImageSourceCreateWithURL(url, std::ptr::null());
    CFRelease(url);
    if src.is_null() { return None; }

    let opts = make_thumb_options(max_px);
    let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts);
    CFRelease(src);
    CFRelease(opts);
    if cg.is_null() { return None; }

    let result = cg_image_to_rgba(cg);
    CGImageRelease(cg);
    result
}

unsafe fn image_impl(path: &Path, max_px: u32) -> Option<(u32, u32, Vec<u8>)> {
    let url = path_to_cfurl(path)?;
    let src = CGImageSourceCreateWithURL(url, std::ptr::null());
    CFRelease(url);
    if src.is_null() { return None; }

    // For full-res loading, use the image directly (no thumbnail pipeline).
    // kCGImageSourceShouldCache=false keeps memory usage low.
    let no_cache_dict = {
        let keys:   [CFTypeRef; 1] = [kCGImageSourceShouldCache];
        let values: [CFTypeRef; 1] = [kCFBooleanFalse];
        CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(), values.as_ptr(), 1,
            &kCFTypeDictionaryKeyCallBacks as *const c_void,
            &kCFTypeDictionaryValueCallBacks as *const c_void,
        )
    };
    let cg = CGImageSourceCreateImageAtIndex(src, 0, no_cache_dict);
    CFRelease(src);
    CFRelease(no_cache_dict);
    if cg.is_null() { return None; }

    let w = CGImageGetWidth(cg);
    let h = CGImageGetHeight(cg);
    let long_edge = w.max(h) as u32;

    // If within size limit, decode directly; otherwise fall through to image crate
    // (CGImage resize is complex; image crate handles it well enough for large files)
    if max_px > 0 && long_edge > max_px {
        CGImageRelease(cg);
        return None; // caller falls back to image crate with resize
    }

    let result = cg_image_to_rgba(cg);
    CGImageRelease(cg);
    result
}
