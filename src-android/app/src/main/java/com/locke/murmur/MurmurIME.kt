package com.locke.murmur

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.view.View
import kotlinx.coroutines.*

class MurmurIME : InputMethodService(), MicKeyboardView.Listener {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private lateinit var keyboardView: MicKeyboardView

    private var audioStreamer: AudioStreamer? = null
    private var volcengineClient: VolcengineClient? = null
    private var eventJob: Job? = null

    override fun onCreateInputView(): View {
        keyboardView = MicKeyboardView(this, this)
        return keyboardView
    }

    // MARK: - MicKeyboardView.Listener

    override fun onPressStart() {
        if (!hasAudioPermission()) {
            requestAudioPermission()
            return
        }
        startSession()
    }

    override fun onPressEnd() {
        stopSession()
    }

    // MARK: - Session lifecycle

    private fun startSession() {
        keyboardView.state = MicKeyboardView.State.RECORDING

        val vc = VolcengineClient()
        volcengineClient = vc
        vc.connect()

        val streamer = AudioStreamer { pcm -> vc.sendAudio(pcm) }
        audioStreamer = streamer
        streamer.start(scope)

        eventJob = scope.launch {
            try {
                for (event in vc.events) {
                    when (event) {
                        is AsrEvent.Result -> {
                            if (event.isFinal) {
                                if (event.text.isNotEmpty()) {
                                    currentInputConnection?.commitText(event.text, 1)
                                }
                                break
                            }
                        }
                        AsrEvent.Error -> break
                    }
                }
            } finally {
                finishSession()
            }
        }
    }

    private fun stopSession() {
        keyboardView.state = MicKeyboardView.State.PROCESSING
        audioStreamer?.stop()
        audioStreamer = null
        volcengineClient?.finish()
        // eventJob stays running — waits for isFinal result from server
    }

    private fun finishSession() {
        keyboardView.state = MicKeyboardView.State.IDLE
        eventJob?.cancel()
        eventJob = null
        volcengineClient?.disconnect()
        volcengineClient = null
    }

    // MARK: - Permissions

    private fun hasAudioPermission() =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestAudioPermission() {
        val intent = Intent(this, PermissionActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        startActivity(intent)
    }

    // MARK: - Lifecycle

    override fun onDestroy() {
        scope.cancel()
        audioStreamer?.stop()
        volcengineClient?.disconnect()
        super.onDestroy()
    }
}
