package com.agraabhi.oshodiscourses.downloads

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What the device's default network allows downloads to do (iOS `NWPathMonitor` + `DownloadNetwork.classify`). */
interface NetworkMonitor {
    val network: StateFlow<DownloadNetwork>
}

/** Follows the default network. Transports, not meteredness, decide Wi-Fi versus mobile data, as on iOS. */
class AndroidNetworkMonitor(context: Context) : NetworkMonitor {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val state = MutableStateFlow(classify(connectivity?.activeNetwork?.let { connectivity.getNetworkCapabilities(it) }))
    override val network: StateFlow<DownloadNetwork> = state.asStateFlow()

    init {
        try {
            connectivity?.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = update(classify(capabilities))

                override fun onLost(network: Network) = update(DownloadNetwork.OFFLINE)
            })
        } catch (e: RuntimeException) {
            Log.w(TAG, "network callback unavailable", e)
        }
    }

    private fun update(value: DownloadNetwork) {
        if (state.value != value) Log.i(TAG, "network=${value.name}")
        state.value = value
    }

    companion object {
        fun classify(capabilities: NetworkCapabilities?): DownloadNetwork {
            if (capabilities == null) return DownloadNetwork.OFFLINE
            return DownloadNetworkClassifier.classify(
                satisfied = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                wifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                wired = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),
                cellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
            )
        }
    }
}

private const val TAG = "Downloads"
