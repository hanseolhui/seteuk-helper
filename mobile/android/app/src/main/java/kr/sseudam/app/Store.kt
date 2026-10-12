package kr.sseudam.app

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

enum class Sync { OFF, PENDING, DONE, FAILED }

data class Recording(
    val id: String = UUID.randomUUID().toString(),
    val fileName: String,
    val createdAt: Long,
    val durationSec: Double,
    val kind: String,
    val memo: String,
    val google: Sync = Sync.OFF,
    val lastError: String = "",
) {
    fun toJson() = JSONObject().put("id", id).put("fileName", fileName).put("createdAt", createdAt)
        .put("duration", durationSec).put("kind", kind).put("memo", memo).put("google", google.name).put("lastError", lastError)

    companion object {
        fun from(o: JSONObject) = Recording(
            o.getString("id"), o.getString("fileName"), o.getLong("createdAt"), o.optDouble("duration", 0.0),
            o.optString("kind", "수업"), o.optString("memo", ""), Sync.valueOf(o.optString("google", "OFF")),
            o.optString("lastError", ""),
        )
    }
}

/** 녹음 목록·연결 정보. 녹음은 선생님이 지우기 전까지 휴대폰에 보관한다(학기말 아카이빙). */
object Store {
    private val _items = MutableStateFlow<List<Recording>>(emptyList())
    val items: StateFlow<List<Recording>> = _items
    private val _paired = MutableStateFlow(false)
    val paired: StateFlow<Boolean> = _paired
    private lateinit var ctx: Context

    fun init(c: Context) {
        if (::ctx.isInitialized) return
        ctx = c.applicationContext
        load()
        _paired.value = googleUrl().isNotEmpty() && googleToken().isNotEmpty()
    }

    val folder: File get() = File(ctx.filesDir, "recordings").apply { mkdirs() }
    private val index: File get() = File(folder, "index.json")
    private val prefs get() = ctx.getSharedPreferences("sseudam", Context.MODE_PRIVATE)

    fun file(r: Recording) = File(folder, r.fileName)
    fun googleUrl(): String = prefs.getString("googleUrl", "") ?: ""
    fun googleToken(): String = prefs.getString("googleToken", "") ?: ""
    fun teacherName(): String = prefs.getString("teacherName", "") ?: ""

    @Synchronized private fun load() {
        val list = mutableListOf<Recording>()
        if (index.exists()) runCatching {
            val arr = JSONArray(index.readText())
            for (i in 0 until arr.length()) list += Recording.from(arr.getJSONObject(i))
        }
        _items.value = list.filter { file(it).exists() }
    }

    @Synchronized private fun save(list: List<Recording>) {
        _items.value = list
        val arr = JSONArray(); list.forEach { arr.put(it.toJson()) }
        val tmp = File(folder, "index.json.tmp"); tmp.writeText(arr.toString()); tmp.renameTo(index)
    }

    fun add(temp: File, durationSec: Double, kind: String, memo: String, at: Long) {
        val f = SimpleDateFormat("yyyyMMdd HHmm", Locale.KOREA)
        var name = "쓰담 " + f.format(Date(at))
        if (kind == "상담") name += " 상담"
        val clean = memo.replace(Regex("[/\\\\:*?\"<>|\\n]"), " ").trim().take(30)
        if (clean.isNotEmpty()) name += " $clean"
        var fileName = "$name.m4a"; var i = 2
        while (File(folder, fileName).exists()) { fileName = "$name ($i).m4a"; i++ }
        temp.copyTo(File(folder, fileName)); temp.delete()
        val r = Recording(fileName = fileName, createdAt = at, durationSec = durationSec, kind = kind, memo = memo,
            google = if (_paired.value) Sync.PENDING else Sync.OFF)
        save(listOf(r) + _items.value)
        UploadWorker.enqueue(ctx)
    }

    fun update(r: Recording) = save(_items.value.map { if (it.id == r.id) r else it })

    fun delete(r: Recording) { file(r).delete(); save(_items.value.filter { it.id != r.id }) }

    fun pair(url: String, token: String, name: String) {
        prefs.edit().putString("googleUrl", url).putString("googleToken", token).putString("teacherName", name).apply()
        _paired.value = true
        save(_items.value.map { if (it.google == Sync.OFF) it.copy(google = Sync.PENDING) else it })
        UploadWorker.enqueue(ctx)
    }

    fun unpair() {
        prefs.edit().remove("googleUrl").remove("googleToken").apply()
        _paired.value = false
        save(_items.value.map { if (it.google != Sync.DONE) it.copy(google = Sync.OFF) else it })
    }

    /** sseudam://pair?u=...&t=...&n=...  (예전 seteuk:// 도 허용) */
    fun parsePairing(text: String): Triple<String, String, String>? {
        val uri = runCatching { android.net.Uri.parse(text.trim()) }.getOrNull() ?: return null
        if (uri.scheme !in listOf("sseudam", "seteuk") || uri.host != "pair") return null
        val u = uri.getQueryParameter("u") ?: return null
        val t = uri.getQueryParameter("t") ?: return null
        if (!u.startsWith("https://") || t.isEmpty()) return null
        return Triple(u, t, uri.getQueryParameter("n") ?: "")
    }
}
