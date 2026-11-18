import Foundation

/// Represents an audio input hardware device available for recording.
public struct AudioInputDevice: Equatable, Sendable {
  public var id: UInt32
  public var uid: String
  public var name: String

  public init(id: UInt32, uid: String, name: String) {
    self.id = id
    self.uid = uid
    self.name = name
  }

  /// Resolves `preferred` (device UID or name; `""` / `"default"` / `"system"` means system default)
  /// against `available`. Returns `nil` when system default is requested or when the preferred device
  /// is disconnected (so the caller falls back to the system default input device).
  public static func resolve(preferred: String, available: [AudioInputDevice]) -> AudioInputDevice? {
    let query = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty,
          query.caseInsensitiveCompare("default") != .orderedSame,
          query.caseInsensitiveCompare("system") != .orderedSame
    else { return nil }

    if let exactUID = available.first(where: { $0.uid == query }) { return exactUID }
    if let ciUID = available.first(where: { $0.uid.caseInsensitiveCompare(query) == .orderedSame }) { return ciUID }
    if let exactName = available.first(where: { $0.name == query }) { return exactName }
    if let ciName = available.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return ciName }
    if let partial = available.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) { return partial }
    return nil
  }
}
