import CSherpaOnnx
import Darwin
import Foundation

public enum Wave {
  /// Read a mono 16-bit PCM WAV file into normalized float samples.
  public static func read(_ path: String) -> (samples: [Float], sampleRate: Int)? {
    guard let w = SherpaOnnxReadWave(path) else { return nil }
    defer { SherpaOnnxFreeWave(w) }
    let samples = Array(UnsafeBufferPointer(start: w.pointee.samples, count: Int(w.pointee.num_samples)))
    return (samples, Int(w.pointee.sample_rate))
  }
}

public enum ProcessStats {
  /// Physical footprint in MB — the number Activity Monitor shows as "Memory".
  public static var footprintMB: Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
  }
}
