import Foundation
import Testing
@testable import OshoDiscoursesWatch

struct CompanionProtocolTests {
    @Test func requestRoundTripsThroughTheWireCodec() throws {
        let request = CompanionRequest(
            id: UUID(), action: .playItem(rowID: "d:x"), expectedDiscourseID: "x", watchInventory: ["a", "b"]
        )
        let decoded = try CompanionWire.decode(CompanionRequest.self, from: CompanionWire.encode(request))
        #expect(decoded == request)
    }

    @Test(arguments: [
        CompanionAction.snapshot, .browse(.series("s:tao")), .setPlaying(true), .setPlaying(false), .skipForward, .skipBackward,
        .nextDiscourse, .previousDiscourse, .setRate(1.5), .playItem(rowID: "b:1"), .sendToWatch(discourseID: "d1"),
    ])
    func everyActionRoundTrips(action: CompanionAction) throws {
        let request = CompanionRequest(id: UUID(), action: action)
        #expect(try CompanionWire.decode(CompanionRequest.self, from: CompanionWire.encode(request)).action == action)
    }

    @Test func responseWithPageAndOfflineMetadataRoundTrip() throws {
        let page = CompanionPage(
            location: .downloads, title: "Downloads",
            rows: [CompanionRow(id: "s:tao", kind: .series, title: "Tao", subtitle: "3 discourses")],
            isTruncated: false, emptyMessage: "Nothing"
        )
        let response = CompanionResponse(requestID: UUID(), snapshot: Fixtures.snapshot(accent: "teal"), page: page)
        #expect(try CompanionWire.decode(CompanionResponse.self, from: CompanionWire.encode(response)) == response)
        let file = CompanionOfflineFile(discourseID: "d", title: "T", series: "S", resumePosition: 12, duration: 99)
        #expect(try CompanionWire.decode(CompanionOfflineFile.self, from: CompanionWire.encode(file)) == file)
    }

    @Test func savedPositionsAndResumeStampsRoundTripAndAreOptional() throws {
        let snapshot = Fixtures.snapshot(saved: [Fixtures.saved("d1", 300, at: 5), Fixtures.saved("d2", 0, at: 9, finished: true)])
        #expect(try CompanionWire.decode(CompanionSnapshot.self, from: CompanionWire.encode(snapshot)) == snapshot)
        let file = Fixtures.offlineFile("d1", resume: 300, savedAt: Fixtures.t0)
        #expect(try CompanionWire.decode(CompanionOfflineFile.self, from: CompanionWire.encode(file)) == file)

        var bare = try JSONSerialization.jsonObject(with: CompanionWire.encode(Fixtures.snapshot())) as? [String: Any]
        bare?["savedPositions"] = nil
        let decoded = try CompanionWire.decode(CompanionSnapshot.self, from: JSONSerialization.data(withJSONObject: bare ?? [:]))
        #expect(decoded.savedPositions == nil)
    }

    @Test func payloadsOverTheBoundAreRejectedBothWays() throws {
        let rows = (0..<2_000).map {
            CompanionRow(id: "d:\($0)", kind: .discourse, title: String(repeating: "t", count: 40), subtitle: "s")
        }
        let page = CompanionPage(location: .downloads, title: "D", rows: rows, isTruncated: false, emptyMessage: "")
        #expect(throws: CompanionError.payloadTooLarge) { try CompanionWire.encode(page) }
        let big = Data(repeating: 0x20, count: CompanionWire.maximumPayloadBytes + 1)
        #expect(throws: CompanionError.payloadTooLarge) { try CompanionWire.decode(CompanionPage.self, from: big) }
    }

    @Test func onlySnapshotAndBrowseAreReadOnly() {
        #expect(CompanionAction.snapshot.isReadOnly)
        #expect(CompanionAction.browse(.bookmarks).isReadOnly)
        #expect(!CompanionAction.setPlaying(true).isReadOnly)
        #expect(!CompanionAction.sendToWatch(discourseID: "x").isReadOnly)
    }
}
