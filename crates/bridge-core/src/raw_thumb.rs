/// Extract embedded JPEG preview data from various RAW file formats.
///
/// Supported formats and extraction strategies:
///
/// | Format | Magic / Header             | Strategy                                     |
/// |--------|----------------------------|----------------------------------------------|
/// | ARW    | II + 0x002A (TIFF)         | kamadak-exif → IFD1 JPEGInterchangeFormat    |
/// | CR2    | II + 0x002A (TIFF)         | kamadak-exif → IFD1 JPEGInterchangeFormat    |
/// | CR3    | ftyp (ISOBMFF)             | Walk MP4 boxes → uuid PRVW (UUID eaf42b5e…) |
/// | DNG    | II + 0x002A (TIFF)         | kamadak-exif → fallback SubIFD Compression=7 |
/// | NEF    | II + 0x002A (TIFF)         | kamadak-exif → fallback SubIFD JpegOffset    |
/// | ORF    | II + 0x4F52 (Olympus TIFF) | Scan file for JPEG SOI/EOI pairs             |
/// | PEF    | II + 0x002A (TIFF)         | kamadak-exif → IFD1 JPEGInterchangeFormat    |
/// | RAF    | FUJIFILMCCD-RAW header     | Read JPEG offset/size from bytes [84:92]     |
/// | RW2    | II + 0x0055 (Panasonic)    | Walk IFD0 tag 0x002E → scan blob            |

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use exif::{In, Tag, Value};

/// Quality / size of the requested embedded JPEG.
pub enum Quality {
    /// Small thumbnail (IFD1 or smallest SubIFD). Fastest to decode.
    Thumbnail,
    /// Medium preview (IFD0 or mid-size SubIFD). Good for sidebar display.
    Preview,
    /// Full-size JPEG (IFD2 or largest SubIFD).
    Full,
}

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Returns raw JPEG bytes extracted from the RAW file, or `None` on failure.
pub fn extract(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    let mut header = [0u8; 16];
    {
        let mut f = std::fs::File::open(path).ok()?;
        f.read_exact(&mut header).ok()?;
    }

    // RAF: proprietary "FUJIFILMCCD-RAW " header
    if &header[..16] == b"FUJIFILMCCD-RAW " {
        return extract_raf(path);
    }

    // CR3: ISOBMFF container (ftyp box at offset 0)
    if &header[4..8] == b"ftyp" {
        return extract_cr3(path, quality);
    }

    // TIFF-based: determine endianness and magic
    let is_le = &header[..2] == b"II";
    let magic = if is_le {
        u16::from_le_bytes([header[2], header[3]])
    } else {
        u16::from_be_bytes([header[2], header[3]])
    };

    match magic {
        0x0055 => extract_rw2(path, quality),    // Panasonic RW2
        0x4F52 => extract_orf(path, quality),    // Olympus ORF
        0x002A => {
            // Standard TIFF: try kamadak-exif IFDs, fall back to SubIFD walk.
            //
            // IFD layout varies by format:
            //   CR2  – IFD1=small JPEG (~18 KB); IFD2=uncompressed RGB (no JPEG)
            //   PEF  – IFD1=small JPEG (~7 KB);  IFD2=large JPEG (~4 MB)
            //   ARW  – IFD1=small JPEG;           SubIFDs=large previews
            //   NEF  – IFD1=small JPEG;           SubIFDs=large previews
            //
            // Quality::Preview / Full should return the *largest* JPEG available.
            //
            // `extract_tiff_subifd` now walks the entire IFD tree (main chain + SubIFDs)
            // and selects by size, so it is a superset of the kamadak-exif IFD0/IFD1/IFD2
            // lookups. We therefore run it FIRST for Preview/Full: otherwise a small IFD0
            // JPEG (e.g. Nikon Z6 III's 160×120 in IFD0) short-circuits the chain and the
            // real large preview in a SubIFD is never reached. kamadak-exif stays as a
            // fallback for any layout the manual walk happens to miss.
            //
            // Thumbnail keeps kamadak's IFD1 lookup first (cheapest path to a small JPEG).
            // Final fallback `extract_tiff_rgb_preview`: medium-format backs (Hasselblad
            // 3FR/FFF, Phase One IIQ) embed no JPEG — only an uncompressed RGB preview.
            // It runs last so it never overrides a real embedded JPEG.
            match quality {
                Quality::Thumbnail =>
                    extract_from_ifd(path, In::THUMBNAIL)
                        .or_else(|| extract_tiff_subifd(path, is_le, quality))
                        .or_else(|| extract_tiff_rgb_preview(path, is_le)),
                Quality::Preview =>
                    extract_tiff_subifd(path, is_le, quality)
                        .or_else(|| extract_from_ifd(path, In::PRIMARY))
                        .or_else(|| extract_from_ifd(path, In(2)))
                        .or_else(|| extract_from_ifd(path, In::THUMBNAIL))
                        .or_else(|| extract_tiff_rgb_preview(path, is_le)),
                Quality::Full =>
                    extract_tiff_subifd(path, is_le, quality)
                        .or_else(|| extract_from_ifd(path, In(2)))
                        .or_else(|| extract_from_ifd(path, In::PRIMARY))
                        .or_else(|| extract_from_ifd(path, In::THUMBNAIL))
                        .or_else(|| extract_tiff_rgb_preview(path, is_le)),
            }
        }
        _ => None,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Standard TIFF path (ARW, CR2, PEF, …)
// ─────────────────────────────────────────────────────────────────────────────

fn extract_from_ifd(path: &Path, ifd: In) -> Option<Vec<u8>> {
    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut reader = std::io::BufReader::new(file);

    let exif = exif::Reader::new().read_from_container(&mut reader).ok()?;

    let offset = exif
        .get_field(Tag::JPEGInterchangeFormat, ifd)
        .and_then(|f| match &f.value {
            Value::Long(v) => v.first().copied(),
            _ => None,
        })? as u64;

    let length = exif
        .get_field(Tag::JPEGInterchangeFormatLength, ifd)
        .and_then(|f| match &f.value {
            Value::Long(v) => v.first().copied(),
            _ => None,
        })? as usize;

    if length < 10 || offset + length as u64 > file_len {
        return None;
    }

    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(offset)).ok()?;
    let mut buf = vec![0u8; length];
    f.read_exact(&mut buf).ok()?;

    if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// TIFF IFD-tree walk (NEF / DNG / Apple ProRAW / Samsung …)
// ─────────────────────────────────────────────────────────────────────────────
//
// kamadak-exif only checks the standard IFD0 + IFD1 chain via JPEGInterchangeFormat,
// so it misses previews stored elsewhere. We walk the entire IFD tree manually:
//
//   • main IFD chain (IFD0 → IFD1 → … via NextIFD pointers)
//   • every SubIFD referenced from those IFDs (tag 0x014A)
//
// and in each IFD collect a JPEG candidate via either:
//
//   • JPEGInterchangeFormat (0x0201) + JPEGInterchangeFormatLength (0x0202)   ← NEF
//   • Compression (0x0103) == 7 (JPEG) + StripOffsets (0x0111) + StripByteCounts (0x0117)
//        ← DNG SubIFD (Leica) AND Apple ProRAW / iPhone DNG, where the preview JPEG
//          lives in the *main* IFD chain rather than a SubIFD (single-strip).
//
// Each candidate is verified to actually begin with a JPEG SOI before being kept,
// so non-JPEG strips (raw sensor data) can never be selected by mistake.

fn extract_tiff_subifd(path: &Path, is_le: bool, quality: Quality) -> Option<Vec<u8>> {
    use std::io::{BufReader, Read, Seek, SeekFrom};

    fn r16(buf: &[u8], le: bool) -> u16 {
        if le { u16::from_le_bytes([buf[0], buf[1]]) } else { u16::from_be_bytes([buf[0], buf[1]]) }
    }
    fn r32(buf: &[u8], le: bool) -> u32 {
        if le { u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) } else { u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) }
    }
    fn read16(f: &mut impl Read, le: bool) -> Option<u16> {
        let mut b = [0u8; 2]; f.read_exact(&mut b).ok()?;
        Some(if le { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) })
    }
    fn read32(f: &mut impl Read, le: bool) -> Option<u32> {
        let mut b = [0u8; 4]; f.read_exact(&mut b).ok()?;
        Some(if le { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) })
    }
    // Read a count==1 scalar tag value honoring its TIFF type. Critical for big-endian
    // (MM) files: a SHORT (type 3) is left-justified in the 4-byte value field, so reading
    // it as a u32 yields `value << 16` (e.g. Compression 7 → 0x00070000). Apple ProRAW /
    // iPhone DNG are big-endian, which is why `compression == 7` silently failed before.
    fn tag_scalar(buf: &[u8], base: usize, le: bool) -> u64 {
        let typ = r16(&buf[base + 2..], le);
        match typ {
            3 => r16(&buf[base + 8..], le) as u64,  // SHORT
            1 => buf[base + 8] as u64,              // BYTE
            _ => r32(&buf[base + 8..], le) as u64,  // LONG / offsets / fallback
        }
    }
    // Read an IFD: returns (entries_buf, next_ifd_offset). File position lands after entries.
    fn read_ifd(f: &mut BufReader<std::fs::File>, off: u64, le: bool) -> Option<(Vec<u8>, u64)> {
        f.seek(SeekFrom::Start(off)).ok()?;
        let count = read16(f, le)?.min(1000) as usize;
        let mut buf = vec![0u8; count * 12];
        f.read_exact(&mut buf).ok()?;
        let next = read32(f, le).unwrap_or(0) as u64;
        Some((buf, next))
    }
    // Does the file contain a JPEG SOI (FF D8) at `off`?
    fn is_jpeg_at(f: &mut BufReader<std::fs::File>, off: u64) -> bool {
        if f.seek(SeekFrom::Start(off)).is_err() { return false; }
        let mut b = [0u8; 2];
        f.read_exact(&mut b).is_ok() && b == [0xFF, 0xD8]
    }

    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut f = BufReader::with_capacity(65536, file);

    // Read IFD0 offset from TIFF header.
    f.seek(SeekFrom::Start(4)).ok()?;
    let ifd0_off = read32(&mut f, is_le)? as u64;

    // Build the list of IFD offsets to inspect: main chain + their SubIFDs.
    let mut ifd_offsets: Vec<u64> = Vec::new();
    let mut seen: std::collections::HashSet<u64> = std::collections::HashSet::new();
    let mut next = ifd0_off;
    let mut guard = 0;
    while next != 0 && next < file_len && seen.insert(next) && guard < 32 {
        guard += 1;
        let Some((buf, next_ifd)) = read_ifd(&mut f, next, is_le) else { break };
        ifd_offsets.push(next);

        // Collect SubIFDs (0x014A) referenced from this IFD.
        let count = buf.len() / 12;
        for i in 0..count {
            let base = i * 12;
            if r16(&buf[base..], is_le) != 0x014A { continue; }
            let cnt = r32(&buf[base + 4..], is_le) as usize;
            let val = r32(&buf[base + 8..], is_le) as u64;
            if cnt * 4 > 4 {
                if f.seek(SeekFrom::Start(val)).is_ok() {
                    for _ in 0..cnt.min(32) {
                        if let Some(sub) = read32(&mut f, is_le) {
                            let sub = sub as u64;
                            if sub != 0 && sub < file_len && seen.insert(sub) { ifd_offsets.push(sub); }
                        }
                    }
                }
            } else if val != 0 && val < file_len && seen.insert(val) {
                ifd_offsets.push(val);
            }
        }
        next = next_ifd;
    }

    // Scan each IFD for a JPEG candidate (verified to begin with SOI).
    let mut candidates: Vec<(u64, usize)> = Vec::new();
    for off in ifd_offsets {
        let Some((buf, _)) = read_ifd(&mut f, off, is_le) else { continue };
        let count = buf.len() / 12;

        let mut jpeg_off: Option<u64> = None;
        let mut jpeg_len: Option<usize> = None;
        let mut strip_off: Option<u64> = None;
        let mut strip_len: Option<usize> = None;
        let mut compression: u64 = 1;
        let mut photometric: u64 = 0;

        for i in 0..count {
            let base = i * 12;
            let tag = r16(&buf[base..], is_le);
            let val = tag_scalar(&buf, base, is_le);
            match tag {
                0x0201 => jpeg_off    = Some(val),
                0x0202 => jpeg_len    = Some(val as usize),
                0x0111 => strip_off   = Some(val),
                0x0117 => strip_len   = Some(val as usize),
                0x0103 => compression = val,
                0x0106 => photometric = val,
                _ => {}
            }
        }

        // JPEGInterchangeFormat is by definition an embedded JPEG (never raw sensor data),
        // so accept unconditionally once the SOI is verified. (NEF / ARW / CR2 thumbnails.)
        if let (Some(o), Some(l)) = (jpeg_off, jpeg_len) {
            if l >= 10 && o + l as u64 <= file_len && is_jpeg_at(&mut f, o) {
                candidates.push((o, l));
            }
        }
        // Compression==7 (JPEG) stored via strips — covers DNG SubIFD previews (Leica) AND
        // Apple ProRAW / iPhone DNG where the preview lives in the main IFD chain.
        // Gate on PhotometricInterpretation ∈ {RGB(2), YCbCr(6)} so the actual raw image
        // (CFA / LinearRaw, which is *also* a lossless-JPEG strip starting with FF D8) is
        // never mistaken for a displayable preview. Single-strip assumption (count==1).
        if compression == 7 && (photometric == 2 || photometric == 6) {
            if let (Some(o), Some(l)) = (strip_off, strip_len) {
                if l >= 10 && o + l as u64 <= file_len && is_jpeg_at(&mut f, o) {
                    candidates.push((o, l));
                }
            }
        }
    }

    if candidates.is_empty() { return None; }
    candidates.sort_by_key(|&(_, len)| len);
    candidates.dedup();

    let (off, len) = match quality {
        Quality::Thumbnail => candidates[0],
        Quality::Preview   => candidates[candidates.len() / 2],
        Quality::Full      => *candidates.last()?,
    };

    f.seek(SeekFrom::Start(off)).ok()?;
    let mut buf = vec![0u8; len];
    f.read_exact(&mut buf).ok()?;
    if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// Uncompressed-RGB preview → JPEG (medium format: Hasselblad 3FR/FFF, Phase One IIQ)
// ─────────────────────────────────────────────────────────────────────────────
//
// These backs embed NO JPEG preview — only an uncompressed, interleaved 8-bit RGB image
// (PhotometricInterpretation=RGB, Compression=1) in a TIFF IFD, alongside the CFA raw.
// We read the largest such RGB strip and JPEG-encode it so the rest of the pipeline
// (which expects JPEG bytes) can display it.
//
// 8-bit chunky only: validated via `strip_len == width*height*3` and PlanarConfiguration,
// so 16-bit / planar / unexpected layouts are skipped rather than mis-decoded. This runs
// only as a last resort after the JPEG paths return None, so it never overrides a real
// embedded JPEG preview.
fn extract_tiff_rgb_preview(path: &Path, is_le: bool) -> Option<Vec<u8>> {
    use std::io::{BufReader, Read, Seek, SeekFrom};
    fn r16(b: &[u8], le: bool) -> u16 { if le { u16::from_le_bytes([b[0], b[1]]) } else { u16::from_be_bytes([b[0], b[1]]) } }
    fn r32(b: &[u8], le: bool) -> u32 { if le { u32::from_le_bytes([b[0], b[1], b[2], b[3]]) } else { u32::from_be_bytes([b[0], b[1], b[2], b[3]]) } }
    fn read16(f: &mut impl Read, le: bool) -> Option<u16> { let mut b = [0u8; 2]; f.read_exact(&mut b).ok()?; Some(if le { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) }) }
    fn read32(f: &mut impl Read, le: bool) -> Option<u32> { let mut b = [0u8; 4]; f.read_exact(&mut b).ok()?; Some(if le { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) }) }
    fn tag_scalar(buf: &[u8], base: usize, le: bool) -> u64 {
        match r16(&buf[base + 2..], le) { 3 => r16(&buf[base + 8..], le) as u64, 1 => buf[base + 8] as u64, _ => r32(&buf[base + 8..], le) as u64 }
    }
    fn read_ifd(f: &mut BufReader<std::fs::File>, off: u64, le: bool) -> Option<(Vec<u8>, u64)> {
        f.seek(SeekFrom::Start(off)).ok()?;
        let c = read16(f, le)?.min(1000) as usize;
        let mut buf = vec![0u8; c * 12];
        f.read_exact(&mut buf).ok()?;
        let next = read32(f, le).unwrap_or(0) as u64;
        Some((buf, next))
    }

    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut f = BufReader::with_capacity(65536, file);
    f.seek(SeekFrom::Start(4)).ok()?;
    let ifd0 = read32(&mut f, is_le)? as u64;

    // Collect main IFD chain + SubIFDs.
    let mut offs: Vec<u64> = Vec::new();
    let mut seen: std::collections::HashSet<u64> = std::collections::HashSet::new();
    let mut next = ifd0;
    let mut guard = 0;
    while next != 0 && next < file_len && seen.insert(next) && guard < 32 {
        guard += 1;
        let Some((buf, nx)) = read_ifd(&mut f, next, is_le) else { break };
        offs.push(next);
        let c = buf.len() / 12;
        for i in 0..c {
            let b = i * 12;
            if r16(&buf[b..], is_le) != 0x014A { continue; }
            let cnt = r32(&buf[b + 4..], is_le) as usize;
            let val = r32(&buf[b + 8..], is_le) as u64;
            if cnt * 4 > 4 {
                if f.seek(SeekFrom::Start(val)).is_ok() {
                    for _ in 0..cnt.min(32) {
                        if let Some(s) = read32(&mut f, is_le) {
                            let s = s as u64;
                            if s != 0 && s < file_len && seen.insert(s) { offs.push(s); }
                        }
                    }
                }
            } else if val != 0 && val < file_len && seen.insert(val) { offs.push(val); }
        }
        next = nx;
    }

    // Pick the largest interleaved 8-bit RGB image.
    let mut best: Option<(u64, usize, u32, u32)> = None; // (off, len, w, h)
    for off in offs {
        let Some((buf, _)) = read_ifd(&mut f, off, is_le) else { continue };
        let c = buf.len() / 12;
        let (mut w, mut h, mut spp, mut comp, mut pi, mut planar, mut so, mut sl) =
            (0u64, 0u64, 1u64, 1u64, 0u64, 1u64, 0u64, 0u64);
        for i in 0..c {
            let b = i * 12;
            match r16(&buf[b..], is_le) {
                0x0100 => w      = tag_scalar(&buf, b, is_le),
                0x0101 => h      = tag_scalar(&buf, b, is_le),
                0x0115 => spp    = tag_scalar(&buf, b, is_le),
                0x0103 => comp   = tag_scalar(&buf, b, is_le),
                0x0106 => pi     = tag_scalar(&buf, b, is_le),
                0x011C => planar = tag_scalar(&buf, b, is_le),
                0x0111 => so     = tag_scalar(&buf, b, is_le),
                0x0117 => sl     = tag_scalar(&buf, b, is_le),
                _ => {}
            }
        }
        // RGB, uncompressed, 3 chunky 8-bit samples (len == w*h*3), single strip in-bounds.
        if pi == 2 && comp == 1 && spp == 3 && planar == 1
            && w > 0 && h > 0 && w <= 10000 && h <= 10000
            && sl == w * h * 3 && so + sl <= file_len
        {
            if best.map_or(true, |(_, _, bw, bh)| w * h > bw as u64 * bh as u64) {
                best = Some((so, sl as usize, w as u32, h as u32));
            }
        }
    }

    let (off, len, w, h) = best?;
    f.seek(SeekFrom::Start(off)).ok()?;
    let mut rgb = vec![0u8; len];
    f.read_exact(&mut rgb).ok()?;

    let mut out = Vec::new();
    let encoder = jpeg_encoder::Encoder::new(&mut out, 85);
    encoder.encode(&rgb, w as u16, h as u16, jpeg_encoder::ColorType::Rgb).ok()?;
    if out.starts_with(&[0xFF, 0xD8]) { Some(out) } else { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// Panasonic RW2
// ─────────────────────────────────────────────────────────────────────────────

fn extract_rw2(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    let mut file = std::fs::File::open(path).ok()?;

    let mut hdr = [0u8; 8];
    file.read_exact(&mut hdr).ok()?;
    let ifd0_off = u32::from_le_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]) as u64;

    // Walk IFD0 to find tag 0x002E (Panasonic preview blob)
    file.seek(SeekFrom::Start(ifd0_off)).ok()?;
    let mut cnt_buf = [0u8; 2];
    file.read_exact(&mut cnt_buf).ok()?;
    let entry_count = u16::from_le_bytes(cnt_buf) as usize;

    let mut blob_offset: u64 = 0;
    let mut blob_size: usize = 0;

    for _ in 0..entry_count {
        let mut entry = [0u8; 12];
        if file.read_exact(&mut entry).is_err() { break; }
        let tag = u16::from_le_bytes([entry[0], entry[1]]);
        let count = u32::from_le_bytes([entry[4], entry[5], entry[6], entry[7]]);
        let val_or_off = u32::from_le_bytes([entry[8], entry[9], entry[10], entry[11]]);

        if tag == 0x002E {
            blob_offset = val_or_off as u64;
            blob_size = count as usize;
            break;
        }
    }

    if blob_size == 0 { return None; }

    let mut file = std::fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(blob_offset)).ok()?;
    let mut blob = vec![0u8; blob_size];
    file.read_exact(&mut blob).ok()?;

    let jpegs = collect_jpegs(&blob);
    if jpegs.is_empty() { return None; }

    let (rel_off, jpeg_len) = match quality {
        Quality::Thumbnail => jpegs[0],
        Quality::Preview | Quality::Full => *jpegs.last()?,
    };

    Some(blob[rel_off..rel_off + jpeg_len].to_vec())
}

// ─────────────────────────────────────────────────────────────────────────────
// Olympus ORF (magic 0x4F52)
// ─────────────────────────────────────────────────────────────────────────────
//
// ORF uses the same TIFF structure as standard files but with magic 0x4F52
// ('OR'). Preview JPEGs are not referenced by standard IFD tags; instead we
// scan the first portion of the file for JPEG SOI/EOI pairs.

fn extract_orf(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    // Preview JPEGs appear in the first ~10% of the file before raw sensor data
    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let scan_limit = (file_len / 10).max(128 * 1024);
    let mut data = Vec::with_capacity(scan_limit as usize);
    file.take(scan_limit).read_to_end(&mut data).ok()?;

    let jpegs = collect_jpegs(&data);
    if jpegs.is_empty() { return None; }

    let (rel_off, jpeg_len) = match quality {
        Quality::Thumbnail => jpegs[0],
        Quality::Preview | Quality::Full => *jpegs.last()?,
    };

    Some(data[rel_off..rel_off + jpeg_len].to_vec())
}

// ─────────────────────────────────────────────────────────────────────────────
// Fujifilm RAF
// ─────────────────────────────────────────────────────────────────────────────
//
// RAF header layout (all fields big-endian):
//   [  0..16] "FUJIFILMCCD-RAW " signature
//   [ 16..20] Format version string
//   [ 20..28] Camera model ID
//   [ 28..60] Camera model string
//   [ 60..84] (various fields)
//   [ 84..88] JPEG preview offset (from file start)
//   [ 88..92] JPEG preview size

fn extract_raf(path: &Path) -> Option<Vec<u8>> {
    let mut f = std::fs::File::open(path).ok()?;

    let mut hdr = [0u8; 92];
    f.read_exact(&mut hdr).ok()?;

    let jpeg_off = u32::from_be_bytes([hdr[84], hdr[85], hdr[86], hdr[87]]) as u64;
    let jpeg_len = u32::from_be_bytes([hdr[88], hdr[89], hdr[90], hdr[91]]) as usize;

    if jpeg_len < 10 { return None; }

    f.seek(SeekFrom::Start(jpeg_off)).ok()?;
    let mut buf = vec![0u8; jpeg_len];
    f.read_exact(&mut buf).ok()?;

    if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// Canon CR3 (ISOBMFF / MP4 container)
// ─────────────────────────────────────────────────────────────────────────────
//
// CR3 wraps RAW data in an ISO Base Media File Format container. Canon stores
// preview JPEGs in top-level `uuid` boxes with specific GUIDs:
//
//   eaf42b5e1c984b88b9fbb7dc406e4d16  — PRVW (preview JPEG)
//   be7acfcb97a942e89c71999491e3afac  — XPacket metadata (no JPEG)
//
// Within the PRVW uuid box, the JPEG starts at offset +56 from the box start.

const CR3_PRVW_UUID: [u8; 16] = [
    0xea, 0xf4, 0x2b, 0x5e, 0x1c, 0x98, 0x4b, 0x88,
    0xb9, 0xfb, 0xb7, 0xdc, 0x40, 0x6e, 0x4d, 0x16,
];
const CR3_THMB_UUID: [u8; 16] = [
    0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0,
    0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48,
];

fn extract_cr3(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    use std::io::{BufReader, Read, Seek, SeekFrom};

    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut f = BufReader::with_capacity(65536, file);

    let mut prvw: Option<(u64, usize)> = None; // (file offset, size)
    let mut thmb: Option<Vec<u8>> = None;       // already extracted bytes
    let mut pos: u64 = 0;

    while pos + 8 <= file_len {
        let mut hdr = [0u8; 8];
        if f.read_exact(&mut hdr).is_err() { break; }
        let box_size = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as u64;
        let box_type = &hdr[4..8];

        if box_size < 8 || pos + box_size > file_len { break; }

        if box_type == b"uuid" && box_size >= 24 {
            let mut uuid = [0u8; 16];
            if f.read_exact(&mut uuid).is_err() { break; }

            if uuid == CR3_PRVW_UUID && prvw.is_none() && box_size > 60 {
                // JPEG size at box+52, data at box+56
                if f.seek(SeekFrom::Start(pos + 52)).is_ok() {
                    let mut sz = [0u8; 4];
                    if f.read_exact(&mut sz).is_ok() {
                        let jpeg_size = u32::from_be_bytes(sz) as usize;
                        let jpeg_off = pos + 56;
                        if jpeg_size >= 10 && jpeg_off + jpeg_size as u64 <= file_len {
                            prvw = Some((jpeg_off, jpeg_size));
                        }
                    }
                }
            } else if uuid == CR3_THMB_UUID && thmb.is_none() {
                let inner_len = (box_size - 24) as usize;
                let mut inner = vec![0u8; inner_len];
                if f.read_exact(&mut inner).is_ok() {
                    let found = collect_jpegs(&inner);
                    if let Some(&(rel, sz)) = found.last() {
                        thmb = Some(inner[rel..rel + sz].to_vec());
                    }
                }
            }
        }

        pos += box_size;
        if f.seek(SeekFrom::Start(pos)).is_err() { break; }

        let done = match quality {
            Quality::Thumbnail => thmb.is_some() || prvw.is_some(),
            Quality::Preview | Quality::Full => prvw.is_some(),
        };
        if done { break; }
    }

    match quality {
        Quality::Thumbnail => {
            if let Some(bytes) = thmb {
                if bytes.starts_with(&[0xFF, 0xD8]) { return Some(bytes); }
            }
            if let Some((off, len)) = prvw {
                f.seek(SeekFrom::Start(off)).ok()?;
                let mut buf = vec![0u8; len];
                f.read_exact(&mut buf).ok()?;
                if buf.starts_with(&[0xFF, 0xD8]) { return Some(buf); }
            }
            None
        }
        Quality::Preview | Quality::Full => {
            let (off, len) = prvw?;
            f.seek(SeekFrom::Start(off)).ok()?;
            let mut buf = vec![0u8; len];
            f.read_exact(&mut buf).ok()?;
            if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// JPEG helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Scan a byte slice for JPEG SOI/EOI pairs. Returns (offset, length) pairs
/// sorted by ascending length.
fn collect_jpegs(data: &[u8]) -> Vec<(usize, usize)> {
    let mut results = Vec::new();
    let mut i = 0;
    while i + 3 < data.len() {
        // SOI (FF D8) の直後は必ず正規マーカー (FF C0..=FE: APPn / DQT / DHT / SOF / COM …) が来る。
        // 4 バイト目を検証しないと、RAW センサーデータ中の偶発的な FF D8 FF 列を JPEG と誤検出する。
        // 例: OM-5 MarkII の ORF はオフセット 27053 が "FF D8 FF 2A" で、これを拾うと本物のプレビュー
        // (52224, 3200x2400) を巻き込んだ非デコード塊を返し、ORF だけサムネが表示されなくなる。
        if data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF && data[i + 3] >= 0xC0 {
            if let Some(eoi) = find_jpeg_eoi(data, i) {
                let size = eoi - i + 2;
                if size > 512 {
                    results.push((i, size));
                }
                i = eoi + 2;
                continue;
            }
        }
        i += 1;
    }
    results.sort_by_key(|&(_, size)| size);
    results
}

/// Walk JPEG markers from `start` to locate the EOI (0xFF 0xD9).
/// Returns the byte offset of the EOI, or None if not found.
fn find_jpeg_eoi(data: &[u8], start: usize) -> Option<usize> {
    let mut pos = start + 2; // skip SOI
    while pos + 1 < data.len() {
        if data[pos] != 0xFF {
            pos += 1;
            continue;
        }
        let marker_byte = *data.get(pos + 1)?;
        match marker_byte {
            0x00 | 0xFF => { pos += 1; }  // stuffed / fill byte
            0xD9 => return Some(pos),      // EOI
            0xD8 => return None,           // unexpected nested SOI
            0xD0..=0xD7 => { pos += 2; }  // RST (no length field)
            _ => {
                let len = if pos + 3 < data.len() {
                    u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize
                } else {
                    return None;
                };
                if len < 2 { return None; }
                pos += 2 + len;
            }
        }
    }
    None
}
