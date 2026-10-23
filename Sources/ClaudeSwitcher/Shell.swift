import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Shell {
    /// Runs a program and waits for it. Both pipes are drained concurrently so a
    /// chatty child can't deadlock on a full pipe buffer.
    static func run(
        _ path: String,
        _ args: [String],
        stdin: String? = nil,
        env: [String: String]? = nil,
        cwd: URL? = nil,
        timeout: TimeInterval = 30,
        qos: QualityOfService = .default
    ) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.qualityOfService = qos
        if let env { p.environment = env }
        if let cwd { p.currentDirectoryURL = cwd }

        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp

        do { try p.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: "\(error)")
        }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            group.wait()
        }
        p.waitUntilExit()
        return ShellResult(
            status: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
