// Standalone test for clipboard capture and paste, compiling the real sources rather than copies.
// Every case drives `NSPasteboard.withUniqueName()`: writing to `.general` would land in the
// reader's own running Tinycast as a genuine copy.
import AppKit

@main
@MainActor
struct PasteboardTests {
    static var failures = 0
    static var passes = 0
    static let cap = ClipboardManager.maxCapturedFiles

    static func main() {
        finderCopyReadsAsAFileNotItsName()
        everyFileFlavourIsRead()
        multipleFilesReadNewestLast()
        linksAndTextAreNotFiles()
        volatileAndMissingFilesFallThrough()
        theBatchIsCapped()
        rejectedFilesDoNotCountTowardTheCap()
        theBoundedReaderStopsAtItsLimit()
        aModernFileURLSuppressesTheLegacyFallback()
        fileEntriesWriteBackAsFiles()
        imageEntriesWriteBackWithTheirFile()
        clopsMarkNamesItsRewrite()
        aVanishedFileWritesNothing()
        clopsCopyReplacesTheCaptureItRewrites()
        clopsCopyOfOurFilePasteIsIgnored()
        anUnrelatedClopCopyIsRecorded()
        theSourceTagOutranksFocus()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Reading
    /// One reader, every flavour: a board naming a file must never fall through to its name.
    static func everyFileFlavourIsRead() {
        withScratch { dir in
            let file = dir.appendingPathComponent("Tinycast-Settings-2026-08-20.json")
            try? Data("{}".utf8).write(to: file)

            // Finder's real shape: one item carrying the URL and the display name together.
            let item = NSPasteboardItem()
            item.setData(file.dataRepresentation, forType: .fileURL)
            item.setString(file.lastPathComponent, forType: .string)
            let single = board()
            single.writeObjects([item])
            expect(
                PasteboardFiles.urls(on: single) == [file],
                "a URL and a display name on one item reads as the file")

            // Some boards carry the URL as a string rather than as UTF-8 data.
            let asString = NSPasteboardItem()
            asString.setString(file.absoluteString, forType: .fileURL)
            let stringBoard = board()
            stringBoard.writeObjects([asString])
            expect(
                PasteboardFiles.urls(on: stringBoard) == [file],
                "and so does one carrying the URL as a string")

            // The pre-UTI flavour, still written by plenty of apps.
            let legacy = board()
            legacy.declareTypes([.init("NSFilenamesPboardType")], owner: nil)
            legacy.setPropertyList([file.path], forType: .init("NSFilenamesPboardType"))
            expect(
                PasteboardFiles.urls(on: legacy) == [file],
                "the legacy filenames flavour is read when no file URL is present")

            let text = board()
            text.declareTypes([.string], owner: nil)
            text.setString("Tinycast-Settings-2026-08-20.json", forType: .string)
            expect(
                PasteboardFiles.urls(on: text).isEmpty,
                "a bare file name is text, not a file")
        }
    }

    /// The reported bug: Finder puts the display name on `.string` beside `public.file-url`.
    static func finderCopyReadsAsAFileNotItsName() {
        withScratch { dir in
            let file = dir.appendingPathComponent("Screen Recording.mov")
            try? Data("movie".utf8).write(to: file)
            let pb = board()
            pb.declareTypes([.fileURL, .string], owner: nil)
            pb.setData(file.dataRepresentation, forType: .fileURL)
            pb.setString("Screen Recording.mov", forType: .string)

            expect(
                ClipboardManager.fileURLs(on: pb, volatileRoots: []) == [file.path],
                "a Finder copy reads as its path, never as its name")
        }
    }

    static func multipleFilesReadNewestLast() {
        withScratch { dir in
            let urls = ["a.txt", "b.txt", "c.txt"].map { name -> URL in
                let url = dir.appendingPathComponent(name)
                try? Data(name.utf8).write(to: url)
                return url
            }
            let pb = board()
            pb.writeObjects(urls as [NSURL])
            // Reversed, so inserting in order leaves the first file copied leading the history.
            expect(
                ClipboardManager.fileURLs(on: pb, volatileRoots: []) == urls.map(\.path).reversed(),
                "three files read back reversed")
        }
    }

    /// Only a real file URL counts, so a copied link stays a link.
    static func linksAndTextAreNotFiles() {
        let pb = board()
        pb.declareTypes([.string], owner: nil)
        pb.setString("https://example.com/report.pdf", forType: .string)
        expect(ClipboardManager.fileURLs(on: pb) == nil, "an http URL is not a file")

        let plain = board()
        plain.declareTypes([.string], owner: nil)
        plain.setString("just some prose", forType: .string)
        expect(ClipboardManager.fileURLs(on: plain) == nil, "and neither is prose")

        expect(ClipboardManager.fileURLs(on: board()) == nil, "an empty pasteboard reads as nil")
    }

    /// An app that stages a temp file beside better inline content must keep the inline content.
    static func volatileAndMissingFilesFallThrough() {
        let temp = URL(fileURLWithPath: "/private/tmp/tinycast-volatile-\(UUID().uuidString).png")
        try? Data("x".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pb = board()
        pb.writeObjects([temp as NSURL])
        expect(
            ClipboardManager.fileURLs(on: pb) == nil,
            "a file under /private/tmp is not durable, against the shipped roots")

        let gone = board()
        gone.writeObjects([URL(fileURLWithPath: "/nowhere/\(UUID().uuidString).txt") as NSURL])
        expect(ClipboardManager.fileURLs(on: gone) == nil, "and neither is one that is not there")
    }

    static func theBatchIsCapped() {
        withScratch { dir in
            let urls = (0..<40).map { index -> URL in
                let url = dir.appendingPathComponent("f\(index).txt")
                try? Data("x".utf8).write(to: url)
                return url
            }
            for legacy in [false, true] {
                for count in [1, cap - 1, cap, cap + 1, 40] {
                    let pb = fileBoard(Array(urls.prefix(count)), legacy: legacy)
                    defer { pb.releaseGlobally() }
                    expect(
                        ClipboardManager.fileURLs(on: pb, volatileRoots: [])
                            == Array(urls.prefix(min(count, cap)).map(\.path).reversed()),
                        "the first durable files stay reversed at the \(count)-file boundary (legacy: \(legacy))"
                    )
                }
            }
        }
    }

    static func rejectedFilesDoNotCountTowardTheCap() {
        withScratch { dir in
            let volatile = dir.appendingPathComponent("volatile", isDirectory: true)
            let staged = volatile.appendingPathComponent("staged.txt")
            let missing = dir.appendingPathComponent("missing.txt")
            let durableLink = dir.appendingPathComponent("durable-link")
            let volatileLink = dir.appendingPathComponent("volatile-link")
            let brokenLink = dir.appendingPathComponent("broken-link")
            let files = (0..<40).map { dir.appendingPathComponent("f\($0).txt") }
            do {
                try FileManager.default.createDirectory(at: volatile, withIntermediateDirectories: true)
                try Data("staged".utf8).write(to: staged)
                for file in files { try Data("file".utf8).write(to: file) }
                try FileManager.default.createSymbolicLink(at: durableLink, withDestinationURL: files[0])
                try FileManager.default.createSymbolicLink(at: volatileLink, withDestinationURL: staged)
                try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: missing)
            } catch {
                fail("cannot create file capture fixtures: \(error)")
                return
            }
            var root = volatile.resolvingSymlinksInPath().path
            if root.hasPrefix("/private/") { root.removeFirst("/private".count) }
            let rejected = [missing, staged, volatileLink, brokenLink]
            let accepted = [durableLink, files[0]] + files
            let mixed = Array(repeating: missing, count: 40) + rejected + accepted
            for legacy in [false, true] {
                let empty = fileBoard(rejected, legacy: legacy)
                defer { empty.releaseGlobally() }
                expect(
                    ClipboardManager.fileURLs(on: empty, volatileRoots: [root + "/"]) == nil,
                    "missing, volatile and broken targets fall through (legacy: \(legacy))")
                let pb = fileBoard(mixed, legacy: legacy)
                defer { pb.releaseGlobally() }
                expect(
                    ClipboardManager.fileURLs(on: pb, volatileRoots: [root + "/"])
                        == Array(accepted.prefix(cap).map(\.standardizedFileURL.path).reversed()),
                    "rejected files do not consume the cap; links and duplicates keep their order (legacy: \(legacy))"
                )
            }
        }
    }

    /// Bounding lives in the reader now, so both the limit and the predicate must stop exactly.
    static func theBoundedReaderStopsAtItsLimit() {
        let urls = (0..<100).map { URL(fileURLWithPath: "/fixture/\($0).txt") }
        let pb = fileBoard(urls, legacy: false)
        defer { pb.releaseGlobally() }
        expect(PasteboardFiles.urls(on: pb) == urls, "the attachment reader stays uncapped")
        for limit in [-1, 0, 1, cap - 1, cap, cap + 1, 100, Int.max] {
            var visited: [URL] = []
            let matched = PasteboardFiles.urls(on: pb, limit: limit) { url in
                visited.append(url)
                return true
            }
            let expected = Array(urls.prefix(max(0, limit)))
            expect(matched == expected, "a limit of \(limit) bounds the result in board order")
            expect(visited == expected, "and nothing is decoded past a limit of \(limit)")
        }
        var visited: [URL] = []
        let afterRejections = PasteboardFiles.urls(on: pb, limit: cap) { url in
            visited.append(url)
            return visited.count > 40
        }
        expect(
            afterRejections == Array(urls[40..<(40 + cap)]),
            "rejected URLs do not consume the limit")
        expect(
            visited == Array(urls.prefix(40 + cap)),
            "and every URL is tested once, with testing stopping at the limit")
    }

    /// A board naming a file in the modern flavour must never fall back, even when we reject it.
    static func aModernFileURLSuppressesTheLegacyFallback() {
        withScratch { dir in
            let legacy = dir.appendingPathComponent("legacy.txt")
            let modern = dir.appendingPathComponent("modern.txt")
            let missing = dir.appendingPathComponent("missing.txt")
            try? Data("legacy".utf8).write(to: legacy)
            try? Data("modern".utf8).write(to: modern)
            for url in [modern, missing, URL(string: "https://example.com/file")!] {
                let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
                let pb = board()
                defer { pb.releaseGlobally() }
                pb.declareTypes([type, .fileURL], owner: nil)
                pb.setPropertyList([legacy.path], forType: type)
                pb.setData(url.dataRepresentation, forType: .fileURL)

                let named = url.isFileURL ? [url] : [legacy]
                expect(
                    PasteboardFiles.urls(on: pb) == named,
                    "a modern file URL outranks the legacy paths beside it")
                var visited: [URL] = []
                let rejected = PasteboardFiles.urls(on: pb, limit: cap) { candidate in
                    visited.append(candidate)
                    return false
                }
                expect(rejected.isEmpty, "rejecting every candidate names no file")
                expect(visited == named, "and a rejected modern URL still suppresses the fallback")
                expect(
                    ClipboardManager.fileURLs(on: pb, volatileRoots: [])
                        == (url == missing ? nil : named.map(\.path)),
                    "so a missing modern file never captures the legacy path instead")
            }
        }
    }

    static func fileBoard(_ urls: [URL], legacy: Bool) -> NSPasteboard {
        let pb = board()
        if legacy {
            let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            pb.declareTypes([type], owner: nil)
            expect(pb.setPropertyList(urls.map(\.path), forType: type), "legacy fixture is written")
        } else {
            expect(pb.writeObjects(urls as [NSURL]), "file URL fixture is written")
        }
        return pb
    }

    // MARK: - Writing

    /// The round trip: what Finder handed us goes back out as a file, plus the path as text.
    static func fileEntriesWriteBackAsFiles() {
        withScratch { dir in
            let file = dir.appendingPathComponent("report.pdf")
            try? Data("pdf".utf8).write(to: file)
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
            store.addFiles([file.path], sourceBundleID: nil)
            let pb = board()

            expect(Paster.write(store.items[0], store: store, to: pb), "a present file writes")
            let read = pb.readObjects(forClasses: [NSURL.self]) as? [URL]
            expect(read?.first?.path == file.path, "and reads back as the same file URL")
            expect(pb.string(forType: .string) == file.path, "with the path as text, not the name")
            expect(
                pb.types?.contains(ClipboardManager.internalType) == true,
                "marked, so the poller skips our own write")
        }
    }

    /// A terminal pastes only text, so an image reaches it through its stored file's path.
    static func imageEntriesWriteBackWithTheirFile() {
        withScratch { dir in
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let file = dir.appendingPathComponent("shot.png")
            try? png.write(to: file)
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
            let item = ClipboardItem(imagePath: file.path, sourceBundleID: nil)
            let pb = board()

            expect(Paster.write(item, store: store, to: pb), "a stored image writes")
            expect(pb.data(forType: .png) == png, "as its bytes, for apps that take pixels")
            let read = pb.readObjects(forClasses: [NSURL.self]) as? [URL]
            expect(read?.first?.path == file.path, "and as its stored file, for terminals")
            expect(
                pb.types?.contains(ClipboardManager.internalType) == true,
                "marked, so the poller skips our own write")
        }
    }

    /// Clop skips a board carrying its mark, so an image paste carries it and Clop leaves it be.
    static func clopsMarkNamesItsRewrite() {
        let rewrite = board()
        rewrite.declareTypes([.png, ClipboardManager.clopOptimisedType], owner: nil)
        rewrite.setString("true", forType: ClipboardManager.clopOptimisedType)
        expect(ClipboardManager.isClopRewrite(rewrite), "Clop's own output reads as its rewrite")

        let plain = board()
        plain.declareTypes([.png], owner: nil)
        plain.setData(Data([1]), forType: .png)
        expect(!ClipboardManager.isClopRewrite(plain), "an unmarked image is the copier's")

        withScratch { dir in
            let file = dir.appendingPathComponent("shot.png")
            try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
            let image = board()
            Paster.write(ClipboardItem(imagePath: file.path, sourceBundleID: nil), store: store, to: image)
            expect(ClipboardManager.isClopRewrite(image), "an image paste carries the mark")

            store.addText("note", sourceBundleID: nil)
            let text = board()
            Paster.write(store.items[0], store: store, to: text)
            expect(!ClipboardManager.isClopRewrite(text), "a text paste does not")
        }
    }

    static func aVanishedFileWritesNothing() {
        withScratch { dir in
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
            store.addFiles(["/nowhere/\(UUID().uuidString).txt"], sourceBundleID: nil)
            let pb = board()
            pb.declareTypes([.string], owner: nil)
            pb.setString("untouched", forType: .string)

            expect(!Paster.write(store.items[0], store: store, to: pb), "a vanished file refuses")
            expect(pb.string(forType: .string) == "untouched", "and leaves the pasteboard alone")
        }
    }

    // MARK: - Capture

    /// The Sukusho-then-Clop sequence through the poller: one entry, Clop's bytes, Sukusho's name.
    static func clopsCopyReplacesTheCaptureItRewrites() {
        withScratch { dir in
            let (store, manager, _) = capturing(in: dir)
            let pb = board()
            defer { pb.releaseGlobally() }
            let copied = Date()
            write(to: pb) {
                $0.setData(Data("original".utf8), forType: .png)
                $0.setString("com.tommyent.Sukusho", forType: ClipboardManager.sourceType)
            }
            capture(pb, with: manager, into: store, at: copied)
            let cached = dir.appendingPathComponent("clop-cache.png")
            try? Data("optimised".utf8).write(to: cached)
            // Clop's shape with its file path option on: the path rides beside the bytes.
            write(to: pb) {
                $0.setString(cached.absoluteString, forType: .fileURL)
                $0.setData(Data("optimised".utf8), forType: .png)
                $0.setString(cached.path, forType: .string)
                $0.setString("true", forType: ClipboardManager.clopOptimisedType)
            }
            capture(pb, with: manager, into: store, at: copied + 1)

            expect(store.items.count == 1, "Clop's copy replaces the capture instead of adding one")
            expect(store.items.first?.kind == .image, "as the optimised image, not Clop's path")
            expect(
                store.items.first?.sourceBundleID == "com.tommyent.Sukusho",
                "still credited to the app that copied it")
        }
    }

    /// A file paste carries no Clop mark, so Clop optimising it must not come back as an entry.
    static func clopsCopyOfOurFilePasteIsIgnored() {
        withScratch { dir in
            let (store, manager, _) = capturing(in: dir)
            let file = dir.appendingPathComponent("shot.png")
            try? Data("png".utf8).write(to: file)
            store.addFiles([file.path], sourceBundleID: nil)
            let pb = board()
            defer { pb.releaseGlobally() }

            expect(Paster.write(store.items[0], store: store, to: pb), "the file paste writes")
            expect(!ClipboardManager.isClopRewrite(pb), "unmarked, so Clop may optimise it")
            capture(pb, with: manager, into: store)
            writeClop(to: pb)
            capture(pb, with: manager, into: store)
            expect(store.items.count == 1, "Clop's copy of our paste adds no entry")
        }
    }

    /// A Clop board that follows nothing we captured or wrote is an ordinary copy.
    static func anUnrelatedClopCopyIsRecorded() {
        withScratch { dir in
            let (store, manager, _) = capturing(in: dir)
            let pb = board()
            defer { pb.releaseGlobally() }
            writeClop(to: pb)
            capture(pb, with: manager, into: store)
            expect(store.items.count == 1, "a Clop copy with nothing before it is recorded")
            expect(
                store.items.first?.sourceBundleID == "com.google.Chrome",
                "and credited like any other copy")

            write(to: pb) { $0.setString("first", forType: .string) }
            capture(pb, with: manager, into: store)
            write(to: pb) { $0.setString("never read", forType: .string) }
            writeClop(to: pb)
            capture(pb, with: manager, into: store)
            expect(store.items.count == 3, "and so is one a change past the newest entry")
            expect(store.items.first?.kind == .image, "as its image")
        }
    }

    /// A writer's tag names the source over focus, for the entry and for exclusions alike.
    static func theSourceTagOutranksFocus() {
        withScratch { dir in
            let (store, manager, settings) = capturing(in: dir)
            let pb = board()
            defer { pb.releaseGlobally() }
            @MainActor func copy(_ text: String, taggedAs source: String) {
                write(to: pb) {
                    $0.setString(text, forType: .string)
                    $0.setString(source, forType: ClipboardManager.sourceType)
                }
                capture(pb, with: manager, into: store)
            }

            copy("tagged", taggedAs: "com.tommyent.Sukusho")
            expect(
                store.items.first?.sourceBundleID == "com.tommyent.Sukusho",
                "the tag names the source though another app is in front")
            copy("untagged", taggedAs: "")
            expect(
                store.items.first?.sourceBundleID == "com.google.Chrome",
                "an empty tag falls back to the front app")

            settings.clipboardDisabledApps = ["com.tommyent.Sukusho"]
            copy("excluded", taggedAs: "com.tommyent.Sukusho")
            expect(store.items.first?.text == "untagged", "an excluded tagged app's copy is dropped")

            settings.clipboardDisabledApps = ["com.google.Chrome"]
            copy("allowed", taggedAs: "com.tommyent.Sukusho")
            expect(
                store.items.first?.text == "allowed",
                "and an excluded front app no longer drops a tagged copy")
        }
    }

    static func capturing(in dir: URL) -> (ClipboardStore, ClipboardManager, AppSettings) {
        let store = ClipboardStore(directory: dir.appendingPathComponent("store"))
        let settings = AppSettings()
        return (store, ClipboardManager(store: store, settings: settings), settings)
    }

    /// A write as Clop and most apps make one: a clear and a single item, so a single change.
    static func write(to pb: NSPasteboard, _ fill: (NSPasteboardItem) -> Void) {
        let item = NSPasteboardItem()
        fill(item)
        pb.clearContents()
        pb.writeObjects([item])
    }

    static func writeClop(to pb: NSPasteboard) {
        write(to: pb) {
            $0.setData(Data("optimised".utf8), forType: .png)
            $0.setString("true", forType: ClipboardManager.clopOptimisedType)
        }
    }

    /// An image lands after its blob write, so give a capture time to arrive, or not to.
    static func capture(
        _ pb: NSPasteboard, with manager: ClipboardManager, into store: ClipboardStore,
        at now: Date = Date()
    ) {
        let before = store.items.first?.id
        manager.capture(pb, frontmost: "com.google.Chrome", at: now)
        let deadline = Date().addingTimeInterval(0.5)
        while store.items.first?.id == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Harness

    static func board() -> NSPasteboard { NSPasteboard.withUniqueName() }

    static func withScratch(_ body: (URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-pasteboard-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        body(dir)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            fail(message)
        }
    }

    static func fail(_ message: String) {
        failures += 1
        print("FAIL: \(message)")
    }
}

// MARK: - Stubs for what the shipped sources reach that this harness does not exercise

@MainActor
final class AppSettings {
    var clipboardDisabledApps: Set<String> = []
}

enum Permissions {
    static func ensureAccessibility() -> Bool { false }
}

final class NotificationToken {
    init(_ observer: Any, center: NotificationCenter) {}
}
