package com.example.shlamp

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal data class BleLampStatus(
    val lampId: String,
    val power: Boolean,
    val targetBrightness: Int,
    val currentBrightness: Int,
    val fadeMode: Int,
    val timerRemainingSeconds: Long,
    val rssi: Int
)

internal data class BleLampIdentity(
    val localLampId: String,
    val cloudLampId: String?
)

internal interface BleLampListener {
    fun onScanUpdated(lamps: List<NearbyLamp>)
    fun onScanFinished()
    fun onBleIdentity(identity: BleLampIdentity)
    fun onBleReady(lampId: String, address: String, advertisedName: String)
    fun onBleDisconnected(address: String?)
    fun onBleLampStatus(status: BleLampStatus)
    fun onBleBatteryLevel(lampId: String, percent: Int)
    fun onBlePowerMode(mode: LampPowerMode)
    fun onBleWifiStatus(message: String)
    fun onSavedWifiNetworks(networks: List<SavedWifiNetwork>)
    fun onLampControllers(controllers: List<LampControllerAccess>)
    fun onBleError(message: String)
}

private data class BleWriteRequest(
    val characteristicUuid: UUID,
    val bytes: ByteArray,
    var attempt: Int = 0
)

private data class TextAssembly(
    val expectedLength: Int,
    val bytes: ByteArray,
    val received: BooleanArray,
    var flags: Int = 0,
    var secondLength: Int = 0
) {
    fun complete(): Boolean = expectedLength == 0 || received.all { it }
}

/**
 * Scans every SH Lamp, but keeps only one active GATT session at a time.
 * The selected lamp is identified by FFE3 and never only by its display name.
 */
internal class BleLampManager(
    context: Context,
    private val handler: Handler,
    private val listener: BleLampListener
) {
    companion object {
        private const val SCAN_TIMEOUT_MS = 10_000L
        private const val REQUESTED_MTU = 185
        private const val WRITE_RETRY_MS = 90L
        private const val MAX_WRITE_ATTEMPTS = 5
        private const val STATUS_REQUEST_DEBOUNCE_MS = 1_500L
        @Volatile private var lastStatusRequestAt = 0L

        private val SERVICE_UUID: UUID =
            UUID.fromString("0000ffe0-0000-1000-8000-00805f9b34fb")
        private val CONTROL_UUID: UUID =
            UUID.fromString("0000ffe1-0000-1000-8000-00805f9b34fb")
        private val WIFI_UUID: UUID =
            UUID.fromString("0000ffe2-0000-1000-8000-00805f9b34fb")
        private val IDENTITY_UUID: UUID =
            UUID.fromString("0000ffe3-0000-1000-8000-00805f9b34fb")
        private val BATTERY_SERVICE_UUID: UUID =
            UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_LEVEL_UUID: UUID =
            UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
        private val CCCD_UUID: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val appContext = context.applicationContext
    private val bluetoothManager =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter?
        get() = bluetoothManager.adapter

    private val scanResults = ConcurrentHashMap<String, NearbyLamp>()
    private var scanning = false
    private var gatt: BluetoothGatt? = null
    private var controlCharacteristic: BluetoothGattCharacteristic? = null
    private var wifiCharacteristic: BluetoothGattCharacteristic? = null
    private var identityCharacteristic: BluetoothGattCharacteristic? = null
    private var batteryCharacteristic: BluetoothGattCharacteristic? = null
    private var connectedAddress: String? = null
    private var connectedAdvertisedName = "SH Lamp"
    private var connectedLampId = ""
    private var negotiatedMtu = 23
    private var lastRssi = -127
    private var initialStateRequested = false

    private val descriptorQueue = ArrayDeque<BluetoothGattCharacteristic>()
    private val writeQueue = ArrayDeque<BleWriteRequest>()
    private var writeRunning = false
    private var currentWrite: BleWriteRequest? = null

    private val savedAssemblies = ConcurrentHashMap<Int, TextAssembly>()
    private val controllerAssemblies = ConcurrentHashMap<Int, TextAssembly>()
    private var savedExpectedCount = 0
    private var controllerExpectedCount = 0

    private val scanTimeout = Runnable {
        if (scanning) {
            stopScan()
            listener.onScanFinished()
        }
    }

    @SuppressLint("MissingPermission")
    fun startScan() {
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            listener.onBleError("Bluetooth scanner is unavailable")
            return
        }

        stopScan()
        scanResults.clear()
        scanning = true
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(null, settings, scanCallback)
        handler.removeCallbacks(scanTimeout)
        handler.postDelayed(scanTimeout, SCAN_TIMEOUT_MS)
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        if (!scanning) return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        scanning = false
        handler.removeCallbacks(scanTimeout)
    }

    @SuppressLint("MissingPermission")
    fun connect(address: String, advertisedName: String) {
        stopScan()
        disconnect()

        val device = runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) {
            listener.onBleError("The selected Bluetooth lamp is unavailable")
            return
        }

        connectedAddress = address
        connectedAdvertisedName = advertisedName
        connectedLampId = parseLampIdFromName(advertisedName)
        @Suppress("DEPRECATION")
        val newGatt = device.connectGatt(
            appContext,
            false,
            gattCallback,
            BluetoothDevice.TRANSPORT_LE
        )
        gatt = newGatt
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        val oldGatt = gatt
        gatt = null
        if (oldGatt != null) {
            runCatching { oldGatt.disconnect() }
            runCatching { oldGatt.close() }
        }
        clearConnectionState()
    }

    fun isConnectedTo(address: String?): Boolean =
        address != null && address == connectedAddress && gatt != null && controlCharacteristic != null

    fun power(on: Boolean) =
        writeControl(byteArrayOf(0x05, if (on) 0x01 else 0x00))

    fun brightness(percent: Int) =
        writeControl(byteArrayOf(0x02, percent.coerceIn(0, 100).toByte()), coalesceBrightness = true)

    fun fade(mode: Int) =
        writeControl(byteArrayOf(0x03, mode.coerceIn(0, 3).toByte()))

    fun timer(minutes: Int) {
        val value = when (minutes) {
            0, 15, 30, 60 -> minutes
            else -> 0
        }
        writeControl(byteArrayOf(0x04, value.toByte()))
    }

    fun identify() = writeControl(byteArrayOf(0x07))

    fun requestStatus(force: Boolean = false) {
        val now = android.os.SystemClock.elapsedRealtime()
        synchronized(BleLampManager::class.java) {
            if (!force && now - lastStatusRequestAt < STATUS_REQUEST_DEBOUNCE_MS) return
            lastStatusRequestAt = now
        }
        writeControl(byteArrayOf(0x06))
    }

    fun powerMode(mode: LampPowerMode) =
        writeControl(byteArrayOf(0x08, mode.binaryValue))

    fun requestWifiStatus() = writeWifi(byteArrayOf(0x21))

    fun retryWifi() = writeWifi(byteArrayOf(0x22))

    fun requestSavedWifiNetworks() = writeWifi(byteArrayOf(0x25))

    fun selectSavedWifi(ssid: String) {
        buildSsidPacket(0x26, ssid)?.let(::writeWifi)
    }

    fun deleteSavedWifi(ssid: String) {
        buildSsidPacket(0x27, ssid)?.let(::writeWifi)
    }

    fun renameLamp(name: String) {
        val bytes = name.trim().toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > 32) {
            listener.onBleError("Lamp name must contain 1 to 32 bytes")
            return
        }
        writeWifi(ByteArray(2 + bytes.size).also { packet ->
            packet[0] = 0x40
            packet[1] = bytes.size.toByte()
            bytes.copyInto(packet, destinationOffset = 2)
        })
    }

    fun registerController(controllerId: String, label: String) {
        val idBytes = controllerId.trim().take(8).toByteArray(Charsets.UTF_8)
        val maxLabelBytes = if (negotiatedMtu > 23) 24 else 9
        val labelBytes = label.trim().ifBlank { "This phone" }
            .toByteArray(Charsets.UTF_8)
            .take(maxLabelBytes)
            .toByteArray()

        if (idBytes.size !in 4..16 || labelBytes.isEmpty()) return
        writeWifi(ByteArray(3 + idBytes.size + labelBytes.size).also { packet ->
            packet[0] = 0x50
            packet[1] = idBytes.size.toByte()
            packet[2] = labelBytes.size.toByte()
            idBytes.copyInto(packet, destinationOffset = 3)
            labelBytes.copyInto(packet, destinationOffset = 3 + idBytes.size)
        })
    }

    fun requestControllers() = writeWifi(byteArrayOf(0x51))

    fun removeController(controllerId: String) {
        val bytes = controllerId.trim().toByteArray(Charsets.UTF_8)
        if (bytes.size !in 4..16) return
        writeWifi(ByteArray(2 + bytes.size).also { packet ->
            packet[0] = 0x52
            packet[1] = bytes.size.toByte()
            bytes.copyInto(packet, destinationOffset = 2)
        })
    }

    fun provisionWifi(ssid: String, password: String) {
        val ssidBytes = ssid.trim().toByteArray(Charsets.UTF_8)
        val passwordBytes = password.toByteArray(Charsets.UTF_8)
        if (ssidBytes.isEmpty() || ssidBytes.size > 32) {
            listener.onBleError("Wi-Fi name must contain 1 to 32 bytes")
            return
        }
        if ((passwordBytes.isNotEmpty() && passwordBytes.size < 8) || passwordBytes.size > 63) {
            listener.onBleError("Wi-Fi password must be blank or 8 to 63 bytes")
            return
        }

        val packetSize = 3 + ssidBytes.size + passwordBytes.size
        if (packetSize <= negotiatedMtu - 3) {
            writeWifi(ByteArray(packetSize).also { packet ->
                packet[0] = 0x20
                packet[1] = ssidBytes.size.toByte()
                packet[2] = passwordBytes.size.toByte()
                ssidBytes.copyInto(packet, destinationOffset = 3)
                passwordBytes.copyInto(packet, destinationOffset = 3 + ssidBytes.size)
            })
            return
        }

        val payload = ssidBytes + passwordBytes
        val chunkSize = (negotiatedMtu - 6).coerceAtLeast(1).coerceAtMost(17)
        writeWifi(byteArrayOf(0x30, ssidBytes.size.toByte(), passwordBytes.size.toByte()))
        var offset = 0
        while (offset < payload.size) {
            val length = minOf(chunkSize, payload.size - offset)
            writeWifi(ByteArray(3 + length).also { packet ->
                packet[0] = 0x31
                packet[1] = offset.toByte()
                packet[2] = length.toByte()
                payload.copyInto(
                    packet,
                    destinationOffset = 3,
                    startIndex = offset,
                    endIndex = offset + length
                )
            })
            offset += length
        }
        writeWifi(byteArrayOf(0x32))
    }

    fun close() {
        stopScan()
        disconnect()
        handler.removeCallbacksAndMessages(null)
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val name = result.scanRecord?.deviceName
                ?: runCatching { result.device.name }.getOrNull()
                ?: return
            if (!name.startsWith("SH Lamp", ignoreCase = true) &&
                !name.equals("LampBT conTest", ignoreCase = true)
            ) return

            val address = result.device.address
            val lampId = parseLampIdFromName(name).ifBlank {
                "BLE-${address.replace(":", "").takeLast(6)}"
            }
            scanResults[address] = NearbyLamp(
                lampId = lampId,
                advertisedName = name,
                bleAddress = address,
                rssi = result.rssi
            )
            listener.onScanUpdated(scanResults.values.sortedByDescending { it.rssi })
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            handler.removeCallbacks(scanTimeout)
            listener.onBleError("Bluetooth scan failed: $errorCode")
            listener.onScanFinished()
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            // A disconnect callback from the previously selected lamp can arrive
            // after a new lamp connection has started. Never let that stale GATT
            // clear the new selected-lamp session.
            if (this@BleLampManager.gatt !== gatt) {
                runCatching { gatt.close() }
                return
            }

            when {
                status != BluetoothGatt.GATT_SUCCESS -> {
                    val address = connectedAddress
                    runCatching { gatt.close() }
                    this@BleLampManager.gatt = null
                    clearConnectionState(keepAddress = false)
                    handler.post {
                        listener.onBleError("Bluetooth connection failed: $status")
                        listener.onBleDisconnected(address)
                    }
                }

                newState == BluetoothProfile.STATE_CONNECTED -> {
                    runCatching { gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) }
                    gatt.discoverServices()
                }

                newState == BluetoothProfile.STATE_DISCONNECTED -> {
                    val address = connectedAddress
                    runCatching { gatt.close() }
                    this@BleLampManager.gatt = null
                    clearConnectionState(keepAddress = false)
                    handler.post { listener.onBleDisconnected(address) }
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                listener.onBleError("Bluetooth service discovery failed: $status")
                return
            }
            val service = gatt.getService(SERVICE_UUID)
            controlCharacteristic = service?.getCharacteristic(CONTROL_UUID)
            wifiCharacteristic = service?.getCharacteristic(WIFI_UUID)
            identityCharacteristic = service?.getCharacteristic(IDENTITY_UUID)
            batteryCharacteristic = gatt.getService(BATTERY_SERVICE_UUID)
                ?.getCharacteristic(BATTERY_LEVEL_UUID)

            if (controlCharacteristic == null || wifiCharacteristic == null) {
                listener.onBleError("The selected device is not compatible with SH Lamp")
                return
            }

            val requested = runCatching { gatt.requestMtu(REQUESTED_MTU) }.getOrDefault(false)
            if (!requested) readIdentityOrPrepare(gatt)
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            negotiatedMtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23
            readIdentityOrPrepare(gatt)
        }

        @Deprecated("Required for Android 12 and lower")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            @Suppress("DEPRECATION")
            val bytes = characteristic.value ?: byteArrayOf()
            processCharacteristicRead(gatt, characteristic, bytes, status)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            processCharacteristicRead(gatt, characteristic, value, status)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            enableNextNotification(gatt)
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            val completed = synchronized(writeQueue) {
                val item = currentWrite
                currentWrite = null
                writeRunning = false
                item
            }
            if (status != BluetoothGatt.GATT_SUCCESS && completed != null) {
                retryWrite(completed)
            } else {
                handler.postDelayed(::dispatchWrite, 24L)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) = handleNotification(characteristic.uuid, value)

        @Deprecated("Required for Android 12 and lower")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            @Suppress("DEPRECATION")
            handleNotification(characteristic.uuid, characteristic.value ?: return)
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) lastRssi = rssi
        }
    }

    @SuppressLint("MissingPermission")
    private fun readIdentityOrPrepare(gatt: BluetoothGatt) {
        val identity = identityCharacteristic
        if (identity != null && runCatching { gatt.readCharacteristic(identity) }.getOrDefault(false)) {
            return
        }
        prepareNotifications(gatt)
    }

    private fun processCharacteristicRead(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
        status: Int
    ) {
        when (characteristic.uuid) {
            IDENTITY_UUID -> {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    val rawIdentity = value.toString(Charsets.UTF_8).trim()
                    parseIdentityPayload(rawIdentity)?.let { identity ->
                        connectedLampId = identity.localLampId
                        handler.post { listener.onBleIdentity(identity) }
                    }
                }
                prepareNotifications(gatt)
            }

            BATTERY_LEVEL_UUID -> {
                if (status == BluetoothGatt.GATT_SUCCESS) parseBatteryLevel(value)
                requestInitialState()
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun prepareNotifications(gatt: BluetoothGatt) {
        descriptorQueue.clear()
        controlCharacteristic?.let { characteristic ->
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                descriptorQueue.addLast(characteristic)
            }
        }
        wifiCharacteristic?.let { characteristic ->
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                descriptorQueue.addLast(characteristic)
            }
        }
        batteryCharacteristic?.let { characteristic ->
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                descriptorQueue.addLast(characteristic)
            }
        }
        enableNextNotification(gatt)
    }

    @SuppressLint("MissingPermission")
    private fun enableNextNotification(gatt: BluetoothGatt) {
        while (descriptorQueue.isNotEmpty()) {
            val characteristic = descriptorQueue.removeFirst()
            val descriptor = characteristic.getDescriptor(CCCD_UUID) ?: continue
            if (!gatt.setCharacteristicNotification(characteristic, true)) continue

            val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(
                    descriptor,
                    BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    gatt.writeDescriptor(descriptor)
                }
            }
            if (started) return
        }
        markReady(gatt)
    }

    @SuppressLint("MissingPermission")
    private fun markReady(gatt: BluetoothGatt) {
        if (connectedLampId.isBlank()) {
            connectedLampId = parseLampIdFromName(connectedAdvertisedName).ifBlank {
                "BLE-${connectedAddress.orEmpty().replace(":", "").takeLast(6)}"
            }
        }
        val address = connectedAddress ?: gatt.device.address
        handler.post {
            listener.onBleReady(connectedLampId, address, connectedAdvertisedName)
        }
        runCatching { gatt.readRemoteRssi() }

        val battery = batteryCharacteristic
        val batteryReadStarted = battery != null &&
            battery.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0 &&
            runCatching { gatt.readCharacteristic(battery) }.getOrDefault(false)
        if (!batteryReadStarted) requestInitialState()
    }

    private fun requestInitialState() {
        if (initialStateRequested) return
        initialStateRequested = true
        requestStatus()
        requestWifiStatus()
    }

    private fun handleNotification(uuid: UUID, bytes: ByteArray) {
        when (uuid) {
            CONTROL_UUID -> parseControlStatus(bytes)
            WIFI_UUID -> parseWifiNotification(bytes)
            BATTERY_LEVEL_UUID -> parseBatteryLevel(bytes)
        }
    }

    private fun parseBatteryLevel(bytes: ByteArray) {
        val value = bytes.firstOrNull()?.toInt()?.and(0xFF) ?: return
        if (value !in 0..100) return
        val lampId = connectedLampId.ifBlank {
            parseLampIdFromName(connectedAdvertisedName).ifBlank { return }
        }
        handler.post { listener.onBleBatteryLevel(lampId, value) }
    }

    private fun parseControlStatus(bytes: ByteArray) {
        val text = bytes.toString(Charsets.UTF_8).trim()
        val match = Regex("^P([01])B(\\d{3})C(\\d{3})F([0-3])T(\\d{5})$")
            .matchEntire(text) ?: return
        val status = BleLampStatus(
            lampId = connectedLampId,
            power = match.groupValues[1] == "1",
            targetBrightness = match.groupValues[2].toInt().coerceIn(0, 100),
            currentBrightness = match.groupValues[3].toInt().coerceIn(0, 100),
            fadeMode = match.groupValues[4].toInt().coerceIn(0, 3),
            timerRemainingSeconds = match.groupValues[5].toLong().coerceAtLeast(0L),
            rssi = lastRssi
        )
        handler.post { listener.onBleLampStatus(status) }
    }

    private fun parseWifiNotification(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        when (bytes[0].toInt() and 0xFF) {
            0xC0 -> {
                savedExpectedCount = bytes.getOrNull(1)?.toInt()?.and(0xFF) ?: 0
                savedAssemblies.clear()
                return
            }
            0xC1 -> {
                parseSavedNetworkChunk(bytes)
                return
            }
            0xC2 -> {
                finishSavedNetworks()
                return
            }
            0xD0 -> {
                controllerExpectedCount = bytes.getOrNull(1)?.toInt()?.and(0xFF) ?: 0
                controllerAssemblies.clear()
                return
            }
            0xD1 -> {
                parseControllerChunk(bytes)
                return
            }
            0xD2 -> {
                finishControllers()
                return
            }
        }

        val text = bytes.toString(Charsets.UTF_8).trim()
        when {
            text.startsWith("W:") -> handler.post { listener.onBleWifiStatus(text) }
            text.startsWith("M:") -> parsePowerModeText(text.removePrefix("M:"))?.let { mode ->
                handler.post { listener.onBlePowerMode(mode) }
            }
        }
    }


    private fun parsePowerModeText(raw: String): LampPowerMode? = when (
        raw.trim().uppercase().replace('-', '_').replace(' ', '_')
    ) {
        "BALANCED" -> LampPowerMode.BALANCED
        "MAX_BACKUP", "MAXIMUM_BACKUP" -> LampPowerMode.MAX_BACKUP
        "BLE_ONLY", "BLUETOOTH_ONLY" -> LampPowerMode.BLE_ONLY
        "TOUCH_ONLY" -> LampPowerMode.TOUCH_ONLY
        else -> null
    }

    private fun parseSavedNetworkChunk(bytes: ByteArray) {
        if (bytes.size < 7) return
        val index = bytes[1].toInt() and 0xFF
        val total = bytes[2].toInt() and 0xFF
        val flags = bytes[3].toInt() and 0xFF
        val expected = bytes[4].toInt() and 0xFF
        val offset = bytes[5].toInt() and 0xFF
        val length = bytes[6].toInt() and 0xFF
        if (expected > 32 || length > bytes.size - 7 || offset + length > expected) return
        savedExpectedCount = total
        val assembly = savedAssemblies.compute(index) { _, old ->
            old?.takeIf { it.expectedLength == expected }
                ?: TextAssembly(expected, ByteArray(expected), BooleanArray(expected))
        } ?: return
        assembly.flags = flags
        for (i in 0 until length) {
            assembly.bytes[offset + i] = bytes[7 + i]
            assembly.received[offset + i] = true
        }
    }

    private fun finishSavedNetworks() {
        val networks = savedAssemblies.entries.sortedBy { it.key }.mapNotNull { (_, item) ->
            if (!item.complete()) null
            else SavedWifiNetwork(
                ssid = item.bytes.toString(Charsets.UTF_8),
                active = item.flags and 0x01 != 0
            )
        }.take(savedExpectedCount)
        handler.post { listener.onSavedWifiNetworks(networks) }
    }

    private fun parseControllerChunk(bytes: ByteArray) {
        if (bytes.size < 8) return
        val index = bytes[1].toInt() and 0xFF
        val total = bytes[2].toInt() and 0xFF
        val flags = bytes[3].toInt() and 0xFF
        val idLength = bytes[4].toInt() and 0xFF
        val labelLength = bytes[5].toInt() and 0xFF
        val offset = bytes[6].toInt() and 0xFF
        val length = bytes[7].toInt() and 0xFF
        val expected = idLength + labelLength
        if (idLength !in 4..16 || labelLength !in 1..24 ||
            length > bytes.size - 8 || offset + length > expected
        ) return
        controllerExpectedCount = total
        val assembly = controllerAssemblies.compute(index) { _, old ->
            old?.takeIf { it.expectedLength == expected }
                ?: TextAssembly(
                    expectedLength = expected,
                    bytes = ByteArray(expected),
                    received = BooleanArray(expected),
                    secondLength = labelLength
                )
        } ?: return
        assembly.flags = flags
        assembly.secondLength = labelLength
        for (i in 0 until length) {
            assembly.bytes[offset + i] = bytes[8 + i]
            assembly.received[offset + i] = true
        }
    }

    private fun finishControllers() {
        val controllers = controllerAssemblies.entries.sortedBy { it.key }.mapNotNull { (_, item) ->
            if (!item.complete()) return@mapNotNull null
            val labelLength = item.secondLength
            val idLength = item.expectedLength - labelLength
            LampControllerAccess(
                controllerId = item.bytes.copyOfRange(0, idLength).toString(Charsets.UTF_8),
                label = item.bytes.copyOfRange(idLength, item.expectedLength).toString(Charsets.UTF_8),
                role = if (item.flags and 0x01 != 0) LampAccessRole.OWNER else LampAccessRole.MEMBER
            )
        }.take(controllerExpectedCount)
        handler.post { listener.onLampControllers(controllers) }
    }

    private fun buildSsidPacket(command: Int, ssid: String): ByteArray? {
        val bytes = ssid.trim().toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > 32) return null
        return ByteArray(2 + bytes.size).also { packet ->
            packet[0] = command.toByte()
            packet[1] = bytes.size.toByte()
            bytes.copyInto(packet, destinationOffset = 2)
        }
    }

    private fun writeControl(bytes: ByteArray, coalesceBrightness: Boolean = false) {
        enqueueWrite(CONTROL_UUID, bytes, coalesceBrightness)
    }

    private fun writeWifi(bytes: ByteArray) {
        enqueueWrite(WIFI_UUID, bytes, false)
    }

    private fun enqueueWrite(uuid: UUID, bytes: ByteArray, coalesceBrightness: Boolean) {
        val start = synchronized(writeQueue) {
            if (coalesceBrightness && uuid == CONTROL_UUID && bytes.firstOrNull() == 0x02.toByte()) {
                val iterator = writeQueue.iterator()
                while (iterator.hasNext()) {
                    val old = iterator.next()
                    if (old.characteristicUuid == CONTROL_UUID && old.bytes.firstOrNull() == 0x02.toByte()) {
                        iterator.remove()
                    }
                }
            }
            writeQueue.addLast(BleWriteRequest(uuid, bytes.copyOf()))
            !writeRunning
        }
        if (start) dispatchWrite()
    }

    private fun dispatchWrite() {
        val request = synchronized(writeQueue) {
            if (writeRunning) return
            val next = writeQueue.pollFirst() ?: return
            writeRunning = true
            currentWrite = next
            next
        }
        performWrite(request)
    }

    @SuppressLint("MissingPermission")
    private fun performWrite(request: BleWriteRequest) {
        val currentGatt = gatt
        val characteristic = when (request.characteristicUuid) {
            CONTROL_UUID -> controlCharacteristic
            WIFI_UUID -> wifiCharacteristic
            else -> null
        }
        if (currentGatt == null || characteristic == null) {
            synchronized(writeQueue) {
                currentWrite = null
                writeRunning = false
            }
            listener.onBleError("Bluetooth lamp is not ready")
            return
        }

        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            currentGatt.writeCharacteristic(
                characteristic,
                request.bytes,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                characteristic.value = request.bytes
                currentGatt.writeCharacteristic(characteristic)
            }
        }
        if (!started) {
            synchronized(writeQueue) {
                currentWrite = null
                writeRunning = false
            }
            retryWrite(request)
        }
    }

    private fun retryWrite(request: BleWriteRequest) {
        request.attempt++
        if (request.attempt >= MAX_WRITE_ATTEMPTS) {
            listener.onBleError("Bluetooth command could not be written")
            handler.postDelayed(::dispatchWrite, WRITE_RETRY_MS)
            return
        }
        synchronized(writeQueue) { writeQueue.addFirst(request) }
        handler.postDelayed(::dispatchWrite, WRITE_RETRY_MS)
    }

    private fun clearConnectionState(keepAddress: Boolean = true) {
        controlCharacteristic = null
        wifiCharacteristic = null
        identityCharacteristic = null
        batteryCharacteristic = null
        descriptorQueue.clear()
        synchronized(writeQueue) {
            writeQueue.clear()
            currentWrite = null
            writeRunning = false
        }
        connectedLampId = ""
        negotiatedMtu = 23
        lastRssi = -127
        initialStateRequested = false
        if (!keepAddress) connectedAddress = null
    }

    /**
     * Identity protocol accepted from FFE3:
     *   Legacy: I:SH-A65688
     *   Current: I:SH-A65688|C:SH-0727182134
     * Separators `|`, `;`, comma and new line are accepted so firmware can
     * evolve without breaking older Android builds.
     */
    private fun parseIdentityPayload(raw: String): BleLampIdentity? {
        if (raw.isBlank()) return null
        val tokens = raw
            .replace('\r', '|')
            .replace('\n', '|')
            .split('|', ';', ',')
            .map(String::trim)
            .filter(String::isNotBlank)

        var localId: String? = null
        var cloudId: String? = null
        tokens.forEach { token ->
            val upper = token.uppercase()
            when {
                upper.startsWith("I:SH-") -> localId = normalizeIdentityId(token.substringAfter(':'))
                upper.startsWith("L:SH-") -> localId = normalizeIdentityId(token.substringAfter(':'))
                upper.startsWith("LOCAL:SH-") -> localId = normalizeIdentityId(token.substringAfter(':'))
                upper.startsWith("C:SH-") -> cloudId = normalizeIdentityId(token.substringAfter(':'))
                upper.startsWith("CLOUD:SH-") -> cloudId = normalizeIdentityId(token.substringAfter(':'))
            }
        }

        val fallbackLocal = parseLampIdFromName(connectedAdvertisedName)
            .ifBlank { connectedLampId }
        val resolvedLocal = localId ?: fallbackLocal
        if (!resolvedLocal.startsWith("SH-")) return null
        return BleLampIdentity(
            localLampId = resolvedLocal,
            cloudLampId = cloudId?.takeIf { it.startsWith("SH-") }
        )
    }

    private fun normalizeIdentityId(value: String): String = value
        .trim()
        .uppercase()
        .takeIf { Regex("SH-[A-Z0-9]{4,16}").matches(it) }
        .orEmpty()

    private fun parseLampIdFromName(name: String): String {
        val suffix = Regex("(?i)^SH Lamp ([0-9A-F]{6})$")
            .matchEntire(name.trim())
            ?.groupValues
            ?.getOrNull(1)
            ?.uppercase()
            .orEmpty()
        return if (suffix.isBlank()) "" else "SH-$suffix"
    }
}
