#[derive(Debug, Clone, Default)]
pub struct ExifData {
    pub make: Option<String>,
    pub model: Option<String>,
    /// EXIF format: "YYYY:MM:DD HH:MM:SS"
    pub datetime: Option<String>,
    /// Sub-second suffix for DateTimeOriginal, e.g. "123" for 123 ms.
    /// Used by Phase 10-B to distinguish consecutive single-second shots.
    pub subsec: Option<String>,
    pub exposure_time: Option<String>,
    pub fnumber: Option<String>,
    pub iso: Option<u32>,
    pub focal_length: Option<String>,
    pub focal_length_35mm: Option<u32>,
    pub lens_model: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub software: Option<String>,
    pub artist: Option<String>,
    /// ExposureBiasValue formatted as "+1.0 EV" / "-0.7 EV" / "0 EV".
    pub exposure_bias: Option<String>,
    /// Flash status decoded from the Flash SHORT bitmask.
    pub flash: Option<String>,
    /// WhiteBalance: "Auto" or "Manual".
    pub white_balance: Option<String>,
    /// EXIF ImageDescription tag (0x010E, ASCII). Read-only; write goes to XMP sidecar.
    pub image_description: Option<String>,
    /// EXIF UserComment tag (0x9286, UNDEFINED + 8-byte charset prefix). Read-only; write goes to XMP sidecar.
    pub user_comment: Option<String>,
}

pub fn read_exif_sync(path: &std::path::Path) -> Option<ExifData> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase());

    // CR3: kamadak-exif places CMT2's ExifIFD tags under the "Tiff" namespace
    // instead of "Exif", so Tag::DateTimeOriginal lookups fail.  Parse directly.
    if ext.as_deref() == Some("cr3") {
        return read_exif_from_cr3(path);
    }

    use exif::{In, Tag};

    // Other formats that kamadak-exif cannot parse from their native container.
    let exif = match ext.as_deref() {
        // RAF / RW2: extract embedded JPEG thumbnail, then read EXIF from it.
        Some("raf" | "rw2") => {
            let jpeg =
                crate::raw_thumb::extract(path, crate::raw_thumb::Quality::Thumbnail)?;
            let mut cursor = std::io::Cursor::new(jpeg);
            exif::Reader::new().read_from_container(&mut cursor).ok()?
        }
        // ORF: standard TIFF structure but uses Olympus magic 0x4F52 instead of 0x002A.
        Some("orf") => read_exif_from_orf(path)?,
        _ => {
            let file = std::fs::File::open(path).ok()?;
            let mut bufreader = std::io::BufReader::new(file);
            exif::Reader::new()
                .read_from_container(&mut bufreader)
                .ok()?
        }
    };

    // Extract raw ASCII string (no surrounding quotes from display_value)
    let get_ascii = |tag: Tag| -> Option<String> {
        exif.get_field(tag, In::PRIMARY).and_then(|f| {
            if let exif::Value::Ascii(ref v) = f.value {
                v.first()
                    .and_then(|bytes| std::str::from_utf8(bytes).ok())
                    .map(|s| s.trim().trim_end_matches('\0').to_string())
                    .filter(|s| !s.is_empty())
            } else {
                None
            }
        })
    };

    // Extract display string (e.g. "1/200 s", "f/2.8", "85 mm")
    let get_display = |tag: Tag| -> Option<String> {
        exif.get_field(tag, In::PRIMARY)
            .map(|f| f.display_value().with_unit(&exif).to_string())
    };

    let iso = exif
        .get_field(Tag::PhotographicSensitivity, In::PRIMARY)
        .and_then(|f| {
            if let exif::Value::Short(v) = &f.value {
                v.first().map(|&n| n as u32)
            } else {
                None
            }
        });

    let focal_length_35mm = exif
        .get_field(Tag::FocalLengthIn35mmFilm, In::PRIMARY)
        .and_then(|f| {
            if let exif::Value::Short(v) = &f.value {
                v.first().map(|&n| n as u32)
            } else {
                None
            }
        });

    let width = pixel_dim(&exif, Tag::PixelXDimension);
    let height = pixel_dim(&exif, Tag::PixelYDimension);
    // Fall back to JPEG SOF header when EXIF PixelXDimension/PixelYDimension are absent.
    // Some post-processing tools (e.g. imanage) omit these EXIF IFD tags.
    let (width, height) = match (width, height) {
        (None, None) if matches!(ext.as_deref(), Some("jpg" | "jpeg" | "jfif")) => {
            jpeg_sof_dimensions(path)
                .map(|(w, h)| (Some(w), Some(h)))
                .unwrap_or((None, None))
        }
        pair => pair,
    };

    let exposure_bias = exif
        .get_field(Tag::ExposureBiasValue, In::PRIMARY)
        .and_then(|f| {
            if let exif::Value::SRational(v) = &f.value {
                v.first().map(|r| format_srational_ev(r.num, r.denom))
            } else {
                None
            }
        });

    let flash = exif
        .get_field(Tag::Flash, In::PRIMARY)
        .and_then(|f| {
            if let exif::Value::Short(v) = &f.value {
                v.first().map(|&n| decode_flash(n))
            } else {
                None
            }
        });

    let white_balance = exif
        .get_field(Tag::WhiteBalance, In::PRIMARY)
        .and_then(|f| {
            if let exif::Value::Short(v) = &f.value {
                v.first().map(|&n| match n {
                    0 => "Auto".to_string(),
                    1 => "Manual".to_string(),
                    _ => format!("{}", n),
                })
            } else {
                None
            }
        });

    Some(ExifData {
        make: get_ascii(Tag::Make),
        model: get_ascii(Tag::Model),
        datetime: get_ascii(Tag::DateTimeOriginal)
            .or_else(|| get_ascii(Tag::DateTimeDigitized))
            .or_else(|| get_ascii(Tag::DateTime)),
        subsec: get_ascii(Tag::SubSecTimeOriginal)
            .or_else(|| get_ascii(Tag::SubSecTimeDigitized))
            .or_else(|| get_ascii(Tag::SubSecTime)),
        exposure_time: get_display(Tag::ExposureTime),
        fnumber: get_display(Tag::FNumber),
        iso,
        focal_length: get_display(Tag::FocalLength),
        focal_length_35mm,
        lens_model: get_ascii(Tag::LensModel),
        width,
        height,
        software: get_ascii(Tag::Software),
        artist: get_ascii(Tag::Artist),
        exposure_bias,
        flash,
        white_balance,
        image_description: get_ascii(Tag::ImageDescription),
        user_comment: read_user_comment(&exif),
    })
}

/// Decode EXIF UserComment (tag 0x9286): UNDEFINED type with 8-byte charset prefix.
/// Supports ASCII and UNICODE (UTF-16 with BOM detection) charsets.
fn read_user_comment(exif: &exif::Exif) -> Option<String> {
    use exif::{In, Tag, Value};
    let field = exif.get_field(Tag::UserComment, In::PRIMARY)?;
    let bytes = match &field.value {
        Value::Undefined(v, _) => v.as_slice(),
        _ => return None,
    };
    if bytes.len() < 8 {
        return None;
    }
    let (head, body) = bytes.split_at(8);
    let trim_str = |s: String| -> Option<String> {
        let t = s.trim().trim_end_matches('\0').to_string();
        if t.is_empty() { None } else { Some(t) }
    };
    match head {
        b"ASCII\0\0\0" | b"\0\0\0\0\0\0\0\0" => {
            std::str::from_utf8(body).ok()
                .map(|s| s.to_string())
                .and_then(trim_str)
        }
        b"UNICODE\0" => {
            // BOM-based endian detection; fallback to big-endian (EXIF standard).
            let (le, payload) = if body.len() >= 2 && body[0] == 0xFF && body[1] == 0xFE {
                (true, &body[2..])
            } else if body.len() >= 2 && body[0] == 0xFE && body[1] == 0xFF {
                (false, &body[2..])
            } else {
                (false, body)
            };
            let units: Vec<u16> = payload.chunks_exact(2)
                .map(|c| if le { u16::from_le_bytes([c[0], c[1]]) }
                         else  { u16::from_be_bytes([c[0], c[1]]) })
                .collect();
            String::from_utf16(&units).ok().and_then(trim_str)
        }
        _ => None, // JIS and unknown charsets not supported
    }
}

/// Canon CR3 (ISOBMFF): scan the file for CMT1 and CMT2 boxes, which contain
/// raw TIFF-encoded EXIF data, and assemble an ExifData directly.
///
/// CMT1 → IFD0 (Make 0x010F, Model 0x0110, DateTime 0x0132)
/// CMT2 → ExifIFD stored as IFD0 (DateTimeOriginal 0x9003, ISO 0x8827, etc.)
///
/// We bypass kamadak-exif here because it assigns CMT2's IFD0 tags to the
/// "Tiff" tag namespace rather than "Exif", so Tag::DateTimeOriginal lookups
/// would silently return None.
fn read_exif_from_cr3(path: &std::path::Path) -> Option<ExifData> {
    use std::io::{BufReader, Read, Seek, SeekFrom};

    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut f = BufReader::with_capacity(65536, file);

    let mut cmt1: Option<Vec<u8>> = None;
    let mut cmt2: Option<Vec<u8>> = None;
    let mut pos: u64 = 0;

    while pos + 8 <= file_len && (cmt1.is_none() || cmt2.is_none()) {
        let mut hdr = [0u8; 8];
        if f.read_exact(&mut hdr).is_err() { break; }
        let box_size = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as u64;
        let box_type = &hdr[4..8];
        if box_size < 8 || pos + box_size > file_len { break; }

        if box_type == b"moov" {
            let content_len = (box_size - 8) as usize;
            // Guard against corrupt files; moov is typically < 2MB for CR3
            if content_len > 8 * 1024 * 1024 { break; }
            let mut content = vec![0u8; content_len];
            if f.read_exact(&mut content).is_err() { break; }
            let (c1, c2) = cr3_walk_for_cmt(&content);
            if c1.is_some() { cmt1 = c1; }
            if c2.is_some() { cmt2 = c2; }
        }
        pos += box_size;
        if f.seek(SeekFrom::Start(pos)).is_err() { break; }
    }

    // CMT1 may also appear as a top-level uuid box in some CR3 variants (fallback)
    if cmt1.is_none() && cmt2.is_none() { return None; }

    let r = |tiff: Option<&Vec<u8>>, tag: u16| tiff.and_then(|d| tiff_ascii(d, tag));
    let ri = |tiff: Option<&Vec<u8>>, tag: u16| tiff.and_then(|d| tiff_short(d, tag));
    let rd = |tiff: Option<&Vec<u8>>, tag: u16| {
        tiff.and_then(|d| tiff_rational_display(d, tag))
    };

    Some(ExifData {
        make:     r(cmt1.as_ref(), 0x010F),
        model:    r(cmt1.as_ref(), 0x0110),
        datetime: r(cmt2.as_ref(), 0x9003)
            .or_else(|| r(cmt2.as_ref(), 0x9004))
            .or_else(|| r(cmt1.as_ref(), 0x0132)),
        subsec:           r(cmt2.as_ref(), 0x9291),
        exposure_time:   rd(cmt2.as_ref(), 0x829A),
        fnumber:         rd(cmt2.as_ref(), 0x829D),
        iso:             ri(cmt2.as_ref(), 0x8827).map(|v| v as u32),
        focal_length:    rd(cmt2.as_ref(), 0x920A),
        focal_length_35mm: ri(cmt2.as_ref(), 0xA405).map(|v| v as u32),
        lens_model:       r(cmt2.as_ref(), 0xA434),
        width:           ri(cmt2.as_ref(), 0xA002).map(|v| v as u32)
            .or_else(|| tiff_long(cmt2.as_ref()?, 0xA002)),
        height:          ri(cmt2.as_ref(), 0xA003).map(|v| v as u32)
            .or_else(|| tiff_long(cmt2.as_ref()?, 0xA003)),
        software: None,
        artist:   None,
        exposure_bias: tiff_srational_ev(cmt2.as_ref(), 0x9204),
        flash: ri(cmt2.as_ref(), 0x9209).map(decode_flash),
        white_balance: ri(cmt2.as_ref(), 0xA403).map(|n| match n {
            0 => "Auto".to_string(),
            1 => "Manual".to_string(),
            _ => format!("{}", n),
        }),
        image_description: r(cmt1.as_ref(), 0x010E),
        user_comment: None, // UNDEFINED type; not decoded from CMT2 in Phase 1
    })
}

/// Walk ISOBMFF boxes in `data`, recursing into container boxes, and collect
/// CMT1 / CMT2 payloads (TIFF-encoded EXIF data used by Canon CR3).
fn cr3_walk_for_cmt(data: &[u8]) -> (Option<Vec<u8>>, Option<Vec<u8>>) {
    let mut cmt1 = None;
    let mut cmt2 = None;
    let mut i = 0usize;
    while i + 8 <= data.len() {
        let box_size = u32::from_be_bytes([data[i], data[i+1], data[i+2], data[i+3]]) as usize;
        let box_type = &data[i+4..i+8];
        if box_size < 8 || i + box_size > data.len() { break; }
        let payload = &data[i+8..i+box_size];
        match box_type {
            b"CMT1" if cmt1.is_none() => {
                if payload.len() >= 2 && (payload.starts_with(b"II") || payload.starts_with(b"MM")) {
                    cmt1 = Some(payload.to_vec());
                }
            }
            b"CMT2" if cmt2.is_none() => {
                if payload.len() >= 2 && (payload.starts_with(b"II") || payload.starts_with(b"MM")) {
                    cmt2 = Some(payload.to_vec());
                }
            }
            // Recurse into container boxes
            b"moov" | b"trak" | b"mdia" | b"minf" | b"stbl" | b"udta" | b"CMT3" => {
                let (c1, c2) = cr3_walk_for_cmt(payload);
                if c1.is_some() && cmt1.is_none() { cmt1 = c1; }
                if c2.is_some() && cmt2.is_none() { cmt2 = c2; }
            }
            _ => {}
        }
        if cmt1.is_some() && cmt2.is_some() { break; }
        i += box_size;
    }
    (cmt1, cmt2)
}

// ── Minimal TIFF IFD readers (used by CR3) ────────────────────────────────────

fn tiff_is_le(data: &[u8]) -> bool { data.starts_with(b"II") }

fn tiff_r16(data: &[u8], off: usize, le: bool) -> Option<u16> {
    let b = data.get(off..off + 2)?;
    Some(if le { u16::from_le_bytes([b[0], b[1]]) } else { u16::from_be_bytes([b[0], b[1]]) })
}

fn tiff_r32(data: &[u8], off: usize, le: bool) -> Option<u32> {
    let b = data.get(off..off + 4)?;
    Some(if le { u32::from_le_bytes([b[0], b[1], b[2], b[3]]) } else { u32::from_be_bytes([b[0], b[1], b[2], b[3]]) })
}

/// Find a tag in a TIFF IFD0 and call `f` with (data, le, val_or_offset, count, type).
fn tiff_find_tag<T, F>(data: &[u8], tag: u16, f: F) -> Option<T>
where
    F: Fn(&[u8], bool, u32, u32, u16) -> Option<T>,
{
    if data.len() < 8 { return None; }
    let le = tiff_is_le(data);
    let ifd0 = tiff_r32(data, 4, le)? as usize;
    let count = tiff_r16(data, ifd0, le)? as usize;
    for i in 0..count {
        let base = ifd0 + 2 + i * 12;
        if base + 12 > data.len() { break; }
        if tiff_r16(data, base, le)? != tag { continue; }
        let typ = tiff_r16(data, base + 2, le)?;
        let cnt = tiff_r32(data, base + 4, le)?;
        let val = tiff_r32(data, base + 8, le)?;
        return f(data, le, val, cnt, typ);
    }
    None
}

fn tiff_ascii(data: &[u8], tag: u16) -> Option<String> {
    tiff_find_tag(data, tag, |d, _le, val, cnt, typ| {
        if typ != 2 { return None; } // type 2 = ASCII
        let n = cnt as usize;
        let off = if n <= 4 { val as usize } else { val as usize };
        std::str::from_utf8(d.get(off..off + n)?)
            .ok()
            .map(|s| s.trim().trim_end_matches('\0').to_string())
            .filter(|s| !s.is_empty())
    })
}

fn tiff_short(data: &[u8], tag: u16) -> Option<u16> {
    tiff_find_tag(data, tag, |d, le, val, _cnt, typ| {
        if typ == 3 {
            // SHORT (2 bytes): if count=1, value is inline in the val_or_offset field
            Some(if le { (val & 0xFFFF) as u16 } else { ((val >> 16) & 0xFFFF) as u16 })
        } else if typ == 4 {
            // LONG stored in short field
            tiff_r32(d, val as usize, le).map(|v| v as u16)
        } else {
            None
        }
    })
}

fn tiff_long(data: &[u8], tag: u16) -> Option<u32> {
    tiff_find_tag(data, tag, |_d, le, val, _cnt, typ| {
        if typ == 4 { Some(if le { val } else { val.swap_bytes() }) }
        else if typ == 3 { Some((if le { val & 0xFFFF } else { (val >> 16) & 0xFFFF }) as u32) }
        else { None }
    })
}

fn tiff_rational_display(data: &[u8], tag: u16) -> Option<String> {
    tiff_find_tag(data, tag, |d, le, val, _cnt, typ| {
        let off = val as usize;
        if typ == 5 {
            // RATIONAL: num/den (2 × u32)
            let num = tiff_r32(d, off, le)? as f64;
            let den = tiff_r32(d, off + 4, le)? as f64;
            if den == 0.0 { return None; }
            Some(format!("{}", num / den))
        } else if typ == 10 {
            // SRATIONAL: num/den (2 × i32)
            let b = d.get(off..off + 8)?;
            let (num, den) = if le {
                (i32::from_le_bytes([b[0],b[1],b[2],b[3]]) as f64,
                 i32::from_le_bytes([b[4],b[5],b[6],b[7]]) as f64)
            } else {
                (i32::from_be_bytes([b[0],b[1],b[2],b[3]]) as f64,
                 i32::from_be_bytes([b[4],b[5],b[6],b[7]]) as f64)
            };
            if den == 0.0 { return None; }
            Some(format!("{}", num / den))
        } else {
            None
        }
    })
}

/// Olympus ORF: standard TIFF byte layout but with magic 0x4F52 ('OR') instead
/// of the standard 0x002A. Patch the two magic bytes in a local copy so that
/// kamadak-exif can parse the IFD chain normally.
fn read_exif_from_orf(path: &std::path::Path) -> Option<exif::Exif> {
    use std::io::Read;
    // ORF EXIF lives near the start of the file; limit to 1MB to avoid reading raw sensor data.
    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let read_limit = file_len.min(1024 * 1024);
    let mut data = Vec::with_capacity(read_limit as usize);
    file.take(read_limit).read_to_end(&mut data).ok()?;
    if data.len() < 4 { return None; }
    // Patch Olympus magic 0x4F52 → standard TIFF magic 0x002A so kamadak-exif can parse.
    data[2] = 0x2A;
    data[3] = 0x00;
    let mut cursor = std::io::Cursor::new(data);
    exif::Reader::new().read_from_container(&mut cursor).ok()
}

/// Read pixel dimensions from a JPEG SOF (Start of Frame) marker.
/// Scans for SOF0/SOF1/SOF2 and returns (width, height).
fn jpeg_sof_dimensions(path: &std::path::Path) -> Option<(u32, u32)> {
    use std::io::Read;
    // SOF marker appears within the first few KB; 64KB is more than enough.
    let file = std::fs::File::open(path).ok()?;
    let mut data = Vec::with_capacity(65536);
    file.take(65536).read_to_end(&mut data).ok()?;
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return None;
    }
    let mut i = 2usize;
    while i + 4 <= data.len() {
        if data[i] != 0xFF {
            return None;
        }
        let marker = data[i + 1];
        if marker == 0xD9 { return None; } // EOI
        // Markers without a length field (standalone)
        if matches!(marker, 0xD0..=0xD8) { i += 2; continue; }
        let seg_len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        if seg_len < 2 || i + 2 + seg_len > data.len() {
            return None;
        }
        // SOF0=0xC0, SOF1=0xC1, SOF2=0xC2 (baseline / extended / progressive DCT)
        if matches!(marker, 0xC0 | 0xC1 | 0xC2) && seg_len >= 7 {
            // SOF payload: precision(1) + height(2) + width(2) + components(1) + ...
            let h = u16::from_be_bytes([data[i + 5], data[i + 6]]) as u32;
            let w = u16::from_be_bytes([data[i + 7], data[i + 8]]) as u32;
            if w > 0 && h > 0 {
                return Some((w, h));
            }
        }
        i += 2 + seg_len;
    }
    None
}

fn pixel_dim(exif: &exif::Exif, tag: exif::Tag) -> Option<u32> {
    exif.get_field(tag, exif::In::PRIMARY).and_then(|f| {
        match &f.value {
            exif::Value::Long(v) => v.first().copied(),
            exif::Value::Short(v) => v.first().map(|&n| n as u32),
            _ => None,
        }
    })
}

fn format_srational_ev(num: i32, denom: i32) -> String {
    if denom == 0 { return "0 EV".to_string(); }
    let val = num as f64 / denom as f64;
    if val > 0.0 {
        format!("+{:.1} EV", val)
    } else if val < 0.0 {
        format!("{:.1} EV", val)
    } else {
        "0 EV".to_string()
    }
}

fn decode_flash(v: u16) -> String {
    let fired = v & 0x01 != 0;
    let no_function = (v >> 5) & 0x01 != 0;
    if no_function { return "No flash function".to_string(); }
    let mode = (v >> 3) & 0x03;
    let prefix = match mode {
        1 => "Compulsory, ",
        2 => "Auto, ",
        _ => "",
    };
    if fired { format!("{}Fired", prefix) } else { format!("{}Did not fire", prefix) }
}

fn tiff_srational_ev(data: Option<&Vec<u8>>, tag: u16) -> Option<String> {
    let data = data?;
    tiff_find_tag(data, tag, |d, le, val, _cnt, typ| {
        if typ != 10 { return None; }
        let off = val as usize;
        let b = d.get(off..off + 8)?;
        let (num, den) = if le {
            (i32::from_le_bytes([b[0], b[1], b[2], b[3]]),
             i32::from_le_bytes([b[4], b[5], b[6], b[7]]))
        } else {
            (i32::from_be_bytes([b[0], b[1], b[2], b[3]]),
             i32::from_be_bytes([b[4], b[5], b[6], b[7]]))
        };
        Some(format_srational_ev(num, den))
    })
}

/// Parse focal length mm value from display string like "85 mm" or "24/1 mm"
pub fn parse_focal_mm(s: &str) -> Option<f32> {
    let num_part = s.split_whitespace().next()?;
    if let Ok(v) = num_part.parse::<f32>() {
        return Some(v);
    }
    // rational "N/D"
    let mut parts = num_part.splitn(2, '/');
    let n: f32 = parts.next()?.parse().ok()?;
    let d: f32 = parts.next()?.parse().ok()?;
    if d != 0.0 { Some(n / d) } else { None }
}

