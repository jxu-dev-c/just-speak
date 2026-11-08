import Testing
@testable import JustSpeakCore

@Suite struct PartialTranscriptTests {
  @Test func nothingYetIsEmpty() {
    #expect(PartialTranscript().text == "")
  }

  @Test func tailShowsOnceDecoded() {
    var p = PartialTranscript()
    p.setTail(0)
    #expect(p.text == nil)
    p.finished(0, text: "Hello.")
    #expect(p.text == "Hello.")
  }

  @Test func newerTailHidesUntilDecodedSoTextNeverShrinks() {
    var p = PartialTranscript()
    p.setTail(0)
    p.finished(0, text: "Hello.")
    p.setTail(1)  // the speaker went on and paused again
    #expect(p.text == nil)
    p.finished(1, text: "Hello, world.")
    #expect(p.text == "Hello, world.")
  }

  @Test func chunkCutReplacesTheTailItCovers() {
    var p = PartialTranscript()
    p.setTail(0)
    p.finished(0, text: "First part")
    p.addChunk(1)  // a cut at a pause: this chunk covers the tail's audio
    #expect(p.text == "First part")  // the tail stands in until the chunk is decoded
    p.finished(1, text: "First part.")
    #expect(p.text == "First part.")
    p.setTail(2)
    p.finished(2, text: "Second part.")
    #expect(p.text == "First part. Second part.")
  }

  @Test func tailStartedAtThePauseShowsBeforeTheChunkCutRightAfterIt() {
    var p = PartialTranscript()
    p.setTail(0)
    p.finished(0, text: "One.")
    p.setTail(1)  // pause after more speech
    p.addChunk(2)  // the cut follows at the same pause, before either decode is done
    #expect(p.text == nil)
    p.finished(1, text: "One. Two.")
    #expect(p.text == "One. Two.")
    p.finished(2, text: "One, two.")
    #expect(p.text == "One, two.")
  }

  @Test func reusedTailBecomesTheLastChunk() {
    var p = PartialTranscript()
    p.setTail(0)
    p.addChunk(0)  // at release the tail decode is reused as the last chunk
    #expect(p.text == nil)
    p.finished(0, text: "Done.")
    #expect(p.text == "Done.")
  }

  @Test func laterDecodeWaitsForEarlierChunk() {
    var p = PartialTranscript()
    p.addChunk(0)
    p.setTail(1)
    p.finished(1, text: "two")
    #expect(p.text == nil)
    p.finished(0, text: "one")
    #expect(p.text == "one two")
  }

  @Test func cjkJoinsWithoutSpaces() {
    var p = PartialTranscript()
    p.addChunk(0)
    p.addChunk(1)
    p.finished(0, text: "我明天要去开会。")
    p.finished(1, text: "然后回家。")
    #expect(p.text == "我明天要去开会。然后回家。")
  }
}
