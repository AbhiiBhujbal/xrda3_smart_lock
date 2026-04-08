package com.example.xrda3_smart_life_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

import com.thingclips.smart.optimus.sdk.ThingOptimusSdk
import com.thingclips.smart.optimus.lock.api.IThingLockManager
import com.thingclips.smart.optimus.lock.api.IThingBleLockV2
import com.thingclips.smart.home.sdk.callback.IThingResultCallback
import com.thingclips.smart.sdk.api.IResultCallback
import com.thingclips.smart.sdk.optimus.lock.bean.DynamicPasswordBean
import com.thingclips.smart.optimus.lock.api.bean.OfflineTempPassword
import com.thingclips.smart.optimus.lock.api.enums.OfflineTempPasswordType
import com.thingclips.smart.optimus.lock.api.bean.Record
import com.thingclips.smart.sdk.optimus.lock.bean.ble.TempPasswordBeanV3
import com.thingclips.smart.sdk.optimus.lock.bean.ble.PasswordRequest
import com.thingclips.smart.sdk.optimus.lock.bean.ble.SyncBatchBean

// Camera P2P / IPC imports
import com.thingclips.smart.camera.middleware.p2p.IThingSmartCameraP2P
import com.thingclips.smart.camera.camerasdk.thingplayer.callback.OperationDelegateCallBack
import com.thingclips.smart.camera.ipccamerasdk.p2p.ICameraP2P
import com.thingclips.smart.android.camera.sdk.ThingIPCSdk
import com.thingclips.smart.home.sdk.ThingHomeSdk
import com.thingclips.smart.sdk.bean.DeviceBean

class MainActivity : FlutterActivity() {
    private val LOCK_CHANNEL = "xrda3_smart_lock/lock_extras"
    private val CAMERA_CHANNEL = "xrda3_camera/talk"
    private val DOORBELL_EVENT_CHANNEL = "xrda3_camera/doorbell_events"
    private val REMOTE_UNLOCK_EVENT_CHANNEL = "xrda3_smart_lock/remote_unlock_events"
    private val TAG = "MainActivity"

    // Camera P2P instances keyed by deviceId
    private val cameraP2PMap = mutableMapOf<String, IThingSmartCameraP2P<Any>>()
    private var doorbellEventSink: EventChannel.EventSink? = null
    private var remoteUnlockEventSink: EventChannel.EventSink? = null
    // WiFi lock listeners keyed by deviceId
    private val wifiLockListeners = mutableMapOf<String, com.thingclips.smart.optimus.lock.api.IThingWifiLock>()

    private fun getBleLock(devId: String): IThingBleLockV2 {
        ThingOptimusSdk.init(this)
        val lockManager = ThingOptimusSdk.getManager(IThingLockManager::class.java)
        return lockManager.getBleLockV2(devId)
    }

    private fun getWifiLock(devId: String): com.thingclips.smart.optimus.lock.api.IThingWifiLock {
        wifiLockListeners[devId]?.let { return it }
        ThingOptimusSdk.init(this)
        val lockManager = ThingOptimusSdk.getManager(IThingLockManager::class.java)
        val wifiLock = lockManager.getWifiLock(devId)
        wifiLockListeners[devId] = wifiLock
        return wifiLock
    }

    @Suppress("UNCHECKED_CAST")
    private fun getCameraP2P(devId: String): IThingSmartCameraP2P<Any>? {
        cameraP2PMap[devId]?.let { return it }
        try {
            val ipcCore = ThingIPCSdk.getCameraInstance()
            if (ipcCore != null) {
                val p2p = ipcCore.createCameraP2P(devId) as? IThingSmartCameraP2P<Any>
                if (p2p != null) {
                    cameraP2PMap[devId] = p2p
                }
                return p2p
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create camera P2P: ${e.message}")
        }
        return null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ════════════════════════════════════════════════
        // LOCK EXTRAS CHANNEL (existing)
        // ════════════════════════════════════════════════
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCK_CHANNEL)
            .setMethodCallHandler { call, result ->
                val devId: String? = call.argument("devId")

                when (call.method) {

                    // ── Dynamic Password (OTP) via BLE ──
                    "getDynamicPasswordBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            Log.i(TAG, "getDynamicPasswordBLE for $devId")
                            getBleLock(devId).getLockDynamicPassword(
                                object : IThingResultCallback<DynamicPasswordBean> {
                                    override fun onSuccess(bean: DynamicPasswordBean?) {
                                        Log.i(TAG, "BLE dynamic password SUCCESS: ${bean?.dynamicPassword}")
                                        result.success(bean?.dynamicPassword)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "BLE dynamic password FAILED: $code $message")
                                        result.error("BLE_DYNAMIC_PWD_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            Log.e(TAG, "BLE dynamic password exception: ${e.message}")
                            result.error("BLE_DYNAMIC_PWD_ERROR", e.message, null)
                        }
                    }

                    // ── Dynamic Password (OTP) via WiFi ──
                    "getDynamicPasswordWiFi" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            Log.i(TAG, "getDynamicPasswordWiFi for $devId")
                            val wifiLock = getWifiLock(devId)
                            wifiLock.getDynamicPassword(
                                object : IThingResultCallback<String> {
                                    override fun onSuccess(pwd: String?) {
                                        Log.i(TAG, "WiFi dynamic password SUCCESS: $pwd")
                                        result.success(pwd)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "WiFi dynamic password FAILED: $code $message")
                                        result.error("WIFI_DYNAMIC_PWD_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            Log.e(TAG, "WiFi dynamic password exception: ${e.message}")
                            result.error("WIFI_DYNAMIC_PWD_ERROR", e.message, null)
                        }
                    }

                    // ── Offline Temp Password (single-use OTP) ──
//                    "createOfflinePasswordBLE" -> {
//                        if (devId == null) {
//                            result.error("INVALID_ARG", "devId is required", null)
//                            return@setMethodCallHandler
//                        }
//                        val name: String = call.argument("name") ?: "Temp Password"
//                        val pwdType: String = call.argument("type") ?: "single"
//                        val effectiveTime: Long = call.argument("effectiveTime")
//                            ?: System.currentTimeMillis()
//                        val invalidTime: Long = call.argument("invalidTime")
//                            ?: (System.currentTimeMillis() + 5 * 60 * 1000)
//
//                        val type = if (pwdType == "multiple")
//                            OfflineTempPasswordType.MULTIPLE else OfflineTempPasswordType.SINGLE
//
//                        try {
//                            getBleLock(devId).getOfflinePassword(
//                                type, effectiveTime, invalidTime, name,
//                                object : IThingResultCallback<OfflineTempPassword> {
//                                    override fun onSuccess(pwd: OfflineTempPassword?) {
//                                        Log.i(TAG, "Offline password: ${pwd?.pwd}")
//                                        result.success(hashMapOf(
//                                            "password" to pwd?.pwd,
//                                            "pwdId" to pwd?.pwdId,
//                                            "pwdName" to pwd?.pwdName,
//                                            "gmtStart" to pwd?.gmtStart,
//                                            "gmtExpired" to pwd?.gmtExpired,
//                                        ))
//                                    }
//                                    override fun onError(code: String?, message: String?) {
//                                        Log.e(TAG, "Offline password failed: $code $message")
//                                        result.error("BLE_OFFLINE_PWD_FAILED", message ?: "Unknown error", code)
//                                    }
//                                }
//                            )
//                        } catch (e: Exception) {
//                            result.error("BLE_OFFLINE_PWD_ERROR", e.message, null)
//                        }
//                    }

                    // ── Create Online Temp Password ──
//                    "createOnlinePasswordBLE" -> {
//                        if (devId == null) {
//                            result.error("INVALID_ARG", "devId is required", null)
//                            return@setMethodCallHandler
//                        }
//                        val name: String = call.argument("name") ?: "Online Temp"
//                        val password: String = call.argument("password") ?: ""
//                        val effectiveTime: Long = call.argument("effectiveTime")
//                            ?: System.currentTimeMillis()
//                        val invalidTime: Long = call.argument("invalidTime")
//                            ?: (System.currentTimeMillis() + 24 * 60 * 60 * 1000)
//                        val availTime: Int = call.argument("availTime") ?: 0
//
//                        try {
//                            val request = PasswordRequest()
//                            request.name = name
//                            request.password = password
//                            request.effectiveTime = effectiveTime
//                            request.invalidTime = invalidTime
//                            request.availTime = availTime
//
//                            getBleLock(devId).getCustomOnlinePassword(
//                                request,
//                                object : IThingResultCallback<String> {
//                                    override fun onSuccess(pwdId: String?) {
//                                        Log.i(TAG, "Online password created: $pwdId")
//                                        result.success(pwdId)
//                                    }
//                                    override fun onError(code: String?, message: String?) {
//                                        Log.e(TAG, "Online password failed: $code $message")
//                                        result.error("BLE_ONLINE_PWD_FAILED", message ?: "Unknown error", code)
//                                    }
//                                }
//                            )
//                        } catch (e: Exception) {
//                            result.error("BLE_ONLINE_PWD_ERROR", e.message, null)
//                        }
//                    }

                    // ── List Online Passwords ──
                    "getOnlinePasswordListBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            getBleLock(devId).getOnlinePasswordList(
                                0,
                                object : IThingResultCallback<ArrayList<TempPasswordBeanV3>> {
                                    override fun onSuccess(list: ArrayList<TempPasswordBeanV3>?) {
                                        val passwords = list?.map { pwd ->
                                            hashMapOf(
                                                "passwordId" to pwd.passwordId,
                                                "name" to pwd.name,
                                                "effectiveTime" to pwd.effectiveTime,
                                                "invalidTime" to pwd.invalidTime,
                                                "phase" to pwd.phase,
                                                "effective" to pwd.effective,
                                                "sn" to pwd.sn,
                                            )
                                        } ?: emptyList()
                                        result.success(passwords)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "Password list failed: $code $message")
                                        result.error("BLE_PWD_LIST_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("BLE_PWD_LIST_ERROR", e.message, null)
                        }
                    }

                    // ── Unlock Records (History) ──
                    "getUnlockRecordsBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val offset: Int = call.argument("offset") ?: 0
                        val limit: Int = call.argument("limit") ?: 20

                        try {
                            getBleLock(devId).getUnlockRecordList(
                                offset, limit,
                                object : IThingResultCallback<Record> {
                                    override fun onSuccess(record: Record?) {
                                        val records = record?.datas?.map { r ->
                                            hashMapOf(
                                                "id" to r.id,
                                                "userName" to r.userName,
                                                "unlockType" to r.unlockType,
                                                "unlockName" to r.unlockName,
                                                "createTime" to r.createTime,
                                                "dpValue" to r.dpValue,
                                                "userId" to r.userId,
                                                "tags" to r.tags,
                                            )
                                        } ?: emptyList()
                                        result.success(hashMapOf(
                                            "records" to records,
                                            "totalCount" to (record?.totalCount ?: 0),
                                            "hasNext" to (record?.hasNext ?: false),
                                        ))
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "Unlock records failed: $code $message")
                                        result.error("BLE_RECORDS_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("BLE_RECORDS_ERROR", e.message, null)
                        }
                    }

                    // ── Alarm Records ──
                    "getAlarmRecordsBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val offset: Int = call.argument("offset") ?: 0
                        val limit: Int = call.argument("limit") ?: 20

                        try {
                            getBleLock(devId).getAlarmRecordList(
                                offset, limit,
                                object : IThingResultCallback<Record> {
                                    override fun onSuccess(record: Record?) {
                                        val records = record?.datas?.map { r ->
                                            hashMapOf(
                                                "id" to r.id,
                                                "userName" to r.userName,
                                                "unlockType" to r.unlockType,
                                                "unlockName" to r.unlockName,
                                                "createTime" to r.createTime,
                                                "dpValue" to r.dpValue,
                                                "tags" to r.tags,
                                            )
                                        } ?: emptyList()
                                        result.success(hashMapOf(
                                            "records" to records,
                                            "totalCount" to (record?.totalCount ?: 0),
                                            "hasNext" to (record?.hasNext ?: false),
                                        ))
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "Alarm records failed: $code $message")
                                        result.error("BLE_ALARM_RECORDS_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("BLE_ALARM_RECORDS_ERROR", e.message, null)
                        }
                    }

                    // ── Remote Unlock Toggle ──
                    "getRemoteUnlockType" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            getBleLock(devId).fetchRemoteUnlockType(
                                object : IThingResultCallback<Boolean> {
                                    override fun onSuccess(enabled: Boolean?) {
                                        result.success(enabled ?: false)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        result.error("REMOTE_TYPE_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("REMOTE_TYPE_ERROR", e.message, null)
                        }
                    }

                    "setRemoteUnlockType" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val enabled: Boolean = call.argument("enabled") ?: false
                        try {
                            getBleLock(devId).setRemoteUnlockType(
                                enabled,
                                object : IResultCallback {
                                    override fun onSuccess() {
                                        result.success(true)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        result.error("REMOTE_SET_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("REMOTE_SET_ERROR", e.message, null)
                        }
                    }

                    // ── BLE Connection Status ──
                    "isBLEConnected" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val connected = getBleLock(devId).isBLEConnected
                            result.success(connected)
                        } catch (e: Exception) {
                            result.error("BLE_STATUS_ERROR", e.message, null)
                        }
                    }

                    // ── Robust BLE Unlock with sync + V3 member fallback ──
                    "robustBleUnlock" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val bleLock = getBleLock(devId)
                            // Sync batch data first to refresh member info
                            try {
                                bleLock.getSyncBatchData(
                                    object : IThingResultCallback<SyncBatchBean> {
                                        override fun onSuccess(data: SyncBatchBean?) {
                                            Log.i(TAG, "SyncBatchData success, attempting unlock")
                                            attemptBleUnlock(bleLock, result)
                                        }
                                        override fun onError(code: String?, message: String?) {
                                            Log.w(TAG, "SyncBatchData failed ($code), trying unlock anyway")
                                            attemptBleUnlock(bleLock, result)
                                        }
                                    }
                                )
                            } catch (syncErr: Exception) {
                                Log.w(TAG, "SyncBatchData exception, trying unlock: ${syncErr.message}")
                                attemptBleUnlock(bleLock, result)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "robustBleUnlock exception: ${e.message}")
                            result.error("BLE_UNLOCK_ERROR", e.message, null)
                        }
                    }

                    // ── Get current member detail for debugging ──
                    "getMemberDetail" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            getBleLock(devId).getCurrentMemberDetail(
                                object : IThingResultCallback<com.thingclips.smart.sdk.optimus.lock.bean.ble.BLELockUser> {
                                    override fun onSuccess(user: com.thingclips.smart.sdk.optimus.lock.bean.ble.BLELockUser?) {
                                        result.success(hashMapOf(
                                            "lockUserId" to (user?.lockUserId ?: 0),
                                            "userId" to (user?.userId ?: ""),
                                            "nickName" to (user?.nickName ?: ""),
                                            "userType" to (user?.userType ?: -1),
                                            "phase" to (user?.phase ?: -1),
                                            "permanent" to (user?.permanent ?: false),
                                        ))
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        result.error("MEMBER_DETAIL_FAILED", message ?: "Unknown", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("MEMBER_DETAIL_ERROR", e.message, null)
                        }
                    }

                    // ── Remote Switch Lock (the correct API for WiFi remote unlock) ──
                    "remoteSwitchLock" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val open: Boolean = call.argument("open") ?: true
                        try {
                            val bleLock = getBleLock(devId)
                            Log.i(TAG, "remoteSwitchLock: devId=$devId, open=$open")
                            bleLock.remoteSwitchLock(open, object : IResultCallback {
                                override fun onSuccess() {
                                    Log.i(TAG, "remoteSwitchLock SUCCESS: open=$open")
                                    result.success(true)
                                }
                                override fun onError(code: String?, error: String?) {
                                    Log.e(TAG, "remoteSwitchLock FAILED: $code $error")
                                    result.error("REMOTE_SWITCH_FAILED", "$error (code: $code)", code)
                                }
                            })
                        } catch (e: Exception) {
                            Log.e(TAG, "remoteSwitchLock exception: ${e.message}")
                            result.error("REMOTE_SWITCH_ERROR", e.message, null)
                        }
                    }

                    // ── BLE Manual Lock with auto-connect + timeout + fallback ──
                    "bleManualLock" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val bleLock = getBleLock(devId)
                            val lockHandler = android.os.Handler(android.os.Looper.getMainLooper())
                            var responded = false

                            // Timeout: if bleManualLock doesn't respond in 10s, try remoteSwitchLock
                            lockHandler.postDelayed({
                                if (!responded) {
                                    responded = true
                                    Log.w(TAG, "bleManualLock TIMEOUT after 10s, trying remoteSwitchLock(false)...")
                                    bleLock.remoteSwitchLock(false, object : IResultCallback {
                                        override fun onSuccess() {
                                            Log.i(TAG, "remoteSwitchLock(lock) SUCCESS after bleManualLock timeout")
                                            result.success(true)
                                        }
                                        override fun onError(code: String?, error: String?) {
                                            Log.e(TAG, "remoteSwitchLock(lock) also FAILED: $code $error")
                                            result.error("BLE_LOCK_TIMEOUT", "bleManualLock timed out and remoteSwitchLock failed: $error", code)
                                        }
                                    })
                                }
                            }, 10000)

                            val lockCallback = object : IResultCallback {
                                override fun onSuccess() {
                                    if (!responded) {
                                        responded = true
                                        lockHandler.removeCallbacksAndMessages(null)
                                        Log.i(TAG, "bleManualLock SUCCESS")
                                        result.success(true)
                                    }
                                }
                                override fun onError(code: String?, error: String?) {
                                    if (!responded) {
                                        responded = true
                                        lockHandler.removeCallbacksAndMessages(null)
                                        Log.e(TAG, "bleManualLock FAILED: $code $error")
                                        // Immediate fallback: try remoteSwitchLock
                                        Log.i(TAG, "Trying remoteSwitchLock(false) as fallback...")
                                        bleLock.remoteSwitchLock(false, object : IResultCallback {
                                            override fun onSuccess() {
                                                Log.i(TAG, "remoteSwitchLock(lock) SUCCESS as fallback")
                                                result.success(true)
                                            }
                                            override fun onError(code2: String?, error2: String?) {
                                                Log.e(TAG, "remoteSwitchLock(lock) also FAILED: $code2 $error2")
                                                result.error("BLE_LOCK_FAILED", error ?: "Lock failed", code)
                                            }
                                        })
                                    }
                                }
                            }

                            if (!bleLock.isBLEConnected) {
                                Log.i(TAG, "BLE not connected, auto-connecting for lock...")
                                bleLock.autoConnect(object : com.thingclips.smart.optimus.lock.api.callback.ConnectV2Listener {
                                    override fun onStatusChanged(connected: Boolean) {
                                        if (connected && !responded) {
                                            Log.i(TAG, "BLE connected, now locking...")
                                            bleLock.bleManualLock(lockCallback)
                                        }
                                    }
                                    override fun onError(code: String?, error: String?) {
                                        Log.e(TAG, "BLE auto-connect failed: $code $error")
                                        result.error("BLE_CONNECT_FAILED", error ?: "Connect failed", code)
                                    }
                                })
                            } else {
                                Log.i(TAG, "BLE already connected, locking...")
                                bleLock.bleManualLock(lockCallback)
                            }
                        } catch (e: Exception) {
                            result.error("BLE_LOCK_ERROR", e.message, null)
                        }
                    }

                    // ── Launch Doorbell Call Activity ──
                    "launchDoorbellCall" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val name: String = call.argument("deviceName") ?: "Doorbell"
                        try {
                            val intent = android.content.Intent(this@MainActivity, DoorbellCallActivity::class.java)
                            intent.putExtra(DoorbellCallActivity.EXTRA_DEV_ID, devId)
                            intent.putExtra(DoorbellCallActivity.EXTRA_DEV_NAME, name)
                            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("LAUNCH_FAILED", e.message, null)
                        }
                    }

                    // ── Get device schema (which DPs are rw/ro/wr) ──
                    "getDeviceSchema" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val deviceBean = ThingHomeSdk.getDataInstance().getDeviceBean(devId)
                            val schemaMap = deviceBean?.getSchemaMap() ?: emptyMap()
                            val schemaList = schemaMap.map { (dpId, schema) ->
                                hashMapOf(
                                    "dpId" to dpId,
                                    "code" to schema.code,
                                    "name" to schema.name,
                                    "mode" to schema.mode, // rw, ro, wr
                                    "type" to schema.type,
                                    "schemaType" to schema.schemaType,
                                    "property" to schema.property,
                                )
                            }
                            Log.i(TAG, "Device schema: $schemaList")
                            result.success(schemaList)
                        } catch (e: Exception) {
                            result.error("SCHEMA_ERROR", e.message, null)
                        }
                    }

                    // ── Publish DP via WiFi Lock (uses LAN connection) ──
                    "publishDpViaWifiLock" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val dpId: String = call.argument("dpId") ?: ""
                        val dpValue: Any? = call.argument("dpValue")
                        if (dpId.isEmpty() || dpValue == null) {
                            result.error("INVALID_ARG", "dpId and dpValue required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val valueStr = when (dpValue) {
                                is Boolean -> dpValue.toString()
                                is Number -> dpValue.toString()
                                is String -> "\"$dpValue\""
                                else -> dpValue.toString()
                            }
                            val dpsJson = "{\"$dpId\":$valueStr}"
                            Log.i(TAG, "publishDpViaWifiLock: devId=$devId, dps=$dpsJson")

                            // Use WiFi lock instance which has active LAN connection
                            val wifiLock = getWifiLock(devId)
                            wifiLock.publishDps(dpsJson, object : IResultCallback {
                                override fun onSuccess() {
                                    Log.i(TAG, "publishDpViaWifiLock SUCCESS: $dpsJson")
                                    result.success(true)
                                }
                                override fun onError(code: String?, error: String?) {
                                    Log.e(TAG, "publishDpViaWifiLock FAILED: $code $error for $dpsJson")
                                    result.error("WIFI_PUBLISH_FAILED", "$error (code: $code)", code)
                                }
                            })
                        } catch (e: Exception) {
                            result.error("WIFI_PUBLISH_ERROR", e.message, null)
                        }
                    }

                    // ── Publish DP command directly with proper JSON ──
                    "publishDp" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val dpId: String = call.argument("dpId") ?: ""
                        val dpValue: Any? = call.argument("dpValue")

                        if (dpId.isEmpty() || dpValue == null) {
                            result.error("INVALID_ARG", "dpId and dpValue required", null)
                            return@setMethodCallHandler
                        }

                        try {
                            // Build proper JSON string based on value type
                            val valueStr = when (dpValue) {
                                is Boolean -> dpValue.toString()
                                is Number -> dpValue.toString()
                                is String -> "\"$dpValue\""
                                else -> dpValue.toString()
                            }
                            val dpsJson = "{\"$dpId\":$valueStr}"
                            Log.i(TAG, "publishDp: devId=$devId, dps=$dpsJson")

                            val device = ThingHomeSdk.newDeviceInstance(devId)
                            device.publishDps(dpsJson, object : IResultCallback {
                                override fun onSuccess() {
                                    Log.i(TAG, "publishDp success: $dpsJson")
                                    result.success(true)
                                }
                                override fun onError(code: String?, error: String?) {
                                    Log.e(TAG, "publishDp failed: $code $error for $dpsJson")
                                    result.error("PUBLISH_DP_FAILED", "$error (code: $code) — DP $dpId may be read-only", code)
                                }
                            })
                        } catch (e: Exception) {
                            result.error("PUBLISH_DP_ERROR", e.message, null)
                        }
                    }

                    // ── Register WiFi remote unlock listener ──
                    "registerRemoteUnlockListener" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val wifiLock = getWifiLock(devId)
                            wifiLock.setRemoteUnlockListener(
                                com.thingclips.smart.optimus.lock.api.callback.RemoteUnlockListener { requestDevId, seconds ->
                                    Log.i(TAG, "Remote unlock request from $requestDevId, countdown: ${seconds}s")
                                    runOnUiThread {
                                        remoteUnlockEventSink?.success(hashMapOf(
                                            "event" to "remote_unlock_request",
                                            "devId" to requestDevId,
                                            "countdown" to seconds,
                                            "timestamp" to System.currentTimeMillis(),
                                        ))
                                    }
                                }
                            )
                            Log.i(TAG, "Remote unlock listener registered for $devId")
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "registerRemoteUnlockListener error: ${e.message}")
                            result.error("LISTENER_ERROR", e.message, null)
                        }
                    }

                    // ── Reply to remote unlock request (approve/deny) ──
                    "replyRemoteUnlock" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val allow: Boolean = call.argument("allow") ?: true
                        try {
                            val wifiLock = getWifiLock(devId)
                            wifiLock.replyRemoteUnlock(allow,
                                object : IThingResultCallback<Boolean> {
                                    override fun onSuccess(data: Boolean?) {
                                        Log.i(TAG, "replyRemoteUnlock success: allow=$allow")
                                        result.success(true)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "replyRemoteUnlock failed: $code $message")
                                        result.error("REPLY_UNLOCK_FAILED", message ?: "Failed", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("REPLY_UNLOCK_ERROR", e.message, null)
                        }
                    }

                    // ── Check if remote unlock is enabled on the lock ──
                    "fetchRemoteUnlockEnabled" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            getBleLock(devId).fetchRemoteUnlockType(
                                object : IThingResultCallback<Boolean> {
                                    override fun onSuccess(enabled: Boolean?) {
                                        result.success(enabled ?: false)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        result.error("FETCH_REMOTE_FAILED", message ?: "Failed", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("FETCH_REMOTE_ERROR", e.message, null)
                        }
                    }

                    // ── Enable/disable remote unlock on the lock ──
                    "enableRemoteUnlock" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val enabled: Boolean = call.argument("enabled") ?: true
                        try {
                            getBleLock(devId).setRemoteUnlockType(enabled,
                                object : IResultCallback {
                                    override fun onSuccess() {
                                        Log.i(TAG, "Remote unlock ${if (enabled) "enabled" else "disabled"}")
                                        result.success(true)
                                    }
                                    override fun onError(code: String?, error: String?) {
                                        result.error("SET_REMOTE_FAILED", error ?: "Failed", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("SET_REMOTE_ERROR", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ════════════════════════════════════════════════
        // REMOTE UNLOCK REQUEST EVENT CHANNEL
        // ════════════════════════════════════════════════
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, REMOTE_UNLOCK_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    remoteUnlockEventSink = events
                    Log.i(TAG, "Remote unlock event channel listening")
                }
                override fun onCancel(arguments: Any?) {
                    remoteUnlockEventSink = null
                }
            })

        // ════════════════════════════════════════════════
        // CAMERA TALK / INTERCOM CHANNEL
        // ════════════════════════════════════════════════
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL)
            .setMethodCallHandler { call, result ->
                val devId: String? = call.argument("devId")

                when (call.method) {

                    // ── Start Two-Way Talk ──
                    "startTalk" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val p2p = getCameraP2P(devId)
                        if (p2p == null) {
                            result.error("NO_P2P", "Camera P2P not available for $devId", null)
                            return@setMethodCallHandler
                        }
                        try {
                            p2p.startAudioTalk(object : OperationDelegateCallBack {
                                override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                                    Log.i(TAG, "Talk started for $devId")
                                    runOnUiThread { result.success(true) }
                                }
                                override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                                    Log.e(TAG, "Talk start failed: errCode=$errCode")
                                    runOnUiThread { result.error("TALK_START_FAILED", "Error code: $errCode", null) }
                                }
                            })
                        } catch (e: Exception) {
                            Log.e(TAG, "startTalk exception: ${e.message}")
                            result.error("TALK_ERROR", e.message, null)
                        }
                    }

                    // ── Stop Two-Way Talk ──
                    "stopTalk" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val p2p = getCameraP2P(devId)
                        if (p2p == null) {
                            result.error("NO_P2P", "Camera P2P not available", null)
                            return@setMethodCallHandler
                        }
                        try {
                            p2p.stopAudioTalk(object : OperationDelegateCallBack {
                                override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                                    Log.i(TAG, "Talk stopped for $devId")
                                    runOnUiThread { result.success(true) }
                                }
                                override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                                    runOnUiThread { result.error("TALK_STOP_FAILED", "Error: $errCode", null) }
                                }
                            })
                        } catch (e: Exception) {
                            result.error("TALK_ERROR", e.message, null)
                        }
                    }

                    // ── Mute / Unmute Speaker ──
                    "setMute" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val mute: Boolean = call.argument("mute") ?: false
                        val p2p = getCameraP2P(devId)
                        if (p2p == null) {
                            result.error("NO_P2P", "Camera P2P not available", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val muteVal = if (mute) ICameraP2P.MUTE else ICameraP2P.UNMUTE
                            p2p.setMute(muteVal, object : OperationDelegateCallBack {
                                override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                                    runOnUiThread { result.success(true) }
                                }
                                override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                                    runOnUiThread { result.error("MUTE_FAILED", "Error: $errCode", null) }
                                }
                            })
                        } catch (e: Exception) {
                            result.error("MUTE_ERROR", e.message, null)
                        }
                    }

                    // ── Enable/Disable Loud Speaker ──
                    "enableSpeaker" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val enable: Boolean = call.argument("enable") ?: true
                        val p2p = getCameraP2P(devId)
                        if (p2p == null) {
                            result.error("NO_P2P", "Camera P2P not available", null)
                            return@setMethodCallHandler
                        }
                        try {
                            p2p.setLoudSpeakerStatus(enable)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SPEAKER_ERROR", e.message, null)
                        }
                    }

                    // ── Check if talk is supported ──
                    "isTalkSupported" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val deviceBean: DeviceBean? = ThingHomeSdk.getDataInstance().getDeviceBean(devId)
                            val category = deviceBean?.category ?: ""
                            // Cameras (sp) and doorbells (dgnbj) typically support talk
                            val supported = category == "sp" || category == "dgnbj"
                            result.success(supported)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    // ── Get talk mode (one-way or two-way) ──
                    "getTalkMode" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val deviceBean: DeviceBean? = ThingHomeSdk.getDataInstance().getDeviceBean(devId)
                            val skillStr = deviceBean?.skills?.toString() ?: ""
                            val mode = when {
                                skillStr.contains("talk_mode\":2") || skillStr.contains("talkMode\":2") -> 2
                                skillStr.contains("talk_mode\":1") || skillStr.contains("talkMode\":1") -> 1
                                else -> 1
                            }
                            result.success(mode)
                        } catch (e: Exception) {
                            result.success(1)
                        }
                    }

                    // ── Destroy P2P session ──
                    "destroyP2P" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        cameraP2PMap[devId]?.destroyP2P()
                        cameraP2PMap.remove(devId)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        // ════════════════════════════════════════════════
        // DOORBELL EVENT CHANNEL
        // ════════════════════════════════════════════════
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DOORBELL_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    doorbellEventSink = events
                    Log.i(TAG, "Doorbell event channel listening")
                }
                override fun onCancel(arguments: Any?) {
                    doorbellEventSink = null
                }
            })
    }

    // ── Robust BLE unlock: try V2 member detail, then V3 fallback ──
    private fun attemptBleUnlock(bleLock: IThingBleLockV2, result: MethodChannel.Result) {
        bleLock.getCurrentMemberDetail(
            object : IThingResultCallback<com.thingclips.smart.sdk.optimus.lock.bean.ble.BLELockUser> {
                override fun onSuccess(user: com.thingclips.smart.sdk.optimus.lock.bean.ble.BLELockUser?) {
                    val userId = user?.lockUserId ?: 0
                    Log.i(TAG, "Member detail: lockUserId=$userId, nickName=${user?.nickName}, userType=${user?.userType}")

                    if (userId == 0) {
                        // V2 returned userId=0 — try V3 (Pro) member detail
                        Log.w(TAG, "lockUserId=0, trying getProCurrentMemberDetail")
                        tryProMemberUnlock(bleLock, result)
                    } else {
                        // Valid userId — proceed with BLE unlock
                        performBleUnlockWithId(bleLock, userId, result)
                    }
                }
                override fun onError(code: String?, message: String?) {
                    Log.e(TAG, "getCurrentMemberDetail failed: $code $message, trying V3")
                    tryProMemberUnlock(bleLock, result)
                }
            }
        )
    }

    private fun tryProMemberUnlock(bleLock: IThingBleLockV2, result: MethodChannel.Result) {
        try {
            bleLock.getProCurrentMemberDetail(
                object : IThingResultCallback<com.thingclips.smart.sdk.optimus.lock.bean.ble.BLELockUserV3> {
                    override fun onSuccess(user: com.thingclips.smart.sdk.optimus.lock.bean.ble.BLELockUserV3?) {
                        val userId = user?.lockUserId ?: 0
                        Log.i(TAG, "Pro member detail: lockUserId=$userId")
                        if (userId == 0) {
                            result.error("BLE_NO_MEMBER", "Lock user ID is 0 — this account is not registered as a lock member. Re-pair or add this user as a lock member.", null)
                        } else {
                            performBleUnlockWithId(bleLock, userId, result)
                        }
                    }
                    override fun onError(code: String?, message: String?) {
                        Log.e(TAG, "getProCurrentMemberDetail also failed: $code $message")
                        result.error("BLE_NO_MEMBER", "Cannot get lock member ID. Re-pair the lock or add this user as a lock member. ($code: $message)", null)
                    }
                }
            )
        } catch (e: Exception) {
            result.error("BLE_NO_MEMBER", "Member detail not available: ${e.message}", null)
        }
    }

    private fun performBleUnlockWithId(bleLock: IThingBleLockV2, userId: Int, result: MethodChannel.Result) {
        Log.i(TAG, "Calling bleUnlock with userId=$userId")
        bleLock.bleUnlock(userId, object : IResultCallback {
            override fun onSuccess() {
                Log.i(TAG, "BLE unlock success!")
                result.success(true)
            }
            override fun onError(code: String?, error: String?) {
                Log.e(TAG, "BLE unlock failed: $code $error")
                result.error("BLE_UNLOCK_FAILED", error ?: "Unlock failed", code)
            }
        })
    }

    // Called from push notification service or DP update to notify Flutter of doorbell press
    fun notifyDoorbellRing(devId: String, snapshot: String? = null) {
        runOnUiThread {
            doorbellEventSink?.success(hashMapOf(
                "event" to "doorbell_ring",
                "devId" to devId,
                "snapshot" to snapshot,
                "timestamp" to System.currentTimeMillis(),
            ))
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Clean up all P2P sessions
        cameraP2PMap.values.forEach { it.destroyP2P() }
        cameraP2PMap.clear()
    }
}
