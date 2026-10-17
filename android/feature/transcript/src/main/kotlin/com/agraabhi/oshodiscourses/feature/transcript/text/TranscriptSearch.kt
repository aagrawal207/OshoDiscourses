package com.agraabhi.oshodiscourses.feature.transcript.text

import java.text.Normalizer

/**
 * Case- and diacritic-insensitive find (iOS `range(of:options: [.caseInsensitive,
 * .diacriticInsensitive])`). Only Latin combining marks fold away; Devanagari matras, virama
 * and nukta distinguish words, the same rule the aligner uses.
 */
object TranscriptSearch {
    /** Queries shorter than this match nothing. */
    const val MINIMUM_QUERY_LENGTH = 2

    fun normalizedQuery(query: String): String? {
        val trimmed = query.trim()
        return if (trimmed.length >= MINIMUM_QUERY_LENGTH) trimmed else null
    }

    fun contains(text: String, query: String): Boolean {
        val needle = Folded.of(query).text
        return needle.isNotEmpty() && Folded.of(text).text.contains(needle)
    }

    /** Every non-overlapping occurrence of [query] in [text], as ranges of the original text. */
    fun matches(text: String, query: String): List<TextSpan> {
        val needle = Folded.of(query).text
        if (needle.isEmpty()) return emptyList()
        val haystack = Folded.of(text)
        val result = mutableListOf<TextSpan>()
        var from = 0
        while (true) {
            val found = haystack.text.indexOf(needle, from)
            if (found < 0) break
            val end = found + needle.length
            result += TextSpan(haystack.origin[found], haystack.originEnd(end - 1, text))
            from = end
        }
        return result
    }

    private class Folded(val text: String, val origin: IntArray) {
        fun originEnd(foldedIndex: Int, source: String): Int {
            val start = origin[foldedIndex]
            return start + Character.charCount(source.codePointAt(start))
        }

        companion object {
            fun of(source: String): Folded {
                val out = StringBuilder(source.length)
                val origin = ArrayList<Int>(source.length)
                var i = 0
                while (i < source.length) {
                    val cp = source.codePointAt(i)
                    val decomposed = Normalizer.normalize(String(Character.toChars(cp)), Normalizer.Form.NFD)
                    for (ch in decomposed) {
                        if (ch in '\u0300'..'\u036F') continue
                        for (lower in ch.lowercase()) {
                            out.append(lower)
                            origin += i
                        }
                    }
                    i += Character.charCount(cp)
                }
                return Folded(out.toString(), origin.toIntArray())
            }
        }
    }
}
