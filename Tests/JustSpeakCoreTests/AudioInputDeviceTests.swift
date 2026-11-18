import Foundation
import Testing
@testable import JustSpeakCore

@Suite struct AudioInputDeviceTests {
  let sampleDevices: [AudioInputDevice] = [
    .init(id: 42, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
    .init(id: 77, uid: "AC-DE-48-00-11-22:input", name: "AirPods Pro"),
    .init(id: 99, uid: "USB-Audio- Shure-MV7", name: "Shure MV7 Podcast Mic"),
  ]

  @Test func resolvesByExactAndCaseInsensitiveUIDOrNameAndSubstring() {
    #expect(AudioInputDevice.resolve(preferred: "BuiltInMicrophoneDevice", available: sampleDevices)?.id == 42)
    #expect(AudioInputDevice.resolve(preferred: "builtinmicrophonedevice", available: sampleDevices)?.id == 42)
    #expect(AudioInputDevice.resolve(preferred: "MacBook Pro Microphone", available: sampleDevices)?.id == 42)
    #expect(AudioInputDevice.resolve(preferred: "macbook pro microphone", available: sampleDevices)?.id == 42)
    #expect(AudioInputDevice.resolve(preferred: "Shure MV7", available: sampleDevices)?.id == 99)
  }

  @Test func fallsBackToNilForDefaultOrDisconnectedDevice() {
    #expect(AudioInputDevice.resolve(preferred: "", available: sampleDevices) == nil)
    #expect(AudioInputDevice.resolve(preferred: "   ", available: sampleDevices) == nil)
    #expect(AudioInputDevice.resolve(preferred: "default", available: sampleDevices) == nil)
    #expect(AudioInputDevice.resolve(preferred: "system", available: sampleDevices) == nil)
    #expect(AudioInputDevice.resolve(preferred: "Disconnected USB Mic", available: sampleDevices) == nil)
  }

  @Test func configDecodesAndRoundTripsAudioInputDevice() throws {
    #expect(Config().audio.inputDevice == "")
    let cfg = try Config.decode(Data(#"{"audio": {"inputDevice": "BuiltInMicrophoneDevice"}}"#.utf8))
    #expect(cfg.audio.inputDevice == "BuiltInMicrophoneDevice")
    #expect(try Config.decode(cfg.prettyJSON()) == cfg)
  }
}
