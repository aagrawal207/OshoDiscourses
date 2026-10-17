package com.agraabhi.oshodiscourses.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.FilterChipStyle
import com.agraabhi.oshodiscourses.core.ui.components.LargeTitlePage
import com.agraabhi.oshodiscourses.core.ui.components.OshoFilterChip
import com.agraabhi.oshodiscourses.core.ui.components.SeriesThumbnail
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import kotlinx.serialization.Serializable

internal const val FILTER_BAR_TAG = "libraryFilterBar"

/** The Library tab's root. */
@Serializable
data object LibraryRoute : NavKey

/** Every series with search, filter chips and sort (iOS `LibraryView`). */
@Composable
fun LibraryScreen(
    onOpenSeries: (seriesID: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val services = LocalAppServices.current
    val viewModel = viewModel { LibraryViewModel(services.catalog, services.downloads, services.settings) }
    val state by viewModel.state.collectAsStateWithLifecycle()

    LargeTitlePage(title = "Library", background = Osho.colors.systemBackground, modifier = modifier) {
        item(key = "search", contentType = "search") {
            SearchField(
                value = viewModel.query,
                onValueChange = viewModel::updateQuery,
                placeholder = "Search by name or topic",
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        item(key = "chips", contentType = "chips") {
            FilterSortBar(
                state = state,
                onFilter = viewModel::toggleFilter,
                onSort = viewModel::chooseSort,
                modifier = Modifier.padding(top = 8.dp, bottom = 8.dp),
            )
        }
        items(state.series, key = { it.id }, contentType = { "row" }) { series ->
            SeriesRow(series, viewModel.coverURL(series.id)) { onOpenSeries(series.id) }
            HorizontalDivider(thickness = 0.5.dp, color = Osho.colors.separator, modifier = Modifier.padding(start = 72.dp))
        }
        if (state.showsNoResults) {
            item(key = "noResults", contentType = "noResults") { NoResults(state.query) }
        }
    }
}

/** iOS 26 `.searchable` field: a filled capsule with a magnifier, placeholder and clear button. */
@Composable
private fun SearchField(value: String, onValueChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    val focus = LocalFocusManager.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = Osho.typography.body.copy(color = colors.label),
        cursorBrush = SolidColor(colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
        modifier = modifier.fillMaxWidth().semantics { contentDescription = placeholder },
        decorationBox = { field ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clip(CircleShape)
                    .background(colors.tertiarySystemFill)
                    .padding(start = 12.dp, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Rounded.Search, contentDescription = null, tint = colors.secondaryLabel, modifier = Modifier.size(scaled(22.dp)))
                Box(Modifier.weight(1f).padding(start = 8.dp, top = 10.dp, bottom = 10.dp)) {
                    if (value.isEmpty()) {
                        Text(placeholder, style = Osho.typography.body, color = colors.placeholderText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    field()
                }
                if (value.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .clickable(role = Role.Button) { onValueChange("") }
                            .semantics { contentDescription = "Clear text" },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Rounded.Cancel, contentDescription = null, tint = colors.tertiaryLabel, modifier = Modifier.size(20.dp))
                    }
                } else {
                    Box(Modifier.size(width = 8.dp, height = 1.dp))
                }
            }
        },
    )
}

@Composable
private fun FilterSortBar(
    state: LibraryUiState,
    onFilter: (SeriesFilter) -> Unit,
    onSort: (SortField) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyRow(
        modifier = modifier.fillMaxWidth().testTag(FILTER_BAR_TAG),
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items(state.filters, key = { it.label }) { filter ->
            OshoFilterChip(
                label = filter.label,
                selected = filter == state.activeFilter,
                onClick = { onFilter(filter) },
                style = FilterChipStyle.COMPACT,
            )
        }
        item(key = "sort") { SortChip(state.sort, onSort) }
    }
}

@Composable
private fun SortChip(sort: SortOrder, onSort: (SortField) -> Unit) {
    val colors = Osho.colors
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .background(colors.tertiarySystemFill)
                .clickable(role = Role.DropdownList) { expanded = true }
                .semantics {
                    contentDescription = "Sort"
                    stateDescription = sort.accessibilityValue
                }
                .padding(horizontal = 10.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // A Menu label's `.secondary` resolves against the tint on iOS, so it reads as faded accent.
            Icon(
                if (sort.ascending) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown,
                contentDescription = null,
                tint = colors.accentSecondary,
                modifier = Modifier.size(scaled(12.dp)),
            )
            Text(sort.field.label, style = Osho.typography.caption, fontWeight = FontWeight.Medium, color = colors.accentSecondary)
        }
        ProvideElevatedSurfaces {
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
                shape = RoundedCornerShape(16.dp),
                containerColor = Osho.colors.secondarySystemGroupedBackground,
                shadowElevation = 12.dp,
                tonalElevation = 0.dp,
                modifier = Modifier.widthIn(min = 180.dp),
            ) {
                SortField.entries.forEach { field ->
                    DropdownMenuItem(
                        text = { Text(field.label, style = Osho.typography.body, color = Osho.colors.label) },
                        trailingIcon = if (field == sort.field) {
                            {
                                Icon(
                                    if (sort.ascending) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown,
                                    contentDescription = null,
                                    tint = Osho.colors.label,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        } else {
                            null
                        },
                        onClick = {
                            expanded = false
                            onSort(field)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun SeriesRow(series: SeriesInfo, coverURL: String?, onClick: () -> Unit) {
    val colors = Osho.colors
    val type = Osho.typography
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SeriesThumbnail(series.name, 48.dp, coverURL = coverURL)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(series.name, style = type.subheadline, color = colors.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${series.count} discourses", style = type.caption2, color = colors.secondaryLabel)
                Text("·", style = type.caption2, color = colors.quaternaryLabel)
                Text(if (series.language == Language.HINDI) "Hindi" else "English", style = type.caption2, color = colors.secondaryLabel)
            }
        }
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.quaternaryLabel, modifier = Modifier.size(18.dp))
    }
}

/** System `ContentUnavailableView.search(text:)`. */
@Composable
private fun NoResults(query: String) {
    val colors = Osho.colors
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 40.dp, start = 16.dp, end = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Rounded.Search, contentDescription = null, tint = colors.secondaryLabel, modifier = Modifier.size(scaled(48.dp)))
        Text(
            "No Results for “$query”",
            fontSize = 22.sp,
            lineHeight = 28.sp,
            fontWeight = FontWeight.Bold,
            color = colors.label,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 12.dp).widthIn(max = 320.dp),
        )
        Text(
            "Check the spelling or try a new search.",
            style = Osho.typography.subheadline,
            color = colors.secondaryLabel,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp).widthIn(max = 320.dp),
        )
    }
}

/** SF Symbols sized by a text style grow with Dynamic Type; this keeps icons in step with text. */
@Composable
internal fun scaled(base: Dp): Dp = base * LocalDensity.current.fontScale
