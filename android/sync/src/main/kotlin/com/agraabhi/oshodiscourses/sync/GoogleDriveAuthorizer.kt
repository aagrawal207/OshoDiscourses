package com.agraabhi.oshodiscourses.sync

import android.accounts.Account
import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.auth.api.identity.RevokeAccessRequest
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume

/**
 * Google Identity Services authorization for the app-data scope only. Consent runs through the
 * foreground activity's result registry, so `:app` needs no `onActivityResult` plumbing.
 */
internal class GoogleDriveAuthorizer(
    context: Context,
    private val activityProvider: () -> Activity?,
) : DriveAuthorizer {
    private val client = Identity.getAuthorizationClient(context.applicationContext)
    private val scope = Scope(DriveApi.APP_DATA_SCOPE)

    override suspend fun authorize(interactive: Boolean): AuthOutcome {
        val request = AuthorizationRequest.builder().setRequestedScopes(listOf(scope)).build()
        val result = try {
            client.authorize(request).await()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return failure(e)
        }
        if (!result.hasResolution()) return granted(result)
        if (!interactive) return AuthOutcome.NeedsConsent
        val pendingIntent = result.pendingIntent ?: return AuthOutcome.NeedsConsent
        val activity = activityProvider() as? ComponentActivity ?: return AuthOutcome.NeedsConsent
        val consent = withContext(Dispatchers.Main) { launchConsent(activity, pendingIntent) }
        if (consent.resultCode != Activity.RESULT_OK) return AuthOutcome.NeedsConsent
        return try {
            granted(client.getAuthorizationResultFromIntent(consent.data))
        } catch (e: ApiException) {
            failure(e)
        }
    }

    override suspend fun clearToken(token: String) {
        runCatchingAuth { client.clearToken(ClearTokenRequest.builder().setToken(token).build()).await() }
    }

    override suspend fun revoke(accountName: String?): Boolean {
        if (accountName == null) return false
        val request = RevokeAccessRequest.builder()
            .setAccount(Account(accountName, GOOGLE_ACCOUNT_TYPE))
            .setScopes(listOf(scope))
            .build()
        return runCatchingAuth { client.revokeAccess(request).await() }
    }

    private suspend fun launchConsent(activity: ComponentActivity, pendingIntent: PendingIntent): ActivityResult =
        suspendCancellableCoroutine { continuation ->
            // Registering without a lifecycle owner is allowed after onCreate; the key must be unique.
            val key = "osho.drive.consent.${requestCounter.incrementAndGet()}"
            lateinit var launcher: ActivityResultLauncher<IntentSenderRequest>
            launcher = activity.activityResultRegistry.register(
                key,
                ActivityResultContracts.StartIntentSenderForResult(),
            ) { result ->
                launcher.unregister()
                if (continuation.isActive) continuation.resume(result)
            }
            continuation.invokeOnCancellation { launcher.unregister() }
            try {
                launcher.launch(IntentSenderRequest.Builder(pendingIntent).build())
            } catch (_: RuntimeException) {
                launcher.unregister()
                continuation.resume(ActivityResult(Activity.RESULT_CANCELED, null))
            }
        }

    @Suppress("DEPRECATION")
    private fun granted(result: AuthorizationResult): AuthOutcome {
        val token = result.accessToken ?: return AuthOutcome.NeedsConsent
        // The account name is the only way to revoke later; GoogleSignInAccount is its sole carrier.
        return AuthOutcome.Granted(token, result.toGoogleSignInAccount()?.account?.name)
    }

    private fun failure(e: Exception): AuthOutcome {
        val code = (e as? ApiException)?.statusCode
        return when (code) {
            CommonStatusCodes.CANCELED -> AuthOutcome.NeedsConsent
            CommonStatusCodes.NETWORK_ERROR -> AuthOutcome.Failed(SyncMessages.OFFLINE, offline = true)
            else -> AuthOutcome.Failed(SyncMessages.CANNOT_CONNECT, offline = false)
        }
    }

    private suspend fun runCatchingAuth(block: suspend () -> Unit): Boolean = try {
        block()
        true
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        false
    }

    private companion object {
        const val GOOGLE_ACCOUNT_TYPE = "com.google"
        val requestCounter = AtomicInteger()
    }
}
