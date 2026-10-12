package kr.sseudam.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * '한 줄로 남기기'용 말로 받아쓰기 (기기 SpeechRecognizer, ko-KR).
 * - 안드로이드 12+ 에서 기기 안 인식기가 있으면 그것부터 (인터넷으로 나가지 않음),
 *   한국어를 지원하지 않으면 일반 인식기 + EXTRA_PREFER_OFFLINE(오프라인 우선)으로 한 번 더.
 * - 녹음(MediaRecorder) 중에는 마이크를 함께 쓸 수 없어 쓰지 않는다 → 긴 녹음의 글자 변환은 컴퓨터에서.
 * - 말을 멈추면 인식기가 스스로 끝나므로, 짧은 메모 받아쓰기에 맞다.
 */
class Dictation(private val ctx: Context, private val onPartial: (String) -> Unit, private val onFinal: (String) -> Unit) {
    val listening = MutableStateFlow(false)
    val error = MutableStateFlow("")
    private var sr: SpeechRecognizer? = null
    private var triedFallback = false

    fun available(): Boolean = SpeechRecognizer.isRecognitionAvailable(ctx) ||
        (Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx))

    fun start() {
        if (listening.value) return
        error.value = ""
        triedFallback = false
        val onDevice = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)
        begin(onDevice)
    }

    private fun begin(onDevice: Boolean) {
        destroy()
        val r = if (onDevice && Build.VERSION.SDK_INT >= 31) SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
        else SpeechRecognizer.createSpeechRecognizer(ctx)
        sr = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) { listening.value = true }
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onPartialResults(partialResults: Bundle?) {
                partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let(onPartial)
            }
            override fun onResults(results: Bundle?) {
                listening.value = false
                onFinal(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: "")
            }
            override fun onError(code: Int) {
                listening.value = false
                // 기기 안 인식기가 한국어를 모르면 → 일반 인식기(오프라인 우선)로 다시
                if (onDevice && !triedFallback && SpeechRecognizer.isRecognitionAvailable(ctx)) {
                    triedFallback = true; begin(false); return
                }
                onFinal("")
                error.value = when (code) {
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "말소리를 못 들었어요. 다시 눌러 말해 주세요."
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "마이크 권한이 필요해요."
                    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER ->
                        "이 폰은 인터넷이 있어야 받아쓰기가 돼요. 키보드의 🎤를 써 보세요."
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "마이크를 다른 곳에서 쓰고 있어요."
                    else -> "받아쓰기를 하지 못했어요 (코드 $code). 키보드의 🎤를 써 보세요."
                }
            }
        })
        val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ko-KR")
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        listening.value = true
        r.startListening(i)
    }

    fun stop() { sr?.stopListening() }

    fun destroy() {
        sr?.destroy(); sr = null
        listening.value = false
    }
}
