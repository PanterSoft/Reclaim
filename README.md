# Reclaim

**Free up disk space on your Mac without deleting anything.**

Reclaim is a free, open-source macOS app (and command-line tool) that analyzes your storage
and recovers space using two features built into Apple's file system. Every file keeps its
name, location, contents, dates, tags and permissions. Nothing is moved to the Trash,
uploaded or removed.

| Technique | What happens | Typical wins |
| --- | --- | --- |
| **Duplicate cloning** | Identical files are turned into [APFS clones](https://developer.apple.com/documentation/foundation/file_system/about_apple_file_system). Each copy remains a normal, independent file, but the copies share the same blocks on disk. If you later edit one, APFS copies only the changed blocks; the others are unaffected. | Downloads saved twice, copied project folders, duplicated photo/video exports, installers, datasets |
| **Transparent compression** | Files that compress well are stored compressed by the file system, the same way macOS stores its own system files. Every app reads them exactly as before; macOS decompresses on the fly. | Text, logs, source code, CSVs/JSON, uncompressed images and audio, many app bundles |
| **Storage analysis** | Shows what is using space: by folder, by kind of file, and the largest files. Read-only. | Helps you decide what to clean up yourself |

## Safety

Reclaim is designed so that a bug or a crash cannot cost you data:

- **Scanning is read-only.** Nothing changes until you review the results and confirm.
- **Copy, verify, swap.** A file is never edited in place. Reclaim builds the clone or the
  compressed copy in a hidden temporary file next to the original, copies the original's
  permissions, flags, dates, extended attributes (Finder tags, comments, quarantine info) and
  ACL, checks that its **SHA-256 matches the original's content**, makes sure the original
  has not changed since it was scanned, and only then atomically swaps it in. If any step
  fails, the original is left untouched.
- **Conservative by default.** Reclaim only touches regular files that you own, that have a
  single hard link, are fully downloaded (iCloud placeholders are skipped), and are not locked
  or protected by System Integrity Protection. It skips `~/Library` (app data, iCloud Drive,
  cloud-storage folders), the Trash, system folders (including `/Applications`, `/opt` and
  `/Volumes`), virtual machines (Parallels, VMware Fusion, UTM), app bundles and app-managed libraries
  such as Photos, Music, iMovie and Final Cut Pro, unless you add them as a location yourself.
- **Reversible compression.** `Decompress Files…` in the app (or `reclaim decompress`)
  stores files uncompressed again.

Things worth knowing:

- Cloned and compressed files get a new inode. Backup tools (including Time Machine) will
  back them up again once. Their contents are identical.
- Free space reported by Finder can lag for a while, especially with Time Machine local
  snapshots, which keep the old blocks until the snapshot expires.
- Clones only work within the same APFS volume, and compression requires APFS or HFS+.

## Install

### Download

Grab `Reclaim-x.y.z.zip` from the [Releases](../../releases) page, unzip it and drag
`Reclaim.app` to **Applications**. Release builds are ad-hoc signed, so the first time,
right-click the app and choose **Open** (or run `xattr -dr com.apple.quarantine /Applications/Reclaim.app`).

### Build from source

Requires macOS 13 Ventura or later and Xcode 15+ (or its Command Line Tools).

```bash
git clone <this repository> Reclaim
cd Reclaim
make install   # builds Reclaim.app, copies it to /Applications, links `reclaim` into /usr/local/bin
```

`make app` builds `dist/Reclaim.app` without installing it.

### Permissions

On first launch Reclaim checks for Full Disk Access and, if it is missing, offers to open
**System Settings → Privacy & Security → Full Disk Access**, where you turn Reclaim on (macOS
does not let apps grant this themselves). `make install` launches the app so this happens right
after installing. Without it, macOS asks the first time Reclaim reads Desktop, Documents or
Downloads.

## Using the app

1. **Overview**: check your disk and choose the folders to scan (your home folder by default).
2. **Storage**: see what is taking space.
3. **Duplicates**: find identical files, review the groups, then **Convert to Clones**.
4. **Compression**: find files that shrink well, review, then **Compress**.
5. **Activity**: a log of everything Reclaim did.

Settings (⌘,) control minimum file sizes and whether app bundles are included.

## Command line

```bash
reclaim analyze ~                          # what is using space
reclaim duplicates ~/Documents ~/Downloads # dry run: list duplicate groups
reclaim duplicates --apply ~/Documents     # convert them to clones
reclaim compress --min-size 1M ~/Projects  # dry run: list compressible files
reclaim compress --apply ~/Projects
reclaim decompress ~/Projects              # undo compression
```

`duplicates` and `compress` never change anything without `--apply`. Ctrl-C cancels
cleanly between files.

## How it works

- **Duplicates.** Files are grouped by volume and size, then by a SHA-256 of their first
  64 KiB, then by a SHA-256 of their full contents. Files that already share storage are
  recognized via APFS's clone ID and private size (`getattrlist`) so they are not counted
  twice. Each duplicate is replaced with a `clonefile(2)` copy of the group's "keeper".
- **Compression.** Candidates are sampled at three points and test-compressed to estimate
  the gain; already-compressed formats (JPEG, MP4, ZIP, …) are skipped. Reclaim writes the
  same on-disk format macOS uses for its own compressed files: 64 KiB chunks compressed with
  LZFSE in the file's resource fork, a `com.apple.decmpfs` header and the `UF_COMPRESSED`
  flag. A result is kept only if it saves at least 10%, and files over 256 MB are skipped.
- All file-system logic lives in `Sources/ReclaimCore`, shared by the app and the CLI.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
