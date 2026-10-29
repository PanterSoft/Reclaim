import Foundation
import ReclaimCore

let usage = """
reclaim — free up disk space on your Mac without deleting anything.

USAGE:
  reclaim analyze    [PATH ...]
  reclaim duplicates [--apply] [--min-size SIZE] [--include-apps] [PATH ...]
  reclaim compress   [--apply] [--min-size SIZE] [--include-apps] [PATH ...]
  reclaim decompress PATH ...

COMMANDS:
  analyze      Show what is using space (read-only).
  duplicates   Find identical files and turn them into APFS clones that share storage.
  compress     Find files that benefit from transparent compression and compress them.
  decompress   Undo transparent compression for files or folders.

Without --apply, `duplicates` and `compress` only report what they would do.
PATH defaults to your home folder. SIZE accepts K, M and G suffixes (e.g. 512K, 10M).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func parse(_ arguments: [String]) -> Invocation {
    do {
        guard let invocation = try Invocation.parse(arguments) else { print(usage); exit(0) }
        return invocation
    } catch let error as Invocation.UsageError {
        fail(error.message)
    } catch {
        fail(error.localizedDescription)
    }
}

// MARK: - Output

func column(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

let progressPrinter: ProgressHandler = { update in
    let line = "\(update.summary)  \(update.detail)"
    let clipped = line.count > 100 ? String(line.prefix(97)) + "…" : line
    FileHandle.standardError.write(Data("\r\u{1B}[K\(clipped)".utf8))
}

func clearProgress() {
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
}

func printReport(_ report: OperationReport, verb: String) {
    print("\n\(verb) \(report.succeeded) file(s), reclaimed about \(report.bytesReclaimed.formattedBytes).")
    if report.skipped > 0 { print("Skipped \(report.skipped) file(s) that would not shrink enough.") }
    if !report.failures.isEmpty {
        print("\(report.failures.count) file(s) were left untouched:")
        for failure in report.failures.prefix(20) { print("  • \(failure.reason)") }
    }
}

func printVolume(for url: URL) {
    guard let volume = VolumeInfo(for: url) else { return }
    print("Volume \"\(volume.name)\" (\(volume.format))")
    print("  Capacity  \(volume.totalCapacity.formattedBytes)")
    print("  Used      \(volume.used.formattedBytes)")
    print("  Free      \(volume.availableCapacity.formattedBytes)  (+\(volume.purgeable.formattedBytes) purgeable)")
    print("")
}

// MARK: - Commands

func run(_ invocation: Invocation) throws {
    let roots = invocation.roots
    let options = ScanOptions.conservative(
        minimumFileSize: invocation.minimumSize ?? (invocation.command == "compress" ? 64 << 10 : 1 << 20),
        includeApplicationBundles: invocation.includeApps
    )

    switch invocation.command {
    case "analyze":
        printVolume(for: roots[0])
        let report = try StorageAnalyzer.analyze(roots: roots, progress: progressPrinter)
        clearProgress()
        print("Scanned \(report.fileCount.formatted()) files using \(report.allocatedBytes.formattedBytes) on disk.")
        if report.compressionSavings > 0 {
            print("Transparent compression is already saving \(report.compressionSavings.formattedBytes).")
        }
        if report.cloudOnlyFiles > 0 { print("\(report.cloudOnlyFiles.formatted()) file(s) are stored only in the cloud.") }
        print("\nBy kind:")
        for usage in report.categories { print(column(usage.bytes.formattedBytes, 12) + "  " + usage.category.rawValue) }
        print("\nLargest folders:")
        for entry in report.folders.prefix(15) { print(column(entry.bytes.formattedBytes, 12) + "  " + entry.path) }
        print("\nLargest files:")
        for entry in report.largestFiles.prefix(15) { print(column(entry.bytes.formattedBytes, 12) + "  " + entry.path) }

    case "duplicates":
        let groups = try DuplicateFinder.findDuplicates(in: roots, options: options, progress: progressPrinter)
        clearProgress()
        let total = groups.reduce(0) { $0 + $1.reclaimableBytes }
        guard !groups.isEmpty else { print("No duplicate files found that could share storage."); return }
        for group in groups.prefix(25) {
            print("\(group.reclaimableBytes.formattedBytes) — \(group.allFiles.count) copies of \(group.size.formattedBytes)")
            print("    keep  \(group.keeper.path)")
            for file in group.filesToReplace { print("    clone \(file.path)") }
        }
        if groups.count > 25 { print("… and \(groups.count - 25) more groups") }
        print("\n\(groups.count) group(s); converting them to clones would free about \(total.formattedBytes).")
        guard invocation.apply else { print("Run again with --apply to convert them. No files are deleted."); return }
        printReport(CloneDeduplicator.deduplicate(groups, progress: progressPrinter), verb: "Cloned")

    case "compress":
        let candidates = try TransparentCompression.findCandidates(in: roots, options: options, progress: progressPrinter)
        clearProgress()
        guard !candidates.isEmpty else { print("No files found that would benefit from compression."); return }
        let total = candidates.reduce(0) { $0 + $1.estimatedSavings }
        for candidate in candidates.prefix(25) {
            print(column(candidate.estimatedSavings.formattedBytes, 12) + "  " + candidate.path)
        }
        if candidates.count > 25 { print("… and \(candidates.count - 25) more files") }
        print("\n\(candidates.count) file(s); compressing them would free about \(total.formattedBytes).")
        guard invocation.apply else { print("Run again with --apply to compress them. Files stay readable by every app."); return }
        printReport(TransparentCompression.compress(candidates, progress: progressPrinter), verb: "Compressed")

    case "decompress":
        guard !invocation.paths.isEmpty else { fail("decompress needs at least one path") }
        let report = try TransparentCompression.decompress(invocation.roots)
        for failure in report.failures { print("  • \(failure.reason)") }
        print("Decompressed \(report.succeeded) file(s); they now use \((-report.bytesReclaimed).formattedBytes) more space.")

    default:
        fail("unknown command \(invocation.command)")
    }
}

// Run on a background task so Ctrl-C can cancel cleanly (no temporary files left behind).
setvbuf(stdout, nil, _IOLBF, 0)
let invocation = parse(Array(CommandLine.arguments.dropFirst()))
let work = Task.detached { try run(invocation) }

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    FileHandle.standardError.write(Data("\nCancelling…\n".utf8))
    work.cancel()
}
interrupt.resume()

Task {
    do {
        try await work.value
        exit(0)
    } catch is CancellationError {
        exit(130)
    } catch {
        clearProgress()
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
dispatchMain()
