import Foundation
import Darwin

/// Runs a program in its own process group so cancelling also stops anything
/// the script started (SIGTERM to the group, then SIGKILL).
public enum Subprocess {
    public struct Result { public var status: Int32; public var stderr: String; public var stdout: String }

    public static var killGrace: TimeInterval = 0.5

    public static func run(_ executable: String, _ args: [String], env: [String: String] = [:], cwd: URL? = nil) async throws -> Result {
        try Task.checkCancellation()

        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw ShakenError.other("pipe failed") }

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] { posix_spawn_file_actions_addclose(&fa, fd) }
        if let cwd { posix_spawn_file_actions_addchdir_np(&fa, cwd.path) }

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        // Reset signal handling inherited from the app.
        var def = sigset_t(); sigfillset(&def)
        posix_spawnattr_setsigdefault(&attr, &def)
        flags |= Int16(POSIX_SPAWN_SETSIGDEF)
        posix_spawnattr_setflags(&attr, flags)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolLocator.pathEnv
        for (k, v) in env { environment[k] = v }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ShakenError.other(L("Couldn't start %@: %@", executable, String(cString: strerror(rc))))
        }

        let outReader = PipeReader(fd: outPipe[0])
        let errReader = PipeReader(fd: errPipe[0])
        let child = pid

        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global().async {
                    var st: Int32 = 0
                    while waitpid(child, &st, 0) == -1 && errno == EINTR {}
                    c.resume(returning: st)
                }
            }
        } onCancel: {
            kill(-child, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                // The group may already be gone; ESRCH is fine.
                kill(-child, SIGKILL)
            }
        }
        let err = errReader.finish(), out = outReader.finish()
        // Kill any stragglers left in the group even on success.
        kill(-child, SIGKILL)
        try Task.checkCancellation()

        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: code, stderr: err, stdout: out)
    }
}

/// Drains a pipe on a background thread so a chatty child never blocks.
private final class PipeReader {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(fd: Int32) {
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                if data.count < 1_000_000 { data.append(buf, count: n) }
            }
            close(fd)
            done.signal()
        }
    }

    func finish() -> String {
        // Children of the script could keep the pipe open; don't wait forever.
        _ = done.wait(timeout: .now() + 1)
        return String(decoding: data, as: UTF8.self)
    }
}
