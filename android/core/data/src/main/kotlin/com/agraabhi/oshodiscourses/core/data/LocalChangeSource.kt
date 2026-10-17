package com.agraabhi.oshodiscourses.core.data

import kotlinx.coroutines.flow.SharedFlow

/**
 * A repository that reports changes made on this device, the moments iOS pushes to iCloud.
 * Merges of synced data never emit, so a pull does not echo back as a push.
 */
interface LocalChangeSource {
    val localChanges: SharedFlow<Unit>
}
