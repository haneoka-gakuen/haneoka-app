package org.haneoka.device

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import app.tauri.plugin.Invoke

internal class PlaybackConnection(private val context: Context) : ServiceConnection {
    private var playback: PlaybackService.PlaybackBinder? = null
    private var bound = false
    private val pending = mutableListOf<Pair<PlaybackArgs, Invoke>>()

    fun dispatch(args: PlaybackArgs, invoke: Invoke) {
        val service = playback
        if (service != null) {
            runCatching { service.dispatch(args) }
                .onSuccess(invoke::resolve)
                .onFailure { invoke.reject(it.message ?: "audio_playback") }
            return
        }
        pending += args to invoke
        if (bound) return
        val intent = Intent(context, PlaybackService::class.java).setAction(PlaybackService.BIND_PLAYBACK)
        bound = context.bindService(intent, this, Context.BIND_AUTO_CREATE)
        if (!bound) close()
    }

    override fun onServiceConnected(name: ComponentName, service: IBinder) {
        playback = service as PlaybackService.PlaybackBinder
        val requests = pending.toList()
        pending.clear()
        requests.forEach { (args, invoke) -> dispatch(args, invoke) }
    }

    override fun onServiceDisconnected(name: ComponentName) {
        playback = null
    }

    override fun onBindingDied(name: ComponentName) = close()

    override fun onNullBinding(name: ComponentName) = close()

    fun close() {
        if (bound) context.unbindService(this)
        bound = false
        playback = null
        pending.forEach { (_, invoke) -> invoke.reject("audio_service") }
        pending.clear()
    }
}
