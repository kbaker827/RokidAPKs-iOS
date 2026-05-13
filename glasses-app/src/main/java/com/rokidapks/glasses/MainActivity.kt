package com.rokidapks.glasses

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.Bundle
import android.provider.Settings
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.rokidapks.glasses.spp.SppPacketUtils
import com.rokidapks.glasses.tcp.IosDiscoveryClient
import com.rokidapks.glasses.tcp.TcpControlChannel
import com.rokidapks.glasses.spp.WifiApkSocketDownloader
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity() {

    // ── Views ──────────────────────────────────────────────────────────────

    private lateinit var deviceNameText: TextView
    private lateinit var deviceAddressText: TextView
    private lateinit var statusText: TextView
    private lateinit var progressText: TextView
    private lateinit var transferProgress: ProgressBar
    private lateinit var hintText: TextView
    private lateinit var logText: TextView
    private lateinit var actionContainer: View
    private lateinit var wifiActionButton: TextView

    // ── State ──────────────────────────────────────────────────────────────

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var sessionJob: Job? = null
    private var isTransferring = false

    private val installResultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val message = intent.getStringExtra(PackageInstallHelper.EXTRA_MESSAGE) ?: return
            appendLog(message)
            setStatus(message)
        }
    }

    private val gestureDetector by lazy {
        GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                handleTap()
                return true
            }

            override fun onFling(
                e1: MotionEvent?,
                e2: MotionEvent,
                velocityX: Float,
                velocityY: Float,
            ): Boolean {
                if (velocityX < -800) { handleSwipeLeft(); return true }
                if (velocityX > 800) { handleSwipeRight(); return true }
                return false
            }
        })
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemBars()
        bindViews()
        setupWifiButton()

        PackageInstallHelper.cleanupExpiredPendingApk(this) { appendLog(it) }

        registerReceiver(
            installResultReceiver,
            IntentFilter(PackageInstallHelper.ACTION_INSTALL_STATUS),
            RECEIVER_NOT_EXPORTED,
        )

        showIdle()

        // Auto-start discovery
        startDiscovery()
    }

    override fun onResume() {
        super.onResume()
        if (PackageInstallHelper.resumePendingInstallIfPossible(this) { appendLog(it) }) {
            appendLog("Resumed pending install.")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        runCatching { unregisterReceiver(installResultReceiver) }
        scope.cancel()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        gestureDetector.onTouchEvent(event)
        return super.onTouchEvent(event)
    }

    // ── Gesture handlers ──────────────────────────────────────────────────

    private fun handleTap() {
        if (!isTransferring) startDiscovery()
    }

    private fun handleSwipeLeft() {
        if (!isTransferring) startDiscovery()
    }

    private fun handleSwipeRight() {
        openWifiSettings()
    }

    // ── Discovery + transfer ──────────────────────────────────────────────

    private fun startDiscovery() {
        if (sessionJob?.isActive == true) return

        sessionJob = scope.launch {
            isTransferring = true
            runSession()
            isTransferring = false
        }
    }

    private suspend fun runSession() {
        val discovery = IosDiscoveryClient(this@MainActivity)

        setStatus("Searching for iOS phone...")
        setDeviceName("Scanning Wi-Fi…")
        setHint("Make sure the iPhone app is open and on the same Wi-Fi")
        appendLog("Starting NSD discovery for ${IosDiscoveryClient.SERVICE_TYPE}")

        val socket = runCatching {
            withContext(Dispatchers.IO) { discovery.connect(timeoutMs = 60_000L) }
        }.getOrElse { e ->
            setStatus("Discovery failed: ${e.message}")
            appendLog("Error: ${e.message}")
            setHint("TAP TO RETRY")
            setDeviceName("Not found")
            return
        }

        val hostAddress = socket.inetAddress.hostAddress ?: "unknown"
        setDeviceName("iOS Phone")
        setDeviceAddress(hostAddress)
        setStatus("Connected — awaiting offer…")
        appendLog("TCP connected to $hostAddress")

        socket.use { s ->
            val channel = TcpControlChannel(s)

            val offer = runCatching {
                withContext(Dispatchers.IO) { channel.awaitOffer() }
            }.getOrElse { e ->
                setStatus("Offer read failed: ${e.message}")
                appendLog("Error reading offer: ${e.message}")
                setHint("TAP TO RETRY")
                return
            }

            appendLog("Offer: ${offer.fileName} (${offer.apkSize} bytes)")
            setStatus("Receiving APK…")

            val hostIp = offer.hostIp
            val port = offer.port

            if (hostIp.isNullOrBlank() || port == null) {
                val err = "Offer missing Wi-Fi address or port."
                setStatus(err)
                appendLog(err)
                withContext(Dispatchers.IO) { channel.sendResult(false, err) }
                setHint("TAP TO RETRY")
                return
            }

            // Download APK over Wi-Fi
            val targetFile = File(cacheDir, offer.fileName.replace(Regex("[^A-Za-z0-9._-]"), "_"))
            showProgress()

            val downloader = WifiApkSocketDownloader()
            val downloadResult = withContext(Dispatchers.IO) {
                downloader.downloadApk(
                    hostIp = hostIp,
                    port = port,
                    targetFile = targetFile,
                    totalBytes = offer.apkSize,
                    expectedMd5Hex = offer.md5Hex,
                ) { received, total ->
                    val pct = ((received * 100) / total).toInt()
                    runOnUiThread { updateProgress(pct) }
                }
            }

            downloadResult.onFailure { e ->
                hideProgress()
                val err = "Download failed: ${e.message}"
                setStatus(err)
                appendLog(err)
                withContext(Dispatchers.IO) { channel.sendResult(false, err) }
                setHint("TAP TO RETRY")
                return
            }

            hideProgress()
            appendLog("Download complete. Starting installer…")

            // Verify we have the file
            if (!targetFile.exists()) {
                val err = "APK file missing after download."
                withContext(Dispatchers.IO) { channel.sendResult(false, err) }
                setStatus(err)
                setHint("TAP TO RETRY")
                return
            }

            // Notify the iOS phone before we start the install prompt (which may block)
            withContext(Dispatchers.IO) {
                channel.sendResult(true, "APK received. Install prompt opening on glasses.")
            }

            setStatus("Launching install prompt…")
            setHint("CONFIRM INSTALL ON GLASSES")

            PackageInstallHelper.requestInstall(this@MainActivity, targetFile) { msg ->
                appendLog(msg)
                setStatus(msg)
            }
        }

        setHint("TAP TO START AGAIN")
    }

    // ── UI helpers ────────────────────────────────────────────────────────

    private fun bindViews() {
        deviceNameText = findViewById(R.id.deviceNameText)
        deviceAddressText = findViewById(R.id.deviceAddressText)
        statusText = findViewById(R.id.statusText)
        progressText = findViewById(R.id.progressText)
        transferProgress = findViewById(R.id.transferProgress)
        hintText = findViewById(R.id.hintText)
        logText = findViewById(R.id.logText)
        actionContainer = findViewById(R.id.actionContainer)
        wifiActionButton = findViewById(R.id.wifiActionButton)
    }

    private fun setupWifiButton() {
        wifiActionButton.setOnClickListener { openWifiSettings() }
        actionContainer.visibility = View.VISIBLE
    }

    private fun showIdle() {
        setDeviceName(getString(R.string.no_paired_phone))
        setDeviceAddress("")
        setStatus(getString(R.string.status_idle))
        setHint("TAP TO SEARCH   SLIDE RIGHT FOR WIFI")
        hideProgress()
    }

    private fun setDeviceName(name: String) { deviceNameText.text = name }
    private fun setDeviceAddress(addr: String) { deviceAddressText.text = addr }
    private fun setStatus(msg: String) { statusText.text = msg }
    private fun setHint(msg: String) { hintText.text = msg }

    private fun showProgress() {
        progressText.visibility = View.VISIBLE
        transferProgress.visibility = View.VISIBLE
    }

    private fun hideProgress() {
        progressText.visibility = View.GONE
        transferProgress.visibility = View.GONE
    }

    private fun updateProgress(pct: Int) {
        progressText.text = "$pct%"
        transferProgress.progress = pct
    }

    private fun appendLog(message: String) {
        val time = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
        val current = logText.text.toString()
        val lines = current.lines().takeLast(2) + listOf("[$time] $message")
        logText.text = lines.joinToString("\n")
    }

    private fun openWifiSettings() {
        setStatus(getString(R.string.status_opening_wifi))
        appendLog(getString(R.string.log_opening_wifi))
        runCatching {
            startActivity(Intent(Settings.ACTION_WIFI_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        }.onFailure {
            setStatus(getString(R.string.status_wifi_unavailable))
        }
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }
}
