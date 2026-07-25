import Foundation
import Testing
@testable import OshoDiscourses

/// Covers the pure error-classification logic behind the download robustness
/// fixes: out-of-space detection across error domains/nesting, and the
/// save-error mapping that keeps raw Cocoa sentences out of the UI.
/// (The queue/cancel behavior lives in @MainActor async flows with real
/// URLSession transfers, so it isn't unit-testable without seams the service
/// deliberately doesn't have.)
@Suite
@MainActor
struct DownloadServiceRobustnessTests {

    // MARK: - isOutOfSpace

    @Test func detectsCocoaOutOfSpaceError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        #expect(DownloadService.isOutOfSpace(error))
    }

    @Test func detectsPosixENOSPC() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(DownloadService.isOutOfSpace(error))
    }

    @Test func detectsENOSPCNestedUnderURLError() {
        // URLSession reports a full disk as a URLError wrapping a POSIX error —
        // the detector must walk the underlying chain, not just the top level.
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let cocoa = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: posix]
        )
        let urlError = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotWriteToFile.rawValue,
            userInfo: [NSUnderlyingErrorKey: cocoa]
        )
        #expect(DownloadService.isOutOfSpace(urlError))
    }

    @Test func ignoresUnrelatedErrors() {
        #expect(!DownloadService.isOutOfSpace(URLError(.timedOut)))
        #expect(!DownloadService.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        // Same code number as ENOSPC but the wrong domain must not match.
        #expect(!DownloadService.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: Int(ENOSPC))))
    }

    // MARK: - saveError mapping

    @Test func saveErrorMapsOutOfSpaceToDiskFull() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        guard case .diskFull = DownloadService.saveError(from: error) else {
            Issue.record("Expected .diskFull")
            return
        }
    }

    @Test func saveErrorMapsOtherFileErrorsToSaveFailed() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        guard case .saveFailed = DownloadService.saveError(from: error) else {
            Issue.record("Expected .saveFailed")
            return
        }
    }

    // MARK: - User-facing message

    @Test func diskFullHasShortDescription() {
        let description = DownloadService.DownloadError.diskFull.errorDescription ?? ""
        #expect(description.localizedCaseInsensitiveContains("storage"))
        // Short enough to fit a row subtitle without truncation.
        #expect(description.count < 60)
    }

    // MARK: - Stall watchdog (network-change hang recovery)
    //
    // Background sessions never fail fast when connectivity changes — after a
    // network switch the connection can hang dead without an error until the
    // 6h resource timeout. The watchdog restarts a transfer that hasn't moved
    // within the threshold, bounded by a per-attempt restart budget.

    @Test func stalledTransferPastThresholdRestarts() {
        let last = Date(timeIntervalSinceNow: -DownloadService.stallThreshold - 1)
        #expect(DownloadService.shouldRestartStalledTransfer(
            lastProgress: last, now: Date(), restartsSoFar: 0))
    }

    @Test func activeTransferWithinThresholdDoesNotRestart() {
        let last = Date(timeIntervalSinceNow: -30)
        #expect(!DownloadService.shouldRestartStalledTransfer(
            lastProgress: last, now: Date(), restartsSoFar: 0))
    }

    @Test func restartBudgetIsBounded() {
        // A transfer legitimately waiting (e.g. cellular gate closed, waiting
        // for Wi-Fi) must not be churned forever — after the budget the
        // system's own retry/timeout semantics take over.
        let last = Date(timeIntervalSinceNow: -3600)
        #expect(DownloadService.shouldRestartStalledTransfer(
            lastProgress: last, now: Date(), restartsSoFar: DownloadService.maxStallRestarts - 1))
        #expect(!DownloadService.shouldRestartStalledTransfer(
            lastProgress: last, now: Date(), restartsSoFar: DownloadService.maxStallRestarts))
    }

    @Test func stallThresholdIsAtExactBoundary() {
        let now = Date()
        let atThreshold = now.addingTimeInterval(-DownloadService.stallThreshold)
        #expect(DownloadService.shouldRestartStalledTransfer(
            lastProgress: atThreshold, now: now, restartsSoFar: 0))
        let justUnder = now.addingTimeInterval(-DownloadService.stallThreshold + 1)
        #expect(!DownloadService.shouldRestartStalledTransfer(
            lastProgress: justUnder, now: now, restartsSoFar: 0))
    }
}
