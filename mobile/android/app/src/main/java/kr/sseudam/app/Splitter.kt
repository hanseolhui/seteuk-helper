package kr.sseudam.app

/**
 * 받아쓴 글(또는 메모)을 학생 이름이 나오는 곳에서 나눈다 — 아이폰 Splitter.swift · 맥 pipeline.rule_segment 와 같은 규칙.
 * 더해서 "2학년 3반 김민수"처럼 반을 말하면 그 반 명단에서 먼저 찾는다 (이름이 같은 학생 구분),
 * 받아쓰기가 이름을 살짝 틀리게 적으면(자모 1개 차이) 그 학생으로 담되 '확인'을 붙인다.
 */
object Splitter {
    /** ambiguous: 이름이 같은 학생이 여러 반에 있고 어느 반인지 말하지 않았을 때 (선생님 확인 필요) */
    data class Block(val studentUid: String, val content: String, val ambiguous: Boolean = false, val candidates: List<String> = emptyList())
    data class Result(val blocks: List<Block>, val leftover: String)

    private data class Hit(val start: Int, val end: Int, val student: SStudent, val ambiguous: Boolean = false, val candidates: List<String> = emptyList())

    private val classRx = Regex("""(\d{1,2})\s*학년\s*(\d{1,2})\s*반|(\d{1,2})\s*-\s*(\d{1,2})(?=\s|반|$)""")
    private val wordRx = Regex("""[가-힣]{3,6}""")
    private val numRx = Regex("""(?:^|[\s.,])(\d{1,2})\s*번(?=[\s,.]|$)""")
    private val normRx = Regex("""([일이삼사오육]|\d)\s*학년\s*(십?[일이삼사오육칠팔구]?|\d{1,2})\s*반""")
    private const val ENDS = ".?!\n。"

    fun split(text: String, hint: String, classes: List<SClass>, studentsIn: (SClass) -> List<SStudent>): List<Block> =
        splitWithLeftover(text, hint, classes, studentsIn).blocks

    /** preferKind: 같은 반이 교과·담임 둘 다 있을 때 고를 쪽 (상담 → 담임, 수업 → 교과) */
    fun splitWithLeftover(
        raw: String, hint: String, classes: List<SClass>, studentsIn: (SClass) -> List<SStudent>, preferKind: String = "교과",
    ): Result {
        val classByUid = classes.associateBy { it.uid }
        fun room(s: SStudent): String {
            val c = classByUid[s.classUid ?: ""]
            return if (c?.grade == null) (s.classUid ?: "") else "${c.grade}-${c.classNo ?: 0}"
        }
        fun rank(s: SStudent): Int {
            val c = classByUid[s.classUid ?: ""]
            var r = 0
            if (c?.kind == preferKind) r -= 2
            val sub = c?.subject
            if (!sub.isNullOrEmpty() && hint.contains(sub)) r -= 3
            return r
        }
        fun dedupRooms(list: List<SStudent>): List<String> {
            val acc = mutableListOf<SStudent>()
            for (c in list) if (acc.none { room(it) == room(c) }) acc += c
            return acc.map { it.uid }
        }
        fun classFrom(m: MatchResult): SClass? {
            fun g(i: Int) = m.groups[i]?.value?.toIntOrNull()
            val grade = g(1) ?: g(3); val no = g(2) ?: g(4)
            return classes.firstOrNull { it.grade == grade && it.classNo == no }
        }

        val text = normalize(raw)

        // 반 언급 위치: (위치, 학급)
        val classMarks = mutableListOf<Pair<Int, SClass>>()
        for (m in classRx.findAll(text)) classFrom(m)?.let { classMarks += m.range.first to it }
        // 메모·파일 이름에 반이 있으면 처음부터 그 반 (예: "2-3 국어")
        val hintClass = classRx.find(hint)?.let { classFrom(it) }
        fun contextClass(pos: Int): SClass? = classMarks.lastOrNull { it.first <= pos }?.second ?: hintClass

        // 학생별 검색어 (긴 것 우선): 이름, 성 뺀 이름(3글자 이상), 별칭
        val keys = mutableListOf<Pair<String, SStudent>>()
        for (c in classes) for (s in studentsIn(c)) {
            val name = s.displayName
            val names = linkedSetOf(name)
            (s.aliases ?: "").split(',', '/', ' ').filter { it.isNotEmpty() }.forEach { names += it }
            if (name.length >= 3) names += name.drop(1)
            for (n in names) if (n.length >= 2) keys += n to s
        }
        val sortedKeys = keys.sortedByDescending { it.first.length }

        val hits = mutableListOf<Hit>()
        fun taken(p: Int) = hits.any { it.start <= p && p < it.end }
        val byName = LinkedHashMap<String, MutableList<SStudent>>()
        for ((n, s) in sortedKeys) byName.getOrPut(n) { mutableListOf() } += s
        val doneNames = HashSet<String>()
        for ((n, _) in sortedKeys) {
            if (!doneNames.add(n)) continue
            val cands = byName[n] ?: continue
            var from = 0
            while (true) {
                val start = text.indexOf(n, from)
                if (start < 0) break
                from = start + n.length
                if (taken(start)) continue
                val ctx = contextClass(start)
                // 말한 반(또는 같은 학년·반) 학생을 먼저, 그다음 수업/상담에 맞는 반
                val inCtx = if (ctx == null) null else cands.filter { c ->
                    c.classUid == ctx.uid || (ctx.grade != null && room(c) == "${ctx.grade}-${ctx.classNo ?: 0}")
                }.sortedBy { rank(it) }.firstOrNull()
                val pool = cands.sortedBy { rank(it) }
                val pick = inCtx ?: pool.first()
                // 다른 학년·반에 같은 이름이 있을 때만 '동명이인' (같은 반의 교과/담임은 같은 학생)
                val unsure = inCtx == null && cands.map { room(it) }.toSet().size > 1
                hits += Hit(start, start + n.length, pick, unsure, if (unsure) dedupRooms(pool) else emptyList())
            }
        }

        // 받아쓰기가 이름을 살짝 틀리게 적은 경우 ("김민쑤", "김밍수") — 성이 같고 자모 하나만 다르면 확인 표시와 함께
        val fuzzyNames = LinkedHashMap<String, SStudent>()
        for ((n, s) in sortedKeys) if (n.length == 3 && n == s.displayName) fuzzyNames[n] = s
        if (fuzzyNames.isNotEmpty()) {
            for (m in wordRx.findAll(text)) {
                val start = m.range.first
                if (taken(start)) continue
                val core = m.value.take(3)   // 조사 등 뒤는 버림
                if (fuzzyNames.containsKey(core)) continue
                // 성이 같고 자모 1개 차이, 또는 앞 두 글자가 같고 끝 글자만 비슷 ("김민쑤" ↔ "김민수", "이서윤" ↔ "이서연")
                val near = fuzzyNames.keys.filter { k ->
                    if (k[0] != core[0]) return@filter false
                    val d = jamoDistance(k, core)
                    d == 1 || (d == 2 && k.take(2) == core.take(2))
                }
                if (near.size != 1) continue
                val cands = (byName[near[0]] ?: continue).sortedBy { rank(it) }
                val ctx = contextClass(start)
                val pick = cands.firstOrNull { it.classUid == ctx?.uid } ?: cands.firstOrNull() ?: continue
                hits += Hit(start, start + 3, pick, true, dedupRooms(cands))
            }
        }

        // "N번" — 지금 말하는 반이 있을 때만
        for (m in numRx.findAll(text)) {
            val g = m.groups[1] ?: continue
            val pos = g.range.first
            val c = contextClass(pos) ?: continue
            val num = g.value.toIntOrNull() ?: continue
            val s = studentsIn(c).firstOrNull { it.number == num } ?: continue
            if (taken(pos)) continue
            hits += Hit(pos, m.range.last + 1, s)
        }
        hits.sortBy { it.start }
        if (hits.isEmpty()) return Result(emptyList(), squash(text))

        // 언급이 든 문장의 시작부터 다음 언급 문장 직전까지가 그 학생 몫
        val starts = mutableListOf<Int>()
        for (h in hits) {
            // 문장 시작부터 (같은 문장 안의 "2학년 3반"도 그 학생 몫에 들어감 — 아이폰과 같은 결과)
            var st = sentenceStart(text, h.start)
            if (starts.isNotEmpty() && st <= starts.last()) st = h.start
            starts += st
        }
        data class Span(val hit: Hit, val a: Int, var b: Int)
        val spans = mutableListOf<Span>()
        for ((i, h) in hits.withIndex()) {
            val stop = if (i + 1 < hits.size) starts[i + 1] else text.length
            val last = spans.lastOrNull()
            if (last != null && last.hit.student.uid == h.student.uid) last.b = stop
            else spans += Span(h, starts[i], stop)
        }
        val out = spans.mapNotNull { sp ->
            if (sp.a >= sp.b) return@mapNotNull null
            val chunk = squash(text.substring(sp.a, sp.b))
            if (chunk.length < 6) null
            else Block(sp.hit.student.uid, chunk.take(1200), sp.hit.ambiguous, sp.hit.candidates)
        }
        val lead = squash(text.substring(0, maxOf(0, starts[0])))
        return Result(out, if (lead.length >= 6) lead else "")
    }

    fun squash(s: String): String = s.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

    /** 문장 나누기 (마침표·물음표·느낌표·줄바꿈) */
    fun sentences(text: String): List<String> {
        val out = mutableListOf<String>()
        val cur = StringBuilder()
        for (ch in text) {
            cur.append(ch)
            if (ch in ENDS) {
                val t = cur.toString().trim()
                if (t.isNotEmpty()) out += t
                cur.clear()
            }
        }
        val t = cur.toString().trim()
        if (t.isNotEmpty()) out += t
        return out
    }

    /** 한글 자모 단위 편집 거리 (초성·중성·종성) */
    fun jamoDistance(a: String, b: String): Int {
        fun jamo(s: String): List<Int> {
            val out = mutableListOf<Int>()
            s.codePoints().forEach { v ->
                if (v in 0xAC00..0xD7A3) {
                    val i = v - 0xAC00
                    out += 1000 + i / 588; out += 2000 + (i % 588) / 28; out += 3000 + i % 28
                } else out += v
            }
            return out
        }
        val x = jamo(a); val y = jamo(b)
        val d = IntArray(y.size + 1) { it }
        for (i in 1..x.size) {
            var prev = d[0]; d[0] = i
            for (j in 1..y.size) {
                val t = d[j]
                d[j] = minOf(d[j] + 1, d[j - 1] + 1, prev + if (x[i - 1] == y[j - 1]) 0 else 1)
                prev = t
            }
        }
        return d[y.size]
    }

    private fun sentenceStart(text: String, pos: Int): Int {
        var i = pos
        while (i > 0 && text[i - 1] !in ENDS) {
            i--
            if (pos - i > 40) return pos
        }
        return i
    }

    /** 받아쓰기가 "이학년 삼반"처럼 한글 숫자로 적은 것을 숫자로 (학년과 반이 함께 나올 때만) */
    fun normalize(s: String): String {
        var out = s
        for (m in normRx.findAll(s).toList().reversed()) {
            val g = num(m.groupValues[1]); val c = num(m.groupValues[2])
            if (g <= 0 || c <= 0) continue
            out = out.replaceRange(m.range, "${g}학년 ${c}반")
        }
        return out
    }

    private fun num(w: String): Int {
        w.toIntOrNull()?.let { return it }
        val digits = mapOf('일' to 1, '이' to 2, '삼' to 3, '사' to 4, '오' to 5, '육' to 6, '칠' to 7, '팔' to 8, '구' to 9)
        var value = 0; var cur = 0
        for (ch in w) {
            if (ch == '십') { value += (if (cur == 0) 1 else cur) * 10; cur = 0 }
            else digits[ch]?.let { cur = it }
        }
        return value + cur
    }
}
