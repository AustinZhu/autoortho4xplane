import Foundation

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

@MainActor
final class EngineBridge {
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var sequence = 0
    private var buffer = Data()
    private(set) var diagnostics = ""

    func connect() throws {
        guard process == nil else { return }
        guard let resources = Bundle.main.resourceURL else { throw BridgeError.message("The app bundle is incomplete.") }
        let executable = resources.appendingPathComponent("Engine.app/Contents/MacOS/autoortho")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BridgeError.message("The streaming helper is missing. Rebuild the app with macos/build.py.")
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--native-ui-service"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        child.environment = ProcessInfo.processInfo.environment.merging(["PYINSTALLER_RESET_ENVIRONMENT": "1"]) { _, new in new }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.diagnostics += String(decoding: data, as: UTF8.self)
                self.diagnostics = String(self.diagnostics.suffix(32000))
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in self?.disconnected(child.terminationStatus) }
        }
        try child.run()
        process = child; input = stdin.fileHandleForWriting
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = object["error"] as? String {
                continuation.resume(throwing: BridgeError.message(error))
            } else {
                do {
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: object["result"] ?? [:]))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func disconnected(_ status: Int32) {
        let continuations = pending.values
        pending.removeAll(); process = nil; input = nil
        for continuation in continuations {
            continuation.resume(throwing: BridgeError.message("The streaming helper exited (\(status)).\n\(diagnostics.suffix(2000))"))
        }
    }

    func request(_ method: String, _ params: [String: Any] = [:], timeout: Double = 150) async throws -> Data {
        try connect()
        sequence += 1
        let id = sequence
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input?.write(contentsOf: data) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: BridgeError.message("The operation is taking longer than expected. Check Diagnostics before trying again."))
            }
        }
    }

    func close() { try? input?.close(); input = nil }
}
