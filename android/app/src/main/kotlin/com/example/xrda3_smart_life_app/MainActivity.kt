package com.example.xrda3_smart_life_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

import com.thingclips.smart.optimus.sdk.ThingOptimusSdk
import com.thingclips.smart.optimus.lock.api.IThingLockManager
import com.thingclips.smart.optimus.lock.api.IThingBleLockV2
import com.thingclips.smart.home.sdk.callback.IThingResultCallback
import com.thingclips.smart.sdk.optimus.lock.bean.DynamicPasswordBean
import com.thingclips.smart.optimus.lock.api.bean.OfflineTempPassword
import com.thingclips.smart.optimus.lock.api.enums.OfflineTempPasswordType

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

                            bleLock.getLockDynamicPassword(
                                object : IThingResultCallback<DynamicPasswordBean> {
                                    override fun onSuccess(bean: DynamicPasswordBean?) {
                                        val password = bean?.dynamicPassword
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
                        val effectiveTime: Long? = call.argument("effectiveTime")
                        val invalidTime: Long? = call.argument("invalidTime")

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

                            val startTime = effectiveTime ?: System.currentTimeMillis()
                            val endTime = invalidTime ?: (System.currentTimeMillis() + 24 * 60 * 60 * 1000)

                            bleLock.getOfflinePassword(
                                OfflineTempPasswordType.MULTIPLE,
                                startTime,
                                endTime,
                                name ?: "Temp Password",
                                object : IThingResultCallback<OfflineTempPassword> {
                                    override fun onSuccess(offlinePwd: OfflineTempPassword?) {
                                        val password = offlinePwd?.pwd
                                        Log.i("BLE Lock", "Temp password created: $password")
                                        result.success(password)
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
