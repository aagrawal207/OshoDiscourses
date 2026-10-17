package com.agraabhi.oshodiscourses.downloads

import android.content.Context
import android.telephony.TelephonyManager
import java.util.Locale
import java.util.TimeZone

/**
 * iOS `isNearOshoworldNow`, read per download: locale region and time zone as on iOS, plus the SIM and
 * network country, which iOS cannot read and Android gives without a permission.
 */
class DeviceRegion(context: Context) {
    private val telephony = context.getSystemService(TelephonyManager::class.java)

    fun isNearOshoworld(): Boolean {
        val regions = listOf(
            Locale.getDefault().country,
            runCatching { telephony?.simCountryIso }.getOrNull(),
            runCatching { telephony?.networkCountryIso }.getOrNull(),
        ).map { it?.uppercase(Locale.ROOT)?.takeIf(String::isNotEmpty) }
        return DownloadSourcePolicy.isNearOshoworld(regions, TimeZone.getDefault().id)
    }
}
