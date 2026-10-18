import Foundation
import Darwin

public struct SoftwareCommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
    public init(status: Int32, output: String, error: String) { self.status = status; self.output = output; self.error = error }
}

public enum SoftwareCommand {
    public static func run(_ executable: URL, arguments: [String], token: CancellationToken? = nil,
                           timeout: TimeInterval? = 30, environment: [String: String] = [:]) throws -> SoftwareCommandResult {
        if token?.isCancelled == true { throw MacEvenError(localized("检查已取消。")) }
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        let files = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        defer { for file in files { try? file.close() } }
        for file in files {
            guard fcntl(file.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw MacEvenError(localized("无法读取工具输出。")) }
        }
        try process.run()
        var data = [Data(), Data()], buffer = [UInt8](repeating: 0, count: 8192)
        var failure: String?, stoppedAt: TimeInterval?
        let start = ProcessInfo.processInfo.systemUptime
        func drain() {
            for (position, file) in files.enumerated() {
                for _ in 0..<32 {
                    let count = read(file.fileDescriptor, &buffer, buffer.count)
                    if count <= 0 {
                        if count < 0 && errno != EAGAIN && errno != EINTR { failure = failure ?? localized("工具输出读取失败。") }
                        break
                    }
                    let remaining = max(0, 2 * 1024 * 1024 - data[position].count)
                    data[position].append(contentsOf: buffer.prefix(min(count, remaining)))
                    if count > remaining { failure = failure ?? localized("工具输出超过 2 MiB，结果不完整。") }
                }
            }
        }
        while process.isRunning {
            drain()
            let now = ProcessInfo.processInfo.systemUptime
            if token?.isCancelled == true { failure = failure ?? localized("检查已取消。") }
            if let timeout, now - start > timeout { failure = failure ?? localized("工具执行超时。") }
            // An installer must finish even if its output is truncated; killing it can lose software.
            if failure != nil && (timeout != nil || token != nil) {
                if stoppedAt == nil { process.terminate(); stoppedAt = now }
                else if now - stoppedAt! > 0.5 { kill(process.processIdentifier, SIGKILL) }
            }
            usleep(5_000)
        }
        process.waitUntilExit(); drain()
        if let failure { throw MacEvenError(failure) }
        guard let output = String(data: data[0], encoding: .utf8), let error = String(data: data[1], encoding: .utf8) else {
            throw MacEvenError(localized("工具输出编码无法识别。"))
        }
        return SoftwareCommandResult(status: process.terminationStatus, output: output, error: error)
    }
}
