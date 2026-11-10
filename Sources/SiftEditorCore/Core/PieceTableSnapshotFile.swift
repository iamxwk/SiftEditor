import Foundation

/// Materializes one immutable editor snapshot without saving over the user's file.
/// The caller owns the returned temporary URL and must remove it after scanning.
enum PieceTableSnapshotFile {
    static func write(_ snapshot: PieceTable, cancelled: () -> Bool = { false },
                      progress: (Double) -> Void = { _ in }) throws -> URL {
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiftEditor-search-").path
        var template = Array((prefix + "XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw FrequentStrings.Failure.unreadable }
        let url = URL(fileURLWithPath: String(cString: template))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var written = 0
            try snapshot.writeAll { bytes in
                if cancelled() { throw FrequentStrings.Failure.cancelled }
                try handle.write(contentsOf: Data(bytes))
                written += bytes.count
                progress(Double(written) / Double(max(snapshot.byteCount, 1)))
            }
            try handle.close()
            return url
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
