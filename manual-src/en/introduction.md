# What is bridge-lite

bridge-lite is a **lightweight image viewer** for photographers who shoot RAW+JPG simultaneously.

In a folder of camera JPEGs, RAWs, and developed files, bridge-lite tracks which files have been developed and what ratings they carry — your current position in the workflow.

## What it does

bridge-lite does three things:

- **Browse** — Scroll through large sets of photos in the thumbnail grid
- **Evaluate** — Assign 0–5 star XMP ratings from the keyboard
- **Compare** — Switch between camera JPEG, RAW, and developed variants as one shot

It does not develop, retouch, or export. Those belong to Lightroom, Capture One, or whatever tool you already use.

## What it does not do

| Out of scope | Use instead |
|---|---|
| Developing / color grading | Lightroom / Capture One / Darkroom |
| Export / resize | Your editing tool |
| Catalog management | Your editing tool |
| Cloud sharing | Out of scope |

## Files are never modified

Browsing, scrolling, and filtering never touch your originals — not a single byte, timestamp, or permission bit. Safe to use directly from a memory card or network drive.

Rating data is written to XMP sidecar files only. RAW files are never modified.

## Requirements

| | |
|---|---|
| OS | macOS 14 Sonoma or later |
| Chip | Apple Silicon (M1 or later) |
| Price | Free (MIT License) |
