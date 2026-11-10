import Foundation

/// Streams ripgrep's JSON events. The helper is bundled with the app; tests can use rg on PATH.
enum RipgrepSearch {
    enum Failure: Error { case failed(String), invalidOutput }

    /// ICU and ripgrep use different regex engines. Only route plain ASCII
    /// patterns without escapes, groups with options, or character classes.
    static func canUseFastPath(_ pattern: String) -> Bool {
        !pattern.isEmpty
            && pattern.unicodeScalars.allSatisfy { $0.value < 0x80 }
            && !pattern.contains("\\")
            && !pattern.contains("(?")
            && !pattern.contains("[")
            && !pattern.contains("{")
            && !pattern.contains("|")
    }

    static var executable: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("rg")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func scan(url: URL, pattern: String, caseSensitive: Bool,
                     cancelled: @escaping () -> Bool = { false },
                     match: (Int, String) throws -> Void) throws {
        guard let executable else { throw Failure.failed("ripgrep is unavailable") }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-config", "--json", "--text", "--crlf", "--engine", "auto"]
            + (caseSensitive ? [] : ["--ignore-case"]) + ["--", pattern, url.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        let errorQueue = DispatchQueue(label: "SiftEditor.ripgrep.stderr")
        var errorData = Data()
        errorQueue.async { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { if cancelled(), process.isRunning { process.terminate() } }
        timer.resume()
        defer {
            timer.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            errorQueue.sync {}
        }
        var pending = Data()
        while true {
            if cancelled() { throw FrequentStrings.Failure.cancelled }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let event = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let json = try JSONSerialization.jsonObject(with: event) as? [String: Any],
                      let type = json["type"] as? String else { throw Failure.invalidOutput }
                guard type == "match" else { continue }
                guard let data = json["data"] as? [String: Any],
                      let number = data["line_number"] as? Int,
                      let lines = data["lines"] as? [String: Any],
                      let value = lines["text"] as? String else { throw Failure.invalidOutput }
                var line = value
                if line.utf8.last == 0x0A { line.removeLast() }
                if line.utf8.last == 0x0D { line.removeLast() }
                try match(number - 1, line)
            }
        }
        process.waitUntilExit()
        if cancelled() { throw FrequentStrings.Failure.cancelled }
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw Failure.failed(String(data: errorData, encoding: .utf8) ?? "ripgrep failed")
        }
    }
}
