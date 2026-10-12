package kr.sseudam.app

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@Composable
fun ConnectScreen() {
    val ctx = LocalContext.current
    val paired by Store.paired.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var syncMsg by remember { mutableStateOf("") }
    var autoUpdate by remember { mutableStateOf(Updater.autoCheck(ctx)) }
    var updateMsg by remember { mutableStateOf("") }
    val update by Updater.available.collectAsStateWithLifecycle()

    fun test() = scope.launch {
        result = "확인 중…"
        result = try {
            withContext(Dispatchers.IO) { UploadWorker.post(Store.googleUrl(), JSONObject().put("action", "ping_phone").put("token", Store.googleToken())) }
            "✓ 연결되었어요"
        } catch (e: Exception) { e.message ?: "연결 실패" }
    }
    fun handle(text: String) {
        val p = Store.parsePairing(text)
        if (p == null) result = "쓰담 연결 QR이 아니에요." else { Store.pair(p.first, p.second, p.third); test() }
    }
    val scan = rememberLauncherForActivityResult(ScanContract()) { r -> r.contents?.let(::handle) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        syncMsg = try {
            val text = ctx.contentResolver.openInputStream(uri)!!.use { it.bufferedReader().readText() }
            val n = DataStore.importDoc(text)
            if (n == 0) "✓ 이미 같은 내용이에요" else "✓ 기록 ${n}개를 합쳤어요"
        } catch (e: Exception) { "가져오지 못했어요: ${e.message ?: "쓰담 기록 파일인지 확인해 주세요"}" }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        ScreenTitle("연결")
        Column(Modifier.fillMaxWidth().card(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("🖥️ 컴퓨터와 연결 (구글 드라이브)", fontWeight = FontWeight.Bold, color = T.ink, fontSize = 16.sp)
            if (paired) {
                Text("연결됨 · ${Store.teacherName().ifEmpty { "내 구글 드라이브" }}", color = T.mint, fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ChipButton("연결 확인") { test() }
                    ChipButton("연결 끊기", T.coral) { Store.unpair(); result = "" }
                }
            } else {
                BigButton("📷 컴퓨터 화면의 QR 찍기", Modifier.fillMaxWidth()) {
                    scan.launch(ScanOptions().setPrompt("컴퓨터 화면의 QR을 비춰 주세요").setBeepEnabled(false).setOrientationLocked(true))
                }
                TextButton({ manual = true }) { Text("연결 코드 붙여넣기") }
            }
            if (result.isNotEmpty()) Text(result, fontSize = 13.sp, color = if (result.startsWith("✓")) T.mint else T.coral)
            Text("컴퓨터의 쓰담 → 설정 → ‘휴대폰 쓰담 앱 연결’에 나오는 QR을 찍으세요. 녹음과 한 줄 메모는 선생님 본인의 구글 드라이브를 거쳐 컴퓨터로 가요. 이 연결로는 녹음·메모를 올리기만 할 수 있어요.",
                fontSize = 12.sp, color = T.soft)
        }

        // 학생 기록(글) 주고받기 — 구글 연결은 '올리기 전용'이라 파일로 옮긴다
        Column(Modifier.fillMaxWidth().card(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("📁 학생 기록 파일 (맥·다른 폰과 맞추기)", fontWeight = FontWeight.Bold, color = T.ink, fontSize = 16.sp)
            Text("반·학생 명단·관찰 기록·초안을 한 파일(.json)로 내보내거나, 맥·아이폰·다른 폰에서 내보낸 파일을 가져와 합쳐요. 녹음은 빠지고 글만 들어가요. 같은 기록은 나중에 고친 쪽이 남아요.",
                fontSize = 12.sp, color = T.soft)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("내보내기", T.blue, filled = true) {
                    runCatching { shareFile(ctx, DataStore.exportFile(), "application/json", "쓰담 기록 파일 보내기") }
                        .onFailure { syncMsg = "내보내지 못했어요: ${it.message}" }
                }
                ChipButton("가져오기", T.lavender) { pick.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }
                ChipButton("엑셀(CSV)", T.mint) { shareFile(ctx, DataStore.exportCSV(), "text/csv", "학생 기록 CSV") }
            }
            if (syncMsg.isNotEmpty()) Text(syncMsg, fontSize = 13.sp, color = if (syncMsg.startsWith("✓")) T.mint else T.coral)
            Text("💡 학생 기록 파일은 학생 이름이 들어 있어요. 내 구글 드라이브나 나에게 보내기처럼 선생님만 볼 수 있는 곳으로 옮겨 주세요.",
                fontSize = 12.sp, color = T.soft)
        }

        Column(Modifier.fillMaxWidth().card(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("✨ 자동으로 새 버전 확인", fontWeight = FontWeight.Bold, color = T.ink, fontSize = 16.sp)
                    Text("지금 버전 ${Updater.currentVersion(ctx)} · 하루에 한 번 확인해요", fontSize = 12.sp, color = T.soft)
                }
                Switch(autoUpdate, { autoUpdate = it; Updater.setAutoCheck(ctx, it) },
                    colors = SwitchDefaults.colors(checkedTrackColor = T.blue))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ChipButton("지금 확인") {
                    updateMsg = "확인 중…"
                    scope.launch {
                        val r = Updater.check(ctx, force = true)
                        updateMsg = if (Updater.installedFromPlay(ctx)) "플레이 스토어에서 업데이트돼요"
                        else if (r != null) "새 버전 ${r.version}이 있어요 · ‘담기’ 화면에서 업데이트를 눌러 주세요" else "✓ 최신 버전이에요"
                    }
                }
                if (update != null) ChipButton("업데이트", T.blue, filled = true) { scope.launch { Updater.downloadAndInstall(ctx, update!!) } }
            }
            if (updateMsg.isNotEmpty()) Text(updateMsg, fontSize = 13.sp, color = T.soft)
        }

        Column(Modifier.fillMaxWidth().card(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("🗂️ 녹음 보관", fontWeight = FontWeight.Bold, color = T.ink)
            Text("녹음은 선생님이 지우기 전까지 휴대폰에 그대로 보관돼요. 컴퓨터의 쓰담과 구글 드라이브에도 원본이 학기말 이후까지 보관돼요.", fontSize = 13.sp, color = T.soft)
        }
        TextButton({ openUrl(ctx, "https://github.com/hanseolhui/sseudam") }) { Text("컴퓨터용 쓰담 설치·사용법") }
        TextButton({ openUrl(ctx, "https://hanseolhui.github.io/sseudam/privacy.html") }) { Text("개인정보 처리방침") }
        Spacer(Modifier.height(20.dp))
    }
    if (manual) AlertDialog(onDismissRequest = { manual = false }, containerColor = T.card, title = { Text("연결 코드") },
        text = { OutlinedTextField(code, { code = it }, placeholder = { Text("sseudam://pair?…") }) },
        confirmButton = { TextButton({ manual = false; handle(code); code = "" }) { Text("연결") } },
        dismissButton = { TextButton({ manual = false }) { Text("취소") } })
}
