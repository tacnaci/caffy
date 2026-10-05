import Darwin
import Foundation

/// 防休眠期间运行用户设置的命令（如 frpc 隧道）：开启时启动，关闭时结束整个进程组，
/// 意外退出时退避重启。命令以当前用户身份运行，与 root helper 无关。
@MainActor
final class AwakeCommand: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case restarting(exitCode: Int32, delay: Int)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var command: String
    @Published private(set) var isEnabled: Bool

    let log = CommandLog()

    private let defaults = UserDefaults.standard
    /// 防休眠是否开启，由 AppState 同步
    private var isAwake = false
    private var process: Process?
    private var launchedAt: Date?
    /// 连续意外退出次数，决定下次重启前的等待时间
    private var failures = 0
    private var restartTask: Task<Void, Never>?
    /// 每次启动递增，过期的退出回调和重启任务据此忽略
    private var generation = 0

    private static let maxRestartDelay = 60
    /// 运行超过这个时长后再退出，视为偶发故障，重启等待从头计算
    private static let stableRunTime: TimeInterval = 60

    init() {
        command = defaults.string(forKey: "awakeCommand") ?? ""
        isEnabled = defaults.bool(forKey: "awakeCommandEnabled")
        cleanUpOrphan()
    }

    var shouldRun: Bool { isAwake && isEnabled && !command.isEmpty }

    func setAwake(_ awake: Bool) {
        guard awake != isAwake else { return }
        isAwake = awake
        update()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "awakeCommandEnabled")
        update()
    }

    func setCommand(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != command else { return }
        command = trimmed
        defaults.set(trimmed, forKey: "awakeCommand")
        // 运行中修改命令时用新命令重新启动
        stop(reason: "command changed")
        update()
    }

    /// App 退出时调用：只发 SIGTERM，不等待；残留进程由下次启动时清理
    func terminate() {
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        if let pid = process?.processIdentifier {
            // App 马上退出，同步写入，否则这一行来不及落盘
            log.event("Caffy is quitting, stopping process group \(pid)", waitUntilWritten: true)
            kill(-pid, SIGTERM)
        }
        process = nil
    }

    private func update() {
        if shouldRun {
            if process == nil, restartTask == nil {
                failures = 0
                start()
            }
        } else {
            stop(reason: isAwake ? "disabled" : "Keep Awake turned off")
        }
    }

    // MARK: - 启停

    private func start() {
        generation += 1
        let current = generation
        restartTask = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        // 从菜单栏启动的 App 拿不到 shell 里的 PATH，补上 Homebrew 的目录
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = self.log
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                log.write(data)
            }
        }

        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            let signaled = finished.terminationReason == .uncaughtSignal
            Task { @MainActor in
                self?.processExited(generation: current, code: code, signaled: signaled)
            }
        }

        log.event("Starting: \(command)")
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log.event("Couldn’t start: \(error.localizedDescription)")
            scheduleRestart(exitCode: -1)
            return
        }
        // Process 让子进程自成一个进程组（pgid == pid），停止时结束整个组，
        // 这样 zsh 派生出的 frpc 等子进程也会一起退出
        let pid = process.processIdentifier
        self.process = process
        launchedAt = Date()
        status = .running
        saveRecord(pid: pid)
    }

    private func stop(reason: String) {
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        status = .idle
        guard let process else { return }
        self.process = nil
        let pid = process.processIdentifier
        log.event("Stopping (\(reason))")
        Self.killGroup(pid)
        clearRecord()
    }

    private func processExited(generation exited: Int, code: Int32, signaled: Bool) {
        // 主动停止或已被新进程取代
        guard exited == generation, let process else { return }
        let pid = process.processIdentifier
        self.process = nil
        log.event(signaled ? "Exited on signal \(code)" : "Exited with code \(code)")
        // 清理留在进程组里的后台子进程，保证同一时间只有一组在运行
        Self.killGroup(pid)
        clearRecord()

        if let launchedAt, Date().timeIntervalSince(launchedAt) >= Self.stableRunTime {
            failures = 0
        }
        scheduleRestart(exitCode: code)
    }

    private func scheduleRestart(exitCode: Int32) {
        guard shouldRun else {
            status = .idle
            return
        }
        failures += 1
        let delay = min(Self.maxRestartDelay, 1 << min(failures - 1, 6))
        status = .restarting(exitCode: exitCode, delay: delay)
        log.event("Restarting in \(delay) s")
        let current = generation
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self, !Task.isCancelled, current == self.generation, self.shouldRun else { return }
            self.start()
        }
    }

    /// 先 SIGTERM，3 秒后进程组仍在则 SIGKILL
    private static func killGroup(_ pgid: pid_t) {
        guard kill(-pgid, SIGTERM) == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if kill(-pgid, 0) == 0 {
                kill(-pgid, SIGKILL)
            }
        }
    }

    // MARK: - 崩溃后的残留进程

    /// 记录进程组号和组长的启动时间，Caffy 崩溃后下次启动时据此清理
    private func saveRecord(pid: pid_t) {
        guard let start = Self.startTime(of: pid) else { return }
        defaults.set(["pgid": Int(pid), "sec": Int(start.tv_sec), "usec": Int(start.tv_usec)],
                     forKey: "awakeCommandProcess")
    }

    private func clearRecord() {
        defaults.removeObject(forKey: "awakeCommandProcess")
    }

    private func cleanUpOrphan() {
        guard let record = defaults.dictionary(forKey: "awakeCommandProcess"),
              let pgid = (record["pgid"] as? Int).map(pid_t.init),
              let sec = record["sec"] as? Int, let usec = record["usec"] as? Int
        else { return }
        clearRecord()
        // 组长还在时核对启动时间，防止 PID 被复用后误杀无关进程。组长已退出而进程组仍在时，
        // 内核不会把这个号分配给新进程，可以确认是上次留下的
        if let start = Self.startTime(of: pgid), start.tv_sec != sec || start.tv_usec != usec {
            return
        }
        guard kill(-pgid, 0) == 0 else { return }
        log.event("Stopping process group \(pgid) left over from the last run")
        Self.killGroup(pgid)
    }

    private static func startTime(of pid: pid_t) -> timeval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_proc.p_un.__p_starttime
    }
}

/// 命令输出与 Caffy 事件写入 ~/Library/Logs/Caffy/run-while-awake.log，
/// 超过 1 MB 时轮转为 .log.1。只有当前用户可读，因为命令行里可能带有凭据。
final class CommandLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.caffy.awake-command-log")
    private var handle: FileHandle?
    private static let maxSize: UInt64 = 1_000_000

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Caffy/run-while-awake.log")
    }

    func event(_ text: String, waitUntilWritten: Bool = false) {
        let data = Data("\(Self.timestamp.string(from: Date())) [Caffy] \(text)\n".utf8)
        if waitUntilWritten {
            queue.sync { append(data) }
        } else {
            write(data)
        }
    }

    func write(_ data: Data) {
        queue.async { [self] in append(data) }
    }

    private func append(_ data: Data) {
        guard let handle = openHandle() else { return }
        handle.write(data)
        if handle.offsetInFile >= Self.maxSize {
            rotate()
        }
    }

    /// 确保日志文件存在，供“查看日志”打开
    func prepare() {
        queue.sync { _ = openHandle() }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }

    private func rotate() {
        handle?.closeFile()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
