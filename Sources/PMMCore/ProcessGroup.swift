import Darwin
import Foundation

/// A child spawned into a process group of its own, so it can be killed with its descendants.
///
/// `Process` cannot do this. Its children inherit *our* process group, which makes `kill(-pgid,…)`
/// unusable — it would signal the app along with the child. Escalating to the child's pid alone is
/// what leaks: a shell that starts background work from an rc file dies while everything it started
/// keeps running, holding the descriptors it inherited. Spawning with `POSIX_SPAWN_SETPGROUP` makes
/// the child a group leader, and the whole group can then be signalled as one.
///
/// Used for work we started for our own reasons and may abandon — the login-shell probe, and the
/// query commands a scan runs. Never for an install or an update: those the user asked for, and
/// they are theirs to finish or to stop deliberately.
struct ProcessGroupChild {
    let id: pid_t

    /// Spawns `executable` as its own group leader. Descriptors are duplicated onto the standard
    /// streams; the caller keeps ownership of them.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32
    ) -> ProcessGroupChild? {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        // `setpgroup(0)` means "your own group, with you as leader".
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { return nil }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, target) in [
            (standardInput, STDIN_FILENO),
            (standardOutput, STDOUT_FILENO),
            (standardError, STDERR_FILENO),
        ] where posix_spawn_file_actions_adddup2(&actions, source, target) != 0 {
            return nil
        }

        var id: pid_t = 0
        let spawned = withCStringArray([executable] + arguments) { argv in
            withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&id, executable, &actions, &attributes, argv, envp)
            }
        }
        guard spawned == 0 else { return nil }
        return ProcessGroupChild(id: id)
    }

    /// Waits for exit, up to `timeout`. Returns the exit status, or nil if it was still running.
    func wait(timeout: TimeInterval, pollInterval: TimeInterval = 0.02) -> Int32? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let status = reap(blocking: false) { return status }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return reap(blocking: false)
    }

    /// Signals the whole group — the child and everything it started that did not detach itself.
    ///
    /// A process that called `setsid` has left the group and survives, which is correct: an agent
    /// the user's rc file deliberately daemonised is not ours to kill.
    func terminateGroup(grace: TimeInterval) {
        kill(-id, SIGTERM)
        if wait(timeout: grace) != nil { return }
        kill(-id, SIGKILL)
        // Blocking, so the child is reaped rather than left a zombie.
        _ = reap(blocking: true)
    }

    @discardableResult
    private func reap(blocking: Bool) -> Int32? {
        var status: Int32 = 0
        let result = waitpid(id, &status, blocking ? 0 : WNOHANG)
        guard result == id else { return nil }
        // Mirrors Process.terminationStatus: the code for a normal exit, 128+n for a signal.
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }
}

private func withCStringArray<R>(_ values: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
