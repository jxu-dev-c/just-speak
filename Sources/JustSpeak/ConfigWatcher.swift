import Foundation
import JustSpeakCore

/// Calls `onChange` when config.json is modified. Watches the directory rather than the file
/// because editors save by writing a temp file and renaming it over the original.
@MainActor
final class ConfigWatcher {
  private let url: URL
  private var source: DispatchSourceFileSystemObject?
  private var lastModified: Date?
  private var pending: DispatchWorkItem?
  private let onChange: () -> Void

  init(url: URL, onChange: @escaping () -> Void) {
    self.url = url
    self.onChange = onChange
    lastModified = modificationDate()
  }

  func start() {
    let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
    src.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.changed() }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    source = src
  }

  private func changed() {
    // Debounce: one save can produce several directory events.
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let m = self.modificationDate()
        guard m != self.lastModified else { return }
        self.lastModified = m
        self.onChange()
      }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }

  private func modificationDate() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
