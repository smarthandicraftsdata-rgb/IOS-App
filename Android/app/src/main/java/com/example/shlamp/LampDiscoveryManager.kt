package com.example.shlamp

/**
 * Converts verified mDNS/HTTP snapshots into per-lamp updates.
 * The permanent lampId is always used for deduplication.
 */
internal class LampDiscoveryManager(
    private val wifiController: WifiLampController,
    private val onSnapshot: (WifiLampSnapshot) -> Unit
) {
    fun start() {
        wifiController.startDiscovery { snapshot ->
            if (snapshot.lampId.startsWith("SH-")) onSnapshot(snapshot)
        }
    }

    fun stop() {
        wifiController.stopDiscovery()
    }
}
