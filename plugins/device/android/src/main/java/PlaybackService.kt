package org.haneoka.device

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Binder
import android.os.IBinder
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.CacheBitmapLoader
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import app.tauri.annotation.InvokeArg
import app.tauri.plugin.JSObject
import okhttp3.OkHttpClient
import org.json.JSONArray
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.io.IOException
import java.util.UUID

@InvokeArg
class PlaybackArgs {
    lateinit var action: String
    var queueRevision: String? = null
    var queue: List<PlaybackTrack>? = null
    var index: Int? = null
    var position: Double? = null
    var playing: Boolean? = null
    var mode: String? = null
    var volume: Double? = null
}

@InvokeArg
class PlaybackTrack {
    lateinit var queueId: String
    lateinit var id: String
    lateinit var title: String
    lateinit var artist: String
    lateinit var url: String
    lateinit var source: String
    var songKey: String? = null
    var titleLanguage: String? = null
    var cover: String = ""
    var artwork: String? = null
    var detailPath: String? = null

    fun mediaItem() = MediaItem.Builder()
        .setMediaId(queueId)
        .setUri(source)
        .setMediaMetadata(MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)
            .setArtworkUri(artwork?.let(Uri::parse))
            .build())
        .build()

    fun display() = JSObject()
        .put("queueId", queueId)
        .put("id", id)
        .put("title", title)
        .put("artist", artist)
        .put("url", url)
        .put("songKey", songKey)
        .put("titleLanguage", titleLanguage)
        .put("cover", cover)
        .put("detailPath", detailPath)
}

@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    companion object {
        const val BIND_PLAYBACK = "org.haneoka.device.BIND_PLAYBACK"
        @Volatile var directProxyPort = 0
    }

    inner class PlaybackBinder : Binder() {
        fun dispatch(args: PlaybackArgs): JSObject = handle(args)
    }

    private lateinit var player: ExoPlayer
    private lateinit var session: MediaSession
    private var queue = emptyList<PlaybackTrack>()
    private var queueRevision = "empty"
    private var mode = "repeat-all"

    override fun onCreate() {
        super.onCreate()
        val systemProxy = ProxySelector.getDefault()
        val httpClient = OkHttpClient.Builder().proxySelector(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                val port = directProxyPort
                val host = uri.host.orEmpty()
                if (port > 0 && (host == "haneoka.org" || host.endsWith(".haneoka.org") ||
                        host == "haneoka.com" || host.endsWith(".haneoka.com"))) {
                    return listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port)))
                }
                return systemProxy?.select(uri) ?: listOf(Proxy.NO_PROXY)
            }

            override fun connectFailed(uri: URI, address: SocketAddress, failure: IOException) {
                systemProxy?.connectFailed(uri, address, failure)
            }
        }).build()
        val dataSource = OkHttpDataSource.Factory(httpClient)
        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .setAudioAttributes(AudioAttributes.DEFAULT, true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setMaxSeekToPreviousPositionMs(3_000)
            .build()
        setMode(mode)
        val builder = MediaSession.Builder(this, player)
            .setBitmapLoader(CacheBitmapLoader(DataSourceBitmapLoader.Builder(this)
                .setDataSourceFactory(dataSource)
                .build()))
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            builder.setSessionActivity(PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE))
        }
        session = builder.build()
        addSession(session)
    }

    override fun onBind(intent: Intent?): IBinder? =
        if (intent?.action == BIND_PLAYBACK) PlaybackBinder() else super.onBind(intent)

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession = session

    override fun onDestroy() {
        session.release()
        player.release()
        super.onDestroy()
    }

    private fun handle(args: PlaybackArgs): JSObject {
        when (args.action) {
            "state" -> Unit
            "configure" -> configure(args)
            "play" -> play()
            "pause" -> player.pause()
            "toggle" -> if (isPlaying()) player.pause() else play()
            "seek" -> if (queue.isNotEmpty()) player.seekTo(milliseconds(requireNotNull(args.position)))
            "next" -> skip(true)
            "previous" -> skip(false)
            "mode" -> setMode(requireNotNull(args.mode))
            "volume" -> player.volume = requireNotNull(args.volume).toFloat().coerceIn(0f, 1f)
            "clear" -> {
                player.pause()
                player.clearMediaItems()
                queue = emptyList()
                queueRevision = UUID.randomUUID().toString()
            }
            else -> error("audio_action")
        }
        return snapshot(args.queueRevision)
    }

    private fun configure(args: PlaybackArgs) {
        val tracks = requireNotNull(args.queue)
        require(tracks.isNotEmpty())
        val oldIndex = player.currentMediaItemIndex
        val oldItem = player.currentMediaItem
        val oldPosition = player.currentPosition
        val wasPlaying = isPlaying()
        val items = tracks.map(PlaybackTrack::mediaItem)
        val current = items.indexOfFirst {
            it.mediaId == oldItem?.mediaId && it.localConfiguration?.uri == oldItem?.localConfiguration?.uri
        }
        val index = (args.index ?: current.takeIf { it >= 0 } ?: oldIndex).coerceIn(items.indices)
        val position = args.position?.let(::milliseconds) ?: if (current == index) oldPosition else 0
        args.mode?.let(::setMode)
        args.volume?.let { player.volume = it.toFloat().coerceIn(0f, 1f) }
        if (current < 0 || current != index && args.index != null) {
            player.setMediaItems(items, index, position)
            player.prepare()
        } else {
            updateItems(items)
            if (args.index != null || args.position != null) player.seekTo(index, position)
        }
        queue = tracks
        queueRevision = UUID.randomUUID().toString()
        if (args.playing ?: wasPlaying) play() else player.pause()
    }

    private fun updateItems(items: List<MediaItem>) {
        val wanted = items.mapTo(HashSet()) { it.mediaId }
        for (index in player.mediaItemCount - 1 downTo 0) {
            if (player.getMediaItemAt(index).mediaId !in wanted) player.removeMediaItem(index)
        }
        items.forEachIndexed { index, item ->
            val existing = (index until player.mediaItemCount).firstOrNull {
                player.getMediaItemAt(it).mediaId == item.mediaId
            }
            if (existing == null) {
                player.addMediaItem(index, item)
            } else {
                if (existing != index) player.moveMediaItem(existing, index)
                if (player.getMediaItemAt(index) != item) player.replaceMediaItem(index, item)
            }
        }
        if (player.mediaItemCount > items.size) player.removeMediaItems(items.size, player.mediaItemCount)
    }

    private fun play() {
        if (queue.isEmpty()) return
        when (player.playbackState) {
            Player.STATE_IDLE -> player.prepare()
            Player.STATE_ENDED -> player.seekToDefaultPosition(player.currentMediaItemIndex)
        }
        player.play()
    }

    private fun skip(forward: Boolean) {
        if (queue.isEmpty()) return
        val index = player.currentMediaItemIndex
        val next = when {
            !forward && player.currentPosition > 3_000 -> index
            forward && mode == "shuffle" -> player.nextMediaItemIndex.takeIf { it != C.INDEX_UNSET } ?: index
            else -> (index + (if (forward) 1 else -1) + queue.size) % queue.size
        }
        player.seekTo(next, 0)
        play()
    }

    private fun setMode(value: String) {
        player.repeatMode = when (value) {
            "sequential" -> Player.REPEAT_MODE_OFF
            "repeat-one" -> Player.REPEAT_MODE_ONE
            "repeat-all", "shuffle" -> Player.REPEAT_MODE_ALL
            else -> error("audio_mode")
        }
        player.shuffleModeEnabled = value == "shuffle"
        mode = value
    }

    private fun isPlaying() = player.playWhenReady && player.playbackState != Player.STATE_ENDED &&
        player.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE && player.playerError == null

    private fun snapshot(revision: String?): JSObject {
        val ended = player.playbackState == Player.STATE_ENDED
        val state = JSObject()
            .put("queueRevision", queueRevision)
            .put("index", if (queue.isEmpty()) -1 else player.currentMediaItemIndex)
            .put("position", if (ended) 0.0 else player.currentPosition.coerceAtLeast(0) / 1_000.0)
            .put("duration", player.duration.coerceAtLeast(0) / 1_000.0)
            .put("playing", isPlaying())
            .put("mode", mode)
            .put("volume", player.volume.toDouble())
        if (revision != queueRevision) state.put("queue", JSONArray(queue.map(PlaybackTrack::display)))
        return state
    }

    private fun milliseconds(seconds: Double) = (seconds.coerceAtLeast(0.0) * 1_000).toLong()
}
