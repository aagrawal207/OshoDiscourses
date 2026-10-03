import Testing
@testable import OshoDiscourses

/// A transfer can finish while no process is waiting for it: after Quit on the
/// Mac (nsurlsessiond keeps going) or after iOS ends the app in the background.
struct UnclaimedDownloadTests {

    @Test func fileFinishedWhileAppWasNotRunningIsKept() {
        #expect(!DownloadService.discardsUnclaimedFile(hasRow: false, wasCancelled: false, isDownloaded: false))
    }

    @Test func cancelledTransferIsDiscarded() {
        #expect(DownloadService.discardsUnclaimedFile(hasRow: false, wasCancelled: true, isDownloaded: false))
    }

    @Test func duplicateOfCommittedDownloadIsDiscarded() {
        #expect(DownloadService.discardsUnclaimedFile(hasRow: false, wasCancelled: false, isDownloaded: true))
    }

    @Test func adoptedRowAlwaysCommits() {
        #expect(!DownloadService.discardsUnclaimedFile(hasRow: true, wasCancelled: true, isDownloaded: true))
    }
}
