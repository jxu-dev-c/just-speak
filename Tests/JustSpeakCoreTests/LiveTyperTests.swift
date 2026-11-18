import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct LiveTyperTests {
  @MainActor
  @Test func detachesWhenFocusMovesBeforeFirstPartial() {
    var activePID: pid_t? = 1001
    let tracker = LiveTypingTracker(config: .init(), targetPID: activePID, frontmostPID: { activePID })

    // User switches apps before any partial is typed (`typed` is still "").
    activePID = 2002
    let edit = tracker.nextEdit(for: "hello world")
    #expect(edit == nil)
    #expect(tracker.detached == true)
    #expect(tracker.typed == "")

    // Switching back later still does not resume typing once detached.
    activePID = 1001
    #expect(tracker.nextEdit(for: "hello world") == nil)
  }

  @MainActor
  @Test func detachesWhenFocusMovesAfterPartialRevisedToEmpty() {
    var activePID: pid_t? = 1001
    let tracker = LiveTypingTracker(config: .init(), targetPID: activePID, frontmostPID: { activePID })

    #expect(tracker.nextEdit(for: "um") == .init(delete: 0, insert: "um"))
    #expect(tracker.nextEdit(for: "") == .init(delete: 2, insert: ""))
    #expect(tracker.typed == "")

    // Even though `typed` is empty again, targetPID remains 1001.
    activePID = 3003
    #expect(tracker.nextEdit(for: "final text") == nil)
    #expect(tracker.detached == true)
  }

  @MainActor
  @Test func typesAndRevisesWhileFocusRemainsOnTargetApp() {
    let activePID: pid_t? = 1001
    let tracker = LiveTypingTracker(config: .init(), targetPID: activePID, frontmostPID: { activePID })

    #expect(tracker.nextEdit(for: "hello") == .init(delete: 0, insert: "hello"))
    #expect(tracker.nextEdit(for: "hello there") == .init(delete: 0, insert: " there"))
    #expect(tracker.nextEdit(for: "Hello, there.") == .init(delete: 11, insert: "Hello, there."))
    #expect(tracker.detached == false)
    #expect(tracker.typed == "Hello, there.")
    #expect(tracker.deleted == 11)
  }
}
