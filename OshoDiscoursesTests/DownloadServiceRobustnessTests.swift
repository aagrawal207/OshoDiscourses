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
}
