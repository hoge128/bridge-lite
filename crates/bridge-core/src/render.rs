use std::path::Path;

/// Render a RAW file to JPEG using rawloader + imagepipe (pure Rust pipeline).
///
/// Decodes → demosaics → applies WB / tone curve / sRGB conversion → resizes → JPEG.
/// max_width: output width upper limit (height scales proportionally); 0 = full resolution.
/// quality: JPEG quality 0–100.
pub fn render_raw_to_jpeg(path: &Path, max_width: u32, quality: u8) -> Option<Vec<u8>> {
    let path_str = path.to_str()?;

    let mut pipeline = imagepipe::Pipeline::new_from_file(path_str).ok()?;
    pipeline.run(None);
    let output = pipeline.output_8bit(None).ok()?;

    let w = output.width as u32;
    let h = output.height as u32;

    let img = image::RgbImage::from_raw(w, h, output.data)?;

    let final_img = if max_width > 0 && w > max_width {
        let ratio = max_width as f32 / w as f32;
        let new_h = (h as f32 * ratio).round() as u32;
        image::imageops::resize(&img, max_width, new_h, image::imageops::FilterType::Lanczos3)
    } else {
        img
    };

    let mut buf = Vec::new();
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, quality);
    image::DynamicImage::ImageRgb8(final_img)
        .write_with_encoder(encoder)
        .ok()?;
    Some(buf)
}
