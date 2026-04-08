package com.example.xrda3_smart_life_app

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

import com.thingclips.smart.android.camera.sdk.ThingIPCSdk
import com.thingclips.smart.camera.camerasdk.thingplayer.callback.AbsP2pCameraListener
import com.thingclips.smart.camera.camerasdk.thingplayer.callback.OperationDelegateCallBack
import com.thingclips.smart.camera.ipccamerasdk.p2p.ICameraP2P
import com.thingclips.smart.camera.middleware.p2p.IThingSmartCameraP2P
import com.thingclips.smart.camera.middleware.widget.ThingCameraView
import com.thingclips.smart.home.sdk.ThingHomeSdk
import com.thingclips.smart.optimus.lock.api.IThingBleLockV2
import com.thingclips.smart.optimus.lock.api.IThingLockManager
import com.thingclips.smart.optimus.sdk.ThingOptimusSdk
import com.thingclips.smart.sdk.api.IResultCallback

class DoorbellCallActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_DEV_ID = "devId"
        const val EXTRA_DEV_NAME = "deviceName"
        private const val TAG = "DoorbellCall"
    }

    private lateinit var devId: String
    private var deviceName: String = "Doorbell"

    // Views
    private lateinit var cameraView: ThingCameraView
    private lateinit var connectingOverlay: LinearLayout
    private lateinit var incomingButtons: LinearLayout
    private lateinit var callControls: LinearLayout
    private lateinit var tvStatus: TextView
    private lateinit var tvTimer: TextView
    private lateinit var tvDeviceName: TextView
    private lateinit var tvMuteLabel: TextView
    private lateinit var tvTalkLabel: TextView
    private lateinit var tvUnlockLabel: TextView
    private lateinit var btnUnlock: ImageView

    // Camera P2P
    private var cameraP2P: IThingSmartCameraP2P<Any>? = null
    private var isLocked = true
    private var isConnected = false
    private var isPreviewing = false
    private var isTalking = false
    private var isMuted = false

    // Timer
    private val handler = Handler(Looper.getMainLooper())
    private var callSeconds = 0
    private val timerRunnable = object : Runnable {
        override fun run() {
            callSeconds++
            val min = callSeconds / 60
            val sec = callSeconds % 60
            tvTimer.text = String.format("%02d:%02d", min, sec)
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Show over lock screen
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )

        setContentView(R.layout.activity_doorbell_call)

        devId = intent.getStringExtra(EXTRA_DEV_ID) ?: run {
            Log.e(TAG, "No devId provided")
            finish()
            return
        }
        deviceName = intent.getStringExtra(EXTRA_DEV_NAME) ?: "Doorbell"

        initViews()
        initP2P()
    }

    private fun initViews() {
        cameraView = findViewById(R.id.camera_view)
        connectingOverlay = findViewById(R.id.connecting_overlay)
        incomingButtons = findViewById(R.id.incoming_buttons)
        callControls = findViewById(R.id.call_controls)
        tvStatus = findViewById(R.id.tv_status)
        tvTimer = findViewById(R.id.tv_timer)
        tvDeviceName = findViewById(R.id.tv_device_name)
        tvMuteLabel = findViewById(R.id.tv_mute_label)
        tvTalkLabel = findViewById(R.id.tv_talk_label)
        tvUnlockLabel = findViewById(R.id.tv_unlock_label)
        btnUnlock = findViewById(R.id.btn_unlock)

        tvDeviceName.text = deviceName

        // Decline button
        findViewById<ImageView>(R.id.btn_decline).setOnClickListener {
            Log.i(TAG, "Declined")
            cleanup()
            finish()
        }

        // Answer button — connect P2P and start preview + audio
        findViewById<ImageView>(R.id.btn_answer).setOnClickListener {
            Log.i(TAG, "Answered")
            answerCall()
        }

        // Mute button
        findViewById<ImageView>(R.id.btn_mute).setOnClickListener {
            toggleMute()
        }

        // Talk button
        findViewById<ImageView>(R.id.btn_talk).setOnClickListener {
            toggleTalk()
        }

        // Unlock/Lock toggle button
        btnUnlock.setOnClickListener {
            if (isLocked) unlockDoor() else lockDoor()
        }

        // End call button
        findViewById<ImageView>(R.id.btn_end_call).setOnClickListener {
            Log.i(TAG, "End call")
            cleanup()
            finish()
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun initP2P() {
        try {
            val ipcCore = ThingIPCSdk.getCameraInstance() ?: run {
                Log.e(TAG, "IPC SDK not available")
                tvStatus.text = "Camera SDK not available"
                return
            }
            cameraP2P = ipcCore.createCameraP2P(devId) as? IThingSmartCameraP2P<Any>
            if (cameraP2P == null) {
                Log.e(TAG, "Failed to create P2P for $devId")
                tvStatus.text = "Camera not available"
                return
            }

            // Create the video view
            cameraView.createVideoView(devId)

            // Generate camera view for rendering
            val viewObj = cameraView.createdView()
            if (viewObj != null) {
                cameraP2P?.generateCameraView(viewObj)
            }

            // Register P2P listener
            cameraP2P?.registerP2PCameraListener(object : AbsP2pCameraListener() {
                override fun onSessionStatusChanged(camera: Any?, sessionId: Int, sessionStatus: Int) {
                    Log.i(TAG, "Session status: $sessionStatus")
                    runOnUiThread {
                        when (sessionStatus) {
                            -3 -> tvStatus.text = "Connection timeout"
                            -1 -> tvStatus.text = "Connection failed"
                            2 -> {
                                tvStatus.text = "Connected"
                                isConnected = true
                            }
                        }
                    }
                }
            })

            Log.i(TAG, "P2P initialized for $devId")
        } catch (e: Exception) {
            Log.e(TAG, "initP2P error: ${e.message}")
            tvStatus.text = "Camera init failed"
        }
    }

    private fun answerCall() {
        tvStatus.text = "Connecting..."

        // Connect to camera P2P
        cameraP2P?.connect(devId, object : OperationDelegateCallBack {
            override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                Log.i(TAG, "P2P connected!")
                isConnected = true
                runOnUiThread {
                    // Switch to active call UI
                    connectingOverlay.visibility = View.GONE
                    callControls.visibility = View.VISIBLE
                    // Start call timer
                    handler.post(timerRunnable)

                    // 1. Start video preview
                    startPreview()
                    // 2. Enable audio (unmute speaker so you hear the person)
                    enableAudio()
                    // 3. Start two-way talk (open mic so they hear you)
                    startTalk()
                }
            }

            override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                Log.e(TAG, "P2P connect failed: errCode=$errCode")
                runOnUiThread {
                    tvStatus.text = "Connection failed ($errCode)"
                }
            }
        })
    }

    private fun startPreview() {
        cameraP2P?.startPreview(object : OperationDelegateCallBack {
            override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                Log.i(TAG, "Preview started")
                isPreviewing = true
            }

            override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                Log.e(TAG, "Preview failed: $errCode")
                runOnUiThread {
                    Toast.makeText(this@DoorbellCallActivity, "Video preview failed", Toast.LENGTH_SHORT).show()
                }
            }
        })
    }

    /// Enable audio: unmute the camera speaker + enable loudspeaker on phone
    private fun enableAudio() {
        // Unmute camera audio so you can hear the person at the door
        cameraP2P?.setMute(ICameraP2P.UNMUTE, object : OperationDelegateCallBack {
            override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                Log.i(TAG, "Audio unmuted — you can now hear the doorbell")
                isMuted = false
            }
            override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                Log.e(TAG, "Unmute failed: $errCode")
            }
        })

        // Enable loud speaker so audio plays through phone speaker (not earpiece)
        try {
            cameraP2P?.setLoudSpeakerStatus(true)
            Log.i(TAG, "Loudspeaker enabled")
        } catch (e: Exception) {
            Log.e(TAG, "setLoudSpeakerStatus error: ${e.message}")
        }
    }

    private fun startTalk() {
        cameraP2P?.startAudioTalk(object : OperationDelegateCallBack {
            override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                Log.i(TAG, "Talk started — person at door can hear you")
                isTalking = true
                runOnUiThread {
                    tvTalkLabel.text = "Talking"
                }
            }

            override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                Log.e(TAG, "Talk start failed: $errCode")
                isTalking = false
                runOnUiThread {
                    tvTalkLabel.text = "Talk"
                }
            }
        })
    }

    private fun stopTalk() {
        cameraP2P?.stopAudioTalk(object : OperationDelegateCallBack {
            override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                Log.i(TAG, "Talk stopped")
                isTalking = false
                runOnUiThread { tvTalkLabel.text = "Talk" }
            }

            override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                Log.e(TAG, "Talk stop failed: $errCode")
            }
        })
    }

    private fun toggleTalk() {
        if (isTalking) stopTalk() else startTalk()
    }

    private fun toggleMute() {
        val muteVal = if (isMuted) ICameraP2P.UNMUTE else ICameraP2P.MUTE
        cameraP2P?.setMute(muteVal, object : OperationDelegateCallBack {
            override fun onSuccess(sessionId: Int, requestId: Int, data: String?) {
                isMuted = !isMuted
                runOnUiThread {
                    tvMuteLabel.text = if (isMuted) "Unmute" else "Mute"
                }
            }

            override fun onFailure(sessionId: Int, requestId: Int, errCode: Int) {
                Log.e(TAG, "Mute toggle failed: $errCode")
            }
        })
    }

    private fun getBleLockInstance(): IThingBleLockV2 {
        ThingOptimusSdk.init(this)
        val lockManager = ThingOptimusSdk.getManager(IThingLockManager::class.java)
        return lockManager.getBleLockV2(devId)
    }

    private fun unlockDoor() {
        Log.i(TAG, "Unlocking door: $devId")
        Toast.makeText(this, "Unlocking...", Toast.LENGTH_SHORT).show()

        try {
            getBleLockInstance().remoteSwitchLock(true, object : IResultCallback {
                override fun onSuccess() {
                    Log.i(TAG, "Door unlocked!")
                    isLocked = false
                    runOnUiThread {
                        Toast.makeText(this@DoorbellCallActivity, "Door unlocked!", Toast.LENGTH_SHORT).show()
                        tvUnlockLabel.text = "Lock"
                        tvUnlockLabel.setTextColor(0xFFFF5252.toInt())
                        btnUnlock.setColorFilter(0xFFFF5252.toInt())
                    }
                }

                override fun onError(code: String?, error: String?) {
                    Log.e(TAG, "Unlock failed: $code $error")
                    runOnUiThread {
                        Toast.makeText(this@DoorbellCallActivity, "Unlock failed: $error", Toast.LENGTH_SHORT).show()
                    }
                }
            })
        } catch (e: Exception) {
            Log.e(TAG, "Unlock exception: ${e.message}")
            Toast.makeText(this, "Unlock error: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    private fun lockDoor() {
        Log.i(TAG, "Locking door: $devId")
        Toast.makeText(this, "Locking...", Toast.LENGTH_SHORT).show()

        try {
            val bleLock = getBleLockInstance()
            // Try BLE manual lock (most reliable)
            bleLock.bleManualLock(object : IResultCallback {
                override fun onSuccess() {
                    Log.i(TAG, "Door locked!")
                    isLocked = true
                    runOnUiThread {
                        Toast.makeText(this@DoorbellCallActivity, "Door locked!", Toast.LENGTH_SHORT).show()
                        tvUnlockLabel.text = "Unlock"
                        tvUnlockLabel.setTextColor(0xFF4CAF50.toInt())
                        btnUnlock.setColorFilter(0xFF4CAF50.toInt())
                    }
                }

                override fun onError(code: String?, error: String?) {
                    Log.e(TAG, "BLE lock failed: $code $error, trying remoteSwitchLock...")
                    // Fallback: remote switch lock
                    bleLock.remoteSwitchLock(false, object : IResultCallback {
                        override fun onSuccess() {
                            isLocked = true
                            runOnUiThread {
                                Toast.makeText(this@DoorbellCallActivity, "Door locked!", Toast.LENGTH_SHORT).show()
                                tvUnlockLabel.text = "Unlock"
                                tvUnlockLabel.setTextColor(0xFF4CAF50.toInt())
                                btnUnlock.setColorFilter(0xFF4CAF50.toInt())
                            }
                        }
                        override fun onError(code2: String?, error2: String?) {
                            runOnUiThread {
                                Toast.makeText(this@DoorbellCallActivity, "Lock failed", Toast.LENGTH_SHORT).show()
                            }
                        }
                    })
                }
            })
        } catch (e: Exception) {
            Log.e(TAG, "Lock exception: ${e.message}")
            Toast.makeText(this, "Lock error: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    private fun cleanup() {
        handler.removeCallbacks(timerRunnable)

        if (isTalking) {
            cameraP2P?.stopAudioTalk(null)
            isTalking = false
        }
        if (isPreviewing) {
            cameraP2P?.stopPreview(null)
            isPreviewing = false
        }
        cameraP2P?.destroyP2P()
        cameraP2P = null
        isConnected = false
    }

    override fun onResume() {
        super.onResume()
        cameraView.onResume()
    }

    override fun onPause() {
        super.onPause()
        cameraView.onPause()
    }

    override fun onDestroy() {
        cleanup()
        super.onDestroy()
    }
}
