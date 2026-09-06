import Testing
import Foundation
@testable import OshoDiscourses

struct TranscriptParserTests {

    @Test func englishQuotedQuestionBecomesOneEmphasisBlock() {
        let html = "<strong>BELOVED MASTER,</strong><br><strong>THE JAPANESE MASTER NAN-IN GAVE AUDIENCE\r\nTO A PROFESSOR OF PHILOSOPHY.\r\nSTOP!</strong><br>You have come to an even more dangerous person than Nan-in.<br>The story is beautiful."
        let paragraphs = TranscriptParser.paragraphs(fromHTML: html)
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].isEmphasis)
        #expect(paragraphs[0].text == "BELOVED MASTER,\nTHE JAPANESE MASTER NAN-IN GAVE AUDIENCE\nTO A PROFESSOR OF PHILOSOPHY.\nSTOP!")
        #expect(!paragraphs[1].isEmphasis)
        #expect(paragraphs[1].text == "You have come to an even more dangerous person than Nan-in.")
        #expect(paragraphs[2].text == "The story is beautiful.")
        #expect(paragraphs.map(\.index) == [0, 1, 2])
    }

    @Test func hindiVersesSplitOnBreaksAndTrailingRuleIsDropped() {
        let html = "जनक उवाच।<br><br>कथं ज्ञानमवाप्नोति कथं मुक्तिर्भविष्यति।<br>वैराग्यं च कथं प्राप्तमेतद् ब्रूहि मम प्रभो।। 1।।<br><br>एक अनूठी यात्रा पर हम निकलते हैं।<br>हरि ॐ तत्सत्‌!<br><hr>"
        let paragraphs = TranscriptParser.paragraphs(fromHTML: html)
        #expect(paragraphs.map(\.text) == [
            "जनक उवाच।",
            "कथं ज्ञानमवाप्नोति कथं मुक्तिर्भविष्यति।",
            "वैराग्यं च कथं प्राप्तमेतद् ब्रूहि मम प्रभो।। 1।।",
            "एक अनूठी यात्रा पर हम निकलते हैं।",
            "हरि ॐ तत्सत्‌!",
        ])
        #expect(paragraphs.allSatisfy { !$0.isEmphasis })
    }

    @Test func siteSpecificQuoteTagsAreEmphasisAndSeparateBlocksStaySeparate() {
        let html = "Try to understand it.<br><q>CONFUCIUS WAS LOOKING AT THE CATARACT.\r\nIT FALLS FROM A HEIGHT.</q><br><q>YET CONFUCIUS SAW AN OLD MAN GO IN.</q><br>भगवान,<cr>मैंने उपवास के संबंध में कुछ कहा।</cr><br>तो सबसे पहले।"
        let paragraphs = TranscriptParser.paragraphs(fromHTML: html)
        #expect(paragraphs.count == 5)
        #expect(paragraphs[1].isEmphasis && paragraphs[1].text.hasPrefix("CONFUCIUS"))
        #expect(paragraphs[1].text.contains("\n"))
        // Two adjacent <q> blocks separated only by <br> read as one quoted passage.
        #expect(paragraphs[1].text.hasSuffix("GO IN."))
        #expect(paragraphs[2].text == "भगवान,")
        #expect(!paragraphs[2].isEmphasis)
        #expect(paragraphs[3].isEmphasis && paragraphs[3].text == "मैंने उपवास के संबंध में कुछ कहा।")
        #expect(paragraphs[4].text == "तो सबसे पहले।")
    }

    @Test func inlineItalicsKeepTheirTextAndBlockTagsSplitMidLine() {
        let html = "<i>Maitreya</i> means the friend.<br>भगवान,<strong>क्या उपवास से मेरा विरोध है?</strong>"
        let paragraphs = TranscriptParser.paragraphs(fromHTML: html)
        #expect(paragraphs.map(\.text) == ["Maitreya means the friend.", "भगवान,", "क्या उपवास से मेरा विरोध है?"])
        #expect(paragraphs.map(\.isEmphasis) == [false, false, true])
    }

    @Test func entitiesAndBlankMarkupAreHandled() {
        #expect(TranscriptParser.decodeEntities("Tom &amp; Jerry &lt;3 &#39;yes&#39; &#x2014; &hellip; &unknown;") == "Tom & Jerry <3 'yes' \u{2014} \u{2026} &unknown;")
        #expect(TranscriptParser.paragraphs(fromHTML: "<p><br><hr></p>").isEmpty)
        #expect(TranscriptParser.paragraphs(fromHTML: "").isEmpty)
        #expect(TranscriptParser.paragraphs(fromHTML: "Osho").count == 1)
    }

    @Test func wordCountIgnoresMarkupArtifacts() {
        let transcript = Transcript(
            discourseID: "x", sourceID: "y", fetchedAt: Date(),
            paragraphs: TranscriptParser.paragraphs(fromHTML: "One two<br>three\r\nfour  five")
        )
        #expect(transcript.wordCount == 5)
    }
}

struct TranscriptSyncModelTests {

    private func paragraphs(_ lengths: [Int]) -> [Transcript.Paragraph] {
        lengths.enumerated().map { i, n in
            Transcript.Paragraph(index: i, text: String(repeating: "a", count: n), isEmphasis: false)
        }
    }

    @Test func withoutAnchorsTimeIsProportionalToText() {
        let model = TranscriptSyncModel(paragraphs: paragraphs([100, 100, 200]), duration: 400)
        #expect(model.startTime(ofParagraph: 0) == 0)
        #expect(model.startTime(ofParagraph: 1) == 100)
        #expect(model.startTime(ofParagraph: 2) == 200)
        #expect(model.paragraph(at: 0) == 0)
        #expect(model.paragraph(at: 150) == 1)
        #expect(model.paragraph(at: 250) == 2)
        #expect(model.paragraph(at: 10_000) == 2)
        #expect(model.paragraph(at: -5) == 0)
    }

    @Test func whitespaceDoesNotWeighParagraphs() {
        let letters = String(repeating: "a", count: 120)
        let spaced = Transcript.Paragraph(index: 0, text: letters.map(String.init).joined(separator: " "), isEmphasis: false)
        let dense = Transcript.Paragraph(index: 1, text: letters, isEmphasis: false)
        let model = TranscriptSyncModel(paragraphs: [spaced, dense], duration: 100)
        #expect(model.startTime(ofParagraph: 1) == 50)
    }

    @Test func shortVersesGetAMinimumShareOfTime() {
        // A one-line sutra (8 characters) before a 400-character paragraph:
        // without the floor it would own 2% of the time, so the highlight would
        // leave it after a second or two even though it is recited slowly.
        let verse = Transcript.Paragraph(index: 0, text: "जनक उवाच", isEmphasis: false)
        let prose = Transcript.Paragraph(index: 1, text: String(repeating: "b", count: 400), isEmphasis: false)
        let model = TranscriptSyncModel(paragraphs: [verse, prose], duration: 450)
        #expect(model.startTime(ofParagraph: 1) == 50)
    }

    @Test func anchorPinsParagraphMidpointAndBendsTheMapAroundIt() {
        let base = TranscriptSyncModel(paragraphs: paragraphs([100, 100, 100, 100]), duration: 400)
        // Paragraph 1 (chars 100-200, midpoint 150) was actually heard at t=250.
        let anchor = TranscriptAnchor(paragraph: 1, time: 250, createdAt: Date())
        let model = base.with(knots: [base.knot(for: anchor)!])
        #expect(model.paragraph(at: 250) == 1)
        // Before the anchor the pace is slower: 150 chars over 250 s.
        #expect(abs(model.startTime(ofParagraph: 1) - 250 * (100.0 / 150.0)) < 0.001)
        // After it, faster: remaining 250 chars in 150 s.
        #expect(abs(model.startTime(ofParagraph: 3) - (250 + 150 * (150.0 / 250.0))) < 0.001)
        // Endpoints are untouched.
        #expect(model.startTime(ofParagraph: 0) == 0)
        #expect(model.time(atPosition: 400) == 400)
    }

    @Test func contradictoryKnotsAreDroppedKeepingTheMapMonotonic() {
        let base = TranscriptSyncModel(paragraphs: paragraphs([100, 100, 100, 100]), duration: 400)
        let good = base.knot(paragraph: 1, startingAt: 100)!
        let backwards = base.knot(paragraph: 2, startingAt: 50)!    // later text, earlier time
        let outside = TranscriptSyncModel.Knot(position: 350, time: 900) // beyond duration
        let model = base.with(knots: [backwards, good, outside])
        #expect(model.knots.count == 3)
        #expect(model.knots[1] == good)
        var last = -1.0
        for k in model.knots {
            #expect(k.time > last)
            last = k.time
        }
    }

    @Test func anchorsOverrideTheAlignedStartsTheyContradict() {
        let base = TranscriptSyncModel(paragraphs: paragraphs([100, 100, 100, 100]), duration: 400)
        // Alignment says paragraphs start at 0/100/200/300; the listener says
        // paragraph 1 is playing at t=250, so paragraph 2 cannot have started
        // at 200. Paragraph 1 starting at 100 is still consistent and stays.
        let anchor = TranscriptAnchor(paragraph: 1, time: 250, createdAt: Date())
        let knots = base.knots(alignedStarts: [0, 100, 200, 300], anchors: [anchor])
        #expect(knots.map(\.position) == [0, 100, 300, 150])   // anchor sits at the midpoint of paragraph 1
        let model = base.with(knots: knots)
        #expect(model.paragraph(at: 250) == 1)
        #expect(model.startTime(ofParagraph: 3) == 300)
        // Without anchors the aligned starts pass straight through, skipping nils.
        #expect(base.knots(alignedStarts: [nil, 100, nil, 300], anchors: []).map(\.time) == [100, 300])
    }

    @Test func degenerateInputsDoNotTrap() {
        let empty = TranscriptSyncModel(paragraphs: [], duration: 100)
        #expect(empty.paragraph(at: 50) == 0)
        #expect(empty.startTime(ofParagraph: 3) == 0)
        let noDuration = TranscriptSyncModel(paragraphs: paragraphs([10, 10]), duration: 0)
        #expect(noDuration.paragraph(at: 50) == 1)
        #expect(noDuration.startTime(ofParagraph: 1) == 0)
    }

    @Test func insertingAnchorEvictsWhatItContradicts() {
        let t0 = Date()
        let existing = [
            TranscriptAnchor(paragraph: 2, time: 100, createdAt: t0),
            TranscriptAnchor(paragraph: 5, time: 300, createdAt: t0),
            TranscriptAnchor(paragraph: 8, time: 500, createdAt: t0),
        ]
        // Paragraph 5 was really at 90 s: the p2@100 anchor now contradicts it.
        let corrected = TranscriptSyncModel.inserting(TranscriptAnchor(paragraph: 5, time: 90, createdAt: t0.addingTimeInterval(1)), into: existing)
        #expect(corrected.map(\.paragraph) == [5, 8])
        #expect(corrected[0].time == 90)
        // A later paragraph pinned earlier than an existing later anchor evicts that one too.
        let squeezed = TranscriptSyncModel.inserting(TranscriptAnchor(paragraph: 6, time: 600, createdAt: t0.addingTimeInterval(2)), into: existing)
        #expect(squeezed.map(\.paragraph) == [2, 5, 6])
    }

    @Test func mergeIsOrderIndependent() {
        let t0 = Date()
        let a = [TranscriptAnchor(paragraph: 2, time: 100, createdAt: t0),
                 TranscriptAnchor(paragraph: 9, time: 700, createdAt: t0.addingTimeInterval(5))]
        let b = [TranscriptAnchor(paragraph: 5, time: 80, createdAt: t0.addingTimeInterval(3)),
                 TranscriptAnchor(paragraph: 2, time: 100, createdAt: t0)]
        let ab = TranscriptSyncModel.merge(a, b)
        let ba = TranscriptSyncModel.merge(b, a)
        #expect(ab == ba)
        // p5@80 (newer than p2@100) evicts p2; p9@700 (newest) survives.
        #expect(ab.map(\.paragraph) == [5, 9])
        #expect(TranscriptSyncModel.merge(ab, a) == ab)   // idempotent
    }
}

@MainActor
struct TranscriptStateMergeTests {

    @Test func newerReadPositionWinsAndAnchorsUnion() {
        let t0 = Date()
        let local = TranscriptSyncedState(
            anchors: [TranscriptAnchor(paragraph: 3, time: 100, createdAt: t0)],
            readPosition: TranscriptReadPosition(paragraph: 10, updatedAt: t0),
            paragraphCount: 200
        )
        let remote = TranscriptSyncedState(
            anchors: [TranscriptAnchor(paragraph: 30, time: 900, createdAt: t0.addingTimeInterval(1))],
            readPosition: TranscriptReadPosition(paragraph: 40, updatedAt: t0.addingTimeInterval(60)),
            paragraphCount: 200
        )
        let merged = TranscriptStateService.merge(local: local, incoming: remote)
        #expect(merged.anchors.map(\.paragraph) == [3, 30])
        #expect(merged.readPosition?.paragraph == 40)
        #expect(merged.paragraphCount == 200)
        #expect(TranscriptStateService.merge(local: remote, incoming: local) == merged)
    }

    @Test func differentParagraphSplitTakesTheMoreRecentSideWhole() {
        let t0 = Date()
        let local = TranscriptSyncedState(
            anchors: [TranscriptAnchor(paragraph: 3, time: 100, createdAt: t0)],
            readPosition: nil,
            paragraphCount: 200
        )
        let remote = TranscriptSyncedState(
            anchors: [TranscriptAnchor(paragraph: 4, time: 120, createdAt: t0.addingTimeInterval(10))],
            readPosition: nil,
            paragraphCount: 210
        )
        let merged = TranscriptStateService.merge(local: local, incoming: remote)
        #expect(merged == remote)
        #expect(TranscriptStateService.merge(local: remote, incoming: local) == remote)
    }

    @Test func missingLocalTakesIncoming() {
        let remote = TranscriptSyncedState(anchors: [], readPosition: TranscriptReadPosition(paragraph: 7, updatedAt: Date()), paragraphCount: 50)
        #expect(TranscriptStateService.merge(local: nil, incoming: remote) == remote)
    }

    @Test func serviceRoundTripsThroughDiskAndInvalidatesOnResplit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("state.json")
        let service = TranscriptStateService(fileURL: url)
        service.addAnchor(discourseID: "d1", paragraph: 4, time: 300, paragraphCount: 100)
        service.setAlignment(discourseID: "d1", alignment: TranscriptAlignment(starts: [0, nil, 20], createdAt: Date(), engine: "test"), paragraphCount: 100)

        let reloaded = TranscriptStateService(fileURL: url)
        #expect(reloaded.state(for: "d1")?.anchors.count == 1)
        #expect(reloaded.state(for: "d1")?.alignment?.matchedCount == 2)

        // The transcript was re-fetched and now has a different paragraph count.
        let resplit = reloaded.state(for: "d1", paragraphCount: 101)
        #expect(resplit.anchors.isEmpty)
        #expect(resplit.alignment == nil)
        #expect(resplit.paragraphCount == 101)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func syncedStatesOnlyIncludeDiscoursesWithUserData() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = TranscriptStateService(fileURL: dir.appendingPathComponent("state.json"))
        service.setAlignment(discourseID: "aligned-only", alignment: TranscriptAlignment(starts: [0], createdAt: Date(), engine: "test"), paragraphCount: 1)
        service.addAnchor(discourseID: "anchored", paragraph: 0, time: 5, paragraphCount: 3)
        let synced = service.syncedStates()
        #expect(synced.keys.sorted() == ["anchored"])
        #expect(synced["anchored"]?.anchors.count == 1)
        try? FileManager.default.removeItem(at: dir)
    }
}

struct TranscriptFetcherTests {

    @Test func apiResponseYieldsDescriptionOrNil() {
        #expect(TranscriptFetcher.description(fromAPIResponse: Data(#"{"description":"<b>Hi</b>"}"#.utf8)) == "<b>Hi</b>")
        #expect(TranscriptFetcher.description(fromAPIResponse: Data(#"{"error":true}"#.utf8)) == nil)
        #expect(TranscriptFetcher.description(fromAPIResponse: Data("not json".utf8)) == nil)
    }

    @Test func nextDataIsDugOutOfThePage() {
        let page = """
        <html><body><div>x</div><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"data":{"pageData":{"audioData":{"title":"T","description":"line one<br>line two"}}}}},"page":"/[[...index]]"}</script></body></html>
        """
        #expect(TranscriptFetcher.description(fromPageHTML: page) == "line one<br>line two")
        #expect(TranscriptFetcher.description(fromPageHTML: "<html></html>") == nil)
    }
}

@MainActor
struct TranscriptServiceTests {

    private func makeService(fetch: @escaping (TranscriptCatalog.Entry, Bool) async throws -> String) -> (TranscriptService, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (TranscriptService(directory: dir, fetchHTML: fetch), dir)
    }

    private var knownID: String {
        Catalog.discourses(for: Catalog.allSeries.first { $0.name == "A Bird on the Wing" }!)[0].id
    }

    @Test func fetchesOnceThenServesFromDisk() async throws {
        let text = (1...60).map { "Word\($0)" }.joined(separator: " ")
        var calls = 0
        let (service, dir) = makeService { _, _ in calls += 1; return "<strong>Q</strong><br>\(text)" }
        let id = knownID
        #expect(service.availability(for: id) == .notCached)

        let first = try await service.transcript(for: id)
        #expect(first.paragraphs.count == 2)
        #expect(service.availability(for: id) == .cached)
        #expect(calls == 1)

        // A fresh service over the same folder reads the file, not the network.
        let again = TranscriptService(directory: dir) { _, _ in calls += 1; return "" }
        let second = try await again.transcript(for: id)
        #expect(second == first)
        #expect(calls == 1)

        again.remove(id)
        #expect(again.availability(for: id) == .notCached)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func blankPageIsAnErrorAndNotCached() async {
        let (service, dir) = makeService { _, _ in "<p><br><hr></p>" }
        let id = knownID
        await #expect(throws: TranscriptFetcher.FetchError.blank) {
            try await service.transcript(for: id)
        }
        #expect(service.availability(for: id) == .notCached)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func unknownDiscourseIsUnavailableWithoutNetwork() async {
        var calls = 0
        let (service, dir) = makeService { _, _ in calls += 1; return "" }
        #expect(service.availability(for: "nope-1") == .unavailable)
        await #expect(throws: (any Error).self) { try await service.transcript(for: "nope-1") }
        #expect(calls == 0)
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
struct TranscriptCatalogTests {

    @Test func mappingCoversMostOfTheCatalog() {
        #expect(TranscriptCatalog.mappedDiscourseCount >= 4800)
        #expect(TranscriptCatalog.mappedSeriesCount >= 300)
    }

    @Test func knownDiscoursesResolveToTheirOshoworldPages() throws {
        let hindi = try #require(Catalog.allSeries.first { $0.name == "Ashtavakra Maha Geeta" })
        let hindiEntry = try #require(TranscriptCatalog.entry(for: Catalog.discourses(for: hindi)[0].id))
        #expect(hindiEntry.slug == "ashtavakra-maha-geeta-01")
        #expect(TranscriptCatalog.descriptionURL(for: hindiEntry)?.absoluteString == "https://oshoworld.com/api/server/audio/get-description/\(hindiEntry.id)")
        #expect(TranscriptCatalog.pageURL(for: hindiEntry)?.absoluteString == "https://oshoworld.com/ashtavakra-maha-geeta-01")
        #expect(TranscriptCatalog.transcriptCount(forSeriesID: hindi.id) >= 80)

        let english = try #require(Catalog.allSeries.first { $0.name == "A Bird on the Wing" })
        let englishEntry = try #require(TranscriptCatalog.entry(for: Catalog.discourses(for: english)[0].id))
        #expect(englishEntry.slug == "a-bird-on-the-wing-01")
        #expect(TranscriptCatalog.transcriptCount(forSeriesID: english.id) == 11)
    }

    @Test func everyEntryPointsAtARealDiscourse() {
        // The generator only writes ids it derived from Catalog.swift; this
        // guards against the two drifting apart.
        for series in Catalog.allSeries {
            #expect(TranscriptCatalog.transcriptCount(forSeriesID: series.id) <= series.count, "\(series.name)")
        }
    }
}

struct TranscriptAlignerTests {

    /// Synthetic "recording": the transcript's own words, spoken one per 0.5 s,
    /// with recogniser noise mixed in.
    private func speak(_ paragraphs: [Transcript.Paragraph], dropEvery: Int = 0, misheard: Set<String> = []) -> [RecognizedWord] {
        var words: [RecognizedWord] = []
        var t: TimeInterval = 0
        var n = 0
        for p in paragraphs {
            for token in p.text.split(separator: " ") {
                n += 1
                if dropEvery > 0, n % dropEvery == 0 { t += 0.5; continue }
                let text = misheard.contains(String(token)) ? "mumble" : String(token)
                words.append(RecognizedWord(text: text, start: t, end: t + 0.5))
                t += 0.5
            }
            t += 1.0   // breath between paragraphs
        }
        return words
    }

    private func paragraphs(_ texts: [String]) -> [Transcript.Paragraph] {
        texts.enumerated().map { Transcript.Paragraph(index: $0, text: $1, isEmphasis: false) }
    }

    private let sample = [
        "You have come to an even more dangerous person than Nan-in, because an empty cup will not do; the cup has to be broken completely.",
        "The story is beautiful. It was bound to happen to a professor of philosophy. He must have come for the wrong reasons.",
        "When you argue, you assert. Assertion is violence, aggression, and the truth cannot be known by an aggressive mind.",
        "Ideas create stupidity because the more the ideas are there, the more the mind is burdened. And how can a burdened mind know?",
        "A religious mind is a nonphilosophical mind. A religious mind is an innocent, intelligent mind. The mirror is clear.",
        "This professor came to Nan-in. Those people who are filled with questions cannot receive anything; their cup is already full.",
    ]

    @Test func normalisationStripsPunctuationCaseAndDiacritics() {
        #expect(TranscriptAligner.normalizedTokens("Nan-in said: \"Wait!\" -- don't argue, café.") == ["nan", "in", "said", "wait", "dont", "argue", "cafe"])
        #expect(TranscriptAligner.normalizedTokens("BELOVED MASTER,") == ["beloved", "master"])
    }

    @Test func normalisationKeepsDevanagariWithItsMarks() {
        // Danda and hyphen split; matras, virama and nukta stay, because
        // dropping them would merge distinct words (कि / की, क / क्).
        #expect(TranscriptAligner.normalizedTokens("रामकृष्ण के जीवन में। बार-बार ज़रा") == ["रामकृष्ण", "के", "जीवन", "में", "बार", "बार", "ज़रा"])
        #expect(TranscriptAligner.normalizedTokens("कि की क क्") == ["कि", "की", "क", "क्"])
        #expect(TranscriptAligner.normalizedTokens("‘मैं बोध-रूप हूं’ १०८") == ["मैं", "बोध", "रूप", "हूं", "१०८"])
    }

    @Test func hindiParagraphsAlignLikeEnglishOnes() {
        let ps = paragraphs([
            "रामकृष्ण के जीवन में ऐसा उल्लेख है कि जीवन भर तो उन्होंने मां का ही ध्यान किया। काली की मूर्ति के सामने नाचते रहे।",
            "तोतापुरी ने कहा, यह भी कल्पना है। इसे भी छोड़ो। जब तक मूर्ति है तब तक मन है।",
            "अष्टावक्र कहते हैं, तू निर्दोष है, इसलिए तू भूलकर भी यह मत मानना कि तू बंधा हुआ है।",
            "एक मनोवैज्ञानिक हारवर्ड विश्वविद्यालय में प्रयोग कर रहा था। उसने विद्यार्थियों को सम्मोहित किया।",
        ])
        let starts = TranscriptAligner.paragraphStarts(paragraphs: ps, words: speak(ps, misheard: ["काली", "छोड़ो।"]))
        #expect(starts.compactMap { $0 }.count == ps.count)
        #expect(starts.map { $0 ?? -1 } == starts.map { $0 ?? -1 }.sorted())
    }

    @Test func longestIncreasingChainDropsOutOfOrderMatches() {
        let marks = [
            TranscriptAligner.Landmark(transcriptToken: 0, wordIndex: 0),
            TranscriptAligner.Landmark(transcriptToken: 5, wordIndex: 90),   // coincidence far ahead
            TranscriptAligner.Landmark(transcriptToken: 10, wordIndex: 12),
            TranscriptAligner.Landmark(transcriptToken: 20, wordIndex: 25),
            TranscriptAligner.Landmark(transcriptToken: 30, wordIndex: 3),   // coincidence far behind
            TranscriptAligner.Landmark(transcriptToken: 40, wordIndex: 44),
        ]
        let chain = TranscriptAligner.longestIncreasingChain(marks)
        #expect(chain.map(\.transcriptToken) == [0, 10, 20, 40])
    }

    @Test func perfectRecognitionRecoversEveryParagraphStart() {
        let ps = paragraphs(sample)
        let words = speak(ps)
        let starts = TranscriptAligner.paragraphStarts(paragraphs: ps, words: words)
        #expect(starts.count == ps.count)
        // Each paragraph starts where its first word was spoken, give or take
        // the local-rate walk back from the first landmark inside it.
        var expected: TimeInterval = 0
        for (i, p) in ps.enumerated() {
            let start = try? #require(starts[i])
            #expect(abs((start ?? -1) - expected) < 0.6, "paragraph \(i)")
            expected += Double(p.text.split(separator: " ").count) * 0.5 + 1.0
        }
    }

    @Test func noisyRecognitionStillLandsWithinAFewSeconds() {
        let ps = paragraphs(sample)
        let words = speak(ps, dropEvery: 7, misheard: ["mind", "cup", "professor"])
        let starts = TranscriptAligner.paragraphStarts(paragraphs: ps, words: words)
        let matched = starts.compactMap { $0 }
        #expect(matched.count >= 4)
        var expected: TimeInterval = 0
        for (i, p) in ps.enumerated() {
            if let start = starts[i] {
                #expect(abs(start - expected) < 4, "paragraph \(i): \(start) vs \(expected)")
            }
            expected += Double(p.text.split(separator: " ").count) * 0.5 + 1.0
        }
        // Monotonic where present.
        #expect(matched == matched.sorted())
    }

    @Test func unrelatedAudioYieldsNothingRatherThanNonsense() {
        let ps = paragraphs(sample)
        let other = paragraphs([
            "Zen and Taoists have always laughed about Confucius and this is one of their subtle jokes so try to understand it well.",
            "The cataract at Luliang falls from a height of two hundred feet and its foam reaches fifteen miles away from the falls.",
        ])
        let starts = TranscriptAligner.paragraphStarts(paragraphs: ps, words: speak(other))
        #expect(starts.allSatisfy { $0 == nil })
    }
}

@Suite struct TranscriptSentencesTests {

    @Test func splitsOnTerminatorsAndKeepsClosingQuotes() {
        let text = "He said: \"Wait!\" Then he left... Really? Yes."
        let parts = TranscriptSentences.ranges(in: text).map { String(text[$0]) }
        #expect(parts == ["He said: \"Wait!\"", "Then he left...", "Really?", "Yes."])
    }

    @Test func devanagariDandasAndVerseLinesSplit() {
        let text = "अष्टावक्र उवाच।\nतू निर्दोष है॥ यह सूत्र कहता है।"
        let parts = TranscriptSentences.ranges(in: text).map { String(text[$0]) }
        #expect(parts == ["अष्टावक्र उवाच।", "तू निर्दोष है॥", "यह सूत्र कहता है।"])
        let numbered = "बोधोऽहं सुखी भव।। 14।। निःसंगो निष्क्रियोऽसि।"
        #expect(TranscriptSentences.ranges(in: numbered).map { String(numbered[$0]) } == ["बोधोऽहं सुखी भव।। 14।।", "निःसंगो निष्क्रियोऽसि।"])
    }

    @Test func gluedStopsAndUnterminatedTailsAreHandled() {
        let text = "Version 3.5 is out. See e.g. the notes"
        let parts = TranscriptSentences.ranges(in: text).map { String(text[$0]) }
        #expect(parts == ["Version 3.5 is out.", "See e.g. the notes"])
        let quoted = "If a man is asking \"What is light?\" it shows he is blind. Really? yes."
        #expect(TranscriptSentences.ranges(in: quoted).map { String(quoted[$0]) } == ["If a man is asking \"What is light?\" it shows he is blind.", "Really? yes."])
        #expect(TranscriptSentences.ranges(in: "").isEmpty)
        #expect(TranscriptSentences.ranges(in: "no stop").count == 1)
    }

    @Test func indexFollowsCharacterShare() {
        let text = "Short. A much much much longer second sentence here. End."
        #expect(TranscriptSentences.index(atFraction: 0, in: text) == 0)
        #expect(TranscriptSentences.index(atFraction: 0.5, in: text) == 1)
        #expect(TranscriptSentences.index(atFraction: 0.99, in: text) == 2)
        #expect(TranscriptSentences.index(atFraction: 1.5, in: text) == 2)
        #expect(TranscriptSentences.index(atFraction: 0.5, in: "One sentence only") == 0)
    }
}

@Suite struct TranscriptBlocksTests {

    private let sentence = "This is one sentence of roughly sixty characters for the test. "

    @Test func shortParagraphsStayWhole() {
        let text = String(repeating: sentence, count: 5).trimmingCharacters(in: .whitespaces)   // ~310 chars
        #expect(TranscriptBlocks.ranges(in: text).count == 1)
        #expect(TranscriptBlocks.ranges(in: "").isEmpty)
        // One giant sentence cannot be split.
        #expect(TranscriptBlocks.ranges(in: String(repeating: "word ", count: 200)).count == 1)
    }

    @Test func longParagraphsSplitIntoEvenSentenceAlignedBlocks() {
        let text = String(repeating: sentence, count: 15).trimmingCharacters(in: .whitespaces)   // ~900 chars
        let ranges = TranscriptBlocks.ranges(in: text)
        #expect(ranges.count == 3)
        for r in ranges {
            #expect(text[r].hasSuffix("."))
            #expect(text[r].hasPrefix("This"))
        }
        // Contiguous and covering.
        #expect(ranges.first?.lowerBound == text.startIndex)
        #expect(ranges.last?.upperBound == text.endIndex)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            let gap = String(text[a.upperBound..<b.lowerBound])
            #expect(gap.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let shares = TranscriptBlocks.fractions(of: ranges, in: text)
        #expect(shares.first?.start == 0)
        #expect(shares.last?.end == 1)
        #expect(abs(shares[1].start - 1.0 / 3) < 0.05)
    }

    @Test func noTinyRemainderBlock() {
        let text = String(repeating: sentence, count: 8) + "Short end."
        let ranges = TranscriptBlocks.ranges(in: text)
        let lengths = ranges.map { text[$0].count }
        #expect(lengths.allSatisfy { $0 > 100 })
    }

    @Test func anchorsOnBlocksOfOneParagraphCoexistWhenOrdered() {
        let early = TranscriptAnchor(paragraph: 4, time: 100, createdAt: Date(), fraction: 0.2)
        let late = TranscriptAnchor(paragraph: 4, time: 130, createdAt: Date(), fraction: 0.8)
        let both = TranscriptSyncModel.inserting(late, into: [early])
        #expect(both == [early, late])
        // A later block at an earlier time contradicts; the newest wins.
        let wrong = TranscriptAnchor(paragraph: 4, time: 90, createdAt: Date(), fraction: 0.8)
        #expect(TranscriptSyncModel.inserting(wrong, into: [early]) == [wrong])
        // Legacy whole-paragraph anchor replaces one at the same (middle) spot.
        let legacy = TranscriptAnchor(paragraph: 4, time: 115, createdAt: Date())
        #expect(TranscriptSyncModel.inserting(legacy, into: [TranscriptAnchor(paragraph: 4, time: 100, createdAt: Date(), fraction: 0.5)]) == [legacy])
        // Old JSON without the field still decodes.
        let decoded = try? JSONDecoder().decode(TranscriptAnchor.self, from: Data(#"{"paragraph":1,"time":5,"createdAt":0}"#.utf8))
        #expect(decoded?.fraction == nil)
    }

    @Test func fractionMapsThroughTheModel() {
        let base = TranscriptSyncModel(paragraphs: (0..<4).map { Transcript.Paragraph(index: $0, text: String(repeating: "a", count: 100), isEmphasis: false) }, duration: 400)
        #expect(base.time(paragraph: 1, fraction: 0.5) == 150)
        #expect(base.fraction(atTime: 150, inParagraph: 1) == 0.5)
        #expect(base.fraction(atTime: 350, inParagraph: 1) == 1)
        let anchored = base.with(knots: [base.knot(for: TranscriptAnchor(paragraph: 1, time: 250, createdAt: Date(), fraction: 0.25))!])
        #expect(anchored.knots[1].position == 125)
    }
}

@Suite struct AlignmentCatalogTests {

    @Test func wireFormatRoundTripsWithGapsAndTenths() {
        let entry = AlignmentCatalog.Entry(paragraphCount: 5, duration: 5125.04, starts: [0, nil, 12.34, 12.4, nil])
        let encoded = AlignmentCatalog.encode(entry)
        #expect(encoded == "5;51250;0,-,123,1,-")
        let decoded = try? #require(AlignmentCatalog.decode(encoded))
        #expect(decoded?.paragraphCount == 5)
        #expect(decoded?.duration == 5125.0)
        #expect(decoded?.starts == [0, nil, 12.3, 12.4, nil])
        #expect(decoded?.matchedCount == 3)
    }

    @Test func malformedStringsDecodeToNil() {
        #expect(AlignmentCatalog.decode("") == nil)
        #expect(AlignmentCatalog.decode("3;100;0,5") == nil)        // count mismatch
        #expect(AlignmentCatalog.decode("2;100;0,x") == nil)        // bad token
        #expect(AlignmentCatalog.decode("0;100;") != nil)           // empty transcript is still valid
    }

    @Test func entryAppliesOnlyToTheSameSplitAndRecording() {
        let entry = AlignmentCatalog.Entry(paragraphCount: 3, duration: 600, starts: [0, 200, 400])
        #expect(entry.matches(paragraphCount: 3, duration: 601.5))
        #expect(!entry.matches(paragraphCount: 4, duration: 600))
        #expect(!entry.matches(paragraphCount: 3, duration: 610))
    }

    @Test func bundledCatalogEntriesDecodeAndPointAtTranscripts() {
        // Empty until the batch tool has run; every entry it does contain must
        // be for a discourse that exists and has a transcript.
        var checked = 0
        for (id, _) in Catalog.discourseLookup where AlignmentCatalog.hasAlignment(id) {
            let entry = try? #require(AlignmentCatalog.entry(for: id))
            #expect(TranscriptCatalog.hasTranscript(id), Comment(rawValue: id))
            #expect((entry?.matchedCount ?? 0) > 0, Comment(rawValue: id))
            checked += 1
            if checked >= 200 { break }
        }
    }
}
