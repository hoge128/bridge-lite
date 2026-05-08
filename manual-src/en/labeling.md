# Labeling

## Why labeling matters

Shooting RAW+JPG simultaneously means your folder ends up with a mix of camera JPEGs, RAW files, and developed exports all in one place — and file names alone give no indication of where each file stands in your workflow. To solve this, bridge-lite automatically analyzes every file when you open a folder, combining the file extension, EXIF Software tag, and stem name to determine its type, then displays the result as a badge on each thumbnail. At a glance, the thumbnail grid shows you exactly which files are straight-out-of-camera, which are RAW, and which have been developed, preventing missed files and accidental culling of the wrong variant.

## Badge types

| Badge | Meaning | How it's determined |
|---|---|---|
| `SOOC` | Straight-out-of-camera JPEG | JPEG extension and EXIF Software tag does not match a known editing application |
| `RAW` | RAW file | File extension (`.arw`, `.cr3`, `.nef`, etc.) |
| `Developed` | Developed variant | EXIF Software tag contains a keyword from a known editor (Lightroom, Capture One, etc.) |
| `Indeterminate` | File type could not be determined | Does not match any of the above |

## Cases where detection may fail

Automatic detection is heuristic-based. The following situations can lead to incorrect results.

**Files with no EXIF data**
Without EXIF data, the Software tag cannot be read. Files in this state may show as `Indeterminate` because developed status cannot be determined.

**Files with intentionally stripped EXIF**
When EXIF has been deliberately removed (e.g. before client delivery), grouping falls back to pHash (perceptual hash) visual similarity alone. This increases the risk of incorrectly grouping visually similar shots from different exposures.

**Files exported by an unrecognized application**
If the EXIF Software tag contains an application name not in bridge-lite's known list, the file will not be classified as `Developed` and may appear as `Indeterminate` or `SOOC` instead.

**Files from cameras with non-DCF naming**
Files that do not follow the standard DCF naming convention (e.g. `DSC00001`) used by major camera manufacturers are more prone to incorrect grouping with unrelated shots.

## Duplicate badge

When two or more files with byte-for-byte identical content exist in the folder, a duplicate badge is shown. This is useful for catching accidental double-exports of the same developed result.

Detection works in two stages. First, only files that share the same file size are treated as candidates — files with unique sizes are immediately excluded. SHA-256 hashes are then computed for those candidates only, and files with matching hashes are marked as duplicates. Because the comparison is content-based, files with different names are still detected if their contents are identical. Hash values are cached, so subsequent scans are fast.
