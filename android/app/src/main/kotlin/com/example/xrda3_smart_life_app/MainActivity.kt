package com.example.xrda3_smart_life_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

import com.thingclips.smart.optimus.sdk.ThingOptimusSdk
import com.thingclips.smart.optimus.lock.api.IThingLockManager
import com.thingclips.smart.optimus.lock.api.IThingBleLockV2
import com.thingclips.smart.sdk.api.IThingResultCallback

class MainActivity : FlutterActivity() {
    private val CHANNEL = "xrda3_smart_lock/lock_extras"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDynamicPasswordBLE" -> {
                        val devId: String? = call.argument("devId")
                        if (devId == null) {
                            result.error("INVALID_ARG", "devId is required", null)
                            return@setMethodCallHandler
                        }

                        try {
                            ThingOptimusSdk.init(this)
                            val lockManager = ThingOptimusSdk.getManager(
                                IThingLockManager::class.java
                            )
                            val bleLock = lockManager.getBleLockV2(devId)

                            bleLock.getDynamicPassword(
                                object : IThingResultCallback<String> {
                                    override fun onSuccess(password: String?) {
                                        Log.i("BLE Lock", "Dynamic password: $password")
                                        result.success(password)
                                    }

                                    override fun onError(code: String?, message: String?) {
                                        Log.e("BLE Lock", "Dynamic password failed: $code $message")
                                        result.error(
                                            "BLE_DYNAMIC_PWD_FAILED",
                                            message ?: "Unknown error",
                                            code
                                        )
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            Log.e("BLE Lock", "Dynamic password exception: ${e.message}")
                            result.error("BLE_DYNAMIC_PWD_ERROR", e.message, null)
                        }
                    }

                    "createTempPasswordBLE" -> {
                        val devId: String? = call.argument("devId")
                        val name: String? = call.argument("name")
                        val password: String? = call.argument("password")
                        val effectiveTime: Long? = call.argument("effectiveTime")
                        val invalidTime: Long? = call.argument("invalidTime")
                        val availTimes: Int = call.argument("availTimes") ?: 1

                        if (devId == null || password == null) {
                            result.error("INVALID_ARG", "devId and password are required", null)
                            return@setMethodCallHandler
                        }

                        try {
                            ThingOptimusSdk.init(this)
                            val lockManager = ThingOptimusSdk.getManager(
                                IThingLockManager::class.java
                            )
                            val bleLock = lockManager.getBleLockV2(devId)

                            bleLock.createTempPassword(
                                name ?: "Temp Password",
                                password,
                                null,  // scheduleBean - null for one-time
                                "",    // phone
                                "",    // countryCode
                                effectiveTime ?: System.currentTimeMillis(),
                                invalidTime ?: (System.currentTimeMillis() + 5 * 60 * 1000),
                                availTimes,
                                object : IThingResultCallback<String> {
                                    override fun onSuccess(pwdResult: String?) {
                                        Log.i("BLE Lock", "Temp password created: $pwdResult")
                                        result.success(pwdResult)
                                    }

                                    override fun onError(code: String?, message: String?) {
                                        Log.e("BLE Lock", "Temp password failed: $code $message")
                                        result.error(
                                            "BLE_TEMP_PWD_FAILED",
                                            message ?: "Unknown error",
                                            code
                                        )
                                    }
                                }
                            )
                        } catch (e: Exception) {
                            Log.e("BLE Lock", "Temp password exception: ${e.message}")
                            result.error("BLE_TEMP_PWD_ERROR", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
