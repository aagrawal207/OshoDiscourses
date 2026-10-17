package com.agraabhi.oshodiscourses.feature.transcript

import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.currentStateAsState
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.domain.AppServices
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** The transcript reader for one discourse, presented as a sheet over the player. */
@Serializable
data class TranscriptRoute(val discourseID: String) : NavKey

/**
 * Lyrics-style reader with highlight, auto-follow, anchors and search (iOS `TranscriptView`).
 * [pageURL] is the discourse's oshoworld.com page; the link items show only when it is set.
 */
@Composable
fun TranscriptScreen(
    discourseID: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    pageURL: String? = null,
    showsHandle: Boolean = true,
) {
    val services = LocalAppServices.current
    val vm = viewModel(key = "transcript:$discourseID") { transcriptViewModel(discourseID, services) }
    // Each presentation reloads, as the iOS sheet does; a configuration change keeps the state.
    var started by rememberSaveable(discourseID) { androidx.compose.runtime.mutableStateOf(false) }
    LaunchedEffect(vm) {
        if (!started) {
            started = true
            vm.start()
        }
    }
    TranscriptContentScreen(vm, onDismiss, modifier, pageURL, showsHandle)
}

internal fun transcriptViewModel(discourseID: String, services: AppServices) = TranscriptViewModel(
    discourseID = discourseID,
    catalog = services.catalog,
    transcripts = services.transcripts,
    transcriptState = services.transcriptState,
    player = services.player,
    settings = services.settings,
)

@Composable
internal fun TranscriptContentScreen(
    vm: TranscriptViewModel,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    pageURL: String? = null,
    showsHandle: Boolean = true,
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val uriHandler = LocalUriHandler.current
    val scope = rememberCoroutineScope()

    fun copyText(text: String) {
        scope.launch { clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Transcript", text))) }
    }

    fun share(text: String) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    LaunchedEffect(vm) {
        vm.effects.collect { effect ->
            when (effect) {
                is TranscriptEffect.Copy -> copyText(effect.text)
                is TranscriptEffect.Share -> runCatching { share(effect.text) }
            }
        }
    }
    KeepScreenOnWhilePlaying(state.isPlayingThis && state.isPlaying)

    BackHandler(enabled = state.isSelecting && state.textSelection == null, onBack = vm::stopSelecting)
    BackHandler(enabled = state.isSearching && state.textSelection == null, onBack = vm::cancelSearch)

    Box(modifier.fillMaxSize().background(Osho.colors.systemBackground)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            if (showsHandle) SheetHandle(Modifier.align(Alignment.CenterHorizontally))
            TranscriptToolbar(state, vm, pageURL, onDismiss, onOpenURL = { runCatching { uriHandler.openUri(it) } })
            AnimatedVisibility(
                visible = state.isSearching,
                enter = fadeIn(tween(200)) + expandVertically(tween(200)),
                exit = fadeOut(tween(200)) + shrinkVertically(tween(200)),
            ) {
                TranscriptSearchBar(state, vm)
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                Body(state, vm, pageURL, onOpenURL = { runCatching { uriHandler.openUri(it) } })
                Toast(state.toast, Modifier.align(Alignment.TopCenter))
            }
            when {
                state.isSelecting -> TranscriptSelectionBar(state, vm)
                state.isPlayingThis && state.isLoaded -> TranscriptTransportBar(state, vm)
                else -> androidx.compose.foundation.layout.Spacer(Modifier.windowInsetsPadding(WindowInsets.navigationBars))
            }
        }

        AnimatedVisibility(
            visible = state.textSelection != null,
            enter = slideInVertically(tween(350)) { it },
            exit = slideOutVertically(tween(300)) { it } + fadeOut(tween(300)),
        ) {
            val item = state.textSelection
            if (item != null) {
                BackHandler(onBack = vm::closeTextSelection)
                TranscriptTextSelectionScreen(
                    item = item,
                    fontSize = state.fontSize,
                    onCopyAll = ::copyText,
                    onShare = { runCatching { share(it) } },
                    onDone = vm::closeTextSelection,
                )
            }
        }
    }
}

@Composable
private fun Body(state: TranscriptUiState, vm: TranscriptViewModel, pageURL: String?, onOpenURL: (String) -> Unit) {
    when (val content = state.content) {
        is TranscriptContent.Loaded -> TranscriptReader(state, vm)
        TranscriptContent.Loading -> Column(
            Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            CircularProgressIndicator(color = Osho.colors.secondaryLabel, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
            Text("Loading transcript…", style = Osho.typography.body, color = Osho.colors.secondaryLabel)
        }
        is TranscriptContent.Failed -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            EmptyState(title = "Transcript unavailable", description = content.message) {
                if (content.canRetry) {
                    Text(
                        "Try Again",
                        style = Osho.typography.body,
                        fontWeight = FontWeight.SemiBold,
                        color = Osho.colors.onAccent,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(Osho.colors.accent)
                            .clickable(role = Role.Button, onClick = vm::retry)
                            .padding(horizontal = 20.dp, vertical = 10.dp),
                    )
                }
                if (pageURL != null) {
                    Text(
                        "Open on oshoworld.com",
                        style = Osho.typography.body,
                        color = Osho.colors.accent,
                        modifier = Modifier.clickable(role = Role.Button) { onOpenURL(pageURL) }.padding(8.dp),
                    )
                }
            }
        }
        TranscriptContent.NotPublished -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            EmptyState(title = "No transcript yet", description = "oshoworld.com has not published a transcript for this discourse.")
        }
    }
}

@Composable
private fun Toast(text: String?, modifier: Modifier) {
    AnimatedVisibility(
        visible = text != null,
        enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it },
        exit = fadeOut(tween(200)) + slideOutVertically(tween(200)) { -it },
        modifier = modifier.padding(top = 8.dp),
    ) {
        // Holds the last text while the exit animation runs.
        var shown by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(text.orEmpty()) }
        if (text != null) shown = text
        ToastCapsule(shown)
    }
}

/** Reading along means no touches for minutes, so hold the screen on only while this plays in the foreground. */
@Composable
private fun KeepScreenOnWhilePlaying(playing: Boolean) {
    val view = LocalView.current
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val keepOn = playing && lifecycle.isAtLeast(Lifecycle.State.RESUMED)
    DisposableEffect(view, keepOn) {
        view.keepScreenOn = keepOn
        onDispose { view.keepScreenOn = false }
    }
}
