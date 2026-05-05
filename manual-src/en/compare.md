# Compare three types

bridge-lite treats the camera JPEG, RAW, and developed file from the same shutter press as **one group**.

## Why compare all three

Sometimes the camera's output is simply better. Sometimes heavy processing makes you lose track of the original. Switching between all three gives you a clear ground truth before you decide which to keep.

## Switching between variants

With a photo selected, press `Tab` to cycle through the files in its group:

```
Camera JPEG → RAW → Developed → Camera JPEG → …
```

## How pairing works

RAW and JPG files are automatically paired in this order:

1. **Stem name** — `DSC04867.ARW` and `DSC04867.JPG` share the same stem
2. **EXIF timestamp** — Files shot at the same time, even with different names
3. **pHash** — Perceptual hash for visual similarity

## Group compare view

Press `G` to open the group compare view, which displays all variants side by side on screen.

## What counts as "developed"

A JPEG or TIFF exported from Lightroom (or any editor) with the same stem name in the same folder is automatically recognized as a developed variant.
