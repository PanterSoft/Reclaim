# Contributing to Reclaim

Thanks for helping! Reclaim's one hard rule: **it must never lose or alter user data.**

## Ground rules

- Every change to a file on disk goes through `SafeReplace.replace` (build a copy beside the
  original, copy metadata, verify the content hash, check the original is unchanged, then
  atomically rename). Do not add code paths that write to user files any other way.
- Scanning is read-only. Anything that modifies files must be an explicit, confirmed action.
- New features that free space must keep every file present with identical contents.
  Deleting caches, logs, Time Machine snapshots and so on is out of scope.
- Add a test in `Tests/ReclaimCoreTests` for any new operation, including a failure case.

## Development

Requirements: macOS 13 or later and Xcode 15+ (or the matching Command Line Tools).

```bash
make test      # run the test suite (uses a temporary folder on your APFS disk)
make run       # launch the app straight from source
make dev       # build a debug Reclaim.app bundle and open it
make cli ARGS="analyze ~/Downloads"
make install   # build a release and install it into /Applications and /usr/local/bin
```

Run `make` on its own to list every target.

You can also open the package in Xcode with `make xcode`.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/ReclaimCore` | All file-system logic: scanning, duplicate detection, cloning, compression |
| `Sources/ReclaimApp` | The SwiftUI app |
| `Sources/reclaim` | The command-line tool |
| `Tests/ReclaimCoreTests` | Tests that exercise the real file system |
| `Tests/ReclaimAppTests` | App model and UI rendering tests; `RECLAIM_SNAPSHOTS=<folder> make test` saves a PNG of every screen |
| `scripts/build-app.sh` | Assembles and signs `Reclaim.app` |
