import Testing
import AVFoundation
@testable import OshoDiscourses

/// The load-bearing fix for vanishing Now Playing controls is interruption
/// recovery. After an interruption ends we must reactivate the session (so the
/// controls reappear) but only RESUME playback when we were playing before AND
/// iOS grants `.shouldResume`. These lock down that resume decision so it can't
/// silently regress into auto-playing after a phone call the user took, or
/// failing to resume when it should.
@Suite
struct AudioSessionInterruptionTests {

    @Test func resumesWhenWasPlayingAndSystemAllows() {
        #expect(
            AudioPlayerService.shouldResumeAfterInterruption(
                wasPlaying: true,
                options: .shouldResume
            ) == true
        )
    }

    @Test func doesNotResumeWhenWasPaused() {
        // Paused before the interruption → stay paused, even if iOS says resume.
        #expect(
            AudioPlayerService.shouldResumeAfterInterruption(
                wasPlaying: false,
                options: .shouldResume
            ) == false
        )
    }

    @Test func doesNotResumeWhenSystemWithholdsShouldResume() {
        // We were playing, but iOS did not set .shouldResume (e.g. user is still
        // in another audio app) → do not barge back in.
        #expect(
            AudioPlayerService.shouldResumeAfterInterruption(
                wasPlaying: true,
                options: []
            ) == false
        )
    }

    @Test func doesNotResumeWhenNeitherConditionHolds() {
        #expect(
            AudioPlayerService.shouldResumeAfterInterruption(
                wasPlaying: false,
                options: []
            ) == false
        )
    }
}
