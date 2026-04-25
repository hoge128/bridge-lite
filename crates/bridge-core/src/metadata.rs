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
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub software: Option<String>,
}

pub fn read_exif_sync(path: &std::path::Path) -> Option<ExifData> {
    use exif::{In, Tag};

    let file = std::fs::File::open(path).ok()?;
    let mut bufreader = std::io::BufReader::new(file);
    let exif = exif::Reader::new()
        .read_from_container(&mut bufreader)
        .ok()?;

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

    let width = pixel_dim(&exif, Tag::PixelXDimension);
    let height = pixel_dim(&exif, Tag::PixelYDimension);

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
        width,
        height,
        software: get_ascii(Tag::Software),
    })
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
