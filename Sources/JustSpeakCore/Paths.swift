import Foundation

public enum Paths {
  public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  /// `$XDG_CONFIG_HOME/just-speak`, defaulting to `~/.config/just-speak`.
  public static var configDir: URL {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg).appendingPathComponent("just-speak")
    }
    return home.appendingPathComponent(".config/just-speak")
  }

  public static var configFile: URL { configDir.appendingPathComponent("config.json") }
  public static var envFile: URL { configDir.appendingPathComponent(".env") }

  public static var appSupport: URL {
    home.appendingPathComponent("Library/Application Support/just-speak")
  }

  public static var historyDir: URL { appSupport.appendingPathComponent("history") }
  public static var modelsDir: URL { appSupport.appendingPathComponent("models") }
  public static var logFile: URL { home.appendingPathComponent("Library/Logs/just-speak.log") }

  /// Expand a leading `~` the way a shell would.
  public static func expand(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }
}

/// Watches a config file for both atomic (rename) and in-place (write/truncate) saves.
@MainActor
public final class ConfigFileWatcher {
  private let url: URL
  private var dirSource: DispatchSourceFileSystemObject?
  private var fileSource: DispatchSourceFileSystemObject?
  private var lastSnapshot: FileSnapshot?
  private var pending: DispatchWorkItem?
  private let debounceInterval: TimeInterval
  private let onChange: () -> Void

  private struct FileSnapshot: Equatable {
    var modificationDate: Date?
    var inode: UInt64?
    var size: UInt64?
    var data: Data?
  }

  public init(url: URL, debounceInterval: TimeInterval = 0.2, onChange: @escaping () -> Void) {
    self.url = url
    self.debounceInterval = debounceInterval
    self.onChange = onChange
    lastSnapshot = snapshot()
  }

  deinit {
    dirSource?.cancel()
    fileSource?.cancel()
  }

  public func start() {
    watchDirectory()
    watchFile()
  }

  public func stop() {
    pending?.cancel()
    pending = nil
    dirSource?.cancel()
    dirSource = nil
    fileSource?.cancel()
    fileSource = nil
  }

  private func watchDirectory() {
    dirSource?.cancel()
    dirSource = nil
    let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
    src.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.fileSource == nil { self.watchFile() }
        self.changed()
      }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    dirSource = src
  }

  private func watchFile() {
    fileSource?.cancel()
    fileSource = nil
    let fd = open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete, .link], queue: .main)
    src.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        if !src.data.intersection([.rename, .delete, .link]).isEmpty {
          self.watchFile()
        }
        self.changed()
      }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    fileSource = src
  }

  private func changed() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let currentInode = (try? FileManager.default.attributesOfItem(atPath: self.url.path))?[.systemFileNumber] as? UInt64
        if currentInode != self.lastSnapshot?.inode {
          self.watchFile()
        }
        let s = self.snapshot()
        guard s != self.lastSnapshot else { return }
        self.lastSnapshot = s
        self.onChange()
      }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
  }

  private func snapshot() -> FileSnapshot? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    return FileSnapshot(
      modificationDate: attrs[.modificationDate] as? Date,
      inode: attrs[.systemFileNumber] as? UInt64,
      size: attrs[.size] as? UInt64,
      data: try? Data(contentsOf: url)
    )
  }
}
