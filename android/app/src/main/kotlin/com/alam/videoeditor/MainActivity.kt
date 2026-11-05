package com.alam.videoeditor

import android.media.MediaExtractor
import android.media.MediaMuxer
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "alam.video.editor/trim")
            .setMethodCallHandler { call, result ->
                if (call.method == "replaceAudio") {
                    val input=call.argument<String>("input")
                    val music=call.argument<String>("music")
                    val output=call.argument<String>("output")
                    val start=call.argument<Int>("startMs")
                    val end=call.argument<Int>("endMs")
                    if(input==null || music==null || output==null || start==null || end==null || end<=start) {
                        result.error("ARGS","Invalid audio export arguments",null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            replaceAudio(input,music,output,start.toLong()*1000,end.toLong()*1000)
                            Handler(Looper.getMainLooper()).post {result.success(output)}
                        } catch(e:Exception) {
                            Handler(Looper.getMainLooper()).post {result.error("AUDIO",e.message?:"Audio export failed",null)}
                        }
                    }
                    return@setMethodCallHandler
                }
                if (call.method == "merge") {
                    val inputs = call.argument<List<String>>("inputs")
                    val output = call.argument<String>("output")
                    if (inputs == null || inputs.size < 2 || output == null) {
                        result.error("ARGS", "Select at least two videos", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            merge(inputs, output)
                            Handler(Looper.getMainLooper()).post { result.success(output) }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post { result.error("MERGE", e.message ?: "Merge failed", null) }
                        }
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "trim") { result.notImplemented(); return@setMethodCallHandler }
                val input = call.argument<String>("input")
                val output = call.argument<String>("output")
                val startMs = call.argument<Int>("startMs")
                val endMs = call.argument<Int>("endMs")
                if (input == null || output == null || startMs == null || endMs == null || startMs < 0 || endMs <= startMs) {
                    result.error("ARGS", "Invalid trim arguments", null)
                    return@setMethodCallHandler
                }
                thread {
                    try {
                        trim(input, output, startMs.toLong() * 1000, endMs.toLong() * 1000)
                        Handler(Looper.getMainLooper()).post { result.success(output) }
                    } catch (e: Exception) {
                        Handler(Looper.getMainLooper()).post { result.error("EXPORT", e.message ?: "Export failed", null) }
                    }
                }
            }
    }

    // Remux a video track with an AAC music track. Original audio is replaced, not mixed.
    private fun replaceAudio(input:String,music:String,output:String,startUs:Long,endUs:Long) {
        val video=MediaExtractor()
        val audio=MediaExtractor()
        var muxer:MediaMuxer?=null
        var started=false
        try {
            video.setDataSource(input)
            audio.setDataSource(music)
            var vTrack=-1
            var aTrack=-1
            for(i in 0 until video.trackCount) {
                val mime=video.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?:""
                if(mime.startsWith("video/")){vTrack=i;break}
            }
            for(i in 0 until audio.trackCount) {
                val mime=audio.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?:""
                if(mime=="audio/mp4a-latm"){aTrack=i;break}
            }
            require(vTrack>=0){"No video track"}
            require(aTrack>=0){"Music must contain AAC audio"}
            val m=MediaMuxer(output,MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer=m
            val outV=m.addTrack(video.getTrackFormat(vTrack))
            val outA=m.addTrack(audio.getTrackFormat(aTrack))
            m.start();started=true
            video.selectTrack(vTrack)
            video.seekTo(startUs,MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val buffer=ByteBuffer.allocateDirect(8*1024*1024)
            val info=MediaCodec.BufferInfo()
            var base=-1L
            var count=0
            while(true){
                val t=video.sampleTime
                if(t<0 || t>endUs)break
                buffer.clear()
                val size=video.readSampleData(buffer,0)
                if(size<0)break
                if(base<0)base=t
                info.set(0,size,(t-base).coerceAtLeast(0),video.sampleFlags)
                m.writeSampleData(outV,buffer,info)
                count++
                if(!video.advance())break
            }
            require(count>0){"No video samples"}
            val durationUs=(endUs-base).coerceAtLeast(0)
            audio.selectTrack(aTrack)
            audio.seekTo(0,MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            var audioCount=0
            while(true){
                val t=audio.sampleTime
                if(t<0 || t>durationUs)break
                buffer.clear()
                val size=audio.readSampleData(buffer,0)
                if(size<0)break
                info.set(0,size,t.coerceAtLeast(0),audio.sampleFlags)
                m.writeSampleData(outA,buffer,info)
                audioCount++
                if(!audio.advance())break
            }
            require(audioCount>0){"No AAC samples"}
        } finally {
            video.release();audio.release()
            if(muxer!=null){try{if(started)muxer.stop()}finally{muxer.release()}}
        }
    }

    // Stream-copy MP4 trim: no re-encoding, and cuts may snap to nearby keyframes.
    private fun trim(input: String, output: String, startUs: Long, endUs: Long) {
        val extractor = MediaExtractor()
        extractor.setDataSource(input)
        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false
        try {
            val trackMap = mutableMapOf<Int, Int>()
            var maxInputSize = 1024 * 1024
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                    trackMap[i] = muxer.addTrack(format)
                    extractor.selectTrack(i)
                    if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                        maxInputSize = maxOf(maxInputSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                    }
                }
            }
            require(trackMap.isNotEmpty()) { "No audio/video tracks found" }
            muxer.start()
            started = true
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val buffer = ByteBuffer.allocateDirect(maxInputSize)
            val info = MediaCodec.BufferInfo()
            var firstTimestamp = -1L
            var sampleCount = 0
            while (true) {
                val index = extractor.sampleTrackIndex
                if (index < 0) break
                val time = extractor.sampleTime
                if (time < 0 || time > endUs) break
                val outputTrack = trackMap[index]
                if (outputTrack != null) {
                    buffer.clear()
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    if (firstTimestamp < 0) firstTimestamp = time
                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = (time - firstTimestamp).coerceAtLeast(0L)
                    info.flags = extractor.sampleFlags
                    muxer.writeSampleData(outputTrack, buffer, info)
                    sampleCount++
                }
                if (!extractor.advance()) break
            }
            require(sampleCount > 0) { "No samples found in selected range" }
        } finally {
            extractor.release()
            try { if (started) muxer.stop() } finally { muxer.release() }
        }
    }
    // Stream-copy merge requires matching codecs and media formats.
    private fun merge(inputs: List<String>, output: String) {
        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false
        try {
            val formats = mutableListOf<MediaFormat>()
            val first = MediaExtractor()
            try {
                first.setDataSource(inputs.first())
                for (i in 0 until first.trackCount) {
                    val f = first.getTrackFormat(i)
                    val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/") || mime.startsWith("audio/")) formats.add(f)
                }
            } finally { first.release() }
            require(formats.isNotEmpty()) { "No compatible media tracks" }
            val outputs = formats.map { muxer.addTrack(it) }
            muxer.start()
            started = true
            var offsetUs = 0L
            for (path in inputs) {
                val extractor = MediaExtractor()
                try {
                    extractor.setDataSource(path)
                    val tracks = mutableMapOf<Int, Int>()
                    var j = 0
                    for (i in 0 until extractor.trackCount) {
                        val f = extractor.getTrackFormat(i)
                        val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                        if (!mime.startsWith("video/") && !mime.startsWith("audio/")) continue
                        require(j < formats.size) { "Track count differs; use videos with matching formats" }
                        val expected = formats[j]
                        require(mime == expected.getString(MediaFormat.KEY_MIME)) { "Different video/audio codecs" }
                        if (mime.startsWith("video/")) {
                            require(f.getInteger(MediaFormat.KEY_WIDTH) == expected.getInteger(MediaFormat.KEY_WIDTH) &&
                                f.getInteger(MediaFormat.KEY_HEIGHT) == expected.getInteger(MediaFormat.KEY_HEIGHT)) {
                                "Video resolutions differ"
                            }
                        }
                        if (mime.startsWith("audio/")) {
                            require(f.getInteger(MediaFormat.KEY_SAMPLE_RATE) == expected.getInteger(MediaFormat.KEY_SAMPLE_RATE) &&
                                f.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == expected.getInteger(MediaFormat.KEY_CHANNEL_COUNT)) {
                                "Audio formats differ"
                            }
                        }
                        tracks[i] = outputs[j]
                        extractor.selectTrack(i)
                        j++
                    }
                    require(j == formats.size) { "Track count differs" }
                    val buffer = ByteBuffer.allocateDirect(8 * 1024 * 1024)
                    val info = MediaCodec.BufferInfo()
                    var firstUs = -1L
                    var lastUs = 0L
                    while (true) {
                        val track = extractor.sampleTrackIndex
                        if (track < 0) break
                        val time = extractor.sampleTime
                        if (firstUs < 0) firstUs = time
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        info.offset = 0
                        info.size = size
                        info.presentationTimeUs = offsetUs + (time - firstUs).coerceAtLeast(0L)
                        info.flags = extractor.sampleFlags
                        muxer.writeSampleData(tracks.getValue(track), buffer, info)
                        lastUs = maxOf(lastUs, (time - firstUs).coerceAtLeast(0L))
                        if (!extractor.advance()) break
                    }
                    offsetUs += lastUs + 33333L
                } finally { extractor.release() }
            }
        } finally {
            try { if (started) muxer.stop() } finally { muxer.release() }
        }
    }

}
