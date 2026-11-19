import Foundation

// MARK: - Pi RPC client

final class PiClient {
    private var proc: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var intentionalStop = false
    private var skippingOversizedLine = false
    // Screen captures arrive as multi-MB base64 JSON lines. 32 MB covers them.
    private let maxLineBytes = 33_554_432
    private let lock = NSLock()
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }
    var onDisconnect: () -> Void = {}

    struct RPCError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func resolvePiExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["PI_EXECUTABLE"],
            "\(home)/.local/bin/pi",
            "\(home)/.local/share/pi-node/current/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RPCError(message: "pi executable not found")
        }
        return URL(fileURLWithPath: path)
    }

    func start() throws {
        guard proc == nil else { return }
        intentionalStop = false
        let p = Process()
        let home = FileManager.default.homeDirectoryForCurrentUser
        p.executableURL = try resolvePiExecutable()
        p.arguments = ["--mode", "rpc", "--no-session", "--name", "Kodros Orb"]
        p.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        let localNode = home.appendingPathComponent(".local/share/pi-node/current/bin").path
        environment["HOME"] = home.path
        environment["PATH"] = "\(home.path)/.local/bin:\(localNode):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            var lines: [Data] = []
            var overflowed = false
            while true {
                if self.skippingOversizedLine {
                    if let nl = self.buffer.firstIndex(of: 0x0A) {
                        self.buffer.removeSubrange(0...nl)
                        self.skippingOversizedLine = false
                    } else {
                        self.buffer.removeAll(keepingCapacity: true)
                        break
                    }
                } else if let nl = self.buffer.firstIndex(of: 0x0A) {
                    if nl > self.maxLineBytes { overflowed = true }
                    else { lines.append(self.buffer.subdata(in: 0..<nl)) }
                    self.buffer.removeSubrange(0...nl)
                } else {
                    if self.buffer.count > self.maxLineBytes {
                        overflowed = true
                        self.buffer.removeAll(keepingCapacity: true)
                        self.skippingOversizedLine = true
                    }
                    break
                }
            }
            self.lock.unlock()
            if overflowed { self.onLog("One RPC line exceeded 32 MB and was skipped") }
            for line in lines { self.handleLine(line) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onLog(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let callbacks = Array(self.pending.values)
            self.pending.removeAll()
            self.buffer.removeAll(keepingCapacity: true)
            self.lock.unlock()
            callbacks.forEach { $0(.failure(RPCError(message: "pi disconnected"))) }
            let notifyDisconnect = !self.intentionalStop
            DispatchQueue.main.async {
                self.proc = nil
                self.stdin = nil
                if notifyDisconnect { self.onDisconnect() }
            }
        }
        try p.run()
        proc = p
        stdin = inPipe.fileHandleForWriting
    }

    func stop() {
        intentionalStop = true
        proc?.terminate()
    }

    var isRunning: Bool { proc != nil && proc!.isRunning }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let type = obj["type"] as? String, type == "response",
           let id = obj["id"] as? String {
            lock.lock()
            let cb = pending.removeValue(forKey: id)
            lock.unlock()
            if let success = obj["success"] as? Bool, success {
                cb?(.success(obj))
            } else {
                cb?(.failure(RPCError(message: obj["error"] as? String ?? "unknown")))
            }
            return
        }
        onEvent(obj)
    }

    @discardableResult
    func send(_ cmd: [String: Any], timeout: TimeInterval = 180,
              completion: @escaping (Result<[String: Any], Error>) -> Void) -> String {
        var c = cmd
        let id = UUID().uuidString
        c["id"] = id
        lock.lock()
        guard pending.count < 100 else {
            lock.unlock()
            completion(.failure(RPCError(message: "too many pending RPC requests")))
            return id
        }
        pending[id] = completion
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: c),
              let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) else {
            lock.lock()
            pending.removeValue(forKey: id)
            lock.unlock()
            completion(.failure(RPCError(message: "encode failed")))
            return id
        }
        guard let stdin else {
            lock.lock()
            pending.removeValue(forKey: id)
            lock.unlock()
            completion(.failure(RPCError(message: "pi is not connected")))
            return id
        }
        stdin.write(line)
        let boundedTimeout = max(1, min(timeout, 600))
        DispatchQueue.global().asyncAfter(deadline: .now() + boundedTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cb = self.pending.removeValue(forKey: id)
            self.lock.unlock()
            cb?(.failure(RPCError(message: "timeout")))
        }
        return id
    }

    func prompt(_ text: String, images: [[String: Any]] = [],
                completion: @escaping (Result<[String: Any], Error>) -> Void = { _ in }) {
        var command: [String: Any] = [
            "type": "prompt",
            "message": text,
            "streamingBehavior": "followUp",
        ]
        if !images.isEmpty { command["images"] = images }
        send(command, completion: completion)
    }

    func lastAssistantText(completion: @escaping (String?) -> Void) {
        send(["type": "get_last_assistant_text"], timeout: 15) { result in
            if case .success(let obj) = result,
               let data = obj["data"] as? [String: Any] {
                completion(data["text"] as? String)
            } else {
                completion(nil)
            }
        }
    }
}
