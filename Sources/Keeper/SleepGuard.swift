import Foundation

/// Stops the Mac idling to sleep while footage is moving.
///
/// A copy of a full card can run for the better part of an hour, and a Mac that idles to sleep
/// halfway through leaves a half-copied folder — which is survivable, since nothing is ever
/// written to the card and a re-run skips what already arrived, but it's a bad surprise to come
/// back to. Verifying is covered too: hashing a card takes about as long as copying it.
///
/// **What this can and can't do.** It holds off *idle* sleep — the Mac deciding on its own that
/// nothing is happening. It cannot stop a sleep you ask for: closing a laptop lid, choosing
/// Sleep from the Apple menu, or the battery running out will all still sleep the machine
/// mid-copy. `caffeinate` on the command line has exactly the same limits. The honest version
/// of this feature is "it won't nod off on its own", not "it can't sleep".
///
/// Display sleep is deliberately left alone. The screen going dark costs nothing during a
/// transfer and saves power on battery; it's system sleep that stops the copy.
///
/// Not `@MainActor`, because the copy and verify jobs that drive it run on detached tasks —
/// same reasoning as `Shortcuts` and `Playback`.
final class SleepGuard {
    static let shared = SleepGuard()

    private var token: NSObjectProtocol?
    private let lock = NSLock()

    private init() {}

    /// Whether the Mac should be held awake: a long job is running, and you haven't turned the
    /// setting off. That's the whole rule, and the reason it's one function over all three
    /// inputs rather than a begin/end pair at each job site.
    ///
    /// With a pair of calls, two overlapping jobs release each other's hold: the first to
    /// finish calls `end` while the second is still running. Deriving the answer from every
    /// input each time makes that impossible, and makes a leak impossible too — the hold can
    /// only be wrong until the next time any of the three changes, and the two job flags
    /// always end up false.
    ///
    /// `enabled` being an input rather than a check at the call site is what makes the setting
    /// take effect immediately: switch it off mid-copy and the next recomputation lets go,
    /// rather than the hold lingering until that copy finishes.
    static func shouldHold(copying: Bool, verifying: Bool, enabled: Bool) -> Bool {
        enabled && (copying || verifying)
    }

    /// Takes or releases the assertion. Idempotent in both directions, so it can be called
    /// from a `didSet` on every change without counting anything.
    ///
    /// Returns true when this call actually changed the hold, so the caller can log the two
    /// moments that matter without logging every recomputation.
    @discardableResult
    func keepAwake(_ wanted: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if wanted {
            guard token == nil else { return false }
            // `.userInitiated` is itself a bundle of three: idle system sleep disabled,
            // sudden termination disabled, automatic termination disabled. All three are
            // what you want mid-copy — the last two stop the OS killing or quietly retiring
            // the app while it's part way through writing a file. `.idleSystemSleepDisabled`
            // is named again rather than left implied, because it's the one this whole file
            // exists for and a reader shouldn't have to know what `.userInitiated` expands to.
            //
            // `.idleDisplaySleepDisabled` is deliberately absent. See the note above.
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Keeper is transferring footage")
            return true
        } else {
            guard let held = token else { return false }
            ProcessInfo.processInfo.endActivity(held)
            token = nil
            return true
        }
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }
}
