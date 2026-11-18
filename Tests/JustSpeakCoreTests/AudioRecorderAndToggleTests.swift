@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct AudioRecorderAndToggleTests {
  @Test func toggleModeSuppressesFeedbackOnModifierChordFromIdle() {
    var sm = HotkeyStateMachine(mode: .toggle, minHoldMs: 250)
    // Pressing Option schedules feedback after minHoldMs (250ms), not 0ms.
    #expect(sm.handle(.pressed) == [.begin(delayMs: 250)])
    #expect(sm.announced == false)

    // Pressing Left Arrow (~50ms later) cancels before announce ever fires.
    #expect(sm.handle(.cancelled) == [.cancel])
    #expect(sm.phase == .idle)
    #expect(sm.announced == false)
  }

  @Test func toggleModeAnnouncesImmediatelyOnCleanTapReleaseAndStopsOnSecondTapRelease() {
    var sm = HotkeyStateMachine(mode: .toggle, minHoldMs: 250)
    #expect(sm.handle(.pressed) == [.begin(delayMs: 250)])
    // Clean tap release (80ms) confirms and announces the toggle recording immediately.
    #expect(sm.handle(.released(heldMs: 80)) == [.announce])
    #expect(sm.phase == .recording)
    #expect(sm.announced == true)

    // Modifier chord (e.g. Option+Left) while recording in toggle mode does NOT stop or cancel recording.
    #expect(sm.handle(.pressed) == [])
    #expect(sm.phase == .recording)
    #expect(sm.handle(.cancelled) == [])
    #expect(sm.phase == .recording)
    #expect(sm.handle(.released(heldMs: 60)) == [])
    #expect(sm.phase == .recording)

    // A clean tap of the hotkey stops the toggle recording on release.
    #expect(sm.handle(.pressed) == [])
    #expect(sm.handle(.released(heldMs: 50)) == [.finish])
    #expect(sm.phase == .idle)
  }

  @Test func toggleModeStillCancelsOnEscapeWhileRecording() {
    var sm = HotkeyStateMachine(mode: .toggle, minHoldMs: 250)
    _ = sm.handle(.pressed)
    _ = sm.handle(.released(heldMs: 50))
    #expect(sm.phase == .recording)

    // Escape arrives without the modifier being pressed (`stoppingToggle == false`).
    #expect(sm.handle(.cancelled) == [.cancel])
    #expect(sm.phase == .idle)
  }

  @Test func removingTapOnStartFailureAllowsSubsequentTapInstall() {
    let node = AVAudioMixerNode()
    let engine = AVAudioEngine()
    engine.attach(node)
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    struct StartFailure: Error {}

    func startEngine(shouldFail: Bool) throws {
      if shouldFail { throw StartFailure() }
    }

    func attemptStart(shouldFail: Bool) throws {
      node.removeTap(onBus: 0)
      node.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
      do {
        try startEngine(shouldFail: shouldFail)
      } catch {
        node.removeTap(onBus: 0)
        throw error
      }
    }

    #expect(throws: StartFailure.self) { try attemptStart(shouldFail: true) }
    // A second attempt must not crash with NSException ('nullptr == Tap()').
    #expect(throws: Never.self) { try attemptStart(shouldFail: false) }
    node.removeTap(onBus: 0)
  }
}
