import Foundation
import CoreServices

// MARK: - FolderWatcher

/// Watches a directory tree with FSEvents and fires an onChange callback
/// when supported image files are added, removed, or renamed.
///
/// Lifecycle: owned by LibraryStore. `stop()` must be called before releasing
/// this object (or before setting the owning LibraryStore.watcher to nil)
/// so the FSEventStream's unretained `info` pointer stays valid.
@MainActor final class FolderWatcher {

    enum Event {
        case added([URL])
        case removed([URL])
    }

    private var streamRef: FSEventStreamRef?
    private(set) var lastEventId: FSEventStreamEventId?

    private let onChange: (Event) -> Void

    init(onChange: @escaping (Event) -> Void) {
        self.onChange = onChange
    }

    // MARK: - Public API

    func start(at url: URL, sinceEventId: FSEventStreamEventId? = nil) {
        stop()

        let pathsArray = [url.path] as CFArray
        let sinceWhen = sinceEventId ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

        // passUnretained: the stream is always stopped before self can be deallocated
        // (LibraryStore calls stop() in cancelLoading/reset/suspend/deinit).
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let createFlags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            nil,
            folderWatcherFSEventsCallback,
            &context,
            pathsArray,
            sinceWhen,
            1.0,  // 1 second latency coalesces burst copies into one callback
            createFlags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        streamRef = stream
    }

    func stop() {
        guard let stream = streamRef else { return }
        lastEventId = FSEventStreamGetLatestEventId(stream)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    // MARK: - Internal — called from the C callback via Task

    func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        var addedURLs:   [URL] = []
        var removedURLs: [URL] = []

        for (path, flag) in zip(paths, flags) {
            // File-only events; skip directory notifications
            guard flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }

            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            guard FolderWatcher.supportedExtensions.contains(ext) else { continue }

            let isCreated = flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            let isRemoved = flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
            let isRenamed = flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0

            if isRenamed {
                // "Move to Trash" is a rename from macOS/FSEvents perspective.
                // Use file existence to disambiguate:
                //   - file gone  → moved out / trashed → removed
                //   - file exists → moved in / renamed to this name → added
                if FileManager.default.fileExists(atPath: path) {
                    addedURLs.append(url)
                } else {
                    removedURLs.append(url)
                }
            } else {
                if isCreated { addedURLs.append(url) }
                if isRemoved { removedURLs.append(url) }
            }
        }

        if !addedURLs.isEmpty   { onChange(.added(addedURLs)) }
        if !removedURLs.isEmpty { onChange(.removed(removedURLs)) }
    }

    // Mirrors ScanPipeline.supportedExtensionsSet — kept here to avoid
    // an actor isolation dependency across module boundaries.
    private static let supportedExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "nrw", "rw2", "orf", "pef", "raf", "dng",
        "fff", "3fr", "iiq", "mos", "mrw", "srw", "x3f",
        "jpg", "jpeg", "heic", "heif", "tiff", "tif", "png",
    ]
}

// MARK: - FSEvents C callback (file-scope, @convention(c))

private func folderWatcherFSEventsCallback(
    _: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()

    // NSArray cast is safe for kFSEventStreamCreateFlagUseCFTypes
    guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    let flagsArray = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

    // Hop to MainActor; weak capture protects against stop()-then-callback races
    Task { @MainActor [weak watcher] in
        watcher?.handleEvents(paths: pathsArray, flags: flagsArray)
    }
}
