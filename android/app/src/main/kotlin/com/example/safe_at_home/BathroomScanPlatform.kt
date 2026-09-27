package com.example.safe_at_home

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import com.google.ar.core.ArCoreApk
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class BathroomScanPlatform(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "safe_at_home/bathroom_scan")
    private var pending: MethodChannel.Result? = null
    private var pendingId: String? = null
    private var pendingRequestCode: Int? = null
    private var nextRequestCode = REQUEST_CODE
    private var detached = false

    fun register() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(capabilities())
                "start" -> {
                    val id = bathroomScanRequestId(call.arguments)
                    if (id == null) {
                        result.error("scan_failed", "The scan request is invalid.", null)
                    } else if (pending != null) {
                        result.error("scan_busy", "A bathroom scan is already open.", null)
                    } else {
                        pendingId = id
                        pending = result
                        val requestCode = nextRequestCode++
                        if (nextRequestCode > LAST_REQUEST_CODE) nextRequestCode = REQUEST_CODE
                        pendingRequestCode = requestCode
                        try {
                            activity.startActivityForResult(
                                Intent(activity, BathroomScanActivity::class.java).putExtra(EXTRA_SCAN_ID, id),
                                requestCode,
                            )
                        } catch (_: Exception) {
                            completeError("scan_unavailable", "Bathroom scanning could not be opened.")
                        }
                    }
                }
                "cancel" -> {
                    val id = bathroomScanRequestId(call.arguments)
                    if (id == null) {
                        result.error("scan_failed", "The scan request is invalid.", null)
                    } else {
                        if (id == pendingId) finishPendingActivity("scan_cancelled", "Bathroom scan cancelled.")
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun capabilities(): Map<String, Any?> {
        val availability = try {
            ArCoreApk.getInstance().checkAvailability(activity)
        } catch (_: Exception) {
            null
        }
        val reason = when (availability) {
            ArCoreApk.Availability.SUPPORTED_INSTALLED -> if (
                activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            ) "available" else "permission_denied"
            ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED -> "services_missing"
            ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD -> "services_update_required"
            ArCoreApk.Availability.UNSUPPORTED_DEVICE_NOT_CAPABLE -> "unsupported_device"
            else -> "checking"
        }
        return mapOf(
            "supported" to (availability?.isSupported == true),
            "source" to "arcore",
            "reason" to reason,
            "depthSupported" to null,
        )
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in REQUEST_CODE..LAST_REQUEST_CODE) return false
        if (requestCode != pendingRequestCode) return true
        val result = pending ?: return true
        val expected = pendingId
        pending = null
        pendingId = null
        pendingRequestCode = null
        if (detached) return true
        if (resultCode != Activity.RESULT_OK || data?.getStringExtra(EXTRA_SCAN_ID) != expected) {
            val code = data?.getStringExtra(EXTRA_ERROR)?.takeIf { it in ERROR_CODES }
                ?: "scan_interrupted"
            result.error(code, messageFor(code), null)
            return true
        }
        try {
            val text = data?.getStringExtra(EXTRA_SCENE) ?: error("missing scene")
            require(text.toByteArray(Charsets.UTF_8).size <= BathroomScanGeometry.MAX_JSON_BYTES)
            val json = JSONObject(text)
            require(json.getString("scanId") == expected)
            result.success(toCodecValue(json))
        } catch (_: Exception) {
            result.error("scan_failed", "The scan could not be read. Please scan again.", null)
        }
        return true
    }

    fun detach() {
        detached = true
        channel.setMethodCallHandler(null)
        finishPendingActivity("scan_interrupted", "The scan was interrupted. Please scan again.")
    }

    private fun finishPendingActivity(code: String, message: String) {
        try {
            pendingRequestCode?.let { activity.finishActivity(it) }
        } catch (_: Exception) {
        } finally {
            completeError(code, message)
        }
    }

    private fun completeError(code: String, message: String) {
        val result = pending
        pending = null
        pendingId = null
        pendingRequestCode = null
        result?.error(code, message, null)
    }

    private fun toCodecValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { toCodecValue(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { toCodecValue(value.get(it)) }
        else -> value
    }

    companion object {
        const val REQUEST_CODE = 21314
        private const val LAST_REQUEST_CODE = 21825
        const val EXTRA_SCAN_ID = "sah.scan.id"
        const val EXTRA_SCENE = "sah.scan.scene"
        const val EXTRA_ERROR = "sah.scan.error"
        private val ERROR_CODES = setOf(
            "scan_cancelled", "scan_interrupted", "scan_unavailable", "scan_permission_denied",
            "scan_busy", "scan_failed", "scan_limit",
        )
        fun messageFor(code: String): String = when (code) {
            "scan_cancelled" -> "Bathroom scan cancelled."
            "scan_interrupted" -> "The scan was interrupted. Please scan again."
            "scan_unavailable" -> "ARCore scanning is unavailable. Photos and manual measurements still work."
            "scan_permission_denied" -> "Camera access is needed to scan. You can use manual measurements instead."
            "scan_limit" -> "The scan reached its time, size or device resource limit. Let the device rest, then try a smaller area."
            else -> "The scan could not be completed. Please try again."
        }
    }
}

internal fun bathroomScanRequestId(arguments: Any?): String? {
    val values = arguments as? Map<*, *> ?: return null
    if (values.size != 1 || !values.containsKey("scanId")) return null
    val id = values["scanId"] as? String ?: return null
    return id.takeIf { BathroomScanGeometry.isScanId(it) }
}
