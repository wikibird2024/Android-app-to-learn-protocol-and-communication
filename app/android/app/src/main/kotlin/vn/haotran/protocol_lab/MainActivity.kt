package vn.haotran.protocol_lab

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Native side of lib/core/transport/serial_link.dart and the multicast lock
 * for mDNS. USB serial comes from the community library
 * usb-serial-for-android (CH34x, CP210x, FTDI, PL2303, CDC-ACM); Bluetooth
 * SPP from Android's own BluetoothSocket.
 */
class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    // Blocking work (Bluetooth connect, USB write) runs here, one job at a
    // time, so writes keep their order.
    private val worker = Executors.newSingleThreadExecutor()
    private val openPorts = mutableMapOf<Int, OpenPort>()
    private var nextHandle = 1
    private var eventSink: EventChannel.EventSink? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private interface OpenPort {
        fun write(bytes: ByteArray)
        fun control(dtr: Boolean, rts: Boolean)
        fun close()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "protocol_lab/serial").setMethodCallHandler { call, result ->
            try {
                handleSerial(call, result)
            } catch (error: Exception) {
                result.error("serial", error.message ?: error.toString(), null)
            }
        }
        EventChannel(messenger, "protocol_lab/serial/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
        MethodChannel(messenger, "protocol_lab/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "multicastLock" -> {
                    setMulticastLock(call.argument<Boolean>("hold") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        openPorts.values.forEach { port -> runCatching { port.close() } }
        openPorts.clear()
        setMulticastLock(false)
        worker.shutdown()
        super.onDestroy()
    }

    /** Android drops multicast packets (mDNS) unless an app holds this lock. */
    private fun setMulticastLock(hold: Boolean) {
        if (hold && multicastLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("protocol_lab_mdns").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else if (!hold) {
            multicastLock?.release()
            multicastLock = null
        }
    }

    private fun handleSerial(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(listUsb() + listBluetooth())
            "open" -> {
                val kind = call.argument<String>("kind")
                val id = call.argument<String>("id") ?: ""
                if (kind == "bluetooth") openBluetooth(id, result) else openUsb(call, id, result)
            }
            "write" -> {
                val port = portOf(call)
                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                worker.execute {
                    try {
                        port.write(bytes)
                        mainHandler.post { result.success(null) }
                    } catch (error: Exception) {
                        mainHandler.post { result.error("write", error.message, null) }
                    }
                }
            }
            "control" -> {
                portOf(call).control(
                    call.argument<Boolean>("dtr") == true,
                    call.argument<Boolean>("rts") == true,
                )
                result.success(null)
            }
            "close" -> {
                val handle = call.argument<Int>("handle") ?: -1
                openPorts.remove(handle)?.close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun portOf(call: MethodCall): OpenPort {
        val handle = call.argument<Int>("handle") ?: -1
        return openPorts[handle] ?: throw IllegalStateException("port $handle is not open")
    }

    private fun addPort(port: OpenPort): Int {
        val handle = nextHandle++
        openPorts[handle] = port
        return handle
    }

    private fun emit(handle: Int, bytes: ByteArray?, isClosed: Boolean) {
        mainHandler.post {
            if (isClosed) openPorts.remove(handle)
            eventSink?.success(
                mapOf("handle" to handle, "bytes" to bytes, "closed" to isClosed),
            )
        }
    }

    // ---- USB ---------------------------------------------------------------

    private val usbManager: UsbManager
        get() = getSystemService(Context.USB_SERVICE) as UsbManager

    private fun findDriver(deviceName: String): UsbSerialDriver? =
        UsbSerialProber.getDefaultProber().findAllDrivers(usbManager)
            .firstOrNull { driver -> driver.device.deviceName == deviceName }

    private fun listUsb(): List<Map<String, String>> =
        UsbSerialProber.getDefaultProber().findAllDrivers(usbManager).map { driver ->
            val device = driver.device
            val driverName = driver.javaClass.simpleName.removeSuffix("SerialDriver")
            mapOf(
                "kind" to "usb",
                "id" to device.deviceName,
                "name" to (device.productName ?: "USB serial"),
                "detail" to String.format(
                    "%s %04x:%04x", driverName, device.vendorId, device.productId,
                ),
            )
        }

    private fun openUsb(call: MethodCall, deviceName: String, result: MethodChannel.Result) {
        val driver = findDriver(deviceName)
            ?: return result.error("open", "USB device is gone", null)
        val open = {
            try {
                result.success(openUsbPort(driver, call))
            } catch (error: Exception) {
                result.error("open", error.message ?: error.toString(), null)
            }
        }
        if (usbManager.hasPermission(driver.device)) {
            open()
        } else {
            requestUsbPermission(driver.device) { isGranted ->
                if (isGranted) open() else result.error("permission", "USB permission denied", null)
            }
        }
    }

    private fun openUsbPort(driver: UsbSerialDriver, call: MethodCall): Int {
        val connection = usbManager.openDevice(driver.device)
            ?: throw IllegalStateException("cannot open USB device")
        val port = driver.ports[0]
        port.open(connection)
        val stopBits = if (call.argument<Int>("stopBits") == 2) {
            UsbSerialPort.STOPBITS_2
        } else {
            UsbSerialPort.STOPBITS_1
        }
        port.setParameters(
            call.argument<Int>("baudRate") ?: 115200,
            call.argument<Int>("dataBits") ?: 8,
            stopBits,
            // Same order as Dart's Parity enum: none, odd, even, mark, space.
            call.argument<Int>("parity") ?: UsbSerialPort.PARITY_NONE,
        )
        var handle = 0
        val ioManager = SerialInputOutputManager(
            port,
            object : SerialInputOutputManager.Listener {
                override fun onNewData(data: ByteArray) = emit(handle, data, false)
                override fun onRunError(error: Exception) = emit(handle, null, true)
            },
        )
        handle = addPort(object : OpenPort {
            override fun write(bytes: ByteArray) = port.write(bytes, USB_WRITE_TIMEOUT_MS)
            override fun control(dtr: Boolean, rts: Boolean) {
                port.setDTR(dtr)
                port.setRTS(rts)
            }

            override fun close() {
                ioManager.stop()
                runCatching { port.close() }
            }
        })
        ioManager.start()
        return handle
    }

    private fun requestUsbPermission(device: UsbDevice, done: (Boolean) -> Unit) {
        val action = "$packageName.USB_PERMISSION"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                unregisterReceiver(this)
                done(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
        // Mutable: the system adds EXTRA_PERMISSION_GRANTED to it. Explicit
        // (setPackage), as Android 14 requires for mutable intents.
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val intent = PendingIntent.getBroadcast(this, 0, Intent(action).setPackage(packageName), flags)
        usbManager.requestPermission(device, intent)
    }

    // ---- Bluetooth Classic SPP --------------------------------------------

    // Needs BLUETOOTH_CONNECT, which Dart asks for before calling list/open.
    @SuppressLint("MissingPermission")
    private fun listBluetooth(): List<Map<String, String>> {
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            ?: return emptyList()
        return try {
            adapter.bondedDevices
                .filter { device -> device.type != BluetoothDevice.DEVICE_TYPE_LE }
                .map { device ->
                    mapOf(
                        "kind" to "bluetooth",
                        "id" to device.address,
                        "name" to (device.name ?: device.address),
                        "detail" to "SPP",
                    )
                }
        } catch (error: SecurityException) {
            emptyList()
        }
    }

    @SuppressLint("MissingPermission")
    private fun openBluetooth(address: String, result: MethodChannel.Result) {
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            ?: return result.error("open", "no Bluetooth on this phone", null)
        worker.execute {
            var socket: BluetoothSocket? = null
            try {
                adapter.cancelDiscovery()
                val connected: BluetoothSocket =
                    adapter.getRemoteDevice(address).createRfcommSocketToServiceRecord(SPP_UUID)
                socket = connected
                connected.connect()
                val handle = addPortOnMain(object : OpenPort {
                    override fun write(bytes: ByteArray) {
                        connected.outputStream.write(bytes)
                        connected.outputStream.flush()
                    }

                    override fun control(dtr: Boolean, rts: Boolean) = Unit

                    override fun close() {
                        runCatching { connected.close() }
                    }
                })
                Thread {
                    val buffer = ByteArray(1024)
                    try {
                        while (true) {
                            val count = connected.inputStream.read(buffer)
                            if (count < 0) break
                            emit(handle, buffer.copyOf(count), false)
                        }
                    } catch (_: Exception) {
                        // Socket closed by close() or the device went away.
                    }
                    emit(handle, null, true)
                }.start()
                mainHandler.post { result.success(handle) }
            } catch (error: Exception) {
                runCatching { socket?.close() }
                mainHandler.post { result.error("open", error.message ?: error.toString(), null) }
            }
        }
    }

    /** openPorts is only touched on the main thread. */
    private fun addPortOnMain(port: OpenPort): Int {
        val lock = Object()
        var handle = 0
        var isDone = false
        mainHandler.post {
            synchronized(lock) {
                handle = addPort(port)
                isDone = true
                lock.notifyAll()
            }
        }
        synchronized(lock) {
            while (!isDone) lock.wait()
        }
        return handle
    }

    private companion object {
        const val USB_WRITE_TIMEOUT_MS = 1000
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }
}
