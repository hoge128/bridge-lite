# Rating photos

All ratings are written to **XMP sidecar files**. RAW files are never modified. Ratings are fully compatible with Lightroom, Capture One, and Adobe Bridge.

## Star ratings

| Key | Rating |
|---|---|
| `0` | No rating |
| `1` | ★☆☆☆☆ |
| `2` | ★★☆☆☆ |
| `3` | ★★★☆☆ |
| `4` | ★★★★☆ |
| `5` | ★★★★★ |

## Pick / Reject flags

| Key | Action |
|---|---|
| `P` | Set Pick flag |
| `X` | Set Reject flag |
| `U` | Clear flag |

## Color labels

| Key | Label |
|---|---|
| `6` | Red |
| `7` | Yellow |
| `8` | Green |
| `9` | Blue |

## Where XMP is saved

| File type | Saved to |
|---|---|
| RAW (`.arw`, `.cr3`, etc.) | Sidecar `.xmp` file with the same stem name |
| JPEG | Embedded directly in the file |

## Carrying ratings into Lightroom

After rating in bridge-lite, open the same folder in Lightroom. Ratings appear automatically when XMP auto-read is enabled.
