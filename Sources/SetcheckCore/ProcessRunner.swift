import Foundation
import Darwin

struct ProcessOutput: Sendable {
    var stdout: Data
    var stderr: String
}

/// Owns one directly launched process. Readers continuously drain pipes; retained diagnostics are bounded.
final class MediaProcess: @unchecked Sendable {
    let process = Process()
    let output = Pipe()
    private let errors = Pipe()
    private let readers = DispatchGroup()
    private let lock = NSLock()
    private var diagnostic = Data()
    private var finished = false
    private var outputData = Data()
    private var overflow = false
    let cancellation: CancellationToken

    init(executable: URL, arguments: [String], input: Pipe? = nil, cancellation: CancellationToken) {
        self.cancellation = cancellation
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
    }
    func start(captureOutput: Bool = false) throws {
        try cancellation.check()
        try process.run()
        // Process owns duplicated descriptors after launch. Closing our copies is essential for EOF.
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        readers.enter()
        DispatchQueue.global().async { [self] in
            defer { readers.leave() }
            while let data = try? errors.fileHandleForReading.read(upToCount: 16_384), !data.isEmpty {
                lock.withLock { if diagnostic.count < 65_536 { diagnostic.append(data.prefix(65_536 - diagnostic.count)) } }
            }
        }
        if captureOutput {
            readers.enter()
            DispatchQueue.global().async { [self] in
                defer { readers.leave() }
                while let data = try? output.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
                    lock.withLock {
                        if outputData.count + data.count <= 8_388_608 { outputData.append(data) }
                        else { overflow = true }
                    }
                }
            }
        }
        DispatchQueue.global().async { [self] in
            while !lock.withLock({ finished }) {
                if cancellation.isCancelled { stop(); break }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
    }
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().async { [self] in
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
    func wait() throws -> ProcessOutput {
        process.waitUntilExit()
        lock.withLock { finished = true }
        readers.wait()
        try cancellation.check()
        let snapshot = lock.withLock { (outputData, String(decoding: diagnostic, as: UTF8.self), overflow) }
        if snapshot.2 { throw SetcheckError.message("Ответ медиаобработчика слишком велик.") }
        guard process.terminationStatus == 0 else {
            throw SetcheckError.message("Ошибка обработки медиа: \(snapshot.1.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return ProcessOutput(stdout: snapshot.0, stderr: snapshot.1)
    }
}

enum ProcessRunner {
    static func run(executable: URL, arguments: [String], cancellation: CancellationToken) throws -> ProcessOutput {
        let child = MediaProcess(executable: executable, arguments: arguments, cancellation: cancellation)
        try child.start(captureOutput: true)
        return try child.wait()
    }
}
