import Foundation
import Darwin

public struct CodexTerminalClient: Equatable {
    public let pid: Int
    public let startedAt: TimeInterval
    public let cwd: String
    public let tty: String
    public let terminal: String
    public init(pid: Int, startedAt: TimeInterval, cwd: String, tty: String, terminal: String) {
        self.pid = pid; self.startedAt = startedAt; self.cwd = cwd
        self.tty = tty; self.terminal = terminal
    }
}

/// One bounded process read on the store queue, never a subprocess per row or UI tick.
public struct AgentProcessSnapshot {
    private var rows: [Int: (parent: Int, tty: String, command: String)] = [:]
    public init(_ output: String) {
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
            if parts.count == 4, let pid = Int(parts[0]), let parent = Int(parts[1]) {
                rows[pid] = (parent, String(parts[2]), String(parts[3]).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    public static func read() -> AgentProcessSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return AgentProcessSnapshot(String(decoding: data, as: UTF8.self))
    }

    private func isAgent(_ command: String, provider: AgentProvider) -> Bool {
        let base = (command as NSString).lastPathComponent.lowercased()
        // Helpers such as codex-code-mode-host are not the owning CLI process.
        return provider == .codex ? base == "codex" : (base.hasPrefix("claude") || base == "node")
    }

    public func ancestry(from start: Int, provider: AgentProvider) -> (pid: Int, terminal: String, tty: String) {
        var pid = start, agent = 0, terminal = "", device = ""
        var seen: Set<Int> = []
        while pid > 1, let row = rows[pid], seen.insert(pid).inserted {
            let base = (row.command as NSString).lastPathComponent.lowercased()
            if agent == 0 && isAgent(row.command, provider: provider) { agent = pid }
            if agent > 0 && device.isEmpty && row.tty.hasPrefix("ttys") { device = "/dev/" + row.tty }
            if base == "iterm2" || base.hasPrefix("itermserver-") { terminal = "iTerm2" }
            if base == "terminal" { terminal = "Terminal" }
            pid = row.parent
        }
        return (agent, terminal, device)
    }

    public func codexClients() -> [CodexTerminalClient]? {
        var clients: [CodexTerminalClient] = []
        for (pid, row) in rows where isAgent(row.command, provider: .codex) && row.tty.hasPrefix("ttys") {
            guard let value = pid_t(exactly: pid) else { return nil }
            guard let start = processStartTime(value) else {
                if kill(value, 0) != 0 && errno == ESRCH { continue }
                return nil
            }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
            guard proc_pidinfo(value, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
                // An incomplete scan is not evidence that a client closed.
                return nil
            }
            let cwd = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard !cwd.isEmpty, let arguments = Self.arguments(value) else { return nil }
            let owner = ancestry(from: pid, provider: .codex)
            clients.append(CodexTerminalClient(pid: pid, startedAt: start, cwd: Self.projectDirectory(cwd: cwd, arguments: arguments),
                tty: owner.tty, terminal: owner.terminal))
        }
        return clients
    }

    public static func projectDirectory(cwd: String, arguments: [String]) -> String {
        var directory = cwd
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            var value: String?
            if ["--cd", "-C"].contains(argument), index + 1 < arguments.count {
                index += 1; value = arguments[index]
            } else if argument.hasPrefix("--cd=") { value = String(argument.dropFirst(5)) }
            if let value {
                directory = value.hasPrefix("/") ? value : (cwd as NSString).appendingPathComponent(value)
            }
            index += 1
        }
        return directory
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return nil }
        var index = 4
        // Skip executable path and padding, then read argc strings only (never the environment).
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size else { return nil }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
