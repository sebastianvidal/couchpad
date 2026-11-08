import Darwin
import Foundation
import Network

/// Sends queued datagrams at a few times the encoder's bitrate, a millisecond at a time, so
/// a keyframe leaves over tens of milliseconds instead of as one burst (which Wi-Fi tends to
/// drop whole).
///
/// Lives on its own thread with a real-time scheduling policy, not a dispatch timer: with a
/// fullscreen game on, macOS Game Mode demotes every other process, and a dispatch timer's
/// 1 ms ticks came late and in clumps. Credit is also earned by the clock, not per tick, so
/// a late tick sends what the interval was owed (capped at 10 ms worth) instead of starving.
final class Pacer {
    /// One phone's queue: its UDP flow and the sealed datagrams waiting to go.
    private final class Queue {
        let udp: NWConnection
        var outgoing: [Data] = []
        var credit = 0.0
        init(udp: NWConnection) { self.udp = udp }
    }

    /// Bytes per second the pacer may send to each phone; set by the server as the bitrate moves.
    var bytesPerSecond = 1_000_000.0 { didSet { lock.lock(); rate = bytesPerSecond; lock.unlock() } }
    /// Datagrams queued per phone before the oldest are thrown away (a keyframe and change).
    var maxOutgoing = 400

    private let lock = NSLock()
    private let wake = NSCondition()
    private var queues: [ObjectIdentifier: Queue] = [:]
    private var rate = 1_000_000.0
    private var idle = true
    private var onSendError: (() -> Void)?
    /// Worst gap between ticks since the last `report()`, for the stats line.
    private var maxGap = 0.0
    private var thread: Thread?

    init(onSendError: (() -> Void)? = nil) {
        self.onSendError = onSendError
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "couchpad.pacer"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    /// Queues sealed datagrams for a phone, at the back (new frames) or the front (resends
    /// the phone is holding frames for).
    func enqueue(_ datagrams: [Data], for key: ObjectIdentifier, udp: NWConnection, front: Bool = false) {
        lock.lock()
        let queue = queues[key] ?? Queue(udp: udp)
        queues[key] = queue
        if front { queue.outgoing.insert(contentsOf: datagrams, at: 0) } else { queue.outgoing.append(contentsOf: datagrams) }
        if queue.outgoing.count > maxOutgoing { queue.outgoing.removeFirst(queue.outgoing.count - maxOutgoing) }
        lock.unlock()
        wake.lock()
        if idle { idle = false; wake.signal() }
        wake.unlock()
    }

    /// Drops everything queued for a phone (it went away, or its backlog is being cleared).
    func clear(_ key: ObjectIdentifier) {
        lock.lock()
        queues[key] = nil
        lock.unlock()
    }

    /// Worst tick gap since the last call, in seconds.
    func report() -> Double {
        lock.lock(); defer { lock.unlock() }
        let gap = maxGap
        maxGap = 0
        return gap
    }

    private func run() {
        Pacer.makeRealtime()
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let tickNanos: UInt64 = 1_000_000
        let tickAbs = tickNanos * UInt64(timebase.denom) / UInt64(timebase.numer)
        var deadline = mach_absolute_time()
        var last = CFAbsoluteTimeGetCurrent()
        while true {
            // Nothing queued anywhere: sleep until something is, and restart the clock.
            wake.lock()
            lock.lock()
            let busy = queues.values.contains { !$0.outgoing.isEmpty }
            lock.unlock()
            if !busy {
                idle = true
                while idle { wake.wait() }
                wake.unlock()
                deadline = mach_absolute_time()
                last = CFAbsoluteTimeGetCurrent()
            } else {
                wake.unlock()
            }

            deadline += tickAbs
            mach_wait_until(deadline)
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - last
            last = now

            lock.lock()
            if elapsed > maxGap { maxGap = elapsed }
            let perSecond = rate
            var batches: [(NWConnection, [Data])] = []
            for queue in queues.values where !queue.outgoing.isEmpty {
                queue.credit = min(queue.credit + perSecond * elapsed, perSecond * 0.010)
                var n = 0
                while n < queue.outgoing.count, n == 0 || queue.credit >= Double(queue.outgoing[n].count) {
                    queue.credit -= Double(queue.outgoing[n].count)
                    n += 1
                }
                batches.append((queue.udp, Array(queue.outgoing.prefix(n))))
                queue.outgoing.removeFirst(n)
            }
            lock.unlock()

            for (udp, batch) in batches {
                udp.batch {
                    for datagram in batch {
                        udp.send(content: datagram, completion: .contentProcessed { [weak self] error in
                            if error != nil { self?.onSendError?() }
                        })
                    }
                }
            }
            // Fell far behind (the whole process was paused): don't try to catch up tick by tick.
            if mach_absolute_time() > deadline + tickAbs * 20 { deadline = mach_absolute_time() }
        }
    }

    /// Asks the scheduler for a real-time slot every millisecond: a short, deadline-bound
    /// burst of work, which is what the kernel's time-constraint policy exists for.
    private static func makeRealtime() {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        func abs(_ nanos: UInt64) -> UInt32 { UInt32(nanos * UInt64(timebase.denom) / UInt64(timebase.numer)) }
        var policy = thread_time_constraint_policy(period: abs(1_000_000), computation: abs(100_000), constraint: abs(500_000), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if result != KERN_SUCCESS { NSLog("Pacer: real-time policy refused (%d); running at user-interactive priority", result) }
    }
}
