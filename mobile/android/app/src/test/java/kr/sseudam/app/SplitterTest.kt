package kr.sseudam.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SplitterTest {
    private val c23 = SClass(Uids.classUid(2026, 2, 2, 3, "국어", "교과"), 0.0, year = 2026, semester = 2, grade = 2, classNo = 3, subject = "국어", kind = "교과")
    private val c24 = SClass(Uids.classUid(2026, 2, 2, 4, "국어", "교과"), 0.0, year = 2026, semester = 2, grade = 2, classNo = 4, subject = "국어", kind = "교과")
    private fun st(c: SClass, no: Int, name: String) = SStudent(Uids.studentUid(c.uid, name), 0.0, classUid = c.uid, number = no, name = name)
    private val minsu = st(c23, 1, "김민수")
    private val seoyeon = st(c23, 2, "이서연")
    private val jihun = st(c23, 3, "박지훈")
    private val minsu24 = st(c24, 1, "김민수")
    private val db = DB(listOf(c23, c24), listOf(minsu, seoyeon, jihun, minsu24))

    @Test fun uidsMatchMac() {
        assertEquals("c-0dea6970d95ee072", Uids.classUid(2026, 2, 2, 3, "국어", "교과"))
        assertEquals("s-15e31c410ba6846a", Uids.studentUid("c-0dea6970d95ee072", "김민수"))
    }

    @Test fun splitsByClassAndGivenName() {
        val r = Splitter.splitWithLeftover("이학년 삼반 김민수, 토론에서 근거를 세 가지 들었음. 서연이는 발표 자료를 정리함.", "",
            db.activeClasses, { db.studentsIn(it) })
        assertEquals(listOf(minsu.uid, seoyeon.uid), r.blocks.map { it.studentUid })
        assertTrue(r.blocks[0].content.startsWith("2학년 3반 김민수"))
        assertEquals(false, r.blocks[0].ambiguous)   // 반을 말했으니 2-3 김민수로 확정
        assertEquals("서연이는 발표 자료를 정리함.", r.blocks[1].content)
    }

    @Test fun sameNameWithoutClassIsAmbiguous() {
        val r = Splitter.splitWithLeftover("김민수 친구 의견을 모아 멋지게 발표함.", "", db.activeClasses, { db.studentsIn(it) })
        assertEquals(1, r.blocks.size)
        assertTrue(r.blocks[0].ambiguous)
        assertEquals(setOf(minsu.uid, minsu24.uid), r.blocks[0].candidates.toSet())
    }

    @Test fun fuzzyNameIsMarkedUnsure() {
        val only = DB(listOf(c23), listOf(minsu, seoyeon, jihun))
        val r = Splitter.splitWithLeftover("박지훙 실험 기록을 꼼꼼히 남김.", "", only.activeClasses, { only.studentsIn(it) })
        assertEquals(jihun.uid, r.blocks.single().studentUid)
        assertTrue(r.blocks.single().ambiguous)
    }

    @Test fun jamoAndBytes() {
        assertEquals(1, Splitter.jamoDistance("김민수", "김민쑤"))
        assertEquals(0, Splitter.jamoDistance("이서연", "이서연"))
        assertEquals(3 + 1 + 2, neisBytes("가a\n"))
        assertEquals("2학년 3반 김민수", Splitter.normalize("이학년 삼반 김민수"))
    }

    @Test fun draftParse() {
        val items = listOf(ClassPrompt.Item("학생1", minsu, emptyList()), ClassPrompt.Item("학생2", seoyeon, emptyList()))
        val p = ClassPrompt.parse("[학생1]\n토론에서 근거를 제시함.\n\n**학생2**: 발표 자료를 정리함.", items)
        assertEquals(2, p.size)
        assertEquals("발표 자료를 정리함.", p[1].second)
        assertTrue(DraftCheck.issues("학원에서 배움.", 1500).any { it.serious })
    }
}
