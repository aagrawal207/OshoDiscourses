package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot

/**
 * Every repository's synced slice (iOS `CloudSyncService.push` and `pull`). [merge] must be
 * convergent and idempotent: merging an export back changes nothing and returns false.
 */
interface SnapshotStore {
    suspend fun export(): CloudSnapshot

    /** True if local state changed. */
    suspend fun merge(incoming: CloudSnapshot): Boolean
}
