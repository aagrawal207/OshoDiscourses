import Foundation

/// The phone's playback as last confirmed. Position advances on the watch's own monotonic clock,
/// and only while a fresh reply, reachability and the foreground all hold; otherwise it freezes.
struct WatchSnapshotState {
    enum Source: Equatable { case reply, applicationContext }

    static let confirmationLifetime: TimeInterval = 20

    private(set) var snapshot: CompanionSnapshot?
    private var confirmedAt: TimeInterval?
    private var reachable = false
    private var foreground = false
    private var anchorPosition: Double = 0
    private var anchorUptime: TimeInterval = 0
    private var retiredSessions: [UUID: TimeInterval] = [:]
    /// Newest context from a phone process not yet confirmed by a reply. WCSession does not resend
    /// context, so dropping it would let an older first reply from that process stand as current.
    private var unconfirmedContext: (snapshot: CompanionSnapshot, receivedAt: TimeInterval)?

    mutating func setAvailability(reachable: Bool, foreground: Bool, at uptime: TimeInterval) {
        reanchor(at: uptime)
        if !reachable || !foreground { confirmedAt = nil }
        self.reachable = reachable
        self.foreground = foreground
    }

    mutating func invalidate(at uptime: TimeInterval) {
        reanchor(at: uptime)
        confirmedAt = nil
    }

    /// Returns true when the snapshot replaced the displayed one.
    @discardableResult
    mutating func receive(_ incoming: CompanionSnapshot, source: Source, at uptime: TimeInterval) -> Bool {
        // Retired processes stay rejected past the eight-second reply deadline, covering late concurrent replies.
        retiredSessions = retiredSessions.filter { uptime - $0.value < Self.confirmationLifetime }
        if retiredSessions[incoming.sessionID] != nil { return false }
        let live = source == .reply && reachable && foreground
        if let current = snapshot {
            // Cached context cannot introduce a new phone process; only a correlated reply can.
            if current.sessionID != incoming.sessionID, source == .applicationContext {
                if unconfirmedContext.map({ $0.snapshot.sessionID != incoming.sessionID
                    || $0.snapshot.sequence < incoming.sequence }) ?? true {
                    unconfirmedContext = (incoming, uptime)
                }
                return false
            }
            if current.sessionID == incoming.sessionID, incoming.sequence <= current.sequence {
                if live {
                    // A duplicate confirms the display; an older sequence only proves the phone is alive.
                    if incoming.sequence == current.sequence, confirmedAt == nil {
                        anchorPosition = Self.bounded(incoming.nowPlaying)
                    } else {
                        anchorPosition = position(at: uptime)
                    }
                    anchorUptime = uptime
                    confirmedAt = uptime
                }
                return false
            }
            if current.sessionID != incoming.sessionID { retiredSessions[current.sessionID] = uptime }
        }
        if snapshot?.sessionID != incoming.sessionID { confirmedAt = nil }
        var adopted = incoming
        var anchorAt = uptime
        if let held = unconfirmedContext, held.snapshot.sessionID == incoming.sessionID {
            unconfirmedContext = nil
            // The reply confirms the process; its own content may predate context already received.
            if held.snapshot.sequence > incoming.sequence {
                adopted = held.snapshot
                anchorAt = held.receivedAt
            }
        }
        snapshot = adopted
        anchorPosition = Self.bounded(adopted.nowPlaying)
        anchorUptime = anchorAt
        if live { confirmedAt = uptime }
        return true
    }

    func isCurrent(at uptime: TimeInterval) -> Bool {
        guard reachable, foreground, let confirmedAt, snapshot != nil else { return false }
        return uptime >= confirmedAt && uptime - confirmedAt < Self.confirmationLifetime
    }

    func isPlaying(at uptime: TimeInterval) -> Bool {
        isCurrent(at: uptime) && snapshot?.nowPlaying?.isPlaying == true
    }

    func position(at uptime: TimeInterval) -> Double {
        guard let track = snapshot?.nowPlaying else { return 0 }
        var position = anchorPosition
        if reachable, foreground, track.isPlaying, let confirmedAt {
            let end = min(uptime, confirmedAt + Self.confirmationLifetime)
            let rate = track.rate.isFinite && track.rate > 0 ? Double(track.rate) : 1
            position += max(0, end - anchorUptime) * rate
        }
        return Self.bounded(position, duration: track.duration)
    }

    private mutating func reanchor(at uptime: TimeInterval) {
        anchorPosition = position(at: uptime)
        anchorUptime = uptime
    }

    private static func bounded(_ track: CompanionNowPlaying?) -> Double {
        bounded(track?.elapsed ?? 0, duration: track?.duration ?? 0)
    }

    static func bounded(_ position: Double, duration: Double) -> Double {
        guard position.isFinite else { return 0 }
        if duration.isFinite, duration > 0 { return max(0, min(position, duration)) }
        return max(0, position)
    }
}

enum WatchTime {
    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(min(seconds, 359_999))
        if whole >= 3_600 { return String(format: "%d:%02d:%02d", whole / 3_600, whole / 60 % 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func remaining(_ position: Double, duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        return "-" + timestamp(max(0, duration - position))
    }

    static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0 seconds" }
        let value = Duration.seconds(Int(seconds))
        return value.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    static func rateLabel(_ rate: Float) -> String {
        let value = Double(rate)
        let text = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
        return text + "×"
    }
}
