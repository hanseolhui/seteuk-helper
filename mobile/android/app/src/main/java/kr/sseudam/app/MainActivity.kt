package kr.sseudam.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Accent = Color(0xFF2F6FDE)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Store.init(this)
        handleLink(intent)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Accent)) { App() }
        }
        UploadWorker.enqueue(this)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handleLink(intent) }

    private fun handleLink(i: Intent?) {
        val data = i?.data?.toString() ?: return
        Store.parsePairing(data)?.let { (u, t, n) -> Store.pair(u, t, n) }
    }
}

@Composable
fun App() {
    var tab by remember { mutableIntStateOf(0) }
    Scaffold(bottomBar = {
        NavigationBar {
            NavigationBarItem(tab == 0, { tab = 0 }, { Icon(Icons.Filled.Mic, null) }, label = { Text("녹음") })
            NavigationBarItem(tab == 1, { tab = 1 }, { Icon(Icons.Filled.List, null) }, label = { Text("녹음 목록") })
            NavigationBarItem(tab == 2, { tab = 2 }, { Icon(Icons.Filled.Sync, null) }, label = { Text("연결") })
        }
    }) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when (tab) { 0 -> RecordScreen(); 1 -> ListScreen(); else -> ConnectScreen() }
        }
    }
}

fun timeString(ms: Long): String {
    val s = ms / 1000
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60)
}

@Composable
fun RecordScreen() {
    val ctx = LocalContext.current
    val recording by RecordService.recording.collectAsStateWithLifecycle()
    val paused by RecordService.paused.collectAsStateWithLifecycle()
    val level by RecordService.level.collectAsStateWithLifecycle()
    val paired by Store.paired.collectAsStateWithLifecycle()
    var elapsed by remember { mutableLongStateOf(0L) }
    var pending by remember { mutableStateOf<Triple<File, Long, Long>?>(null) }
    var saved by remember { mutableStateOf(false) }
    LaunchedEffect(recording) { while (recording) { elapsed = RecordService.elapsedMs(); delay(100) } }

    val perm = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res[Manifest.permission.RECORD_AUDIO] == true) RecordService.start(ctx)
    }
    fun toggle() {
        if (recording) {
            val dur = RecordService.elapsedMs(); val at = RecordService.startedAt
            RecordService.stop(ctx)
            RecordService.lastFile?.let { f -> if (dur >= 1000) pending = Triple(f, dur, at) else f.delete() }
            elapsed = 0
        } else if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            RecordService.start(ctx)
        } else {
            val ps = mutableListOf(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) ps += Manifest.permission.POST_NOTIFICATIONS
            perm.launch(ps.toTypedArray())
        }
    }

    Column(Modifier.fillMaxSize().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("쓰담", fontSize = 30.sp, fontWeight = FontWeight.ExtraBold, color = Accent, modifier = Modifier.fillMaxWidth())
        Text("말로 담고, 글로 씁니다", fontSize = 13.sp, color = Color.Gray, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.weight(1f))
        Text(timeString(elapsed), fontSize = 60.sp, fontWeight = FontWeight.Light,
            color = if (recording) MaterialTheme.colorScheme.onBackground else Color.Gray)
        Spacer(Modifier.height(16.dp))
        LinearProgressIndicator(progress = { if (recording && !paused) level else 0f }, modifier = Modifier.fillMaxWidth(0.7f).height(8.dp).clip(CircleShape))
        Spacer(Modifier.height(12.dp))
        Text(if (!recording) "버튼을 누르면 바로 녹음됩니다" else if (paused) "일시정지됨" else "녹음 중 · 화면을 꺼도 계속 녹음됩니다",
            color = Color.Gray, fontSize = 14.sp)
        Spacer(Modifier.height(24.dp))
        FilledIconButton(onClick = ::toggle, modifier = Modifier.size(120.dp),
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = if (recording) Color(0xFFE5484D) else Accent)) {
            Icon(if (recording) Icons.Filled.Stop else Icons.Filled.Mic, contentDescription = if (recording) "녹음 끝내기" else "녹음 시작",
                modifier = Modifier.size(52.dp), tint = Color.White)
        }
        if (recording) {
            Spacer(Modifier.height(12.dp))
            OutlinedButton(onClick = { RecordService.togglePause(ctx) }) { Text(if (paused) "이어서 녹음" else "일시정지") }
        }
        if (saved) {
            Spacer(Modifier.height(12.dp))
            Text(if (paired) "✓ 저장 완료 · 컴퓨터로 자동 전송됩니다" else "✓ 저장 완료 · '연결' 탭에서 컴퓨터와 연결하세요", color = Color(0xFF1F9D6B))
        }
        Spacer(Modifier.weight(1f))
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color(0xFFF0F2F5)).padding(14.dp)) {
            Text("💡 이렇게 말하면 학생별로 자동 정리돼요", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            Text("“2학년 3반 김민수! 친구 의견 모아 멋지게 발표 🌟 이서연은 실험 기록을 꼼꼼히 💛”", color = Color.Gray, fontSize = 13.sp)
        }
    }

    pending?.let { (file, dur, at) ->
        var kind by remember { mutableStateOf("수업") }
        var memo by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = {},
            title = { Text("녹음 저장 (${timeString(dur)})") },
            text = {
                Column {
                    Row { listOf("수업", "상담").forEach { k ->
                        FilterChip(selected = kind == k, onClick = { kind = k }, label = { Text(k) }, modifier = Modifier.padding(end = 8.dp))
                    } }
                    OutlinedTextField(memo, { memo = it }, label = { Text("메모 (선택) 예: 2-3 국어") }, singleLine = true)
                    Text("학급은 컴퓨터의 시간표나 녹음 내용으로 자동 지정됩니다.", fontSize = 12.sp, color = Color.Gray)
                }
            },
            confirmButton = { TextButton({ Store.add(file, dur / 1000.0, kind, memo, at); pending = null; saved = true }) { Text("저장") } },
            dismissButton = { TextButton({ file.delete(); pending = null }) { Text("버리기", color = Color(0xFFE5484D)) } },
        )
    }
}

@Composable
fun ListScreen() {
    val items by Store.items.collectAsStateWithLifecycle()
    var playing by remember { mutableStateOf<String?>(null) }
    val player = remember { MediaPlayer() }
    DisposableEffect(Unit) { onDispose { player.release() } }
    val df = remember { SimpleDateFormat("M월 d일 (E) HH:mm", Locale.KOREA) }
    var confirmDelete by remember { mutableStateOf<Recording?>(null) }

    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Text("녹음 목록", fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(vertical = 16.dp))
        if (items.isEmpty()) {
            Text("아직 녹음이 없습니다. 녹음 탭에서 녹음하면 여기에 쌓이고, 컴퓨터로 자동 전송됩니다.", color = Color.Gray)
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(items, key = { it.id }) { r ->
                Card { Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton({
                        if (playing == r.id) { player.reset(); playing = null } else {
                            player.reset(); player.setDataSource(Store.file(r).absolutePath); player.prepare(); player.start()
                            player.setOnCompletionListener { playing = null }; playing = r.id
                        }
                    }) { Icon(if (playing == r.id) Icons.Filled.StopCircle else Icons.Filled.PlayCircle, null, tint = Accent, modifier = Modifier.size(36.dp)) }
                    Column(Modifier.weight(1f)) {
                        Text(df.format(Date(r.createdAt)), fontWeight = FontWeight.Medium)
                        Text("${r.kind} · ${timeString((r.durationSec * 1000).toLong())}${if (r.memo.isNotEmpty()) " · " + r.memo else ""}",
                            fontSize = 12.sp, color = Color.Gray)
                        if (r.google == Sync.FAILED && r.lastError.isNotEmpty()) Text(r.lastError, fontSize = 11.sp, color = Color(0xFFE5484D))
                    }
                    Text(when (r.google) { Sync.DONE -> "✓ 전송됨"; Sync.PENDING -> "대기"; Sync.FAILED -> "다시 시도"; Sync.OFF -> "" },
                        fontSize = 12.sp, color = when (r.google) { Sync.DONE -> Color(0xFF1F9D6B); Sync.FAILED -> Color(0xFFE5484D); else -> Color.Gray })
                    IconButton({ confirmDelete = r }) { Icon(Icons.Filled.DeleteOutline, "삭제", tint = Color.Gray) }
                } }
            }
        }
    }
    confirmDelete?.let { r ->
        AlertDialog(onDismissRequest = { confirmDelete = null }, title = { Text("이 녹음을 지울까요?") },
            text = { Text(if (r.google == Sync.DONE) "컴퓨터에는 이미 전송되어 보관되어 있습니다." else "아직 컴퓨터로 전송되지 않았습니다. 지우면 되돌릴 수 없습니다.") },
            confirmButton = { TextButton({ Store.delete(r); confirmDelete = null }) { Text("지우기", color = Color(0xFFE5484D)) } },
            dismissButton = { TextButton({ confirmDelete = null }) { Text("취소") } })
    }
}

@Composable
fun ConnectScreen() {
    val ctx = LocalContext.current
    val paired by Store.paired.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }

    fun test() = scope.launch {
        result = "확인 중…"
        result = try {
            withContext(Dispatchers.IO) { UploadWorker.post(Store.googleUrl(), JSONObject().put("action", "ping_phone").put("token", Store.googleToken())) }
            "✓ 연결되었습니다"
        } catch (e: Exception) { e.message ?: "연결 실패" }
    }
    fun handle(text: String) {
        val p = Store.parsePairing(text)
        if (p == null) result = "쓰담 연결 QR이 아닙니다." else { Store.pair(p.first, p.second, p.third); test() }
    }
    val scan = rememberLauncherForActivityResult(ScanContract()) { r -> r.contents?.let(::handle) }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("연결", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Card { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("컴퓨터와 연결 (구글 드라이브)", fontWeight = FontWeight.SemiBold)
            if (paired) {
                Text("연결됨 · ${Store.teacherName().ifEmpty { "내 구글 드라이브" }}", color = Color(0xFF1F9D6B))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(::test) { Text("연결 확인") }
                    TextButton({ Store.unpair(); result = "" }) { Text("연결 끊기", color = Color(0xFFE5484D)) }
                }
            } else {
                Button({ scan.launch(ScanOptions().setPrompt("컴퓨터 화면의 QR을 비춰 주세요").setBeepEnabled(false).setOrientationLocked(true)) }) {
                    Icon(Icons.Filled.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text("컴퓨터 화면의 QR 찍기")
                }
                TextButton({ manual = true }) { Text("연결 코드 붙여넣기") }
            }
            if (result.isNotEmpty()) Text(result, fontSize = 13.sp, color = if (result.startsWith("✓")) Color(0xFF1F9D6B) else Color(0xFFE5484D))
            Text("컴퓨터의 쓰담 → 설정 → '휴대폰 쓰담 앱 연결'에 나오는 QR을 찍으세요. 녹음은 선생님 본인의 구글 드라이브를 거쳐 컴퓨터로 갑니다. 이 앱은 녹음을 올리기만 할 수 있고, 학생 기록을 볼 수는 없습니다.",
                fontSize = 12.sp, color = Color.Gray)
        } }
        Card { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("녹음 보관", fontWeight = FontWeight.SemiBold)
            Text("녹음은 선생님이 지우기 전까지 휴대폰에 그대로 보관됩니다. 컴퓨터의 쓰담과 구글 드라이브에도 원본이 학기말 이후까지 보관됩니다.", fontSize = 13.sp, color = Color.Gray)
        } }
        TextButton({ ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/hanseolhui/sseudam"))) }) { Text("컴퓨터용 쓰담 설치·사용법") }
        TextButton({ ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://hanseolhui.github.io/sseudam/privacy.html"))) }) { Text("개인정보 처리방침") }
    }
    if (manual) AlertDialog(onDismissRequest = { manual = false }, title = { Text("연결 코드") },
        text = { OutlinedTextField(code, { code = it }, placeholder = { Text("sseudam://pair?…") }) },
        confirmButton = { TextButton({ manual = false; handle(code); code = "" }) { Text("연결") } },
        dismissButton = { TextButton({ manual = false }) { Text("취소") } })
}
