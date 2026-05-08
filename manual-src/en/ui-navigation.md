# UI Navigation

BridgeLite consists of three central views and two sidebars.

## Views

- **[Thumbnail grid](./thumbnail-grid)** — The main view, shown when a folder is opened
- **[Compare view](./compare)** — Shows camera JPEG, RAW, and developed variants side by side
- **[Single view](./viewer)** — Displays a single photo at full resolution

## Left sidebar (Filters)

A filter panel for narrowing down the photos shown. Supports filtering by file type, camera, ISO, focal length, date, rating, label, and more. See [Filters](./filter-spec) for details.

## Metadata bar

A panel showing information about the selected photo.

- **Preview** — An enlarged preview of the selected photo
- **Histogram** — Luminosity and color distribution
- **Group** — When the selected photo belongs to a group, shows all members (camera JPEG, RAW, developed, etc.). Individual members can be selected and rated from here
- **Metadata** — Capture information (camera, lens, ISO, shutter speed, aperture) and XMP data for the selected photo

## How views connect

```mermaid
flowchart LR
    G[Thumbnail grid]
    C[Compare view]
    V[Single view]

    G -->|Double-click| C
    C -->|Esc| G
    G -->|Space| V
    V -->|Space / Esc| G
    C -->|Space / Double-click| V
```

## Transition summary

| Transition | Action |
|---|---|
| Grid → Compare view | Double-click a thumbnail |
| Compare view → Grid | `Esc` |
| Compare view → Single view | `Space` or Double-click |
| Grid → Single view | `Space` |
| Single view → Grid | `Space` or `Esc` |
