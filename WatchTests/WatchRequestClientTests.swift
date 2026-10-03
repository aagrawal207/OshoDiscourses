import Foundation
import Testing
@testable import OshoDiscoursesWatch

@MainActor
struct WatchRequestClientTests {
    private func makeClient(
        _ transport: TestTransport, clock: TestClock = TestClock(),
        deadline: @escaping @Sendable () async throws -> Void = neverDeadline
    ) -> WatchRequestClient {
        let client = WatchRequestClient(transport: transport, waitForDeadline: deadline, uptime: { clock.now })
        client.start()
        return client
    }

    @Test func repliesAreCorrelatedByRequestIDEvenOutOfOrder() async throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        let first = Fixtures.request(.snapshot)
        let second = Fixtures.request(.browse(.downloads))
        let a = Task { try await client.send(first) }
        let b = Task { try await client.send(second) }
        try await waitUntil { transport.sent.count == 2 }
        let secondIndex = transport.requests.firstIndex { $0.id == second.id }!
        let firstIndex = transport.requests.firstIndex { $0.id == first.id }!
        transport.reply(at: secondIndex, snapshot: Fixtures.snapshot(sequence: 3))
        transport.reply(at: firstIndex, snapshot: Fixtures.snapshot(sequence: 2))
        #expect(try await a.value.requestID == first.id)
        #expect(try await b.value.requestID == second.id)
    }

    @Test func aReplyForAnotherRequestIsRejected() async throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        let task = Task { try await client.send(Fixtures.request(.snapshot)) }
        try await waitUntil { transport.sent.count == 1 }
        let foreign = CompanionResponse(requestID: UUID(), snapshot: Fixtures.snapshot())
        transport.replyRaw(at: 0, try CompanionWire.encode(foreign))
        await #expect(throws: WatchRequestError.mismatchedReply) { try await task.value }
    }

    @Test func malformedAndWrongVersionRepliesAreRejected() async throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        let first = Task { try await client.send(Fixtures.request(.snapshot)) }
        try await waitUntil { transport.sent.count == 1 }
        transport.replyRaw(at: 0, Data("nope".utf8))
        await #expect(throws: WatchRequestError.invalidReply) { try await first.value }

        let request = Fixtures.request(.snapshot)
        let second = Task { try await client.send(request) }
        try await waitUntil { transport.sent.count == 2 }
        var response = CompanionResponse(requestID: request.id, snapshot: Fixtures.snapshot())
        response.version = 2
        transport.replyRaw(at: 1, try CompanionWire.encode(response))
        await #expect(throws: WatchRequestError.unsupportedVersion) { try await second.value }
    }

    @Test func deadlineTimesOutAndALateReplyIsIgnored() async throws {
        let transport = TestTransport()
        let client = makeClient(transport, deadline: { try await Task.sleep(for: .milliseconds(30)) })
        let task = Task { try await client.send(Fixtures.request(.snapshot)) }
        await #expect(throws: WatchRequestError.timedOut) { try await task.value }
        transport.reply(at: 0, snapshot: Fixtures.snapshot())
        #expect(client.inFlightCount == 0)
    }

    @Test func aReplyAfterTheMonotonicDeadlineCountsAsTimedOut() async throws {
        let transport = TestTransport()
        let clock = TestClock()
        let client = makeClient(transport, clock: clock)
        let task = Task { try await client.send(Fixtures.request(.snapshot)) }
        try await waitUntil { transport.sent.count == 1 }
        clock.advance(WatchRequestClient.replyDeadline + 0.1)
        transport.reply(at: 0, snapshot: Fixtures.snapshot())
        await #expect(throws: WatchRequestError.timedOut) { try await task.value }
    }

    @Test func onlyOneMutationIsInFlightWhileReadsContinue() async throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        let toggle = Task { try await client.send(Fixtures.request(.setPlaying(false), expected: "x")) }
        try await waitUntil { transport.sent.count == 1 }
        await #expect(throws: WatchRequestError.busy) {
            try await client.send(Fixtures.request(.skipForward, expected: "x"))
        }
        let read = Task { try await client.send(Fixtures.request(.snapshot)) }
        try await waitUntil { transport.sent.count == 2 }
        transport.reply(at: 1, snapshot: Fixtures.snapshot())
        _ = try await read.value
        transport.reply(at: 0, snapshot: Fixtures.snapshot(sequence: 2))
        _ = try await toggle.value
        #expect(transport.sent.count == 2)
    }

    @Test func aFailedMutationIsNeverResent() async throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        let task = Task { try await client.send(Fixtures.request(.nextDiscourse, expected: "x")) }
        try await waitUntil { transport.sent.count == 1 }
        transport.fail(at: 0)
        await #expect(throws: WatchRequestError.deliveryFailed) { try await task.value }
        try await Task.sleep(for: .milliseconds(30))
        #expect(transport.sent.count == 1)
        #expect(WatchRequestError.deliveryFailed.leavesOutcomeUnknown)
    }

    @Test func unreachableRefusesWithoutQueuing() async throws {
        let transport = TestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        let client = makeClient(transport)
        await #expect(throws: WatchRequestError.unreachable) {
            try await client.send(Fixtures.request(.setPlaying(false), expected: "x"))
        }
        #expect(transport.sent.isEmpty)
        #expect(!WatchRequestError.unreachable.leavesOutcomeUnknown)
    }

    @Test func losingReachabilityRetiresPendingRequests() async throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        let task = Task { try await client.send(Fixtures.request(.snapshot)) }
        try await waitUntil { transport.sent.count == 1 }
        transport.setState(.ready(reachable: false, installed: true, needsUnlock: false))
        await #expect(throws: WatchRequestError.connectionChanged) { try await task.value }
        transport.reply(at: 0, snapshot: Fixtures.snapshot())
        #expect(client.inFlightCount == 0)
    }

    @Test func dispatchVetoStopsTheSend() async throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        await #expect(throws: WatchRequestError.staleContext) {
            try await client.send(Fixtures.request(.skipBackward, expected: "x")) { false }
        }
        #expect(transport.sent.isEmpty)
    }

    @Test func applicationContextReachesTheSnapshotHandler() throws {
        let transport = TestTransport()
        let client = makeClient(transport)
        var received: [CompanionSnapshot] = []
        client.onSnapshot = { received.append($0) }
        transport.onEvent?(.applicationContext(try CompanionWire.encode(Fixtures.snapshot(sequence: 7))))
        transport.onEvent?(.applicationContext(Data("junk".utf8)))
        #expect(received.map(\.sequence) == [7])
    }
}
