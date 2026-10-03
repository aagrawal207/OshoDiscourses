import Foundation
import Testing
@testable import OshoDiscoursesWatch

struct WatchSnapshotStateTests {
    private func live(_ snapshot: CompanionSnapshot = Fixtures.snapshot(), at time: TimeInterval = 100) -> WatchSnapshotState {
        var state = WatchSnapshotState()
        state.setAvailability(reachable: true, foreground: true, at: time)
        state.receive(snapshot, source: .reply, at: time)
        return state
    }

    @Test func playingInterpolatesOnTheWatchClockAtThePlaybackRate() {
        var state = live(Fixtures.snapshot(elapsed: 42, rate: 1.5))
        #expect(state.isPlaying(at: 104))
        #expect(state.position(at: 104) == 48)
        state = live(Fixtures.snapshot(elapsed: 42))
        #expect(state.position(at: 110) == 52)
    }

    @Test func pausedSnapshotsDoNotAdvance() {
        let state = live(Fixtures.snapshot(playing: false, elapsed: 42))
        #expect(!state.isPlaying(at: 110))
        #expect(state.position(at: 110) == 42)
    }

    @Test func positionClampsToDuration() {
        let state = live(Fixtures.snapshot(elapsed: 5_395))
        #expect(state.position(at: 115) == 5_400)
    }

    @Test func disconnectAndBackgroundFreezeTheClock() {
        var state = live()
        state.setAvailability(reachable: false, foreground: true, at: 105)
        #expect(state.position(at: 150) == 47)
        #expect(!state.isCurrent(at: 106))

        var background = live()
        background.setAvailability(reachable: true, foreground: false, at: 103)
        #expect(background.position(at: 200) == 45)
    }

    @Test func confirmationExpiresAfterTwentySeconds() {
        let state = live()
        #expect(state.isCurrent(at: 119.9))
        #expect(!state.isCurrent(at: 120))
        // Interpolation stops at expiry, never adding unconfirmed time.
        #expect(state.position(at: 300) == 62)
    }

    @Test func cachedContextIsShownButNeverConfirmed() {
        var state = WatchSnapshotState()
        state.setAvailability(reachable: true, foreground: true, at: 100)
        state.receive(Fixtures.snapshot(), source: .applicationContext, at: 100)
        #expect(state.snapshot != nil)
        #expect(!state.isCurrent(at: 100))
        #expect(state.position(at: 130) == 42)
    }

    @Test func staleAndDuplicateSequencesCannotRewind() {
        var state = live(Fixtures.snapshot(sequence: 5, elapsed: 100))
        let r1 = state.receive(Fixtures.snapshot(sequence: 4, elapsed: 10), source: .reply, at: 101)
        #expect(!r1)
        let r2 = state.receive(Fixtures.snapshot(sequence: 5, elapsed: 10), source: .reply, at: 101)
        #expect(!r2)
        #expect(state.snapshot?.nowPlaying?.elapsed == 100)
        let r3 = state.receive(Fixtures.snapshot(sequence: 6, elapsed: 200), source: .reply, at: 102)
        #expect(r3)
        #expect(state.position(at: 102) == 200)
    }

    @Test func aNewPhoneProcessNeedsALiveReplyAndRetiresTheOldOne() {
        var state = live(Fixtures.snapshot(session: Fixtures.sessionA, sequence: 9))
        let r4 = state.receive(Fixtures.snapshot(session: Fixtures.sessionB, sequence: 1), source: .applicationContext, at: 101)
        #expect(!r4)
        let r5 = state.receive(Fixtures.snapshot(session: Fixtures.sessionB, sequence: 1), source: .reply, at: 102)
        #expect(r5)
        #expect(state.snapshot?.sessionID == Fixtures.sessionB)
        let r6 = state.receive(Fixtures.snapshot(session: Fixtures.sessionA, sequence: 99), source: .reply, at: 103)
        #expect(!r6)
        #expect(state.snapshot?.sessionID == Fixtures.sessionB)
    }

    @Test func contextFromANewProcessIsKeptUntilAReplyConfirmsThatProcess() {
        // Phone relaunch: the watch shows the old process, the new one's context (now playing)
        // arrives first, and the first reply from the new process predates it (still paused).
        var state = live(Fixtures.snapshot(session: Fixtures.sessionA, sequence: 41, playing: false))
        let early = state.receive(Fixtures.snapshot(session: Fixtures.sessionB, sequence: 3, playing: true, elapsed: 300),
                                  source: .applicationContext, at: 101)
        #expect(!early)
        #expect(state.snapshot?.sessionID == Fixtures.sessionA)
        let confirmed = state.receive(Fixtures.snapshot(session: Fixtures.sessionB, sequence: 2, playing: false),
                                      source: .reply, at: 102)
        #expect(confirmed)
        #expect(state.snapshot?.sessionID == Fixtures.sessionB)
        #expect(state.snapshot?.sequence == 3)
        #expect(state.isPlaying(at: 102))
        #expect(state.position(at: 104) == 303)
    }

    @Test func aNewerReplyWinsOverHeldContext() {
        var state = live(Fixtures.snapshot(session: Fixtures.sessionA, sequence: 9))
        _ = state.receive(Fixtures.snapshot(session: Fixtures.sessionB, sequence: 3, playing: true),
                          source: .applicationContext, at: 101)
        _ = state.receive(Fixtures.snapshot(session: Fixtures.sessionB, sequence: 5, playing: false),
                          source: .reply, at: 102)
        #expect(state.snapshot?.sequence == 5)
        #expect(!state.isPlaying(at: 102))
    }

    @Test func timestampsFormatSafely() {
        #expect(WatchTime.timestamp(65) == "1:05")
        #expect(WatchTime.timestamp(3_725) == "1:02:05")
        #expect(WatchTime.timestamp(.nan) == "0:00")
        #expect(WatchTime.remaining(60, duration: 125) == "-1:05")
        #expect(WatchTime.remaining(0, duration: 0) == "--:--")
        #expect(WatchTime.rateLabel(1) == "1×")
        #expect(WatchTime.rateLabel(1.25) == "1.25×")
    }
}
