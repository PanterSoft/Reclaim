<p align="center">
  <img src="Resources/icon.png" width="128" alt="Reclaim icon">
</p>

<h1 align="center">Reclaim</h1>

<p align="center"><b>Free up disk space on your Mac without deleting anything.</b></p>

A free, open-source macOS app and CLI that recovers space with two built-in APFS features.
Every file keeps its name, location, contents and metadata. Nothing is trashed, uploaded or removed.

- **Duplicate cloning**: identical files become [APFS clones](https://developer.apple.com/documentation/foundation/file_system/about_apple_file_system) that share blocks on disk but stay independent.
- **Transparent compression**: files are stored compressed, like macOS system files. Apps read them as before.
- **Storage analysis**: see what uses space by folder, file kind and size. Read-only.

> [!WARNING]
> Reclaim changes how files are stored on disk. It is provided **as is**, without warranty ([MIT](LICENSE)).
> **Have a current backup** and try a small folder first.

## Safety

- **Copy, verify, swap.** Each result is built in a temp file, metadata copied, SHA-256 checked against the original, then swapped atomically. Any failure leaves the original untouched.
- **Conservative scope.** Only regular, owned, fully downloaded, single-link files. Skips `~/Library`, the Trash, system folders, VMs, app bundles and Photos/Music libraries by default.
- **Reversible.** `reclaim decompress` or *Decompress Files…* in the app.

Changed files get a new inode, so backups copy them once more. Clones only work within one APFS volume.

## Install

```bash
brew tap pantersoft/reclaim https://github.com/PanterSoft/Reclaim
brew install --cask reclaim   # app + `reclaim` CLI
```

Or download `Reclaim-x.y.z.zip` from [Releases](../../releases), unzip and move `Reclaim.app` to **Applications**.
Builds are ad-hoc signed: right-click → **Open** the first time.

Or build from source (macOS 13+, Xcode 15+):

```bash
git clone https://github.com/PanterSoft/Reclaim.git && cd Reclaim
make install   # app → /Applications, `reclaim` → /usr/local/bin
```

Grant **Full Disk Access** when asked (System Settings → Privacy & Security).

## Usage

Pick folders in **Overview**, then review **Storage**, **Duplicates** and **Compression**.
Every action is logged under **Activity** and in `~/Library/Logs/Reclaim/activity.log`.

Optional **background mode** (Settings) runs from the menu bar and compresses unchanged files once a day, on power only.

```bash
reclaim analyze ~                      # what is using space
reclaim duplicates ~/Documents         # dry run
reclaim duplicates --apply ~/Documents # convert to clones
reclaim compress --apply ~/Projects
reclaim decompress ~/Projects          # undo compression
```

Nothing changes without `--apply`.

## How it works

- **Duplicates**: grouped by size, then partial and full SHA-256, then replaced via `clonefile(2)`. Existing clones are detected and not counted twice.
- **Compression**: LZFSE in 64 KiB chunks, stored in the resource fork with a `decmpfs` header, the same format macOS uses. Kept only if it saves ≥10%.
- Core logic lives in `Sources/ReclaimCore`, shared by app and CLI.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Not affiliated with Apple Inc.

## License

[MIT](LICENSE)
