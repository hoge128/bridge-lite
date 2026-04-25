use std::path::PathBuf;

#[derive(Debug)]
pub enum CoreError {
    Io { path: PathBuf, message: String },
    UnsupportedFormat { path: PathBuf },
    XmpParse { path: PathBuf, message: String },
    XmpWrite { path: PathBuf, message: String },
    Db { message: String },
    ThumbnailDecode { path: PathBuf },
    NotFound { path: PathBuf },
    Cancelled,
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::Io { path, message } => write!(f, "IO error at {:?}: {}", path, message),
            CoreError::UnsupportedFormat { path } => write!(f, "Unsupported format: {:?}", path),
            CoreError::XmpParse { path, message } => write!(f, "XMP parse error at {:?}: {}", path, message),
            CoreError::XmpWrite { path, message } => write!(f, "XMP write error at {:?}: {}", path, message),
            CoreError::Db { message } => write!(f, "DB error: {}", message),
            CoreError::ThumbnailDecode { path } => write!(f, "Thumbnail decode failed: {:?}", path),
            CoreError::NotFound { path } => write!(f, "Not found: {:?}", path),
            CoreError::Cancelled => write!(f, "Operation cancelled"),
        }
    }
}

impl std::error::Error for CoreError {}

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreErrorId {
    Io = 1,
    UnsupportedFormat = 2,
    XmpParse = 3,
    XmpWrite = 4,
    Db = 5,
    ThumbnailDecode = 6,
    NotFound = 7,
    Cancelled = 8,
}

impl CoreError {
    pub fn id(&self) -> CoreErrorId {
        match self {
            CoreError::Io { .. } => CoreErrorId::Io,
            CoreError::UnsupportedFormat { .. } => CoreErrorId::UnsupportedFormat,
            CoreError::XmpParse { .. } => CoreErrorId::XmpParse,
            CoreError::XmpWrite { .. } => CoreErrorId::XmpWrite,
            CoreError::Db { .. } => CoreErrorId::Db,
            CoreError::ThumbnailDecode { .. } => CoreErrorId::ThumbnailDecode,
            CoreError::NotFound { .. } => CoreErrorId::NotFound,
            CoreError::Cancelled => CoreErrorId::Cancelled,
        }
    }
}
