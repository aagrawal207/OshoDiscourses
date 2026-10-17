package com.agraabhi.oshodiscourses.feature.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptTiming
import com.agraabhi.oshodiscourses.core.testing.FakeTranscriptRepository
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptSyncModel
import kotlinx.coroutines.awaitCancellation

/** Made-up neutral text for reader tests and screenshots. */
object TranscriptFixtures {
    private val english = listOf(
        true to "A visitor asked, \"Why does the river never stop?\"",
        false to "The river does not ask where it is going. It simply moves, and in moving it finds the sea. " +
            "Watch it for a while and you will see that it never hurries. Why? Because there is nowhere to arrive.",
        false to "A bird sings at dawn without wondering who is listening. The song is complete in itself. " +
            "Nothing is added by an audience, and nothing is lost without one.",
        false to "Sit by the window in the morning and let the light come in slowly. " +
            "Do not try to hold it or name it. Just let it fill the room.",
        false to "The mind wants a reason for everything. The tree grows without a reason, the clouds pass without a plan, " +
            "and still the whole valley is green.",
        false to "When you walk, simply walk. When you eat, simply eat. That is enough for today.",
        false to "Someone once carried a lamp through the market at noon. People laughed at him. " +
            "He said he was looking for a person who was fully awake.",
        false to "The question and the answer are both small. What matters is the silence between them, " +
            "the pause where nothing needs to be said at all.",
        false to "Breathe in, and feel the air arrive. Breathe out, and let it go. " +
            "The breath has been your companion every moment, and you rarely notice it.",
        false to "In the evening the market grows quiet. The shops close one by one, and the street belongs to the wind again.",
        false to "Tomorrow the river will still be moving. The bird will still sing. Nothing needs your permission to be alive.",
    )

    /** Uses the sample English discourse id so the catalog title resolves. */
    val englishTranscript = Transcript(
        discourseID = SampleCatalog.firstDiscourse.id,
        sourceID = "fixture-en",
        fetchedAt = 0,
        paragraphs = english.mapIndexed { i, (emphasis, text) -> Transcript.Paragraph(i, text, emphasis) },
    )

    private val hindi = listOf(
        true to "एक यात्री ने पूछा, नदी कहाँ जाती है?",
        false to "नदी बहती रहती है। वह कभी नहीं रुकती। सुबह की धूप उस पर चमकती है, और हवा धीरे से चलती है।",
        false to "पक्षी सुबह गाता है। उसे कोई चिंता नहीं होती। गीत अपने आप में पूरा है।",
        false to "खिड़की के पास बैठो और रोशनी को आने दो। उसे पकड़ने की कोशिश मत करो। बस उसे कमरे में भर जाने दो।",
        false to "शाम को बाज़ार शांत हो जाता है। दुकानें एक एक करके बंद होती हैं। गली फिर से हवा की हो जाती है।",
        false to "कल भी नदी बहेगी। पक्षी फिर गाएगा। जीवन को किसी की अनुमति नहीं चाहिए।",
    )

    val hindiTranscript = Transcript(
        discourseID = SampleCatalog.hindiDiscourse.id,
        sourceID = "fixture-hi",
        fetchedAt = 0,
        paragraphs = hindi.mapIndexed { i, (emphasis, text) -> Transcript.Paragraph(i, text, emphasis) },
    )

    fun repository(failure: com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException? = null) = FakeTranscriptRepository(
        transcripts = mapOf(englishTranscript.discourseID to englishTranscript, hindiTranscript.discourseID to hindiTranscript),
        failure = failure,
    )
}

/** Real sync-model timing over the fake, optionally as shipped alignment so the sentence highlight shows. */
class ModelTimingRepository(
    private val base: TranscriptRepository,
    private val aligned: Boolean = false,
    private val hangs: Boolean = false,
) : TranscriptRepository by base {
    override suspend fun transcript(discourseID: String, allowsCellular: Boolean): Transcript {
        if (hangs) awaitCancellation()
        return base.transcript(discourseID, allowsCellular)
    }

    override fun timing(transcript: Transcript, duration: Double, state: TranscriptDiscourseState): TranscriptTiming {
        val estimate = TranscriptSyncModel(transcript.paragraphs, duration)
        val starts = if (aligned) transcript.paragraphs.indices.map { estimate.startTime(it) } else null
        return TranscriptSyncModel.build(transcript.paragraphs, duration, state.anchors, starts, TimingSource.SHIPPED_ALIGNMENT)
    }
}
