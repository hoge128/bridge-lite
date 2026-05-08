# What is BridgeLite

BridgeLite is a **lightweight image viewer** for photographers who shoot RAW+JPG simultaneously.

After a shoot, your folder fills up with camera JPEGs, RAWs, and developed files all mixed together. It's easy to lose track of which ones have been developed and which haven't. Open the folder in BridgeLite and the status of all three types — along with your ratings — is clear at a glance.

## What it does

BridgeLite does just three things:

- **Browse** — Scroll through large sets of photos in the thumbnail grid
- **Evaluate** — Assign 0–5 star XMP ratings at speed using keyboard shortcuts
- **Compare** — Move between camera JPEG, RAW, and developed variants as one group

For developing, retouching, and exporting, keep using the tools you already know. Ratings carry over to Lightroom and Capture One as-is.

## Grouping feature

Developed isn't always the right answer. Sometimes the camera JPEG is simply better, and sometimes repeated edits make you lose track of where you started. BridgeLite lets you treat all three stages as one group and move between them freely.

## Portable by design

BridgeLite has no proprietary database. All information — including ratings — is written to XMP sidecars, making it readable by any software, including Lightroom and Capture One. Even if you stop using BridgeLite, your photo data stays intact.

## What it does not do

BridgeLite does not develop, color grade, export, or resize images. Those tasks belong to the tools you already use, such as Lightroom or Capture One.

BridgeLite has no proprietary catalog or database. Your photos are managed by the filesystem, and your data remains intact even if you stop using BridgeLite. That said, it does use an internal SQLite cache to keep thumbnail display and rating-based filtering fast. This cache can be deleted at any time without affecting your photos or rating data.

## How XMP is written

Browsing, scrolling, and filtering never touch your image pixels or EXIF data. Safe to use directly from a memory card or network drive.

XMP data such as ratings is written differently depending on file type:

| File type | Default | Option |
|---|---|---|
| JPG | Embedded in the file's XMP area | Sidecar (`.xmp`) |
| RAW | Sidecar (`.xmp`) | — |

RAW files cannot have XMP written directly by design, so the sidecar method is always used. For JPGs, XMP is embedded by default, but you can switch to sidecar mode in the settings.

## Requirements

| | |
|---|---|
| OS | macOS 14 Sonoma or later |
| Chip | Apple Silicon (M1 or later) |
| Price | Free (MIT License) |
