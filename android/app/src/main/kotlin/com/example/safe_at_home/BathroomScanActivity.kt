package com.example.safe_at_home

import android.Manifest
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.URLSpan
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Session
import com.google.ar.core.exceptions.UnavailableException
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean

class BathroomScanActivity : ComponentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private var session: Session? = null
    private var surface: GLSurfaceView? = null
    private var renderer: BathroomScanRenderer? = null
    private var status: TextView? = null
    private var reviewButton: Button? = null
    private var scanId: String = ""
    private var startRequested = false
    private var permissionRequested = false
    private var installRequested = false
    private var resumed = false
    private var active = false
    private var completed = false
    private var startedAt = 0L
    private var depthSupported = false
    private var ownsSessionSlot = false
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private val timeout = Runnable { fail("scan_limit") }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        scanId = intent.getStringExtra(BathroomScanPlatform.EXTRA_SCAN_ID) ?: ""
        if (!BathroomScanGeometry.isScanId(scanId) || savedInstanceState != null) {
            fail("scan_interrupted")
            return
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { fail("scan_cancelled") }
        })
        showNotice()
    }

    private fun showNotice() {
        val column = column()
        column.addView(text("Scan your bathroom", 26f))
        column.addView(text("Move slowly from a safe position. Keep the camera facing walls, floor and fixtures. Do not walk backward or step over obstacles while looking at the screen.", 18f))
        column.addView(text("This captures an approximate arrangement of surfaces and points. Android does not automatically identify toilets, sinks or doors. You will review the model and identify what it shows.", 18f))
        column.addView(text("Safe at Home does not save or upload raw camera frames. The reviewed geometry stays in your encrypted case on this device. Backgrounding or exceeding three minutes cancels this scan.", 16f))
        val notice = text("This application runs on Google Play Services for AR (ARCore), which is provided by Google and governed by the Google Privacy Policy.", 16f)
        val linked = SpannableString(notice.text)
        val playLabel = "Google Play Services for AR"
        val policyLabel = "Google Privacy Policy"
        val playStart = linked.toString().indexOf(playLabel)
        val policyStart = linked.toString().indexOf(policyLabel)
        linked.setSpan(URLSpan("https://play.google.com/store/apps/details?id=com.google.ar.core"), playStart, playStart + playLabel.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        linked.setSpan(URLSpan("https://policies.google.com/privacy"), policyStart, policyStart + policyLabel.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        notice.text = linked
        notice.movementMethod = LinkMovementMethod.getInstance()
        notice.setLinkTextColor(Color.rgb(22, 94, 86))
        column.addView(notice)
        column.addView(button("Start bathroom scan") {
            if (!startRequested) {
                startRequested = true
                startIfReady()
            }
        })
        column.addView(button("Cancel") { fail("scan_cancelled") })
        setContentView(ScrollView(this).apply { isFillViewport = true; addView(column) })
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (startRequested && !completed && session == null) startIfReady()
    }

    private fun startIfReady() {
        if (!resumed || completed || active) return
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            if (permissionRequested) return
            permissionRequested = true
            requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION)
            return
        }
        try {
            when (ArCoreApk.getInstance().requestInstall(this, !installRequested)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {
                    installRequested = true
                    return
                }
                ArCoreApk.InstallStatus.INSTALLED -> Unit
            }
            if (!sessionSlot.compareAndSet(false, true)) {
                fail("scan_busy")
                return
            }
            ownsSessionSlot = true
            val created = Session(this)
            session = created
            depthSupported = created.isDepthModeSupported(Config.DepthMode.RAW_DEPTH_ONLY)
            created.configure(Config(created).apply {
                planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                depthMode = if (depthSupported) Config.DepthMode.RAW_DEPTH_ONLY else Config.DepthMode.DISABLED
                focusMode = Config.FocusMode.AUTO
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                lightEstimationMode = Config.LightEstimationMode.DISABLED
                cloudAnchorMode = Config.CloudAnchorMode.DISABLED
                geospatialMode = Config.GeospatialMode.DISABLED
            })
            created.resume()
            active = true
            startedAt = SystemClock.elapsedRealtime()
            if (!observeDevicePressure()) return
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            showCamera(created)
            handler.postDelayed(timeout, MAX_CAPTURE_MS)
        } catch (_: SecurityException) {
            fail("scan_permission_denied")
        } catch (_: UnavailableException) {
            fail("scan_unavailable")
        } catch (_: Exception) {
            fail("scan_failed")
        }
    }

    private fun showCamera(created: Session) {
        val column = BathroomScanCaptureLayout(this).apply {
            setBackgroundColor(Color.rgb(248, 246, 239))
            fitsSystemWindows = true
        }
        val scanRenderer = BathroomScanRenderer(created, BathroomScanGeometry(scanId), depthSupported,
            rotation = { windowManager.defaultDisplay.rotation },
            onProgress = { planes, points, tracking ->
                handler.post {
                    if (!completed && active) {
                        val secondsLeft = ((MAX_CAPTURE_MS - (SystemClock.elapsedRealtime() - startedAt)) / 1000).coerceAtLeast(0)
                        status?.text = if (tracking) {
                            "$planes surfaces · $points sampled points · ${secondsLeft}s remaining. Move slowly. Missing areas stay unknown."
                        } else {
                            "Finding position. Move slowly in good light and avoid blank or reflective surfaces. ${secondsLeft}s remaining."
                        }
                        reviewButton?.isEnabled = planes > 0 || points >= 20
                    }
                }
            },
            onFailure = { handler.post { fail("scan_failed") } },
        )
        renderer = scanRenderer
        val cameraView = GLSurfaceView(this).apply {
            setEGLContextClientVersion(2)
            preserveEGLContextOnPause = false
            contentDescription = "Live bathroom camera view. Detected surfaces and sampled points are outlined."
            setRenderer(scanRenderer)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        }
        surface = cameraView
        column.addView(cameraView, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        val controls = column()
        controls.addView(text("Bathroom scan", 24f))
        status = text("Finding position. Move slowly while facing the bathroom.", 16f)
        controls.addView(status)
        reviewButton = button("Finish and review 3D scan") { finishScan() }.apply { isEnabled = false }
        controls.addView(reviewButton)
        controls.addView(button("Cancel scan") { fail("scan_cancelled") })
        val controlsScroll = ScrollView(this).apply { addView(controls) }
        column.controls = controlsScroll
        column.addView(controlsScroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(280)))
        setContentView(column)
        cameraView.onResume()
    }

    private fun finishScan() {
        if (completed || !active) return
        if (SystemClock.elapsedRealtime() - startedAt >= MAX_CAPTURE_MS) {
            fail("scan_limit")
            return
        }
        completed = true
        stopCapture()
        try {
            val geometry = renderer?.geometry ?: error("missing geometry")
            require(geometry.elementCount > 0 || geometry.pointCount >= 20)
            val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
            val scene = geometry.encodeSceneWithinLimit(formatter.format(Date()), renderer?.capturedDepth == true) {
                JSONObject(it).toString()
            }
            if (scene == null) {
                returnError("scan_limit")
                return
            }
            setResult(RESULT_OK, Intent().putExtra(BathroomScanPlatform.EXTRA_SCAN_ID, scanId).putExtra(BathroomScanPlatform.EXTRA_SCENE, scene))
            finish()
        } catch (_: Exception) {
            returnError("scan_failed")
        }
    }

    private fun fail(code: String) {
        if (completed) return
        completed = true
        stopCapture()
        returnError(code)
    }

    private fun returnError(code: String) {
        setResult(RESULT_CANCELED, Intent().putExtra(BathroomScanPlatform.EXTRA_SCAN_ID, scanId).putExtra(BathroomScanPlatform.EXTRA_ERROR, code))
        finish()
    }

    private fun stopCapture() {
        handler.removeCallbacks(timeout)
        if (Build.VERSION.SDK_INT >= 29) {
            thermalListener?.let {
                try { getSystemService(PowerManager::class.java)?.removeThermalStatusListener(it) } catch (_: Exception) { }
            }
            thermalListener = null
        }
        surface?.onPause()
        if (active) {
            active = false
            try { session?.pause() } catch (_: Exception) {   }
        }
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun observeDevicePressure(): Boolean {
        if (Build.VERSION.SDK_INT < 29) return true
        try {
            val power = getSystemService(PowerManager::class.java) ?: return true
            if (power.currentThermalStatus >= PowerManager.THERMAL_STATUS_SEVERE) {
                fail("scan_limit")
                return false
            }
            val listener = PowerManager.OnThermalStatusChangedListener { status ->
                if (active && !completed && status >= PowerManager.THERMAL_STATUS_SEVERE) fail("scan_limit")
            }
            power.addThermalStatusListener(listener)
            thermalListener = listener
        } catch (_: Exception) {
        }
        return true
    }

    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (active && !completed && level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) fail("scan_limit")
    }

    override fun onPause() {
        resumed = false
        if (active && !completed) fail("scan_interrupted") else stopCapture()
        super.onPause()
    }

    override fun onDestroy() {
        stopCapture()
        renderer = null
        surface = null
        handler.removeCallbacksAndMessages(null)
        val closing = session
        session = null
        if (ownsSessionSlot) {
            ownsSessionSlot = false
            if (closing == null) {
                sessionSlot.set(false)
            } else {
                Thread({
                    try { closing.close() } catch (_: Exception) {
                    } finally { sessionSlot.set(false) }
                }, "bathroom-scan-release").start()
            }
        }
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION || completed) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startIfReady()
        else fail("scan_permission_denied")
    }

    private fun column() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(16), dp(20), dp(16))
        setBackgroundColor(Color.rgb(248, 246, 239))
    }
    private fun text(value: String, size: Float) = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(Color.rgb(23, 55, 51))
        setPadding(dp(8), dp(10), dp(8), dp(10))
    }
    private fun button(label: String, action: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        minHeight = dp(52)
        gravity = Gravity.CENTER
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val CAMERA_PERMISSION = 21315
        private const val MAX_CAPTURE_MS = 180_000L
        private val sessionSlot = AtomicBoolean(false)
    }
}

private class BathroomScanCaptureLayout(context: Context) : LinearLayout(context) {
    var controls: View? = null
    init { orientation = VERTICAL }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        if (MeasureSpec.getMode(heightMeasureSpec) != MeasureSpec.UNSPECIFIED) {
            controls?.layoutParams?.height = bathroomScanControlsHeight(
                MeasureSpec.getSize(heightMeasureSpec) - paddingTop - paddingBottom,
                (280 * resources.displayMetrics.density).toInt(),
            )
        }
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }
}

internal fun bathroomScanControlsHeight(availableHeight: Int, preferredHeight: Int): Int =
    minOf(preferredHeight.coerceAtLeast(0), availableHeight.coerceAtLeast(0) / 2)
