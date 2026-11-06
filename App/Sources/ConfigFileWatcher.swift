import Foundation

/// Beobachtet `config.json` auf Änderungen von außen (SPEC §24.5).
///
/// Überwacht den Ordner (atomares Ersetzen = neuer Eintrag) und die Datei selbst (Schreiben an Ort
/// und Stelle). Nach jedem Ereignis wird die Datei neu geöffnet, weil atomares Ersetzen den
/// Dateideskriptor auf die alte Datei zeigen lässt. Meldet entprellt (150 ms) auf dem Main Thread;
/// ob es eine fremde Änderung war, entscheidet der Aufrufer über den Fingerabdruck.
@MainActor
final class ConfigFileWatcher {
    private let fileURL: URL
    private let onChange: @MainActor () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: Task<Void, Never>?

    init(fileURL: URL, onChange: @escaping @MainActor () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
        directorySource = makeSource(
            path: fileURL.deletingLastPathComponent().path(percentEncoded: false),
            mask: [.write, .rename, .delete]
        )
        armFileSource()
    }

    func stop() {
        pending?.cancel()
        directorySource?.cancel()
        fileSource?.cancel()
        directorySource = nil
        fileSource = nil
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = makeSource(path: fileURL.path(percentEncoded: false), mask: [.write, .extend, .delete, .rename, .attrib])
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.armFileSource()
            self.onChange()
        }
    }
}
