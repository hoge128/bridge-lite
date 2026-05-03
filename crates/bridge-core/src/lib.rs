// bridge-core: core logic library (GUI-independent)

pub mod btime;
pub mod db;
pub mod developed;
pub mod error;
pub mod metadata;
pub mod pairing;
pub mod phash;
pub mod raw_thumb;
pub mod scanner;
pub mod xmp;

pub use error::{CoreError, CoreErrorId};
pub use scanner::{ImageEntry, is_raw, SUPPORTED_EXTENSIONS, RAW_EXTENSIONS};
pub use metadata::ExifData;
pub use xmp::{XmpData, Label, Flag};
pub use phash::{hamming, compute_phash_from_luma_32x32};
