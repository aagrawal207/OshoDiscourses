import AVFoundation
import Foundation
import Testing
@testable import OshoDiscourses

@Suite(.timeLimit(.minutes(2)))
@MainActor
struct NarrationServiceTests {
    @Test func progressIsDeliveredWithoutAVisibleViewAfterAudioIsPublished() async throws {
        try await withService { service, _, _ in
            var counts: [Int] = []
            var finished = false
            let document = try await service.prepare(
                transcript: transcript(["One passage.", "Another passage.", "The final passage."]),
                selection: selection(), translate: translated, renderer: NarrationTestRenderer(),
                onProgress: { document in
                    counts.append(document.segments.count)
                    finished = document.isComplete
                    #expect(service.documents.contains { $0.id == document.id })
                    if !document.segments.isEmpty { #expect(service.playablePrefix(of: document.id) != nil) }
                }
            )
            #expect(counts.first == 0)
            #expect(counts.last == document.expectedSegmentCount)
            #expect(counts == counts.sorted())
            #expect(finished)
        }
    }

    @Test func identicalTextReusesReadyAudioWithoutTranslationOrVoiceAssets() async throws {
        try await withService { service, directory, defaults in
            let original = transcript(["A complete paragraph to translate."])
            let first = try await service.prepare(transcript: original, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let refetched = Transcript(discourseID: original.discourseID, sourceID: "another-site-id", fetchedAt: .distantFuture, paragraphs: original.paragraphs)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents == [first])
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw NarrationTestError.unexpectedWork }
            renderer.beforeAssembly = { _, _ in throw NarrationTestError.unexpectedWork }
            let cached = try await reloaded.prepare(
                transcript: refetched, selection: selection(name: "A localized display name"),
                translate: { _ in throw NarrationTestError.unexpectedWork }, renderer: renderer
            )
            #expect(cached == first)
            #expect(cached.isComplete)
            #expect(reloaded.audioURL(for: cached) == service.audioURL(for: first))
            #expect(renderer.rendered.isEmpty)
            #expect(renderer.assemblyCalls == 0)
            #expect(reloaded.progress == 1)
            #expect(!reloaded.isPreparing)
        }
    }

    @Test func textLanguageVoiceAndQualityEachSelectADistinctCacheEntry() async throws {
        try await withService { service, _, _ in
            let text = transcript(["The source text."])
            let base = selection(target: "fr", voiceID: "voice.fr", voiceLanguage: "fr-FR")
            let requests: [(Transcript, NarrationSelection)] = [
                (text, base),
                (transcript(["Edited source text."]), base),
                (text, selection(source: "hi", target: "fr", voiceID: "voice.fr", voiceLanguage: "fr-FR")),
                (text, selection(target: "de", voiceID: "voice.de", voiceLanguage: "de-DE")),
                (text, selection(target: "fr", voiceID: "another.fr", voiceLanguage: "fr-FR")),
                (text, selection(target: "fr", voiceID: "voice.fr", voiceLanguage: "fr-FR", quality: 2)),
            ]
            var documents: [NarrationDocument] = []
            for (source, choice) in requests {
                documents.append(try await service.prepare(transcript: source, selection: choice, translate: translated, renderer: NarrationTestRenderer()))
            }
            #expect(Set(documents.map(\.id)).count == requests.count)
            #expect(documents.allSatisfy { $0.id.count == 64 && $0.id.allSatisfy(\.isHexDigit) })
            #expect(documents[0].sourceDigest != documents[1].sourceDigest)
            #expect(Set(documents.dropFirst(2).map(\.sourceDigest)) == [documents[0].sourceDigest])
            #expect(service.documents.count == requests.count)
        }
    }

    @Test func regionalSpellingsCanonicalizeButSameBaseLanguageIsRejected() async throws {
        try await withService { service, _, _ in
            let text = transcript(["A paragraph."])
            let first = try await service.prepare(
                transcript: text, selection: selection(source: "EN_us", target: "HI_in", voiceLanguage: "hi_IN"),
                translate: translated, renderer: NarrationTestRenderer()
            )
            let same = try await service.prepare(
                transcript: text, selection: selection(source: "en-US", target: "hi-IN", voiceLanguage: "hi-IN"),
                translate: { _ in throw NarrationTestError.unexpectedWork }, renderer: NarrationTestRenderer()
            )
            #expect(first.id == same.id)
            for choice in [
                selection(source: "en-US", target: "en-GB", voiceLanguage: "en-GB"),
                selection(source: "hi-IN", target: "hi", voiceLanguage: "hi-IN"),
                selection(source: "fr", target: "hi"),
                selection(target: "hi", voiceLanguage: "en-US"),
                selection(voiceID: "  "),
            ] {
                let renderer = NarrationTestRenderer()
                await #expect(throws: NarrationPreparationError.invalidSelection) {
                    try await service.prepare(transcript: text, selection: choice, translate: translated, renderer: renderer)
                }
                #expect(renderer.rendered.isEmpty)
            }
        }
    }

    @Test func unicodeChunksStayBoundedCoherentAndInSourceOrder() async throws {
        try await withService { service, _, _ in
            let tokens = ["कि", "की", "क्", "👨‍👩‍👧‍👦", "e\u{301}"]
            let enormousSentence = String(repeating: tokens.joined(separator: " ") + " ", count: 200)
            let coherentSentence = "यह एक पूरा वाक्य है जिसके सभी शब्द एक साथ रहने चाहिए और अगला वाक्य अलग शुरू होता है।"
            let paragraph = enormousSentence + coherentSentence + " " + coherentSentence
            let source = Transcript(discourseID: "unicode", sourceID: "site", fetchedAt: Date(), paragraphs: [
                .init(index: 4, text: paragraph, isEmphasis: true),
                .init(index: 9, text: "अंतिम अनुच्छेद।", isEmphasis: false),
            ])
            var requests: [[String]] = []
            let renderer = NarrationTestRenderer()
            let document = try await service.prepare(
                transcript: source, selection: selection(source: "hi", target: "en", voiceLanguage: "en-US"),
                translate: { input in
                    requests.append(input)
                    return input.map { "Translation: " + $0 }
                }, renderer: renderer
            )
            let input = requests.flatMap { $0 }
            #expect(input.count > 3)
            #expect(requests.allSatisfy { $0.count <= 4 && $0.reduce(0, { $0 + $1.utf16.count }) <= 6_000 })
            #expect(input.allSatisfy { !$0.isEmpty && $0.utf16.count <= 1_800 })
            #expect(input.last == "अंतिम अनुच्छेद।")
            #expect(input.dropLast().joined().filter { !$0.isWhitespace } == paragraph.filter { !$0.isWhitespace })
            #expect(input.first?.split(whereSeparator: \.isWhitespace).allSatisfy { tokens.contains(String($0)) } == true)
            #expect(input.contains { $0.contains(coherentSentence) })
            #expect(document.segments.map(\.index) == Array(input.indices))
            #expect(document.segments.dropLast().allSatisfy { $0.sourceParagraphIndex == 4 })
            #expect(document.segments.last?.sourceParagraphIndex == 9)
            #expect(document.segments.map(\.text) == renderer.rendered)
            #expect(renderer.rendered == input.map { "Translation: " + $0 })
            #expect(renderer.assemblyInputs.map(\.lastPathComponent) == input.indices.map { "segment-\($0).m4a" })
        }
    }

    @Test(arguments: BadTranslation.allCases)
    func incompleteOrBlankResponsesNeverNarrateTheSource(kind: BadTranslation) async throws {
        try await withService { service, _, _ in
            let source = transcript(["First paragraph.", "Second paragraph."])
            let renderer = NarrationTestRenderer()
            await #expect(throws: NarrationPreparationError.invalidTranslation) {
                try await service.prepare(transcript: source, selection: selection(), translate: { _ in kind.response }, renderer: renderer)
            }
            #expect(renderer.rendered.isEmpty)
            #expect(renderer.assemblyCalls == 0)
            #expect(!service.isPreparing)
            #expect(service.errorMessage != nil)
            #expect(service.documents.allSatisfy { !$0.isComplete && service.audioURL(for: $0) == nil })
            let retried = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            #expect(retried.isComplete)
            #expect(service.errorMessage == nil)
        }
    }

    @Test func unbrokenTextSplitsOnlyAtGraphemeBoundaries() async throws {
        try await withService { service, _, _ in
            let text = String(repeating: "क्👨‍👩‍👧‍👦e\u{301}", count: 700)
            var chunks: [String] = []
            let document = try await service.prepare(transcript: transcript([text]), selection: selection(), translate: { input in
                chunks += input
                return input.map { "Translation: " + $0 }
            }, renderer: NarrationTestRenderer())
            #expect(chunks.count > 1)
            #expect(chunks.allSatisfy { $0.utf16.count <= 1_800 && Set($0).isSubset(of: Set(text)) })
            #expect(chunks.joined() == text)
            #expect(chunks.reduce(0) { $0 + $1.count } == text.count)
            #expect(document.isComplete)
        }
    }

    @Test func translationFailureHasNoFallbackAndDoesNotExposeItsPayload() async throws {
        try await withService { service, _, _ in
            let renderer = NarrationTestRenderer()
            await #expect(throws: (any Error).self) {
                try await service.prepare(transcript: transcript(["Source paragraph."]), selection: selection(), translate: { _ in
                    throw NSError(domain: "private-transcript", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-transcript"])
                }, renderer: renderer)
            }
            #expect(renderer.rendered.isEmpty)
            #expect(service.errorMessage?.contains("private-transcript") == false)
            #expect(service.documents.first?.segments.isEmpty == true)
        }
    }

    @Test func cancellationAndRelaunchReuseSavedTextAndOnlyCommittedAudio() async throws {
        try await withService { service, directory, defaults in
            let source = transcript((0..<4).map { "Paragraph \($0)." })
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let renderer = NarrationTestRenderer()
            renderer.afterRender = { call, _ in
                if call == 2 { entered.open(); await release.wait() }
            }
            let task = Task { try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer) }
            await entered.wait()
            let checkpoint = try #require(service.documents.first)
            #expect(checkpoint.segments.map(\.index) == [0])
            #expect(!checkpoint.isComplete)
            #expect(service.audioURL(for: checkpoint) == nil)
            // One passage spoken and three translated, which count half; the final fifth is joining.
            #expect(abs(service.progress - (1 + 3 * 0.5) / 5.0) < 0.000_001)
            service.cancel()
            #expect(renderer.cancelCalls == 1)
            #expect(!service.isPreparing)
            #expect(service.preparingDiscourseID == nil)
            release.open()
            await expectCancelled(task)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.first?.segments.map(\.index) == [0])
            let resumedRenderer = NarrationTestRenderer()
            var translatedInputs: [String] = []
            let resumed = try await reloaded.prepare(transcript: source, selection: selection(), translate: { input in
                translatedInputs += input
                return input.map { "Retried: " + $0 }
            }, renderer: resumedRenderer)
            #expect(translatedInputs.isEmpty)
            #expect(resumed.segments.first == checkpoint.segments.first)
            #expect(resumedRenderer.rendered == source.paragraphs.dropFirst().map { "Translated: " + $0.text })
            #expect(resumed.segments.map(\.index) == Array(0..<4))
            #expect(resumed.isComplete)
            try expectNoStaging(in: directory)
        }
    }

    @Test func callerTaskCancellationStopsTheActiveRenderer() async throws {
        try await withService { service, directory, _ in
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let renderer = NarrationTestRenderer()
            renderer.afterRender = { _, _ in entered.open(); await release.wait() }
            renderer.onCancel = { release.open() }
            let task = Task { try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: renderer) }
            await entered.wait()
            task.cancel()
            await expectCancelled(task)
            #expect(renderer.cancelCalls == 1)
            #expect(!service.isPreparing)
            #expect(service.errorMessage == nil)
            #expect(service.documents.first?.segments.isEmpty == true)
            try expectNoStaging(in: directory)
        }
    }

    @Test func overlappingPreparationDoesNotReplaceTheActiveJob() async throws {
        try await withService { service, _, _ in
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let task = Task {
                try await service.prepare(transcript: transcript(["First request."], id: "first"), selection: selection(), translate: { input in
                    entered.open(); await release.wait()
                    return input.map { "Translated: " + $0 }
                }, renderer: NarrationTestRenderer())
            }
            await entered.wait()
            let status = service.statusMessage
            let second = NarrationTestRenderer()
            await #expect(throws: NarrationPreparationError.busy) {
                try await service.prepare(transcript: transcript(["Second request."], id: "second"), selection: selection(), translate: translated, renderer: second)
            }
            #expect(service.statusMessage == status)
            #expect(service.preparingDiscourseID == "first")
            #expect(second.rendered.isEmpty)
            release.open()
            let complete = try await task.value
            #expect(complete.isComplete)
        }
    }

    @Test func lateCancelledTranslationCannotOverwriteOrCancelItsReplacement() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["The same source."])
            let oldEntered = NarrationTestGate()
            let oldRelease = NarrationTestGate()
            let oldRenderer = NarrationTestRenderer()
            let old = Task {
                try await service.prepare(transcript: source, selection: selection(), translate: { _ in
                    oldEntered.open(); await oldRelease.wait()
                    return ["Old translation"]
                }, renderer: oldRenderer)
            }
            await oldEntered.wait()
            service.cancel()
            let newEntered = NarrationTestGate()
            let newRelease = NarrationTestGate()
            let newRenderer = NarrationTestRenderer()
            newRenderer.afterRender = { _, _ in newEntered.open(); await newRelease.wait() }
            let replacement = Task {
                try await service.prepare(transcript: source, selection: selection(), translate: { _ in ["New translation"] }, renderer: newRenderer)
            }
            await newEntered.wait()
            let status = service.statusMessage
            oldRelease.open()
            await expectCancelled(old)
            #expect(service.isPreparing)
            #expect(service.statusMessage == status)
            #expect(newRenderer.cancelCalls == 0)
            #expect(oldRenderer.rendered.isEmpty)
            newRelease.open()
            let ready = try await replacement.value
            #expect(ready.segments.map(\.text) == ["New translation"])
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents == [ready])
        }
    }

    @Test func deletionFencesLateAssemblyCompletion() async throws {
        try await withService { service, directory, defaults in
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let renderer = NarrationTestRenderer()
            renderer.afterAssembly = { _, _ in entered.open(); await release.wait() }
            let task = Task { try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: renderer) }
            await entered.wait()
            let partial = try #require(service.documents.first)
            #expect(partial.segments.count == partial.expectedSegmentCount)
            #expect(!partial.isComplete)
            #expect(service.audioURL(for: partial) == nil)
            try await service.remove(partial.id)
            release.open()
            await expectCancelled(task)
            #expect(service.documents.isEmpty)
            #expect(!service.isPreparing)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(partial.id).path))
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.isEmpty)
            try expectNoStaging(in: directory)
        }
    }

    @Test func loadCannotReplaceNewerPreparationOrRestoreADeletedEntry() async throws {
        try await withService { service, _, _ in
            let first = try await service.prepare(transcript: transcript(["Saved first."], id: "first"), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let renderer = NarrationTestRenderer()
            renderer.afterRender = { call, _ in
                if call == 2 { entered.open(); await release.wait() }
            }
            let preparing = Task {
                try await service.prepare(transcript: transcript(["New first.", "New second."], id: "second"), selection: selection(), translate: translated, renderer: renderer)
            }
            await entered.wait()
            let before = service.documents
            let progress = service.progress
            await service.load()
            #expect(service.documents == before)
            #expect(service.progress == progress)
            #expect(service.preparingDiscourseID == "second")
            release.open()
            let second = try await preparing.value
            async let loading: Void = service.load()
            try await service.remove(first.id)
            await loading
            #expect(service.documents.map(\.id) == [second.id])
        }
    }

    @Test func removeAllDiscoversUnloadedVariantsAndKeepsOtherDiscourses() async throws {
        try await withService { service, directory, defaults in
            let first = try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let second = try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(voiceID: "second.voice"), translate: translated, renderer: NarrationTestRenderer())
            let other = try await service.prepare(transcript: transcript(["Another discourse."], id: "other"), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            for document in [first, second, other] { service.savePosition(documentID: document.id, position: 0.05) }
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.removeAll(for: first.discourseID)
            await reloaded.load()
            #expect(reloaded.documents == [other])
            #expect(reloaded.position(for: first.id) == 0)
            #expect(reloaded.position(for: second.id) == 0)
            #expect(reloaded.position(for: other.id) == 0.05)
            #expect(reloaded.audioURL(for: other) != nil)
        }
    }

    @Test(arguments: DamagedFile.allCases)
    func missingOrDamagedJoinedAudioIsRebuiltFromSavedTextWithoutTranslating(kind: DamagedFile) async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First paragraph.", "Second paragraph."])
            let complete = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let url = try #require(service.audioURL(for: complete))
            try damage(url, kind: kind)
            #expect(service.audioURL(for: complete) == nil)
            #expect(service.documents.first?.isComplete == false)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            // Passage files were removed after joining, so only their text remains to rebuild from.
            #expect(reloaded.documents.first?.segments.isEmpty == true)
            #expect(reloaded.documents.first?.isComplete == false)
            let renderer = NarrationTestRenderer()
            let repaired = try await reloaded.prepare(transcript: source, selection: selection(), translate: { _ in
                throw NarrationTestError.unexpectedWork
            }, renderer: renderer)
            #expect(repaired.isComplete)
            #expect(renderer.rendered == complete.segments.map(\.text))
            #expect(repaired.segments.map(\.text) == complete.segments.map(\.text))
            #expect(renderer.assemblyCalls == 1)
            #expect(reloaded.audioURL(for: repaired) != nil)
        }
    }

    @Test func aDamagedMiddlePassagePreservesLaterCheckpointsAndAssemblyOrder() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First.", "Middle.", "Last."])
            let unjoined = NarrationTestRenderer()
            unjoined.beforeAssembly = { _, _ in throw NarrationTestError.interrupted }
            await #expect(throws: NarrationTestError.interrupted) {
                try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: unjoined)
            }
            let complete = try #require(service.documents.first)
            #expect(complete.segments.count == 3)
            let folder = directory.appendingPathComponent(complete.id)
            try damage(folder.appendingPathComponent(complete.segments[1].audioFileName), kind: .sameSizeCorruption)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.first?.segments.map(\.index) == [0, 2])
            #expect(reloaded.documents.first?.isComplete == false)
            var input: [String] = []
            let renderer = NarrationTestRenderer()
            let repaired = try await reloaded.prepare(transcript: source, selection: selection(), translate: { chunks in
                input += chunks
                return chunks.map { "Repaired: " + $0 }
            }, renderer: renderer)
            #expect(input.isEmpty)
            #expect(renderer.rendered == [complete.segments[1].text])
            #expect(repaired.segments[0] == complete.segments[0])
            #expect(repaired.segments[2] == complete.segments[2])
            #expect(renderer.assemblyInputs.map(\.lastPathComponent) == ["segment-0.m4a", "segment-1.m4a", "segment-2.m4a"])
            #expect(repaired.isComplete)
        }
    }

    @Test func aFinishedRenditionKeepsOnlyItsJoinedAudioAndPassageText() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First.", "Second.", "Third."])
            let complete = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let folder = directory.appendingPathComponent(complete.id)
            #expect(try audioFiles(in: folder) == ["narration.m4a"])
            #expect(service.audioURL(for: complete) != nil)
            #expect(service.playablePrefix(of: complete.id) == nil)

            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents == [complete])
            #expect(reloaded.audioURL(for: complete) != nil)
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw NarrationTestError.unexpectedWork }
            renderer.beforeAssembly = { _, _ in throw NarrationTestError.unexpectedWork }
            let cached = try await reloaded.prepare(transcript: source, selection: selection(), translate: { _ in
                throw NarrationTestError.unexpectedWork
            }, renderer: renderer)
            #expect(cached == complete)
        }
    }

    @Test func passagesThatArePlayingAreKeptUntilTheyAreReleased() async throws {
        var inUse = true
        try await withService(passageAudioInUse: { _ in inUse }) { service, directory, _ in
            let complete = try await service.prepare(
                transcript: transcript(["First.", "Second."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer()
            )
            let folder = directory.appendingPathComponent(complete.id)
            #expect(try audioFiles(in: folder) == ["narration.m4a", "segment-0.m4a", "segment-1.m4a"])
            #expect(service.playablePrefix(of: complete.id)?.segmentURLs.count == 2)

            inUse = false
            await service.removeSpentPassageAudio()
            #expect(try audioFiles(in: folder) == ["narration.m4a"])
            #expect(service.audioURL(for: complete) != nil)
        }
    }

    @Test func passageFilesLeftByAnInterruptedRemovalAreClearedOnLoad() async throws {
        try await withService { service, directory, defaults in
            let complete = try await service.prepare(
                transcript: transcript(["First.", "Second."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer()
            )
            let folder = directory.appendingPathComponent(complete.id)
            try FileManager.default.copyItem(at: folder.appendingPathComponent("narration.m4a"), to: folder.appendingPathComponent("segment-1.m4a"))
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(try audioFiles(in: folder) == ["narration.m4a"])
            #expect(reloaded.documents.first?.isComplete == true)
        }
    }

    @Test func recentPlaysPersistMoveWithListeningAndAreForgottenWithTheirRendition() async throws {
        try await withService { service, directory, defaults in
            let complete = try await service.prepare(
                transcript: transcript(["First.", "Second."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer()
            )
            let earlier = Date(timeIntervalSince1970: 1_000)
            service.recordPlay(documentID: complete.id, at: earlier)
            service.savePosition(documentID: complete.id, position: 0.2)
            #expect(try #require(service.recentPlays[complete.id]) > earlier, "listening didn't move it up")

            let reloaded = NarrationService(directory: directory, defaults: defaults)
            #expect(reloaded.recentPlays[complete.id] == service.recentPlays[complete.id])
            reloaded.dismissFromRecent(documentID: complete.id)
            #expect(NarrationService(directory: directory, defaults: defaults).recentPlays.isEmpty)

            service.recordPlay(documentID: complete.id)
            try await service.remove(complete.id)
            #expect(service.recentPlays.isEmpty)
        }
    }

    @Test func storageSizesCoverFinishedAndPartlyPreparedRenditions() async throws {
        try await withService { service, directory, _ in
            let complete = try await service.prepare(
                transcript: transcript(["First."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer()
            )
            let unjoined = NarrationTestRenderer()
            unjoined.beforeAssembly = { _, _ in throw NarrationTestError.interrupted }
            await #expect(throws: NarrationTestError.interrupted) {
                try await service.prepare(
                    transcript: transcript(["Other."], id: "other-discourse"), selection: selection(), translate: translated, renderer: unjoined
                )
            }
            let partial = try #require(service.documents.first { !$0.isComplete })
            let sizes = await service.storageSizes()
            #expect(Set(sizes.keys) == [complete.id, partial.id])
            #expect(sizes.values.allSatisfy { $0 > 0 })
        }
    }

    @Test(arguments: BadManifest.allCases)
    func invalidManifestMetadataNeverAppearsReady(kind: BadManifest) async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First paragraph.", "Second paragraph."])
            let complete = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let manifestURL = directory.appendingPathComponent(complete.id).appendingPathComponent("manifest.json")
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            var document = try #require(manifest["document"] as? [String: Any])
            switch kind {
            case .negativeSegmentDuration:
                var segments = try #require(document["segments"] as? [[String: Any]])
                segments[0]["duration"] = -1.0
                document["segments"] = segments
            case .wrongFinalDuration: document["duration"] = 10_000.0
            case .zeroFinalDuration: document["duration"] = 0.0
            case .missingSegment:
                var segments = try #require(document["segments"] as? [[String: Any]])
                segments.removeLast()
                document["segments"] = segments
            case .renderVersion: manifest["version"] = 999
            case .nonFiniteDuration: document["duration"] = "NaN"
            }
            manifest["document"] = document
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.allSatisfy { !$0.isComplete && reloaded.audioURL(for: $0) == nil })
            let repaired = try await reloaded.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            #expect(repaired.isComplete)
            #expect(reloaded.audioURL(for: repaired) != nil)
        }
    }

    @Test func decodedPathsAndUnsafeIDsCannotReadOrDeleteOutsideTheEntry() async throws {
        try await withService { service, directory, defaults in
            let complete = try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let sentinel = directory.appendingPathComponent("keep.m4a")
            let sentinelData = Data("user-owned sentinel".utf8)
            try sentinelData.write(to: sentinel)
            let manifestURL = directory.appendingPathComponent(complete.id).appendingPathComponent("manifest.json")
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            var document = try #require(manifest["document"] as? [String: Any])
            var segments = try #require(document["segments"] as? [[String: Any]])
            segments[0]["audioFileName"] = "../keep.m4a"
            document["segments"] = segments
            document["audioFileName"] = "../keep.m4a"
            manifest["document"] = document
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.first?.isComplete == false)
            await #expect(throws: (any Error).self) { try await reloaded.remove("../keep.m4a") }
            try await reloaded.remove(complete.id)
            #expect(try Data(contentsOf: sentinel) == sentinelData)
        }
    }

    @Test(arguments: BadRender.allCases)
    func invalidClosedOutputsAreNotCommitted(kind: BadRender) async throws {
        try await withService { service, directory, _ in
            let renderer = NarrationTestRenderer()
            switch kind {
            case .empty: renderer.afterRender = { _, url in try Data().write(to: url) }
            case .corrupt: renderer.afterRender = { _, url in try Data("not AAC".utf8).write(to: url) }
            case .truncated: renderer.afterRender = { _, url in try damage(url, kind: .truncated) }
            case .wrongDuration: renderer.reportedRenderDuration = 1_000
            case .zeroDuration: renderer.reportedRenderDuration = 0
            case .nonFiniteDuration: renderer.reportedRenderDuration = .nan
            }
            await #expect(throws: (any Error).self) {
                try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: renderer)
            }
            #expect(service.documents.first?.segments.isEmpty == true)
            #expect(service.documents.first?.isComplete == false)
            #expect(renderer.assemblyCalls == 0)
            try expectNoStaging(in: directory)
            let retried = try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            #expect(retried.isComplete)
        }
    }

    @Test func failedAssemblyRetainsEveryPassageForAnAssetFreeRetry() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First.", "Second."])
            let renderer = NarrationTestRenderer()
            renderer.beforeAssembly = { _, url in
                try Data("partial assembly".utf8).write(to: url)
                throw NarrationTestError.interrupted
            }
            await #expect(throws: NarrationTestError.interrupted) {
                try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
            }
            #expect(service.documents.first?.segments.count == 2)
            #expect(service.documents.first?.isComplete == false)
            try expectNoStaging(in: directory)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            let retry = NarrationTestRenderer()
            retry.beforeRender = { _, _ in throw NarrationTestError.unexpectedWork }
            let complete = try await reloaded.prepare(transcript: source, selection: selection(), translate: { _ in
                throw NarrationTestError.unexpectedWork
            }, renderer: retry)
            #expect(complete.isComplete)
            #expect(retry.assemblyCalls == 1)
            #expect(retry.rendered.isEmpty)
        }
    }

    @Test func manifestWriteFailureLeavesThePreviousCheckpointReusable() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First.", "Second."])
            let renderer = NarrationTestRenderer()
            var oldManifest: Data?
            var manifestURL: URL?
            renderer.afterRender = { call, _ in
                guard call == 2 else { return }
                let id = try #require(service.documents.first?.id)
                let url = directory.appendingPathComponent(id).appendingPathComponent("manifest.json")
                oldManifest = try Data(contentsOf: url)
                manifestURL = url
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            await #expect(throws: (any Error).self) {
                try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
            }
            #expect(service.documents.first?.segments.map(\.index) == [0])
            let url = try #require(manifestURL)
            try FileManager.default.removeItem(at: url)
            try #require(oldManifest).write(to: url, options: .atomic)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.first?.segments.map(\.index) == [0])
            var inputs: [String] = []
            let complete = try await reloaded.prepare(transcript: source, selection: selection(), translate: { input in
                inputs += input
                return input.map { "Retry: " + $0 }
            }, renderer: NarrationTestRenderer())
            #expect(inputs.isEmpty)
            #expect(complete.segments.map(\.text) == ["Translated: First.", "Translated: Second."])
            #expect(complete.isComplete)
        }
    }

    @Test func positionsArePerRenditionDeviceLocalAndIndependentOfOriginalPlayback() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["A paragraph."])
            let first = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let second = try await service.prepare(transcript: source, selection: selection(voiceID: "another.voice"), translate: translated, renderer: NarrationTestRenderer())
            defaults.set(123.0, forKey: "playbackPosition_" + source.discourseID)
            defaults.set([source.discourseID], forKey: "recentlyPlayed")
            service.savePosition(documentID: first.id, position: 0.05)
            for invalid in [-1.0, Double.nan, .infinity] { service.savePosition(documentID: first.id, position: invalid) }
            #expect(service.position(for: first.id) == 0.05)
            #expect(service.position(for: second.id) == 0)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            #expect(reloaded.position(for: first.id) == 0.05)
            #expect(defaults.double(forKey: "playbackPosition_" + source.discourseID) == 123)
            #expect(defaults.stringArray(forKey: "recentlyPlayed") == [source.discourseID])
            service.savePosition(documentID: first.id, position: 1_000)
            #expect(service.position(for: first.id) == first.duration)
            service.savePosition(documentID: first.id, position: 0)
            #expect(service.position(for: first.id) == 0)
            service.savePosition(documentID: second.id, position: 0.07)
            try await service.remove(second.id)
            #expect(reloaded.position(for: second.id) == 0)
            #expect(service.audioURL(for: second) == nil)
            let otherSuite = "NarrationServiceTests.other.\(UUID().uuidString)"
            let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
            defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
            service.savePosition(documentID: first.id, position: 0.05)
            #expect(NarrationService(directory: directory, defaults: otherDefaults).position(for: first.id) == 0)
        }
    }

    @Test func failedLoadWithdrawsReadinessAndCanRecover() async throws {
        try await withService { service, directory, _ in
            let document = try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let moved = directory.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: directory, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            try Data("blocking file".utf8).write(to: directory)
            await service.load()
            #expect(service.errorMessage != nil)
            #expect(service.documents.first?.isComplete == false)
            #expect(service.audioURL(for: document) == nil)
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.moveItem(at: moved, to: directory)
            await service.load()
            #expect(service.documents == [document])
            #expect(service.errorMessage == nil)
            #expect(service.audioURL(for: document) != nil)
        }
    }

    @Test func symlinkedEntriesCannotBePlayedOrFollowedDuringDeletion() async throws {
        try await withService { service, directory, _ in
            let document = try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let entry = directory.appendingPathComponent(document.id)
            let destination = directory.appendingPathComponent("keep-directory")
            try FileManager.default.moveItem(at: entry, to: destination)
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: destination)
            #expect(service.audioURL(for: document) == nil)
            await service.load()
            #expect(service.documents.isEmpty)
            try await service.remove(document.id)
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
            #expect(!FileManager.default.fileExists(atPath: entry.path))
        }
    }

    @Test func completedCacheFilesAreExcludedFromDeviceBackup() async throws {
        try await withService { service, directory, _ in
            let document = try await service.prepare(transcript: transcript(["A paragraph."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let folder = directory.appendingPathComponent(document.id)
            let files = [directory, folder, folder.appendingPathComponent("manifest.json"), try #require(service.audioURL(for: document))]
            for url in files {
                #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            }
        }
    }

    @Test func emptyAndInvalidParagraphSequencesDoNotStartWork() async throws {
        try await withService { service, _, _ in
            let sources = [
                transcript([]), transcript([" \n\t "]),
                Transcript(discourseID: "invalid", sourceID: "site", fetchedAt: Date(), paragraphs: [
                    .init(index: 2, text: "First.", isEmphasis: false), .init(index: 1, text: "Second.", isEmphasis: false),
                ]),
            ]
            for source in sources {
                let renderer = NarrationTestRenderer()
                await #expect(throws: NarrationPreparationError.emptyTranscript) {
                    try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
                }
                #expect(renderer.rendered.isEmpty)
                #expect(!service.isPreparing)
            }
            #expect(service.documents.isEmpty)
        }
    }

    @Test func translationOverlapsAudioWithOnlyOneBatchOfLookahead() async throws {
        try await withService { service, _, _ in
            let source = transcript((0..<9).map { "Paragraph \($0)." })
            let rendering = NarrationTestGate()
            let nextTranslation = NarrationTestGate()
            let releaseAudio = NarrationTestGate()
            defer { releaseAudio.open() }
            var requests: [[String]] = []
            var audioInFlight = false
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { call, _ in
                if call == 1 {
                    audioInFlight = true
                    rendering.open()
                    await releaseAudio.wait()
                }
            }
            renderer.afterRender = { _, _ in audioInFlight = false }
            renderer.onCancel = { releaseAudio.open() }
            let task = Task {
                try await service.prepare(transcript: source, selection: selection(), translate: { input in
                    requests.append(input)
                    if requests.count == 2 {
                        await rendering.wait()
                        #expect(audioInFlight)
                        nextTranslation.open()
                    }
                    return input.map { "Translated: " + $0 }
                }, renderer: renderer)
            }
            await nextTranslation.wait()
            for _ in 0..<10 { await Task.yield() }
            #expect(requests.count == 2)
            #expect(renderer.rendered.count == 1)
            #expect(service.documents.first?.segments.isEmpty == true)
            releaseAudio.open()
            let ready = try await task.value
            #expect(requests.map(\.count) == [4, 4, 1])
            #expect(ready.segments.map(\.text) == source.paragraphs.map { "Translated: " + $0.text })
            #expect(renderer.assemblyInputs.map(\.lastPathComponent) == (0..<9).map { "segment-\($0).m4a" })
            #expect(ready.isComplete)
        }
    }

    @Test func cancellingLookaheadKeepsSavedTextButRejectsLateTranslations() async throws {
        try await withService { service, directory, defaults in
            let source = transcript((0..<5).map { "Paragraph \($0)." })
            let rendering = NarrationTestGate()
            let translating = NarrationTestGate()
            let releaseAudio = NarrationTestGate()
            let releaseTranslation = NarrationTestGate()
            defer { releaseAudio.open(); releaseTranslation.open() }
            let renderer = NarrationTestRenderer()
            renderer.afterRender = { _, _ in rendering.open(); await releaseAudio.wait() }
            renderer.onCancel = { releaseAudio.open() }
            var calls = 0
            let task = Task {
                try await service.prepare(transcript: source, selection: selection(), translate: { input in
                    calls += 1
                    if calls == 2 {
                        translating.open()
                        await releaseTranslation.wait()
                    }
                    return input.map { "Saved: " + $0 }
                }, renderer: renderer)
            }
            await rendering.wait()
            await translating.wait()
            service.cancel()
            releaseTranslation.open()
            await expectCancelled(task)
            #expect(renderer.cancelCalls == 1)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.first?.segments.isEmpty == true)
            var resumedInputs: [String] = []
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { input in
                resumedInputs += input
                return input.map { "New: " + $0 }
            }, renderer: NarrationTestRenderer())
            #expect(resumedInputs == ["Paragraph 4."])
            #expect(ready.segments.map(\.text) == (0..<4).map { "Saved: Paragraph \($0)." } + ["New: Paragraph 4."])
            #expect(ready.isComplete)
            try expectNoStaging(in: directory)
        }
    }

    @Test func failedLookaheadCancelsAudioWithoutLosingItsSavedTranslation() async throws {
        try await withService { service, directory, defaults in
            let source = transcript((0..<5).map { "Paragraph \($0)." })
            let rendering = NarrationTestGate()
            let release = NarrationTestGate()
            defer { release.open() }
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in rendering.open(); await release.wait() }
            renderer.onCancel = { release.open() }
            var calls = 0
            await #expect(throws: NarrationTestError.interrupted) {
                try await service.prepare(transcript: source, selection: selection(), translate: { input in
                    calls += 1
                    if calls == 2 {
                        await rendering.wait()
                        throw NarrationTestError.interrupted
                    }
                    return input.map { "Saved: " + $0 }
                }, renderer: renderer)
            }
            #expect(renderer.cancelCalls == 1)
            #expect(!service.isPreparing)
            #expect(service.errorMessage?.hasPrefix("Translation could not finish") == true)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            var inputs: [String] = []
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { input in
                inputs += input
                return input.map { "New: " + $0 }
            }, renderer: NarrationTestRenderer())
            #expect(inputs == ["Paragraph 4."])
            #expect(ready.isComplete)
        }
    }

    @Test(arguments: [false, true])
    func fatalAudioFailureRetiresLookaheadBeforeItReturnsAndPreservesTheFirstError(lateFailure: Bool) async throws {
        try await withService { service, directory, _ in
            let source = transcript((0..<5).map { "Paragraph \($0)." })
            let translating = NarrationTestGate()
            let releaseTranslation = NarrationTestGate()
            let failurePublished = NarrationTestGate()
            defer { releaseTranslation.open() }
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in
                await translating.wait()
                throw NativeNarrationSpeechError.voiceUnavailable
            }
            var callbacks: [NativeNarrationSpeechError?] = []
            var calls = 0
            var finished = false
            let task = Task {
                defer { finished = true }
                return try await service.prepare(transcript: source, selection: selection(), translate: { input in
                    calls += 1
                    if calls == 2 {
                        translating.open()
                        await releaseTranslation.wait()
                        if lateFailure { throw NarrationTestError.interrupted }
                    }
                    return input.map { "Saved: " + $0 }
                }, renderer: renderer, onFailure: { error in
                    callbacks.append(error as? NativeNarrationSpeechError)
                    failurePublished.open()
                })
            }
            await failurePublished.wait()
            #expect(!finished)
            #expect(!service.isPreparing)
            #expect(service.preparingDiscourseID == nil)
            #expect(service.errorMessage == NativeNarrationSpeechError.voiceUnavailable.localizedDescription)
            #expect(callbacks == [.voiceUnavailable])
            #expect(renderer.cancelCalls == 1)
            var inputs: [String] = []
            let replacementRenderer = NarrationTestRenderer()
            let replacement = try await service.prepare(transcript: source, selection: selection(), translate: { input in
                inputs += input
                return input.map { "New: " + $0 }
            }, renderer: replacementRenderer)
            #expect(inputs == ["Paragraph 4."])
            releaseTranslation.open()
            await #expect(throws: NativeNarrationSpeechError.voiceUnavailable) { try await task.value }
            #expect(callbacks.count == 1)
            #expect(service.documents == [replacement])
            #expect(service.errorMessage == nil)
            #expect(service.progress == 1)
            #expect(replacementRenderer.cancelCalls == 0)
            #expect(replacement.segments.map(\.text) == (0..<4).map { "Saved: Paragraph \($0)." } + ["New: Paragraph 4."])
            try expectNoStaging(in: directory)
        }
    }

    @Test(arguments: [NativeNarrationSpeechError.timedOut, .noAudio, .incompleteAudio])
    func transientSpeechFailureRetriesAFreshOutputWithoutRetranslating(_ failure: NativeNarrationSpeechError) async throws {
        var delays: [Duration] = []
        try await withService(retrySleep: { delays.append($0) }) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { call, output in
                #expect(!FileManager.default.fileExists(atPath: output.path))
                if call == 1 {
                    try Data("interrupted output".utf8).write(to: output)
                    throw failure
                }
            }
            var translationCalls = 0
            let ready = try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: { _ in
                translationCalls += 1
                return ["Saved translation."]
            }, renderer: renderer)
            #expect(translationCalls == 1)
            #expect(renderer.rendered == ["Saved translation.", "Saved translation."])
            #expect(delays == [.milliseconds(500)])
            #expect(ready.segments.map(\.text) == ["Saved translation."])
            #expect(ready.isComplete)
        }
    }

    @Test func exhaustedSpeechRetryPreservesTextForRelaunch() async throws {
        var delays: [Duration] = []
        try await withService(retrySleep: { delays.append($0) }) { service, directory, defaults in
            let source = transcript(["Source."])
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw NativeNarrationSpeechError.timedOut }
            await #expect(throws: NativeNarrationSpeechError.timedOut) {
                try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
            }
            #expect(renderer.rendered.count == 2)
            #expect(delays == [.milliseconds(500)])
            #expect(service.errorMessage == NativeNarrationSpeechError.timedOut.localizedDescription)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { _ in
                throw NarrationTestError.unexpectedWork
            }, renderer: NarrationTestRenderer())
            #expect(ready.segments.map(\.text) == ["Translated: Source."])
            #expect(ready.isComplete)
        }
    }

    @Test(arguments: [NativeNarrationSpeechError.voiceUnavailable, .invalidBuffer, .unsupportedFormat, .outputExists, .busy])
    func permanentSpeechFailuresDoNotRetry(_ failure: NativeNarrationSpeechError) async throws {
        try await withService(retrySleep: { _ in throw NarrationTestError.unexpectedWork }) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw failure }
            await #expect(throws: failure) {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer)
            }
            #expect(renderer.rendered.count == 1)
            #expect(!service.isPreparing)
        }
    }

    @Test func cancellingSpeechBackoffPreventsAnotherRenderAndKeepsText() async throws {
        let sleeping = NarrationTestGate()
        let release = NarrationTestGate()
        defer { release.open() }
        try await withService(retrySleep: { _ in sleeping.open(); await release.wait() }) { service, directory, defaults in
            let source = transcript(["Source."])
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw NativeNarrationSpeechError.noAudio }
            let task = Task { try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer) }
            await sleeping.wait()
            service.cancel()
            release.open()
            await expectCancelled(task)
            #expect(renderer.rendered.count == 1)
            #expect(renderer.cancelCalls == 1)
            #expect(service.errorMessage == nil)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { _ in
                throw NarrationTestError.unexpectedWork
            }, renderer: NarrationTestRenderer())
            #expect(ready.isComplete)
        }
    }

    @Test func corruptPendingTranslationsAreDroppedWithoutDiscardingValidSavedText() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First.", "Second.", "Third."])
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw NativeNarrationSpeechError.voiceUnavailable }
            await #expect(throws: NativeNarrationSpeechError.voiceUnavailable) {
                try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
            }
            let partial = try #require(service.documents.first)
            let manifestURL = directory.appendingPathComponent(partial.id).appendingPathComponent("manifest.json")
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            manifest["pendingTranslations"] = ["-1": "Outside.", "99": "Outside.", "0": " \n ", "1": "Saved second.", "2": "Saved third."]
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            var inputs: [String] = []
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { input in
                inputs += input
                return ["Fresh first."]
            }, renderer: NarrationTestRenderer())
            #expect(inputs == ["First."])
            #expect(ready.segments.map(\.text) == ["Fresh first.", "Saved second.", "Saved third."])
            #expect(ready.id == partial.id)
            #expect(ready.isComplete)
        }
    }

    @Test(arguments: ["number", "null", "object", "invalidKey", "noncanonicalKey"])
    func malformedPendingEntryKeepsHealthyAudioAndOtherTranslations(kind: String) async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["First.", "Second.", "Third."])
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { call, _ in
                if call == 2 { throw NativeNarrationSpeechError.voiceUnavailable }
            }
            await #expect(throws: NativeNarrationSpeechError.voiceUnavailable) {
                try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
            }
            let partial = try #require(service.documents.first)
            #expect(partial.segments.map(\.index) == [0])
            let folder = directory.appendingPathComponent(partial.id)
            let manifestURL = folder.appendingPathComponent("manifest.json")
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            var pending = try #require(manifest["pendingTranslations"] as? [String: Any])
            switch kind {
            case "number": pending["1"] = 42
            case "null": pending["1"] = NSNull()
            case "object": pending["1"] = ["text": "invalid object"]
            case "invalidKey": pending["1"] = nil; pending["invalid"] = "invalid key"
            default: pending["1"] = nil; pending["01"] = "ambiguous key"
            }
            manifest["pendingTranslations"] = pending
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            #expect(reloaded.documents.first?.segments == partial.segments)
            var inputs: [String] = []
            let resumed = NarrationTestRenderer()
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { input in
                inputs += input
                return ["Fresh second."]
            }, renderer: resumed)
            #expect(inputs == ["Second."])
            #expect(ready.segments.map(\.text) == ["Translated: First.", "Fresh second.", "Translated: Third."])
            #expect(ready.segments[0] == partial.segments[0])
            #expect(resumed.rendered == ["Fresh second.", "Translated: Third."])
            #expect(ready.id == partial.id)
            #expect(ready.isComplete)
        }
    }

    @Test(arguments: ["array", "scalar", "entry"])
    func malformedOptionalMetadataDoesNotInvalidateCompletedAudio(kind: String) async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["Source."])
            let original = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let audioURL = try #require(service.audioURL(for: original))
            let audio = try Data(contentsOf: audioURL)
            let manifestURL = directory.appendingPathComponent(original.id).appendingPathComponent("manifest.json")
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            switch kind {
            case "array": manifest["pendingTranslations"] = ["malformed"]
            case "scalar": manifest["pendingTranslations"] = 42
            default: manifest["pendingTranslations"] = ["0": NSNull()]
            }
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw NarrationTestError.unexpectedWork }
            renderer.beforeAssembly = { _, _ in throw NarrationTestError.unexpectedWork }
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { _ in
                throw NarrationTestError.unexpectedWork
            }, renderer: renderer)
            #expect(ready == original)
            #expect(reloaded.audioURL(for: ready) == audioURL)
            #expect(try Data(contentsOf: audioURL) == audio)
        }
    }

    @Test func legacyManifestWithoutPendingTextKeepsItsReadyIdentityAndBytes() async throws {
        try await withService { service, directory, defaults in
            let source = transcript(["Source."])
            let original = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            let manifestURL = directory.appendingPathComponent(original.id).appendingPathComponent("manifest.json")
            var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            manifest.removeValue(forKey: "pendingTranslations")
            let legacy = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
            try legacy.write(to: manifestURL, options: .atomic)
            let reloaded = NarrationService(directory: directory, defaults: defaults)
            await reloaded.load()
            let ready = try await reloaded.prepare(transcript: source, selection: selection(), translate: { _ in
                throw NarrationTestError.unexpectedWork
            }, renderer: NarrationTestRenderer())
            #expect(ready == original)
            #expect(try Data(contentsOf: manifestURL) == legacy)
            #expect(reloaded.audioURL(for: ready) != nil)
        }
    }

    @Test func reservationRejectsASecondWindowBeforePreflightStarts() async throws {
        try await withService { service, _, _ in
            let first = UUID()
            let second = UUID()
            #expect(service.reservePreparation(owner: first))
            #expect(service.reservePreparation(owner: first))
            #expect(!service.reservePreparation(owner: second))
            #expect(service.preparationOwner == first)
            #expect(!service.isPreparing)
            let renderer = NarrationTestRenderer()
            await #expect(throws: NarrationPreparationError.busy) {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer)
            }
            await #expect(throws: CancellationError.self) {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer, owner: second)
            }
            #expect(service.documents.isEmpty)
            #expect(renderer.rendered.isEmpty)
            #expect(service.preparationOwner == first)
        }
    }

    @Test func nonOwnerCancellationAndIdleReleaseCannotInterruptAnOwnedJob() async throws {
        try await withService { service, _, _ in
            let owner = UUID()
            let other = UUID()
            #expect(service.reservePreparation(owner: owner))
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            defer { release.open() }
            let renderer = NarrationTestRenderer()
            renderer.afterRender = { _, _ in entered.open(); await release.wait() }
            let task = Task {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer, owner: owner)
            }
            await entered.wait()
            let status = service.statusMessage
            service.cancel(owner: other)
            service.releasePreparation(owner: other)
            service.releasePreparation(owner: owner)
            #expect(service.reservePreparation(owner: owner))
            #expect(!service.reservePreparation(owner: other))
            #expect(service.preparationOwner == owner)
            #expect(service.isPreparing)
            #expect(service.statusMessage == status)
            #expect(renderer.cancelCalls == 0)
            release.open()
            let complete = try await task.value
            #expect(complete.isComplete)
            #expect(service.preparationOwner == nil)
        }
    }

    @Test(arguments: [false, true])
    func cancelledPreflightCannotStartWorkOrClearAReplacementReservation(global: Bool) async throws {
        try await withService { service, _, _ in
            let owner = UUID()
            let replacement = UUID()
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            defer { release.open() }
            let renderer = NarrationTestRenderer()
            var translationCalls = 0
            #expect(service.reservePreparation(owner: owner))
            let preflight = Task {
                entered.open()
                await release.wait()
                defer { service.releasePreparation(owner: owner) }
                return try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: { input in
                    translationCalls += 1
                    return input
                }, renderer: renderer, owner: owner)
            }
            await entered.wait()
            if global { service.cancel() } else { service.cancel(owner: owner) }
            #expect(service.preparationOwner == nil)
            #expect(service.reservePreparation(owner: replacement))
            release.open()
            await expectCancelled(preflight)
            #expect(service.preparationOwner == replacement)
            #expect(!service.isPreparing)
            #expect(service.documents.isEmpty)
            #expect(service.errorMessage == nil)
            #expect(translationCalls == 0)
            #expect(renderer.rendered.isEmpty)
            #expect(renderer.cancelCalls == 0)
        }
    }

    @Test func idleReservationCanBeReleasedAndReclaimedWithoutLateOwnerCleanup() async throws {
        try await withService { service, _, _ in
            let first = UUID()
            let second = UUID()
            #expect(service.reservePreparation(owner: first))
            service.releasePreparation(owner: second)
            service.cancel(owner: second)
            #expect(service.preparationOwner == first)
            service.releasePreparation(owner: first)
            #expect(service.preparationOwner == nil)
            #expect(service.reservePreparation(owner: first))
            service.releasePreparation(owner: first)
            #expect(service.reservePreparation(owner: second))
            service.releasePreparation(owner: first)
            service.cancel(owner: first)
            #expect(!service.reservePreparation(owner: first))
            #expect(service.preparationOwner == second)
            service.cancel()
            #expect(service.preparationOwner == nil)
            let legacy = try await service.prepare(transcript: transcript(["Legacy caller."]), selection: selection(), translate: translated, renderer: NarrationTestRenderer())
            #expect(legacy.isComplete)
        }
    }

    @Test(arguments: [false, true])
    func lateOwnedJobCleanupCannotReleaseOrCancelItsReplacement(global: Bool) async throws {
        try await withService { service, directory, _ in
            let first = UUID()
            let second = UUID()
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let replacementEntered = NarrationTestGate()
            let replacementRelease = NarrationTestGate()
            defer { release.open(); replacementRelease.open() }
            #expect(service.reservePreparation(owner: first))
            let oldRenderer = NarrationTestRenderer()
            let old = Task {
                defer { service.releasePreparation(owner: first) }
                return try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: { _ in
                    entered.open()
                    await release.wait()
                    return ["Obsolete translation."]
                }, renderer: oldRenderer, owner: first)
            }
            await entered.wait()
            if global { service.cancel() } else { service.cancel(owner: first) }
            #expect(service.reservePreparation(owner: second))
            let renderer = NarrationTestRenderer()
            renderer.afterRender = { _, _ in replacementEntered.open(); await replacementRelease.wait() }
            let replacement = Task {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: { _ in ["Replacement translation."] }, renderer: renderer, owner: second)
            }
            await replacementEntered.wait()
            let status = service.statusMessage
            old.cancel()
            release.open()
            await expectCancelled(old)
            service.cancel(owner: first)
            #expect(service.preparationOwner == second)
            #expect(service.isPreparing)
            #expect(service.statusMessage == status)
            #expect(renderer.cancelCalls == 0)
            #expect(oldRenderer.cancelCalls == 1)
            #expect(oldRenderer.rendered.isEmpty)
            replacementRelease.open()
            let ready = try await replacement.value
            #expect(ready.segments.map(\.text) == ["Replacement translation."])
            #expect(service.preparationOwner == nil)
            try expectNoStaging(in: directory)
        }
    }

    @Test func failedOwnedPreparationReleasesItsReservationBeforeFailureCallback() async throws {
        try await withService { service, _, _ in
            let owner = UUID()
            let replacement = UUID()
            #expect(service.reservePreparation(owner: owner))
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in throw NativeNarrationSpeechError.voiceUnavailable }
            await #expect(throws: NativeNarrationSpeechError.voiceUnavailable) {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer, owner: owner, onFailure: { _ in
                    #expect(service.preparationOwner == nil)
                    #expect(service.reservePreparation(owner: replacement))
                })
            }
            service.releasePreparation(owner: owner)
            #expect(service.preparationOwner == replacement)
            #expect(!service.isPreparing)
        }
    }

    enum BadTranslation: CaseIterable, Sendable {
        case missing, blank, extra
        var response: [String] {
            switch self {
            case .missing: ["Only one translation"]
            case .blank: ["First translation", " \n\t "]
            case .extra: ["First", "Second", "Unexpected third"]
            }
        }
    }

    enum DamagedFile: CaseIterable, Sendable { case missing, empty, truncated, sameSizeCorruption }
    enum BadManifest: CaseIterable, Sendable { case negativeSegmentDuration, wrongFinalDuration, zeroFinalDuration, missingSegment, renderVersion, nonFiniteDuration }
    enum BadRender: CaseIterable, Sendable { case empty, corrupt, truncated, wrongDuration, zeroDuration, nonFiniteDuration }

    @Test func backgroundActivityReportsPassagesAndTimeLeftThenCompletes() async throws {
        let clock = NarrationTestClock()
        let activity = NarrationTestBackgroundActivity()
        try await withService(now: { clock.now }, backgroundActivity: activity) { service, _, _ in
            let source = transcript((0..<20).map { String(format: "Paragraph %02d.", $0) })
            let renderer = NarrationTestRenderer()
            var estimates: [Int: TimeInterval?] = [:]
            renderer.beforeRender = { call, _ in
                #expect(service.continuesInBackground)
                estimates[call] = service.estimatedSecondsRemaining
                clock.now += 30
            }
            let document = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
            #expect(document.isComplete)
            #expect(activity.titles == ["Translating into \(NarrationLanguageSupport.displayName(for: "hi"))"])
            // One passage, or under ten seconds, is not enough evidence for an estimate.
            #expect(estimates[1] == .some(nil))
            #expect(estimates[2] == .some(nil))
            #expect(estimates[3] == TimeInterval(18 * 30))
            #expect(estimates[20] == TimeInterval(30))
            #expect(activity.updates.contains { $0.subtitle == "2 of 20 passages · About 9 min left" })
            #expect(activity.updates.contains { $0.subtitle == "19 of 20 passages · Less than a minute left" })
            #expect(activity.updates.last?.subtitle == "Finishing the audio…")
            #expect(zip(activity.updates, activity.updates.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
            // A translated batch is reported before any of its audio, so iOS sees progress during translation.
            #expect(activity.updates.contains { $0.subtitle == "0 of 20 passages" && $0.fraction > 0 })
            #expect(activity.ends == [true])
            #expect(!service.continuesInBackground)
            #expect(service.estimatedSecondsRemaining == nil)
            #expect(service.preparingDocumentID == nil)
        }
    }

    @Test func resumedRunEstimatesFromItsOwnSpeedOnly() async throws {
        let clock = NarrationTestClock()
        try await withService(now: { clock.now }) { service, _, _ in
            let source = transcript((0..<10).map { String(format: "Paragraph %02d.", $0) })
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let first = NarrationTestRenderer()
            first.afterRender = { call, _ in
                if call == 5 { entered.open(); await release.wait() }
            }
            // Fast earlier work must not make the resumed run look faster than it is.
            let task = Task { try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: first) }
            await entered.wait()
            service.cancel()
            release.open()
            await expectCancelled(task)
            let resumed = NarrationTestRenderer()
            var estimate: TimeInterval??
            resumed.beforeRender = { call, _ in
                if call == 3 { estimate = service.estimatedSecondsRemaining }
                clock.now += 60
            }
            _ = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: resumed)
            #expect(estimate == .some(.some(TimeInterval(4 * 60))))
        }
    }

    @Test func expiredBackgroundTimePausesAndKeepsFinishedPassages() async throws {
        let activity = NarrationTestBackgroundActivity()
        try await withService(backgroundActivity: activity) { service, directory, _ in
            let source = transcript((0..<4).map { "Paragraph \($0)." })
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { call, _ in
                if call == 2 { activity.expire() }
            }
            let task = Task { try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer) }
            await expectCancelled(task)
            #expect(activity.ends == [false])
            #expect(!service.continuesInBackground)
            #expect(!service.isPreparing)
            #expect(service.backgroundStatus == .paused(.expired))
            #expect(service.statusMessage == "Preparation was stopped in the background. Completed passages are saved.")
            let saved = try #require(service.documents.first)
            #expect(saved.segments.map(\.index) == [0])
            try expectNoStaging(in: directory)
        }
    }

    /// Playing audio keeps the app running after the grace time, so translation goes on; back on screen it is renewed.
    @Test func expiredGraceTimeWithAudioPlayingKeepsPreparingAndRenewsOnReturn() async throws {
        let activity = NarrationTestBackgroundActivity()
        try await withService(backgroundActivity: activity, audioKeepsAppRunning: { true }) { service, _, _ in
            let source = transcript((0..<3).map { "Paragraph \($0)." })
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { call, _ in
                guard call == 2 else { return }
                activity.expire()
                #expect(service.isPreparing)
                #expect(service.backgroundStatus == .paused(.expired))
                service.renewBackgroundTimeIfNeeded()
                #expect(activity.titles.count == 2)
                #expect(service.continuesInBackground)
                service.renewBackgroundTimeIfNeeded()
                #expect(activity.titles.count == 2)
            }
            let document = try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer)
            #expect(document.isComplete)
            #expect(renderer.cancelCalls == 0)
        }
    }

    @Test func rejectedBackgroundTimeStillPreparesInTheForeground() async throws {
        let activity = NarrationTestBackgroundActivity()
        activity.accepts = false
        try await withService(backgroundActivity: activity) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in #expect(!service.continuesInBackground) }
            let document = try await service.prepare(
                transcript: transcript(["One.", "Two."]), selection: selection(), translate: translated, renderer: renderer
            )
            #expect(document.isComplete)
            #expect(activity.titles.count == 1)
            #expect(activity.ends.isEmpty)
            #expect(activity.updates.isEmpty)
        }
    }

    @Test func backgroundEntryPreservesOnlyAnAttachedGrant() async throws {
        let activity = NarrationTestAsynchronousBackgroundActivity()
        try await withService(backgroundActivity: activity) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in
                #expect(service.backgroundStatus == .requesting)
                #expect(!service.continuesInBackground)
                activity.statuses.last?(.running)
                #expect(service.continuesInBackground)
                service.pauseIfBackgroundTimeNotGranted()
                #expect(service.isPreparing)
                #expect(renderer.cancelCalls == 0)
            }
            let document = try await service.prepare(
                transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer
            )
            #expect(document.isComplete)
            #expect(activity.ends == [true])
            #expect(service.backgroundStatus == .idle)
        }
    }

    @Test func backgroundEntryWithAudioPlayingKeepsPreparingWithoutAGrant() async throws {
        let activity = NarrationTestAsynchronousBackgroundActivity()
        try await withService(backgroundActivity: activity) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in
                #expect(!service.continuesInBackground)
                service.pauseIfBackgroundTimeNotGranted(audioKeepsAppRunning: true)
                #expect(service.isPreparing)
                #expect(renderer.cancelCalls == 0)
            }
            let document = try await service.prepare(
                transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer
            )
            #expect(document.isComplete)
        }
    }

    @Test func backgroundEntryWhileRequestingPausesAndIgnoresLateGrant() async throws {
        let activity = NarrationTestAsynchronousBackgroundActivity()
        try await withService(backgroundActivity: activity) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in
                service.pauseIfBackgroundTimeNotGranted()
                #expect(service.backgroundStatus == .paused(.notGranted))
                activity.statuses.last?(.running)
                activity.expirations.last?()
                #expect(service.backgroundStatus == .paused(.notGranted))
            }
            let task = Task {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer)
            }
            await expectCancelled(task)
            #expect(renderer.cancelCalls == 1)
            #expect(activity.ends == [false])
            #expect(!service.isPreparing)
            #expect(service.statusMessage.contains("hadn't been granted"))
        }
    }

    @Test func delayedOldStatusAndExpirationCannotChangeReplacementPreparation() async throws {
        let activity = NarrationTestAsynchronousBackgroundActivity()
        try await withService(backgroundActivity: activity) { service, _, _ in
            let first = NarrationTestRenderer()
            first.beforeRender = { _, _ in service.cancel() }
            let task = Task {
                try await service.prepare(transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: first)
            }
            await expectCancelled(task)
            let oldStatus = try #require(activity.statuses.first)
            let oldExpiration = try #require(activity.expirations.first)
            let second = NarrationTestRenderer()
            second.beforeRender = { _, _ in
                activity.statuses.last?(.running)
                oldStatus(.unavailable(.submissionFailed))
                oldExpiration()
                #expect(service.isPreparing)
                #expect(service.continuesInBackground)
                #expect(second.cancelCalls == 0)
            }
            let ready = try await service.prepare(
                transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: second
            )
            #expect(ready.isComplete)
            #expect(activity.ends == [false, true])
        }
    }

    @Test func rejectedSubmissionRemainsVisibleWhileForegroundPreparationContinues() async throws {
        let activity = NarrationTestAsynchronousBackgroundActivity()
        try await withService(backgroundActivity: activity) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in
                activity.statuses.last?(.unavailable(.immediateRunIneligible))
                #expect(service.backgroundStatus == .unavailable(.immediateRunIneligible))
                #expect(service.backgroundStatusMessage.contains("current system conditions"))
                #expect(service.isPreparing)
                #expect(!service.continuesInBackground)
            }
            let ready = try await service.prepare(
                transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer
            )
            #expect(ready.isComplete)
        }
    }

    @Test func lowPowerIsVisibleButDoesNotOverrideAnActualGrant() async throws {
        let activity = NarrationTestAsynchronousBackgroundActivity()
        var lowPower = false
        try await withService(backgroundActivity: activity, lowPowerMode: { lowPower }) { service, _, _ in
            let renderer = NarrationTestRenderer()
            renderer.beforeRender = { _, _ in
                activity.statuses.last?(.running)
                lowPower = true
                service.pauseIfBackgroundTimeNotGranted()
                #expect(service.isLowPowerModeEnabled)
                #expect(service.backgroundStatusMessage.contains("Low Power Mode is on"))
                service.pauseIfBackgroundTimeNotGranted()
                #expect(service.isPreparing)
                lowPower = false
                service.pauseIfBackgroundTimeNotGranted()
                #expect(!service.isLowPowerModeEnabled)
                #expect(!service.backgroundStatusMessage.contains("Low Power Mode"))
                #expect(service.continuesInBackground)
            }
            _ = try await service.prepare(
                transcript: transcript(["Source."]), selection: selection(), translate: translated, renderer: renderer
            )
        }
    }

    @Test func backgroundEntryReleasesForegroundOnlyPreflightReservation() async throws {
        try await withService { service, _, _ in
            let owner = UUID()
            #expect(service.reservePreparation(owner: owner))
            service.pauseIfBackgroundTimeNotGranted()
            #expect(service.preparationOwner == nil)
            #expect(service.backgroundStatus == .paused(.notGranted))
            #expect(!service.isPreparing)
        }
    }

    @Test func finishedPassagesArePlayableBeforeTheNarrationCompletes() async throws {
        try await withService { service, _, defaults in
            let source = transcript(["A short one.", String(repeating: "A much longer passage. ", count: 6), "Last."])
            let entered = NarrationTestGate()
            let release = NarrationTestGate()
            let renderer = NarrationTestRenderer()
            var events: [String] = []
            service.onEvent = { event in
                switch event {
                case .documentUpdated(let document): events.append("updated:\(document.segments.count)")
                case .preparationEnded: events.append("ended")
                }
            }
            renderer.afterRender = { call, _ in
                if call == 3 { entered.open(); await release.wait() }
            }
            let task = Task { try await service.prepare(transcript: source, selection: selection(), translate: translated, renderer: renderer) }
            await entered.wait()
            let preparing = try #require(service.documents.first)
            #expect(service.preparingDocumentID == preparing.id)
            #expect(service.completedPassages == 2)
            #expect(service.totalPassages == 3)
            // Progress follows source length: the long second passage counts for more than the first.
            let lengths = source.paragraphs.map { Double($0.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) }
            // The translated third passage counts half until it is spoken.
            #expect(abs(service.progress - (lengths[0] + lengths[1] + lengths[2] / 2) / lengths.reduce(0, +) * 3 / 4) < 0.000_001)
            let prefix = try #require(service.playablePrefix(of: preparing.id))
            #expect(prefix.document.segments.map(\.index) == [0, 1])
            #expect(!prefix.document.isComplete)
            #expect(prefix.document.audioFileName == nil)
            #expect(abs(prefix.document.duration - preparing.segments.reduce(0) { $0 + $1.duration }) < 0.000_001)
            #expect(prefix.segmentURLs.count == 2)
            #expect(prefix.segmentURLs.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) })
            service.savePosition(documentID: preparing.id, position: 1_000)
            #expect(defaults.double(forKey: "narration.position." + preparing.id) == prefix.document.duration)
            release.open()
            let complete = try await task.value
            #expect(service.position(for: complete.id) <= complete.duration)
            #expect(events.suffix(2) == ["updated:3", "ended"])
            #expect(service.playablePrefix(of: "not-an-id") == nil)
        }
    }

    @Test func oshoPacePacesEachPassageToTheOriginalParagraphAndNaturalPaceDoesNot() async throws {
        let pacer = NarrationTestPacer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NarrationPacing-\(UUID().uuidString)", isDirectory: true)
        let suite = "NarrationPacing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = NarrationService(directory: directory, defaults: defaults, pacer: pacer)
        // A real shipped alignment: 109 paragraphs of Vigyan Bhairav Tantra Vol 1 #1.
        let source = transcript((0..<109).map { "Paragraph \($0) of the talk." }, id: "english-Vigyan_Bhairav_Tantra_Vol_1-1")
        let timing = try #require(NarrationOriginalTiming.make(transcript: source))
        let natural = try await service.prepare(
            transcript: source, selection: selection(), translate: translated, renderer: NarrationTestRenderer()
        )
        #expect(pacer.targets.isEmpty)
        let osho = try await service.prepare(
            transcript: source, selection: NarrationSelection(
                sourceLanguage: "en", targetLanguage: "hi",
                voice: NarrationVoice(id: "voice.hi", name: "Test voice", language: "hi-IN", quality: 1), pace: .osho
            ),
            translate: translated, renderer: NarrationTestRenderer()
        )
        #expect(osho.id != natural.id)
        #expect(osho.selection.pace == .osho)
        #expect(pacer.targets.count == 109)
        #expect(zip(pacer.targets, 0...).allSatisfy { target, index in
            abs(target - (timing.duration(ofParagraph: index) ?? -1)) < 0.000_1
        })
        #expect(osho.segments.allSatisfy { abs($0.duration - pacer.reported) < 0.05 })
        try expectNoStaging(in: directory)
    }

    @Test func savedRenditionsWithoutAPaceDecodeAsNaturalAndKeepTheirIdentity() throws {
        let legacy = #"{"sourceLanguage":"en","targetLanguage":"hi","voice":{"id":"v","name":"n","language":"hi-IN","quality":1}}"#
        let decoded = try JSONDecoder().decode(NarrationSelection.self, from: Data(legacy.utf8))
        #expect(decoded.pace == .natural)
        #expect(decoded == NarrationSelection(sourceLanguage: "en", targetLanguage: "hi", voice: NarrationVoice(id: "v", name: "n", language: "hi-IN", quality: 1)))
    }

    private func transcript(_ text: [String], id: String = "test-discourse") -> Transcript {
        Transcript(discourseID: id, sourceID: "site", fetchedAt: Date(timeIntervalSince1970: 100), paragraphs: text.enumerated().map {
            .init(index: $0.offset, text: $0.element, isEmphasis: false)
        })
    }

    private func selection(
        source: String = "en", target: String = "hi", voiceID: String = "voice.hi", voiceLanguage: String = "hi-IN",
        quality: Int = 1, name: String = "Test voice"
    ) -> NarrationSelection {
        NarrationSelection(sourceLanguage: source, targetLanguage: target, voice: NarrationVoice(id: voiceID, name: name, language: voiceLanguage, quality: quality))
    }

    private func translated(_ source: [String]) async throws -> [String] { source.map { "Translated: " + $0 } }

    private func damage(_ url: URL, kind: DamagedFile) throws {
        switch kind {
        case .missing: try FileManager.default.removeItem(at: url)
        case .empty: try Data().write(to: url, options: .atomic)
        case .truncated:
            let data = try Data(contentsOf: url)
            try data.prefix(max(1, data.count / 3)).write(to: url, options: .atomic)
        case .sameSizeCorruption:
            let count = try Data(contentsOf: url).count
            try Data(repeating: 0x7F, count: count).write(to: url, options: .atomic)
        }
    }

    private func expectCancelled(_ task: Task<NarrationDocument, Error>) async {
        do {
            _ = try await task.value
            Issue.record("A fenced preparation must throw cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected cancellation, got \(error)")
        }
    }

    private func audioFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".m4a") }.sorted()
    }

    private func expectNoStaging(in directory: URL) throws {
        let staging = directory.appendingPathComponent(".staging")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    private func withService(
        retrySleep: @escaping @MainActor (Duration) async throws -> Void = { _ in try Task.checkCancellation() },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        backgroundActivity: (any NarrationBackgroundActivity)? = nil,
        lowPowerMode: @escaping @MainActor () -> Bool = { false },
        audioKeepsAppRunning: @escaping @MainActor () -> Bool = { false },
        passageAudioInUse: @escaping @MainActor (String) -> Bool = { _ in false },
        _ body: @MainActor (NarrationService, URL, UserDefaults) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NarrationServiceTests-\(UUID().uuidString)", isDirectory: true)
        let suite = "NarrationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let service = NarrationService(
            directory: directory, defaults: defaults, retrySleep: retrySleep, now: now,
            backgroundActivity: backgroundActivity, lowPowerMode: lowPowerMode, audioKeepsAppRunning: audioKeepsAppRunning,
            passageAudioInUse: passageAudioInUse
        )
        defer {
            service.cancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(service, directory, defaults)
    }
}

private enum NarrationTestError: Error { case interrupted, unexpectedWork }

/// Writes a fixed-length passage so the test sees which target each passage was paced to.
private final class NarrationTestPacer: NarrationPacing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    let reported: TimeInterval = 0.5
    var targets: [TimeInterval] { lock.withLock { recorded } }

    func pace(_ input: URL, to output: URL, targetDuration: TimeInterval) async throws -> TimeInterval {
        lock.withLock { recorded.append(targetDuration) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000.0, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
        buffer.frameLength = 12_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<12_000 { samples[index] = 0.1 * sin(Float(index) * 0.1) }
        try file.write(from: buffer)
        file.close()
        let closed = try AVAudioFile(forReading: output)
        defer { closed.close() }
        return Double(closed.length) / closed.processingFormat.sampleRate
    }
}

@MainActor
private final class NarrationTestClock {
    var now: TimeInterval = 0
}

@MainActor
private final class NarrationTestBackgroundActivity: NarrationBackgroundActivity {
    var accepts = true
    var titles: [String] = []
    var updates: [(fraction: Double, subtitle: String)] = []
    var ends: [Bool] = []
    var onExpire: (@MainActor () -> Void)?

    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> Bool {
        titles.append(title)
        guard accepts else { return false }
        self.onExpire = onExpire
        return true
    }

    func update(fraction: Double, subtitle: String) { updates.append((fraction, subtitle)) }

    func end(success: Bool) {
        guard onExpire != nil else { return }
        ends.append(success)
        onExpire = nil
    }

    func expire() {
        let handler = onExpire
        end(success: false)
        handler?()
    }
}

@MainActor
private final class NarrationTestAsynchronousBackgroundActivity: NarrationBackgroundActivity {
    var statuses: [@MainActor (NarrationBackgroundStatus) -> Void] = []
    var expirations: [@MainActor () -> Void] = []
    var ends: [Bool] = []

    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> Bool { false }
    func begin(title: String, subtitle: String,
               onStatusChange: @escaping @MainActor (NarrationBackgroundStatus) -> Void,
               onExpire: @escaping @MainActor () -> Void) {
        statuses.append(onStatusChange)
        expirations.append(onExpire)
        onStatusChange(.requesting)
    }
    func update(fraction: Double, subtitle: String) {}
    func end(success: Bool) { ends.append(success) }
}

@MainActor
private final class NarrationTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class NarrationTestRenderer: NarrationSpeechRendering {
    var rendered: [String] = []
    var assemblyInputs: [URL] = []
    var assemblyCalls = 0
    var cancelCalls = 0
    var reportedRenderDuration: TimeInterval?
    var beforeRender: (@MainActor (Int, URL) async throws -> Void)?
    var afterRender: (@MainActor (Int, URL) async throws -> Void)?
    var beforeAssembly: (@MainActor ([URL], URL) async throws -> Void)?
    var afterAssembly: (@MainActor ([URL], URL) async throws -> Void)?
    var onCancel: (@MainActor () -> Void)?

    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval {
        rendered.append(text)
        try await beforeRender?(rendered.count, outputURL)
        let duration = try Self.writeAudio(to: outputURL, duration: 0.2)
        try await afterRender?(rendered.count, outputURL)
        return reportedRenderDuration ?? duration
    }

    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        assemblyCalls += 1
        assemblyInputs = segments
        try await beforeAssembly?(segments, outputURL)
        let sum = try segments.reduce(0.0) { total, url in
            let audio = try AVAudioFile(forReading: url)
            defer { audio.close() }
            return total + Double(audio.length) / audio.processingFormat.sampleRate
        }
        let duration = try Self.writeAudio(to: outputURL, duration: sum)
        try await afterAssembly?(segments, outputURL)
        return duration
    }

    func cancel() {
        cancelCalls += 1
        onCancel?()
    }

    private static func writeAudio(to url: URL, duration: TimeInterval) throws -> TimeInterval {
        try autoreleasepool {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000.0,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            defer { file.close() }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_048))
            let samples = try #require(buffer.floatChannelData?[0])
            var remaining = max(1, Int((duration * file.processingFormat.sampleRate).rounded()))
            var frame = 0
            while remaining > 0 {
                buffer.frameLength = AVAudioFrameCount(min(remaining, Int(buffer.frameCapacity)))
                for index in 0..<Int(buffer.frameLength) {
                    samples[index] = 0.1 * sin(Float(frame + index) * 0.1)
                }
                try file.write(from: buffer)
                frame += Int(buffer.frameLength)
                remaining -= Int(buffer.frameLength)
            }
        }
        let closed = try AVAudioFile(forReading: url)
        defer { closed.close() }
        return Double(closed.length) / closed.processingFormat.sampleRate
    }
}
