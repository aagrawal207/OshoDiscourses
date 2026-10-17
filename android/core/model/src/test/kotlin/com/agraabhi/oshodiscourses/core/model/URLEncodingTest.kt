package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class URLEncodingTest {
    @Test
    fun requestURLEncodesSpacesAsPercent20AndKeepsURLStructure() {
        assertThat(URLEncoding.requestURL("https://www.oshoworld.com/wp-content/uploads/2020/11/Hindi Audio/OSHO-Maha_Geeta_01.mp3"))
            .isEqualTo("https://www.oshoworld.com/wp-content/uploads/2020/11/Hindi%20Audio/OSHO-Maha_Geeta_01.mp3")
    }

    @Test
    fun requestURLKeepsQueryCharactersButEncodesPercentAndHash() {
        assertThat(URLEncoding.requestURL("https://a.b/x?y=1&z=(2)#f 100%")).isEqualTo("https://a.b/x?y=1&z=(2)%23f%20100%25")
    }

    @Test
    fun emptyRequestURLIsNull() {
        assertThat(URLEncoding.requestURL("")).isNull()
    }

    @Test
    fun pathEncodingEscapesQuestionMarkAndNonASCIIAsUTF8() {
        assertThat(URLEncoding.encodePath("A & B – 01?/é.mp3")).isEqualTo("A%20&%20B%20%E2%80%93%2001%3F/%C3%A9.mp3")
    }

    @Test
    fun pathEncodingEscapesDevanagari() {
        assertThat(URLEncoding.encodePath("ओशो")).isEqualTo("%E0%A4%93%E0%A4%B6%E0%A5%8B")
    }
}
