import Foundation

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
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("rec-\(formatter.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        path = url.path
        frameCount = 0
        isRecording = true
        return url.path
    }

    func append(_ frame: TouchFrame) {
        guard isRecording, let handle, let data = try? encoder.encode(frame) else { return }
        handle.write(data)
        handle.write(Data([0x0a]))
        frameCount += 1
    }

    func stop() {
        try? handle?.close()
        handle = nil
        isRecording = false
    }
}
