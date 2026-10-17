package com.agraabhi.oshodiscourses.core.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import kotlin.math.roundToInt

/** iOS 26 popover metrics, measured from the reference screens. */
private val PopoverCorner = 28.dp
private val ArrowWidth = 22.dp
private val ArrowHeight = 9.dp
private val PopoverMargin = 8.dp
private val PopoverSideMargin = 16.dp

private enum class ArrowEdge { BOTTOM, TOP, LEFT, RIGHT }

/**
 * iOS `.popover` kept as a popover on iPhone (ui-style.md §8): a rounded card with an arrow at
 * [anchor], which is in this host's coordinates. UIKit puts it above the control, or beside it
 * when the arrow would land in a corner. Drawn in-window so it layers with the player.
 */
@Composable
fun AnchoredPopover(
    visible: Boolean,
    anchor: Rect?,
    onDismissRequest: () -> Unit,
    width: Dp,
    title: String,
    content: @Composable () -> Unit,
) {
    val transition = remember { MutableTransitionState(false) }
    transition.targetState = visible && anchor != null
    // The card keeps its place while it fades out after the anchor is cleared.
    var lastAnchor by remember { mutableStateOf(Rect.Zero) }
    if (anchor != null) lastAnchor = anchor
    if (!transition.currentState && !transition.targetState) return
    val dismiss by rememberUpdatedState(onDismissRequest)
    BackHandler(enabled = visible) { dismiss() }

    Box(Modifier.fillMaxSize()) {
        if (visible) {
            Box(Modifier.fillMaxSize().clearAndSetSemantics {}.pointerInput(Unit) { detectTapGestures { dismiss() } })
        }
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val density = LocalDensity.current
            var cardHeight by remember { mutableIntStateOf(0) }
            val placement = with(density) {
                place(
                    anchor = lastAnchor,
                    cardWidth = width.toPx(),
                    cardHeight = cardHeight.toFloat(),
                    hostWidth = constraints.maxWidth.toFloat(),
                    hostHeight = constraints.maxHeight.toFloat(),
                    top = WindowInsets.statusBars.getTop(this) + PopoverMargin.toPx(),
                    bottom = constraints.maxHeight - WindowInsets.navigationBars.getBottom(this) - PopoverMargin.toPx(),
                )
            }
            val shape = PopoverShape(placement.edge, placement.arrowAt)
            val origin = when (placement.edge) {
                ArrowEdge.BOTTOM -> TransformOrigin(0.5f, 1f)
                ArrowEdge.TOP -> TransformOrigin(0.5f, 0f)
                ArrowEdge.LEFT -> TransformOrigin(0f, 0.5f)
                ArrowEdge.RIGHT -> TransformOrigin(1f, 0.5f)
            }
            AnimatedVisibility(
                transition,
                modifier = Modifier.offset { IntOffset(placement.x.roundToInt(), placement.y.roundToInt()) },
                enter = fadeIn(tween(200)) + scaleIn(tween(200), initialScale = 0.85f, transformOrigin = origin),
                exit = fadeOut(tween(150)) + scaleOut(tween(150), targetScale = 0.9f, transformOrigin = origin),
            ) {
                ProvideElevatedSurfaces {
                    val arrowPad = when (placement.edge) {
                        ArrowEdge.BOTTOM -> Modifier.padding(bottom = ArrowHeight)
                        ArrowEdge.TOP -> Modifier.padding(top = ArrowHeight)
                        ArrowEdge.LEFT -> Modifier.padding(start = ArrowHeight)
                        ArrowEdge.RIGHT -> Modifier.padding(end = ArrowHeight)
                    }
                    Box(
                        Modifier
                            .dropShadow(shape, Shadow(radius = 24.dp, color = Color.Black.copy(alpha = 0.18f)))
                            .clip(shape)
                            .background(Osho.colors.secondarySystemGroupedBackground)
                            .then(arrowPad)
                            .semantics { paneTitle = title },
                    ) {
                        Box(Modifier.width(width).onSizeChanged { cardHeight = it.height }) { content() }
                    }
                }
            }
        }
    }
}

private class Placement(val x: Float, val y: Float, val edge: ArrowEdge, val arrowAt: Float)

/** Above the anchor when the arrow clears the corners; otherwise beside it, vertically centred. */
private fun Density.place(
    anchor: Rect,
    cardWidth: Float,
    cardHeight: Float,
    hostWidth: Float,
    hostHeight: Float,
    top: Float,
    bottom: Float,
): Placement {
    val margin = PopoverSideMargin.toPx()
    val arrowH = ArrowHeight.toPx()
    val gap = 2.dp.toPx()
    // UIKit keeps the arrow well clear of the rounded corners before it gives up and moves aside.
    val minArrow = PopoverCorner.toPx() + ArrowWidth.toPx()
    val x = (anchor.center.x - cardWidth / 2).coerceIn(margin, (hostWidth - cardWidth - margin).coerceAtLeast(margin))
    val arrowX = anchor.center.x - x
    val aboveY = anchor.top - gap - arrowH - cardHeight
    if (arrowX in minArrow..(cardWidth - minArrow)) {
        return if (aboveY >= top || anchor.bottom + gap + arrowH + cardHeight > bottom) {
            Placement(x, aboveY.coerceAtLeast(0f), ArrowEdge.BOTTOM, arrowX)
        } else {
            Placement(x, anchor.bottom + gap, ArrowEdge.TOP, arrowX)
        }
    }
    val y = (anchor.center.y - cardHeight / 2).coerceIn(top, (bottom - cardHeight).coerceAtLeast(top))
    val arrowY = (anchor.center.y - y).coerceIn(minArrow, (cardHeight - minArrow).coerceAtLeast(minArrow))
    // Beside the anchor the card still keeps its screen margin, letting the arrow reach into the control.
    val sideMargin = PopoverMargin.toPx() + 2.dp.toPx()
    return if (anchor.center.x < hostWidth / 2) {
        Placement((anchor.right + gap).coerceAtMost(hostWidth - sideMargin - arrowH - cardWidth), y, ArrowEdge.LEFT, arrowY)
    } else {
        Placement((anchor.left - gap - arrowH - cardWidth).coerceAtLeast(sideMargin), y, ArrowEdge.RIGHT, arrowY)
    }
}

/** A rounded card plus a triangular arrow on [edge], centred [arrowAt] px along that edge. */
private data class PopoverShape(val edge: ArrowEdge, val arrowAt: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val h = with(density) { ArrowHeight.toPx() }
        val half = with(density) { ArrowWidth.toPx() / 2 }
        val r = with(density) { PopoverCorner.toPx() }
        val card = when (edge) {
            ArrowEdge.BOTTOM -> Rect(0f, 0f, size.width, size.height - h)
            ArrowEdge.TOP -> Rect(0f, h, size.width, size.height)
            ArrowEdge.LEFT -> Rect(h, 0f, size.width, size.height)
            ArrowEdge.RIGHT -> Rect(0f, 0f, size.width - h, size.height)
        }
        val body = Path().apply { addRoundRect(RoundRect(card, CornerRadius(r))) }
        val arrow = Path().apply {
            when (edge) {
                ArrowEdge.BOTTOM -> { moveTo(arrowAt - half, card.bottom); lineTo(arrowAt, size.height); lineTo(arrowAt + half, card.bottom) }
                ArrowEdge.TOP -> { moveTo(arrowAt - half, card.top); lineTo(arrowAt, 0f); lineTo(arrowAt + half, card.top) }
                ArrowEdge.LEFT -> { moveTo(card.left, arrowAt - half); lineTo(0f, arrowAt); lineTo(card.left, arrowAt + half) }
                ArrowEdge.RIGHT -> { moveTo(card.right, arrowAt - half); lineTo(size.width, arrowAt); lineTo(card.right, arrowAt + half) }
            }
            close()
        }
        return Outline.Generic(Path.combine(PathOperation.Union, body, arrow))
    }
}
