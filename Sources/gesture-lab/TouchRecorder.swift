import Foundation
import TrackpadKit

/// Streams TouchFrames to a JSONL file, one frame per line, so real
/// gestures can be replayed deterministically through the recognizer.
final class TouchRecorder {
    private(set) var isRecording = false
    private(set) var path: String?
    private(set) var frameCount = 0

    private var handle: FileHandle?
    private let encoder = JSONEncoder()

    /// Starts a new recording in `directory` (created if needed) and
    /// returns the file path.
    func start(directory: String) throws -> String {
        stop()
        let dir = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        // Recordings within the same second must not overwrite each other.
        var url = dir.appendingPathComponent("rec-\(stamp).jsonl")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("rec-\(stamp)-\(suffix).jsonl")
            suffix += 1
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        path = url.path
        frameCount = 0
        isRecording = true
        return url.path
    }

    func append(_ frame: TouchFrame) {
        guard isRecording, let handle, var data = try? encoder.encode(frame) else { return }
        data.append(0x0a)
        do {
            try handle.write(contentsOf: data)
            frameCount += 1
        } catch {
            // The legacy write(_:) would crash on a full disk; stop the
            // recording instead and leave what was captured intact.
            stop()
        }
    }

    func stop() {
        try? handle?.close()
        handle = nil
        isRecording = false
    }
}
