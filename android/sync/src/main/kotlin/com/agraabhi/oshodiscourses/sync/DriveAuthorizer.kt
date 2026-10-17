package com.agraabhi.oshodiscourses.sync

/** Grants Drive app-data access tokens. Only an interactive request may show consent UI. */
internal interface DriveAuthorizer {
    suspend fun authorize(interactive: Boolean): AuthOutcome

    /** Drops a token Drive rejected, so the next [authorize] mints a fresh one. */
    suspend fun clearToken(token: String)

    /** Withdraws the app's grant from the Google account. False if Google could not be reached. */
    suspend fun revoke(accountName: String?): Boolean
}

internal sealed interface AuthOutcome {
    data class Granted(val accessToken: String, val accountName: String?) : AuthOutcome

    /** The user must consent first, or declined. */
    data object NeedsConsent : AuthOutcome

    data class Failed(val message: String, val offline: Boolean) : AuthOutcome
}
