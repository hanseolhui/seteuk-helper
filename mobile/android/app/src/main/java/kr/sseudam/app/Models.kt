package kr.sseudam.app

import java.security.MessageDigest
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Locale

// 텍스트 동기화 기록 — 맥의 app/sync_text.py · 아이폰 SyncData.swift 와 같은 형식.
// 이 파일은 안드로이드 API를 쓰지 않는다 (JVM 단위 테스트에서 그대로 돌아가도록).

data class SClass(
    val uid: String,
    val updatedAt: Double,
    val deleted: Boolean = false,
    val year: Int? = null,
    val semester: Int? = null,
    val grade: Int? = null,
    val classNo: Int? = null,
    val subject: String? = null,
    val kind: String? = null,
    val label: String? = null,
) {
    val title: String
        get() {
            if (!label.isNullOrEmpty()) return label
            val base = listOfNotNull(grade?.let { "${it}학년" }, classNo?.let { "${it}반" }).joinToString(" ")
            return when (kind ?: "교과") {
                "담임" -> "$base (담임)"
                "동아리" -> "동아리 " + (subject ?: "")
                else -> listOf(base, subject ?: "").filter { it.isNotEmpty() }.joinToString(" ")
            }
        }
}

data class SStudent(
    val uid: String,
    val updatedAt: Double,
    val deleted: Boolean = false,
    val classUid: String? = null,
    val number: Int? = null,
    val name: String? = null,
    val aliases: String? = null,
) {
    val displayName: String get() = name ?: ""
}

data class SNote(
    val uid: String,
    val updatedAt: Double,
    val deleted: Boolean = false,
    val studentUid: String? = null,
    val date: String? = null,
    val kind: String? = null,
    val area: String? = null,
    val category: String? = null,
    val content: String? = null,
    val source: String? = null,
    val useInDraft: Int? = null,
)

data class SDraft(
    val uid: String,
    val updatedAt: Double,
    val deleted: Boolean = false,
    val studentUid: String? = null,
    val area: String? = null,
    val content: String? = null,
    val status: String? = null,
)

/** 생기부 영역 이름 (맥 db.AREAS 와 같음) */
object Areas {
    data class Area(val id: String, val name: String, val bytes: Int)
    val all = listOf(
        Area("subject", "교과 세특", 1500), Area("individual", "개인별 세특", 1500), Area("behavior", "행동특성", 900),
        Area("autonomy", "자율·자치", 1500), Area("career", "진로활동", 2100), Area("club", "동아리", 1500),
    )
    fun forKind(kind: String?): List<String> = when (kind ?: "교과") {
        "담임" -> listOf("behavior", "autonomy", "career", "individual")
        "동아리" -> listOf("club")
        "기타" -> all.map { it.id }
        else -> listOf("subject")
    }
    fun name(id: String?): String = all.firstOrNull { it.id == id }?.name ?: (id ?: "")
    fun limit(id: String?): Int = all.firstOrNull { it.id == id }?.bytes ?: 1500
}

/** NEIS 글자 수: 한글 3바이트, 영문·숫자 1바이트, 줄바꿈 2바이트 */
fun neisBytes(s: String): Int {
    var n = 0
    var i = 0
    while (i < s.length) {
        val cp = s.codePointAt(i)
        n += if (cp == '\n'.code) 2 else if (cp < 128) 1 else 3
        i += Character.charCount(cp)
    }
    return n
}

/** 맥·아이폰과 같은 uid (같은 반을 따로 만들어도 하나로 합쳐짐) */
object Uids {
    fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    fun classUid(year: Int?, semester: Int?, grade: Int?, classNo: Int?, subject: String?, kind: String?): String {
        val key = listOf(
            year?.toString() ?: "", semester?.toString() ?: "", grade?.toString() ?: "", classNo?.toString() ?: "",
            (subject ?: "").trim(), if (kind.isNullOrEmpty()) "교과" else kind,
        ).joinToString("|")
        return "c-" + sha1(key).take(16)
    }

    fun studentUid(classUid: String, name: String): String = "s-" + sha1("$classUid|${name.trim()}").take(16)

    fun newUid(prefix: String): String = prefix + java.util.UUID.randomUUID().toString().replace("-", "").take(16)
}

fun nowSec(): Double = System.currentTimeMillis() / 1000.0

fun isoDate(ms: Long = System.currentTimeMillis()): String =
    java.text.SimpleDateFormat("yyyy-MM-dd", Locale.US).format(java.util.Date(ms))

fun isoDaysAgo(n: Int): String = isoDate(System.currentTimeMillis() - n * 86_400_000L)

/** 3~8월 1학기, 9~2월 2학기 (1·2월은 전 학년도) */
fun currentTerm(cal: Calendar = Calendar.getInstance()): Pair<Int, Int> {
    val y = cal.get(Calendar.YEAR)
    val m = cal.get(Calendar.MONTH) + 1
    if (m <= 2) return (y - 1) to 2
    return y to (if (m <= 8) 1 else 2)
}

/** "10월 12일 (월)" 처럼 읽기 쉬운 날짜 */
fun friendlyDate(iso: String?): String {
    if (iso == null || iso.length < 10) return iso ?: ""
    val d = runCatching { LocalDate.parse(iso.take(10)) }.getOrNull() ?: return iso
    val today = LocalDate.now()
    if (d == today) return "오늘"
    if (d == today.minusDays(1)) return "어제"
    val f = if (d.year == today.year) DateTimeFormatter.ofPattern("M월 d일 (E)", Locale.KOREA)
    else DateTimeFormatter.ofPattern("yyyy년 M월 d일", Locale.KOREA)
    return d.format(f)
}

private fun cmpTerm(a: SClass, b: SClass): Int {
    val ay = a.year ?: 0; val by = b.year ?: 0
    if (ay != by) return by.compareTo(ay)
    val asem = a.semester ?: 0; val bsem = b.semester ?: 0
    if (asem != bsem) return bsem.compareTo(asem)
    return a.title.compareTo(b.title)
}

/** 한 시점의 전체 기록 (읽기 전용 질의 모음) */
data class DB(
    val classes: List<SClass> = emptyList(),
    val students: List<SStudent> = emptyList(),
    val notes: List<SNote> = emptyList(),
    val drafts: List<SDraft> = emptyList(),
) {
    val activeClasses: List<SClass> get() = classes.filter { !it.deleted }.sortedWith(::cmpTerm)

    fun studentsIn(c: SClass): List<SStudent> = students.filter { !it.deleted && it.classUid == c.uid }
        .sortedWith(compareBy<SStudent>({ it.number ?: 999 }, { it.displayName }))

    fun notesOf(s: SStudent): List<SNote> = notesOf(s.uid)
    fun notesOf(uid: String): List<SNote> = notes.filter { !it.deleted && it.studentUid == uid }
        .sortedWith(compareByDescending<SNote> { it.date ?: "" }.thenByDescending { it.updatedAt })

    fun draftsOf(s: SStudent): List<SDraft> = drafts.filter { !it.deleted && it.studentUid == s.uid }.sortedByDescending { it.updatedAt }
    fun classOf(s: SStudent): SClass? = classes.firstOrNull { it.uid == s.classUid }
    fun cls(uid: String?): SClass? = classes.firstOrNull { it.uid == uid && !it.deleted }
    fun student(uid: String?): SStudent? = students.firstOrNull { it.uid == uid }
    fun noteCount(c: SClass): Int {
        val ids = studentsIn(c).map { it.uid }.toSet()
        return notes.count { !it.deleted && it.studentUid in ids }
    }
    fun notesForSource(source: String): List<SNote> = notes.filter { !it.deleted && it.source == source }
    val hasRoster: Boolean get() = students.any { !it.deleted }

    val currentClasses: List<SClass>
        get() {
            val (y, s) = currentTerm()
            return activeClasses.filter {
                val cy = it.year ?: y; val cs = it.semester ?: s
                cy > y || (cy == y && cs >= s)
            }
        }
    val pastClasses: List<SClass>
        get() {
            val cur = currentClasses.map { it.uid }.toSet()
            return activeClasses.filter { it.uid !in cur }
        }

    fun search(q: String): List<SStudent> {
        val t = q.trim()
        if (t.isEmpty()) return emptyList()
        return students.filter {
            !it.deleted && (it.displayName.contains(t) || (it.aliases ?: "").contains(t)) && classOf(it)?.deleted == false
        }.sortedBy { it.displayName }
    }

    /** 같은 이름을 가진 다른 반 학생 (같은 학년·반의 교과/담임 명단은 같은 학생이므로 뺌) */
    fun sameName(s: SStudent): List<SStudent> {
        fun room(x: SStudent): String {
            val c = classOf(x); val g = c?.grade ?: return x.classUid ?: ""
            return "$g-${c.classNo ?: 0}"
        }
        val mine = room(s)
        return students.filter { !it.deleted && it.uid != s.uid && it.displayName == s.displayName && room(it) != mine }
    }

    fun isUnsure(n: SNote): Boolean = (n.category ?: "").startsWith(UNSURE_TAG) || (n.category ?: "").startsWith(GUESS_TAG)
    fun candidates(n: SNote): List<SStudent> {
        if (!isUnsure(n)) return emptyList()
        val list = (n.category ?: "").substringAfterLast(":")
        return list.split(",").mapNotNull { student(it) }
    }

    companion object {
        /** 동명이인이라 선생님 확인이 필요한 기록 표시 (category = "동명이인:uid,uid") */
        const val UNSURE_TAG = "동명이인"
        const val GUESS_TAG = "AI추정"
    }
}

/** 말하기 어려울 때 톡으로 남기는 빠른 기록 */
object QuickTags {
    val all = listOf(
        "👍" to "발표를 자신 있게 함", "🤝" to "친구를 도와 함께 해결함", "❓" to "좋은 질문을 함",
        "🌱" to "지난번보다 한 뼘 성장함", "📚" to "과제를 성실히 해 옴", "💡" to "창의적인 아이디어를 냄",
    )
}

/** 초안 검사: NEIS 바이트, 기재 금지어, 문장 끝(~함·~임) */
object DraftCheck {
    val forbidden = listOf(
        "토익", "TOEIC", "토플", "TOEFL", "텝스", "TEPS", "HSK", "JLPT", "DELF", "IELTS",
        "교외", "외부 대회", "올림피아드", "경시대회", "공모전", "수상", "입상", "금상", "은상", "동상", "대상을",
        "논문", "학회", "특허", "출판", "저서", "발명", "해외", "어학연수", "유학",
        "부모", "아버지", "어머니", "아빠", "엄마", "가정형편", "직업이", "학원", "과외", "인강",
    )

    data class Issue(val text: String, val serious: Boolean)

    fun issues(text: String, limit: Int): List<Issue> {
        val out = mutableListOf<Issue>()
        val b = neisBytes(text)
        if (b > limit) out += Issue("${b - limit}바이트 넘쳐요 ($b/$limit)", true)
        val low = text.lowercase()
        val found = forbidden.filter { low.contains(it.lowercase()) }
        if (found.isNotEmpty()) out += Issue("기재 금지어: " + found.take(4).joinToString(", "), true)
        val endings = text.split('.', '!', '?', '\n').map { it.trim() }.filter { it.isNotEmpty() }
        val plain = endings.count { it.endsWith("다") || it.endsWith("요") }
        if (plain > 0) out += Issue("‘~함·~임’으로 끝나지 않은 문장 ${plain}개", false)
        return out
    }
}

/** 반 전체 요청문 만들기 / 답 읽기 (이름은 '학생1, 학생2…'로 가림) */
object ClassPrompt {
    data class Item(val label: String, val student: SStudent, val notes: List<SNote>)

    fun items(cls: SClass, db: DB): List<Item> =
        db.studentsIn(cls).filter { db.notesOf(it).isNotEmpty() }.mapIndexed { i, s ->
            Item("학생${i + 1}", s, db.notesOf(s).reversed())
        }

    fun mask(text: String, items: List<Item>): String {
        var t = text
        for (it in items.sortedByDescending { it.student.displayName.length }) {
            val n = it.student.displayName
            if (n.isEmpty()) continue
            t = t.replace(n, it.label)
            if (n.length >= 3) t = t.replace(n.drop(1), it.label)
        }
        return t
    }

    fun build(items: List<Item>, area: String): String {
        val limit = Areas.limit(area)
        val body = items.joinToString("\n\n") { it ->
            "[${it.label}]\n" + it.notes.joinToString("\n") { n -> "- ${n.date ?: ""} ${mask(n.content ?: "", items)}" }
        }
        return """
너는 학교 선생님의 학교생활기록부 작성을 돕는 보조자야. 아래 학생마다 '관찰 기록'에 있는 사실만 근거로 ${Areas.name(area)} 초안을 써 줘.

[규칙]
- 학생마다 따로, 반드시 이 형식으로만 답해:
  [학생1]
  (초안 한 문단)

  [학생2]
  (초안 한 문단)
- 학생 이름은 쓰지 말고, 기록에 없는 활동·성과·수상은 절대 지어내지 마.
- 문장 끝은 '~함', '~임' 같은 명사형으로.
- 학생마다 NEIS 기준 ${limit}바이트(한글 1자 3바이트) 이내.
- 사교육·부모 직업·교외 수상·어학 시험 같은 기재 금지 내용은 넣지 마.
- 기록이 적은 학생은 짧게 써도 돼. 억지로 늘리지 마.

[관찰 기록]
$body
""".trim()
    }

    private val headRx = Regex("""(?m)^\s*[\[(【]?\s*\**\s*학생\s*(\d{1,3})\s*\**\s*[\])】]?\s*[:：.\-]?\s*""")

    fun parse(answer: String, items: List<Item>): List<Pair<Item, String>> {
        val ms = headRx.findAll(answer).toList()
        val out = mutableListOf<Pair<Item, String>>()
        for ((i, m) in ms.withIndex()) {
            val n = m.groupValues[1].toIntOrNull() ?: continue
            if (n < 1 || n > items.size) continue
            val start = m.range.last + 1
            val end = if (i + 1 < ms.size) ms[i + 1].range.first else answer.length
            var text = if (end > start) answer.substring(start, end).trim() else ""
            text = text.replace(Regex("""학생\s*\d{1,3}(은|는|이|가)?\s*"""), "").replace("**", "").trim()
            if (text.isNotEmpty()) out += items[n - 1] to text
        }
        return out
    }

    /** 학생 한 명 요청문 (이름은 'OO'으로) */
    fun forStudent(s: SStudent, notes: List<SNote>, area: String): String {
        val name = s.displayName
        val short = if (name.length >= 3) name.drop(1) else name
        val lines = notes.reversed().joinToString("\n") { n ->
            var t = n.content ?: ""
            if (name.isNotEmpty()) t = t.replace(name, "OO")
            if (short.isNotEmpty()) t = t.replace(short, "OO")
            "- [${n.date ?: ""}] $t"
        }
        return """
너는 학교 선생님의 학교생활기록부 작성을 돕는 보조자야. 아래 '관찰 기록'에 있는 사실만 근거로 ${Areas.name(area)} 초안을 써 줘.
- 학생은 'OO'로만 부르고 이름을 만들지 마.
- 기록에 없는 활동·성과·수상은 절대 지어내지 마.
- 문장 끝은 '~함', '~임' 같은 명사형으로, 한 문단으로 써 줘.
- NEIS 기준 ${Areas.limit(area)}바이트(한글 3바이트) 이내.
- 사교육·부모 직업·교외 수상 등 기재 금지 내용은 넣지 마.

관찰 기록:
$lines
""".trim()
    }
}

/** 명단 붙여넣기 한 줄 해석: "번호 이름" 또는 "이름". 반환 (번호, 이름) */
object Roster {
    private val numRx = Regex("""^\d{1,3}(번|\.|\))?\s*""")
    fun parse(text: String): List<Pair<Int?, String>> {
        val out = mutableListOf<Pair<Int?, String>>()
        for (raw in text.split('\n', ',', ';', '\t')) {
            var line = raw.trim()
            if (line.isEmpty()) continue
            var number: Int? = null
            numRx.find(line)?.let { m ->
                number = m.value.filter { it.isDigit() }.toIntOrNull()
                line = line.substring(m.range.last + 1).trim()
            }
            val name = line.split(" ").first()
            if (name.length !in 2..10) continue
            out += number to name
        }
        return out
    }
}
