import Foundation

/// 받아쓴 글을 학생 이름이 나오는 곳에서 나눈다 (맥 pipeline.rule_segment 와 같은 규칙).
/// 더해서 "2학년 3반 김민수"처럼 반을 말하면 그 반 명단에서 먼저 찾는다 (이름이 같은 학생 구분).
enum Splitter {
    /// ambiguous: 이름이 같은 학생이 여러 반에 있고 어느 반인지 말하지 않았을 때 (선생님 확인 필요)
    struct Block { var studentUID: String; var content: String; var ambiguous: Bool = false; var candidates: [String] = [] }
    struct Result { var blocks: [Block]; var leftover: String }

    private struct Hit { var start: Int; var end: Int; var student: SStudent; var ambiguous = false; var candidates: [String] = [] }

    static func split(text raw: String, hint: String, classes: [SClass], studentsIn: (SClass) -> [SStudent]) -> [Block] {
        splitWithLeftover(text: raw, hint: hint, classes: classes, studentsIn: studentsIn).blocks
    }

    /// preferKind: 같은 반이 교과·담임 둘 다 있을 때 고를 쪽 (상담 → 담임, 수업 → 교과)
    static func splitWithLeftover(text raw: String, hint: String, classes: [SClass], studentsIn: (SClass) -> [SStudent],
                                  preferKind: String = "교과") -> Result {
        let classByUID = Dictionary(uniqueKeysWithValues: classes.map { ($0.uid, $0) })
        func room(_ s: SStudent) -> String {
            let c = classByUID[s.class_uid ?? ""]
            return c?.grade == nil ? (s.class_uid ?? "") : "\(c?.grade ?? 0)-\(c?.class_no ?? 0)"
        }
        func rank(_ s: SStudent) -> Int {
            let c = classByUID[s.class_uid ?? ""]
            var r = 0
            if c?.kind == preferKind { r -= 2 }
            if let sub = c?.subject, !sub.isEmpty, hint.contains(sub) { r -= 3 }
            return r
        }
        let text = normalize(raw)
        let chars = Array(text)
        let ns = text as NSString

        // 반 언급 위치: (위치, 학급)
        var classMarks: [(Int, SClass)] = []
        let rx = try! NSRegularExpression(pattern: #"(\d{1,2})\s*학년\s*(\d{1,2})\s*반|(\d{1,2})\s*-\s*(\d{1,2})(?=\s|반|$)"#)
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
            let grade = g(1) ?? g(3), no = g(2) ?? g(4)
            if let c = classes.first(where: { $0.grade == grade && $0.class_no == no }) {
                classMarks.append((charIndex(text, m.range.location), c))
            }
        }
        // 메모·파일 이름에 반이 있으면 처음부터 그 반 (예: "2-3 국어")
        let hintClass: SClass? = {
            let hns = hint as NSString
            guard let m = rx.firstMatch(in: hint, range: NSRange(location: 0, length: hns.length)) else { return nil }
            func g(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(hns.substring(with: m.range(at: i))) }
            let grade = g(1) ?? g(3), no = g(2) ?? g(4)
            return classes.first { $0.grade == grade && $0.class_no == no }
        }()
        func contextClass(at pos: Int) -> SClass? { classMarks.last(where: { $0.0 <= pos })?.1 ?? hintClass }

        // 학생별 검색어 (긴 것 우선): 이름, 성 뺀 이름(3글자 이상), 별칭
        var keys: [(String, SStudent)] = []
        for c in classes {
            for s in studentsIn(c) {
                let name = s.displayName
                var names = Set([name])
                (s.aliases ?? "").split(whereSeparator: { ",/ ".contains($0) }).forEach { names.insert(String($0)) }
                if name.count >= 3 { names.insert(String(name.dropFirst())) }
                for n in names where n.count >= 2 { keys.append((n, s)) }
            }
        }
        keys.sort { $0.0.count > $1.0.count }

        var hits: [Hit] = []
        func taken(_ p: Int) -> Bool { hits.contains { $0.start <= p && p < $0.end } }
        // 같은 글자에 여러 학생이 걸리면 (동명이인) 문맥상 반을 우선
        var byName: [String: [SStudent]] = [:]
        for (n, s) in keys { byName[n, default: []].append(s) }
        var doneNames = Set<String>()
        for (n, _) in keys where !doneNames.contains(n) {
            doneNames.insert(n)
            let cands = byName[n] ?? []
            var from = text.startIndex
            while let r = text.range(of: n, range: from..<text.endIndex) {
                let start = text.distance(from: text.startIndex, to: r.lowerBound)
                from = r.upperBound
                if taken(start) { continue }
                let ctx = contextClass(at: start)
                // 말한 반(또는 같은 학년·반) 학생을 먼저, 그다음 수업/상담에 맞는 반
                let inCtx = cands.filter { c in
                    guard let ctx else { return false }
                    return c.class_uid == ctx.uid || (ctx.grade != nil && room(c) == "\(ctx.grade ?? 0)-\(ctx.class_no ?? 0)")
                }.sorted { rank($0) < rank($1) }.first
                let pool = cands.sorted { rank($0) < rank($1) }
                let pick = inCtx ?? pool.first!
                // 다른 학년·반에 같은 이름이 있을 때만 '동명이인' (같은 반의 교과/담임은 같은 학생)
                let unsure = inCtx == nil && Set(cands.map(room)).count > 1
                hits.append(Hit(start: start, end: start + n.count, student: pick, ambiguous: unsure,
                                candidates: unsure ? pool.reduce(into: [SStudent]()) { acc, c in
                                    if !acc.contains(where: { room($0) == room(c) }) { acc.append(c) } }.map(\.uid) : []))
            }
        }
        // "N번" — 지금 말하는 반이 있을 때만
        let numRx = try! NSRegularExpression(pattern: #"(?:^|[\s.,])(\d{1,2})\s*번(?=[\s,.]|$)"#)
        for m in numRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let pos = charIndex(text, m.range(at: 1).location)
            guard let c = contextClass(at: pos), let num = Int(ns.substring(with: m.range(at: 1))),
                  let s = studentsIn(c).first(where: { $0.number == num }), !taken(pos) else { continue }
            hits.append(Hit(start: pos, end: charIndex(text, m.range.location + m.range.length), student: s))
        }
        hits.sort { $0.start < $1.start }
        func squash(_ s: String) -> String { s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        guard !hits.isEmpty else { return Result(blocks: [], leftover: squash(text)) }

        // 언급이 든 문장의 시작부터 다음 언급 문장 직전까지가 그 학생 몫
        var starts: [Int] = []
        for h in hits {
            var st = sentenceStart(chars, h.start)
            // "2학년 3반 김민수"면 반 언급부터 그 학생 몫
            if let mark = classMarks.last(where: { $0.0 < h.start && h.start - $0.0 <= 12 }), mark.0 >= st { st = min(st, mark.0) }
            if let last = starts.last, st <= last { st = h.start }
            starts.append(st)
        }
        var blocks: [(Hit, Int, Int)] = []
        for (i, h) in hits.enumerated() {
            let stop = i + 1 < hits.count ? starts[i + 1] : chars.count
            if let last = blocks.last, last.0.student.uid == h.student.uid {
                blocks[blocks.count - 1].2 = stop
            } else {
                blocks.append((h, starts[i], stop))
            }
        }
        let out: [Block] = blocks.compactMap { h, a, b in
            guard a < b else { return nil }
            let chunk = squash(String(chars[a..<b]))
            return chunk.count < 6 ? nil : Block(studentUID: h.student.uid, content: String(chunk.prefix(1200)),
                                                 ambiguous: h.ambiguous, candidates: h.candidates)
        }
        let lead = squash(String(chars[0..<max(0, starts[0])]))
        return Result(blocks: out, leftover: lead.count >= 6 ? lead : "")
    }

    private static func sentenceStart(_ chars: [Character], _ pos: Int) -> Int {
        var i = pos
        while i > 0 && !".?!\n。".contains(chars[i - 1]) {
            i -= 1
            if pos - i > 40 { return pos }
        }
        return i
    }

    private static func charIndex(_ s: String, _ utf16: Int) -> Int {
        let idx = String.Index(utf16Offset: utf16, in: s)
        return s.distance(from: s.startIndex, to: idx)
    }

    /// 받아쓰기가 "이학년 삼반"처럼 한글 숫자로 적은 것을 숫자로. ("일반", "이번" 같은 낱말은 건드리지 않게
    /// 학년과 반이 함께 나올 때만 바꾼다.)
    static func normalize(_ s: String) -> String {
        let rx = try! NSRegularExpression(pattern: #"([일이삼사오육]|\d)\s*학년\s*(십?[일이삼사오육칠팔구]?|\d{1,2})\s*반"#)
        let ns = s as NSString
        var out = s
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let g = num(ns.substring(with: m.range(at: 1))), c = num(ns.substring(with: m.range(at: 2)))
            guard g > 0, c > 0 else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: "\(g)학년 \(c)반")
        }
        return out
    }

    private static func num(_ w: String) -> Int {
        if let n = Int(w) { return n }
        let digits: [Character: Int] = ["일": 1, "이": 2, "삼": 3, "사": 4, "오": 5, "육": 6, "칠": 7, "팔": 8, "구": 9]
        var value = 0, cur = 0
        for ch in w {
            if ch == "십" { value += (cur == 0 ? 1 : cur) * 10; cur = 0 } else if let d = digits[ch] { cur = d }
        }
        return value + cur
    }
}
