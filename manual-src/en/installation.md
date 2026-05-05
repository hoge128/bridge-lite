# Installation

## Download

Download the latest DMG from [GitHub Releases](https://github.com/hoge128/bridge-lite/releases/latest).

## Install

1. Open the downloaded `.dmg` file
2. Drag `BridgeLite.app` to your **Applications** folder
3. Launch bridge-lite from the Applications folder

## Gatekeeper warning

bridge-lite is not notarized by Apple, so Gatekeeper will show a warning on first launch.

**Option 1 — GUI**
1. Right-click the viewer in Finder
2. Choose "Open"
3. Click "Open" in the dialog

**Option 2 — Terminal**

```sh
xattr -dr com.apple.quarantine ~/Applications/BridgeLite.app
```

After that, launch normally.
