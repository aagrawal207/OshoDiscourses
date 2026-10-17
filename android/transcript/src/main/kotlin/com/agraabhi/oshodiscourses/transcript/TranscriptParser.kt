package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript

/**
 * Turns the light HTML oshoworld serves as a discourse "description" into paragraphs
 * (iOS `TranscriptParser`). The markup is a flat run of text with `<br>`/CRLF breaks, block
 * emphasis via `<strong>`, `<q>` or the site's own `<cr>` tag, an occasional `<i>` and a trailing `<hr>`.
 */
object TranscriptParser {
    /** Tags wrapping a quoted block (question or sutra); consecutive lines inside one stay together. */
    private val emphasisTags = setOf("strong", "b", "q", "cr", "blockquote")

    /** Tags that end a line. Every other tag is stripped, keeping its text. */
    private val breakTags = setOf("br", "hr", "p", "div", "li", "tr", "h1", "h2", "h3", "h4")

    private const val EMPHASIS_OPEN = '\u0001'
    private const val EMPHASIS_CLOSE = '\u0002'

    private val namedEntities = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to "\u00A0",
        "hellip" to "\u2026", "mdash" to "\u2014", "ndash" to "\u2013",
        "lsquo" to "\u2018", "rsquo" to "\u2019", "ldquo" to "\u201C", "rdquo" to "\u201D",
    )

    fun paragraphs(html: String): List<Transcript.Paragraph> {
        val marked = decodeEntities(replaceTags(html))
        val result = mutableListOf<Transcript.Paragraph>()
        val pendingEmphasis = mutableListOf<String>()
        val current = StringBuilder()
        var emphasized = 0
        var plain = 0
        var inEmphasis = false
        // Consecutive line breaks since the last text or tag boundary; two in a row is a blank
        // line, which separates one quoted block from the next.
        var blankRun = 0

        fun flushEmphasis() {
            if (pendingEmphasis.isEmpty()) return
            result += Transcript.Paragraph(result.size, pendingEmphasis.joinToString("\n"), isEmphasis = true)
            pendingEmphasis.clear()
        }

        fun endSegment() {
            val text = current.toString().trim()
            if (text.isNotEmpty()) {
                if (emphasized > 0 && emphasized >= plain) {
                    pendingEmphasis += text
                } else {
                    flushEmphasis()
                    result += Transcript.Paragraph(result.size, text, isEmphasis = false)
                }
            }
            current.clear()
            emphasized = 0
            plain = 0
        }

        for (ch in marked) {
            when (ch) {
                '\n' -> if (plain + emphasized > 0) {
                    endSegment()
                    blankRun = 1
                } else {
                    blankRun += 1
                    if (blankRun >= 2) flushEmphasis()
                }
                // A block boundary inside a line ("भगवान,<cr>question…") starts a new paragraph;
                // the site never uses these tags inline.
                EMPHASIS_OPEN, EMPHASIS_CLOSE -> {
                    if (plain + emphasized > 0) endSegment()
                    inEmphasis = ch == EMPHASIS_OPEN
                    blankRun = 0
                }
                else -> {
                    current.append(ch)
                    if (!ch.isWhitespace()) {
                        if (inEmphasis) emphasized += 1 else plain += 1
                    }
                }
            }
        }
        endSegment()
        flushEmphasis()
        return result
    }

    /** Replaces tags with line breaks or emphasis sentinels, drops the rest, and normalises CR/CRLF. */
    private fun replaceTags(html: String): String {
        val out = StringBuilder(html.length)
        var i = 0
        while (i < html.length) {
            val ch = html[i]
            val close = if (ch == '<') html.indexOf('>', i + 1) else -1
            when {
                close >= 0 -> {
                    val isClosing = i + 1 < close && html[i + 1] == '/'
                    val nameStart = if (isClosing) i + 2 else i + 1
                    var nameEnd = nameStart
                    while (nameEnd < close && html[nameEnd].isLetterOrDigit()) nameEnd++
                    val name = html.substring(nameStart, nameEnd).lowercase()
                    if (name in emphasisTags) {
                        out.append(if (isClosing) EMPHASIS_CLOSE else EMPHASIS_OPEN)
                    } else if (name in breakTags) {
                        out.append('\n')
                    }
                    i = close + 1
                }
                ch == '\r' -> {
                    out.append('\n')
                    i += if (i + 1 < html.length && html[i + 1] == '\n') 2 else 1
                }
                else -> {
                    out.append(ch)
                    i += 1
                }
            }
        }
        return out.toString()
    }

    /** The source is raw UTF-8, so only structural entities and numeric references need decoding. */
    fun decodeEntities(text: String): String {
        if ('&' !in text) return text
        val out = StringBuilder(text.length)
        var i = 0
        while (i < text.length) {
            val ch = text[i]
            val semi = if (ch == '&') text.indexOf(';', i).takeIf { it >= 0 && it - i < 12 } else null
            val replacement = semi?.let { decodeEntity(text.substring(i + 1, it)) }
            if (semi != null && replacement != null) {
                out.append(replacement)
                i = semi + 1
            } else {
                out.append(ch)
                i += 1
            }
        }
        return out.toString()
    }

    private fun decodeEntity(body: String): String? {
        val code = when {
            body.startsWith("#x") || body.startsWith("#X") -> body.drop(2).toUIntOrNull(16)
            body.startsWith("#") -> body.drop(1).toUIntOrNull()
            else -> return namedEntities[body]
        } ?: return null
        val scalar = code.toLong()
        if (scalar > 0x10FFFF || scalar in 0xD800..0xDFFF) return null
        return String(Character.toChars(scalar.toInt()))
    }
}
