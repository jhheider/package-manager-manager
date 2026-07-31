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
/// Deliberately *not* for package commands. Killing a group is right for a probe we started for our
/// own reasons and can abandon; an install the user asked for is theirs to finish or stop.
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
    ///
    /// Deliberately does not reap. Reaping frees the leader's pid, and the group id *is* that pid —
    /// so once reaped, a signal aimed at "the group" can land on whatever process has since
    /// inherited the number. Holding the zombie keeps the id reserved, which is the only thing that
    /// makes the cleanup below safe. Call ``reap()`` once the group is dealt with.
    func wait(timeout: TimeInterval, pollInterval: TimeInterval = 0.02) -> Int32? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let status = exitStatus() { return status }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return exitStatus()
    }

    /// Releases the zombie. Nothing may signal the group after this.
    func reap() {
        var status: Int32 = 0
        _ = waitpid(id, &status, 0)
    }

    /// The leader's exit status, observed without consuming it.
    private func exitStatus() -> Int32? {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(id), &info, WEXITED | WNOWAIT | WNOHANG) == 0, info.si_pid != 0 else {
            return nil
        }
        // Mirrors Process.terminationStatus: the code for a normal exit, 128+n for a signal.
        return info.si_code == Int32(CLD_EXITED) ? info.si_status : 128 + info.si_status
    }

    /// Signals the whole group — the child and everything it started that did not detach itself.
    ///
    /// A process that called `setsid` has left the group and survives, which is correct: an agent
    /// the user's rc file deliberately daemonised is not ours to kill.
    func terminateGroup(grace: TimeInterval) {
        kill(-id, SIGTERM)
        let leaderExited = wait(timeout: grace) != nil
        // Escalate even when the leader went quietly. `wait` observes the leader and nothing else,
        // so stopping here on a polite shell left exactly the processes this exists to reach: the
        // ones ignoring SIGTERM, which they inherit across exec. Nothing has been reaped yet, so
        // the group id is still ours to signal.
        kill(-id, SIGKILL)
        _ = leaderExited
        reap()
    }

    /// Clears out whatever is left in the group once the leader is done.
    ///
    /// The leader exiting is not the tree exiting: `wait` observes the leader and nothing else, so an
    /// rc file's `foo &` outlives every *successful* probe as well as every timed-out one. Costs a
    /// single `kill(…, 0)` in the normal case, where the group is already empty.
    ///
    /// A process that called `setsid` has left the group and is not touched, which is intended.
    func terminateRemainingGroup(grace: TimeInterval = 0.25) {
        // Owns the reap on every path, including the early return. `wait` deliberately leaves the
        // leader a zombie so the group id stays reserved while it is signalled, and something has
        // to release it afterwards. Leaving that to the caller leaked one zombie per probe — and
        // the no-descendant early return, which is the ordinary case, leaked on every single one.
        defer { reap() }
        guard groupExists else { return }
        kill(-id, SIGTERM)
        let deadline = Date(timeIntervalSinceNow: grace)
        while Date() < deadline {
            if !groupExists { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Checked immediately before signalling, and never deferred to a later queue. A group id is
        // only free to be reused once the group is empty, so a delayed kill can land on whatever
        // process has since inherited the number — which is not a theoretical risk: an earlier
        // version of this scheduled the escalation and spent its afternoon killing unrelated
        // processes, including other tests' subprocesses.
        if groupExists { kill(-id, SIGKILL) }
    }

    /// Short on purpose: this runs on the success path of every probe, and what it is waiting for is
    /// leftovers nobody asked for. Costs nothing in the ordinary case, where the group is empty.
    static let remainingGroupGrace: TimeInterval = 0.25

    /// Whether the group still has members. The group outlives its leader while any remain, and the
    /// leader's pid cannot be reused while it is still a live group id.
    private var groupExists: Bool { kill(-id, 0) == 0 }

}

private func withCStringArray<R>(_ values: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
