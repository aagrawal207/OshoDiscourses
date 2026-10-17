package com.agraabhi.oshodiscourses.core.testing

/** A settable epoch-millisecond clock shared by fakes that stamp dates. */
class FakeClock(var nowMillis: Long = 1_760_000_000_000L) {
    fun advance(millis: Long) {
        nowMillis += millis
    }
}
