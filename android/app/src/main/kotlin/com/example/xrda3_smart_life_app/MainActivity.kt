package com.example.xrda3_smart_life_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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

class MainActivity : FlutterActivity() {
    private val CHANNEL = "xrda3_smart_lock/lock_extras"
    private val TAG = "LockExtras"

    private fun getBleLock(devId: String): IThingBleLockV2 {
        ThingOptimusSdk.init(this)
        val lockManager = ThingOptimusSdk.getManager(IThingLockManager::class.java)
        return lockManager.getBleLockV2(devId)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val devId: String? = call.argument("devId")

                when (call.method) {

                    // ── Dynamic Password (OTP) ──
                    "getDynamicPasswordBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            getBleLock(devId).getLockDynamicPassword(
                                object : IThingResultCallback<DynamicPasswordBean> {
                                    override fun onSuccess(bean: DynamicPasswordBean?) {
                                        Log.i(TAG, "Dynamic password: ${bean?.dynamicPassword}")
                                        result.success(bean?.dynamicPassword)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "Dynamic password failed: $code $message")
                                        result.error("BLE_DYNAMIC_PWD_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            Log.e(TAG, "Dynamic password exception: ${e.message}")
                            result.error("BLE_DYNAMIC_PWD_ERROR", e.message, null)
                        }
                    }

                    // ── Offline Temp Password (single-use OTP) ──
                    "createOfflinePasswordBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val name: String = call.argument("name") ?: "Temp Password"
                        val pwdType: String = call.argument("type") ?: "single"
                        val effectiveTime: Long = call.argument("effectiveTime")
                            ?: System.currentTimeMillis()
                        val invalidTime: Long = call.argument("invalidTime")
                            ?: (System.currentTimeMillis() + 5 * 60 * 1000)

                        val type = if (pwdType == "multiple")
                            OfflineTempPasswordType.MULTIPLE else OfflineTempPasswordType.SINGLE

                        try {
                            getBleLock(devId).getOfflinePassword(
                                type, effectiveTime, invalidTime, name,
                                object : IThingResultCallback<OfflineTempPassword> {
                                    override fun onSuccess(pwd: OfflineTempPassword?) {
                                        Log.i(TAG, "Offline password: ${pwd?.pwd}")
                                        result.success(hashMapOf(
                                            "password" to pwd?.pwd,
                                            "pwdId" to pwd?.pwdId,
                                            "pwdName" to pwd?.pwdName,
                                            "gmtStart" to pwd?.gmtStart,
                                            "gmtExpired" to pwd?.gmtExpired,
                                        ))
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "Offline password failed: $code $message")
                                        result.error("BLE_OFFLINE_PWD_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("BLE_OFFLINE_PWD_ERROR", e.message, null)
                        }
                    }

                    // ── Create Online Temp Password ──
                    "createOnlinePasswordBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        val name: String = call.argument("name") ?: "Online Temp"
                        val password: String = call.argument("password") ?: ""
                        val effectiveTime: Long = call.argument("effectiveTime")
                            ?: System.currentTimeMillis()
                        val invalidTime: Long = call.argument("invalidTime")
                            ?: (System.currentTimeMillis() + 24 * 60 * 60 * 1000)
                        val availTime: Int = call.argument("availTime") ?: 0  // 0 = unlimited

                        try {
                            val request = PasswordRequest()
                            request.name = name
                            request.password = password
                            request.effectiveTime = effectiveTime
                            request.invalidTime = invalidTime
                            request.availTime = availTime

                            getBleLock(devId).getCustomOnlinePassword(
                                request,
                                object : IThingResultCallback<String> {
                                    override fun onSuccess(pwdId: String?) {
                                        Log.i(TAG, "Online password created: $pwdId")
                                        result.success(pwdId)
                                    }
                                    override fun onError(code: String?, message: String?) {
                                        Log.e(TAG, "Online password failed: $code $message")
                                        result.error("BLE_ONLINE_PWD_FAILED", message ?: "Unknown error", code)
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            result.error("BLE_ONLINE_PWD_ERROR", e.message, null)
                        }
                    }

                    // ── List Online Passwords ──
                    "getOnlinePasswordListBLE" -> {
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            getBleLock(devId).getOnlinePasswordList(
                                0,  // authTypes bitmask (0 = all)
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

                    else -> result.notImplemented()
                }
            }
    }
}
