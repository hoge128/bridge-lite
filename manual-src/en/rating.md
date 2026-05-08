# Rating photos

Rating and label data is written in **XMP format**. For JPEG files, XMP is embedded directly in the file by default. For RAW files, a sidecar file (`.xmp`) is always used. JPEG files can be switched to sidecar mode in Settings. Ratings are fully compatible with Lightroom, Capture One, and Adobe Bridge.

## Star ratings

Star ratings can be applied via **keyboard shortcut** or **right-click menu**. Ratings are stored in the `xmp:Rating` field of the XMP metadata — a standard field supported by Lightroom, Capture One, Adobe Bridge, FastRawViewer, and most other photo software.

### Keyboard shortcuts

The shortcut can be changed under **Rating / Label Key** in Settings:

| Option | Shortcut |
|---|---|
| Number key | `0`–`9` |
| ⌘ + number | `⌘0`–`⌘9` |
| ^ + number | `^0`–`^9` |

| Key | Rating |
|---|---|
| `0` | No rating |
| `1` | ★☆☆☆☆ |
| `2` | ★★☆☆☆ |
| `3` | ★★★☆☆ |
| `4` | ★★★★☆ |
| `5` | ★★★★★ |

### Right-click menu

Right-click a thumbnail → **Rating** to apply the same ratings without leaving the mouse. Useful when working keyboard-free.

## Rating grouped photos

When you rate a grouped photo (e.g. a burst sequence), the rating **propagates to every shot in the group** by default. To adjust the rating for individual shots, use the metadata bar.

See [Rating propagation](./rating-spec) for full details on how this works and how to adjust individual shots.


## Color labels

Label data is written to `xmp:Label` and `photoshop:LabelColor` (Adobe Bridge compatible). Color labels can be set via **keyboard shortcut** or **right-click menu**.

| Key | Label |
|---|---|
| `6` | Red |
| `7` | Yellow |
| `8` | Green |
| `9` | Blue |
| —  | Purple (no shortcut assigned) |

Purple can be applied from the right-click menu or the metadata bar.

## Where XMP is saved

| File type | Default | Option |
|---|---|---|
| JPEG | Embedded directly in the file | Sidecar (`.xmp`) — changeable in Settings |
| RAW (`.arw`, `.cr3`, etc.) | Sidecar `.xmp` file with the same stem name | — |

## Carrying ratings into Lightroom

After rating in bridge-lite, open the same folder in Lightroom. Ratings appear automatically when XMP auto-read is enabled.
