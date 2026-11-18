import Foundation

/// Pure state machine for hold and toggle hotkey interactions, including modifier-chord suppression.
public struct HotkeyStateMachine: Sendable {
  public enum Event: Sendable {
    case pressed
    case released(heldMs: Int)
    case cancelled
    case holdDelayElapsed
  }

  public enum Action: Equatable, Sendable {
    case begin(delayMs: Int)
    case announce
    case finish
    case cancel
  }

  public enum Phase: Equatable, Sendable {
    case idle
    case recording
  }

  public let mode: Config.Hotkey.Mode
  public let minHoldMs: Int
  public private(set) var phase: Phase = .idle
  public private(set) var announced = false
  public private(set) var stoppingToggle = false

  public init(mode: Config.Hotkey.Mode, minHoldMs: Int = 250) {
    self.mode = mode
    self.minHoldMs = minHoldMs
  }

  public mutating func handle(_ event: Event) -> [Action] {
    switch (mode, event, phase) {
    case (_, .holdDelayElapsed, .recording):
      guard !announced else { return [] }
      announced = true
      return [.announce]

    case (_, .cancelled, .recording):
      if mode == .toggle && stoppingToggle {
        stoppingToggle = false
        return []
      }
      phase = .idle
      announced = false
      stoppingToggle = false
      return [.cancel]

    case (.hold, .pressed, .idle), (.toggle, .pressed, .idle):
      phase = .recording
      announced = false
      stoppingToggle = false
      return [.begin(delayMs: minHoldMs)]

    case (.hold, .released(let heldMs), .recording):
      phase = .idle
      announced = false
      return [heldMs < minHoldMs ? .cancel : .finish]

    case (.toggle, .pressed, .recording):
      stoppingToggle = true
      return []

    case (.toggle, .released, .recording):
      if stoppingToggle {
        phase = .idle
        announced = false
        stoppingToggle = false
        return [.finish]
      } else if !announced {
        announced = true
        return [.announce]
      }
      return []

    default:
      return []
    }
  }
}
