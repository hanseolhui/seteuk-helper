#!/usr/bin/env python3
"""쓰담 수익모델 시뮬레이션 (36개월, 결정론적 코호트 모델)

요금 구조 (확정안):
  1) 무료        : 완전 오프라인. AI 기능 없음 (프롬프트 복사 → 본인 ChatGPT 붙여넣기만).
  2) 내 API 키   : BYOK. 교사 본인 Gemini/OpenAI 키로 AI 기능 실행. 개발자 API 비용 0.
                    무료 또는 1회 잠금해제 요금(옵션)으로 비교.
  3) 쓰담 플러스  : 구독. 개발자 서버 API로 서버 전사, AI 분리, 학생별 AI 요약, 생기부 초안,
                    크로스플랫폼 암호화 동기화. (+ 학원 플랜: 강사 좌석 단위)

사용법:
    python3 pricing_sim.py                    # 보고서용 표 전체 (Markdown)
    python3 pricing_sim.py --months 24        # 기간 변경
    python3 pricing_sim.py --detail base B    # 시나리오/가격안 월별 상세

모든 수치는 '가정'이다. 외부 단가 출처는 수익모델_시뮬레이션.md 출처 목록 참고.
금액 단위는 원(KRW). 소비자 가격은 부가세 10% 포함. 현금 기준(학기권·연간권은 결제한 달에
전액 입금). 소득세·대표 인건비는 현금에서 제외(지원 시간은 별도 표시).
"""
from __future__ import annotations

import argparse
import math
from dataclasses import dataclass, field, replace

# ---------------------------------------------------------------------------
# 1. 외부 단가 (2026-10 조사값, USD)
# ---------------------------------------------------------------------------
STT_USD_PER_MIN = {
    "gpt-4o-mini-transcribe": 0.003,
    "gpt-4o-transcribe": 0.006,
    "deepgram-nova-3": 0.0043,
    "google-stt-v2": 0.016,
}
LLM_USD_PER_MTOK = {  # (입력, 출력) USD / 1M tokens
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-2.5-flash": (0.30, 2.50),
    "gpt-5-nano": (0.05, 0.40),
    "claude-haiku-4.5": (1.00, 5.00),
}
BATCH_DISCOUNT = 0.5             # Gemini Batch Mode 50% 할인 (24시간 내 처리)

# 토큰 사용량 가정 (한국어 1토큰 ≈ 1.3자 가정)
CHARS_PER_TOKEN = 1.3
SPLIT_TOK_PER_AUDIO_MIN = (1200, 400)  # 정리·학생별 분리: 전사 1분당 (입력, 출력)
DRAFT_TOK = (3500, 700)                # 생기부 초안 1건
DRAFT_CALLS = 1.5                      # 바이트 맞춤·재생성 포함 평균 호출 수
REPORT_COST_RATIO = 0.6                # 학원 학부모 리포트 1건 = 초안의 60%

# 학생별 AI 요약 (페이지 상단)
SUMMARY_PROMPT_TOK = 500
SUMMARY_NOTES_PER_SEM = 40             # 학기당 학생 1인 메모 수 (범위 20~60)
SUMMARY_NOTE_CHARS = 60
SUMMARY_OUT_CHARS = 400                # 300~500자


def _tok(chars: float) -> int:
    return int(round(chars / CHARS_PER_TOKEN))


SUMMARY_FULL_TOK = (SUMMARY_PROMPT_TOK + _tok(SUMMARY_NOTES_PER_SEM * SUMMARY_NOTE_CHARS), _tok(SUMMARY_OUT_CHARS))
# 증분: 직전 요약 + 새 메모(평균 2건) + 지침
SUMMARY_INCR_TOK = (SUMMARY_PROMPT_TOK + _tok(SUMMARY_OUT_CHARS) + _tok(2 * SUMMARY_NOTE_CHARS), _tok(SUMMARY_OUT_CHARS))
SUMMARY_NOTES_PER_MONTH = SUMMARY_NOTES_PER_SEM / 6

SUMMARY_MODES = {
    # key: (설명, 증분 여부, 배치 여부)
    "realtime_full": "새 메모마다 전체 재생성 (실시간)",
    "ondemand_incr": "열람 시 + 변경된 학생만 증분 갱신",
    "weekly_incr": "주 1회 배치, 변경된 학생만 증분 + 월 1회 전체 재정리",
}


@dataclass
class CostConfig:
    name: str = "기본(저가 모델)"
    fx: float = 1400.0                  # 원/USD (가정)
    stt_model: str = "gpt-4o-mini-transcribe"
    split_model: str = "gemini-2.5-flash"
    draft_model: str = "gemini-2.5-flash"
    summary_model: str = "gemini-2.5-flash-lite"
    summary_mode: str = "weekly_incr"
    stt_overhead: float = 1.10
    infra_per_payer: float = 10.0       # 동기화 저장·요청 등 유료 사용자당 월 (원)
    trial_cost_per_signup: float = 130.0  # 플러스 7일 체험(옵트인) 평균 비용

    def llm(self, model: str, tok: tuple[int, int], batch: bool = False) -> float:
        i, o = LLM_USD_PER_MTOK[model]
        c = (tok[0] * i + tok[1] * o) / 1e6 * self.fx
        return c * (BATCH_DISCOUNT if batch else 1.0)

    @property
    def per_audio_min(self) -> float:
        stt = STT_USD_PER_MIN[self.stt_model] * self.fx * self.stt_overhead
        return stt + self.llm(self.split_model, SPLIT_TOK_PER_AUDIO_MIN)

    @property
    def per_draft(self) -> float:
        return self.llm(self.draft_model, DRAFT_TOK) * DRAFT_CALLS

    def summary_cost(self, students: float, cm: int, mode: str | None = None) -> float:
        """학생별 AI 요약: 교사 1인의 해당 달 비용."""
        mode = mode or self.summary_mode
        notes = SUMMARY_NOTES_PER_MONTH * AUDIO_SEASON[cm]          # 학생 1인 월 메모 수
        full = self.llm(self.summary_model, SUMMARY_FULL_TOK)
        incr = self.llm(self.summary_model, SUMMARY_INCR_TOK)
        if mode == "realtime_full":
            refreshes, unit = notes, full
            extra = 0.0
        elif mode == "ondemand_incr":
            refreshes, unit = min(notes, 2.0), incr                    # 월 2회 정도 열람
            extra = 0.0
        elif mode == "weekly_incr":
            p_dirty = 1 - math.exp(-notes / 4.3)                       # 주에 새 메모가 있을 확률
            refreshes = 4.3 * p_dirty
            unit = self.llm(self.summary_model, SUMMARY_INCR_TOK, batch=True)
            extra = full * BATCH_DISCOUNT if notes > 0.5 else 0.0      # 월 1회 전체 재정리
        else:
            raise ValueError(mode)
        return students * (refreshes * unit + extra)


COST_BASE = CostConfig()
COST_PREMIUM = CostConfig(name="고품질 모델+환율1500+실시간 요약", fx=1500.0, stt_model="gpt-4o-transcribe",
                          split_model="claude-haiku-4.5", draft_model="claude-haiku-4.5",
                          summary_model="claude-haiku-4.5", summary_mode="realtime_full")

# ---------------------------------------------------------------------------
# 2. 사용량 가정 (플러스 사용자 1인)
# ---------------------------------------------------------------------------
@dataclass
class Profile:
    name: str
    share: float
    audio_min: float          # 학기 중 평상월 서버 전사 분
    drafts_per_sem: float     # 학기당 초안 생성 건수(재생성 포함)
    students: int             # 요약 대상 학생 수


MIX_BASE = [
    Profile("가벼움", 0.45, 60, 120, 30),
    Profile("보통", 0.40, 150, 350, 90),
    Profile("많음", 0.12, 500, 900, 150),
    Profile("극단(수업 통녹음)", 0.03, 2000, 2500, 150),
]
MIX_HEAVY = [
    Profile("가벼움", 0.20, 60, 120, 30),
    Profile("보통", 0.40, 150, 350, 90),
    Profile("많음", 0.30, 500, 900, 150),
    Profile("극단(수업 통녹음)", 0.10, 2000, 2500, 150),
]

AUDIO_SEASON = {1: .2, 2: .3, 3: 1.0, 4: 1.1, 5: 1.1, 6: 1.0, 7: .8, 8: .2, 9: 1.0, 10: 1.1, 11: 1.0, 12: .7}
DRAFT_SHARE = {6: .3, 7: .7, 11: .2, 12: .6, 1: .2}
SIGNUP_SEASON = {1: .8, 2: 1.2, 3: 1.5, 4: 1.0, 5: .9, 6: 1.3, 7: 1.5, 8: .5, 9: 1.0, 10: .9, 11: 1.3, 12: 1.5}
CONV_SEASON = {1: 1.5, 2: .8, 3: .6, 4: .6, 5: .8, 6: 2.0, 7: 3.0, 8: .3, 9: .6, 10: .8, 11: 2.0, 12: 3.0}
MONTHLY_CHURN = {1: .25, 2: .35, 3: .15, 8: .40}


@dataclass
class Caps:
    name: str = "권장 상한"
    stt_min_per_month: float | None = 400
    drafts_per_month: float | None = 600
    summary_students: int | None = 200


NO_CAPS = Caps(name="상한 없음", stt_min_per_month=None, drafts_per_month=None, summary_students=None)


def payer_cost(cm: int, cost: CostConfig, mix: list[Profile], caps: Caps) -> float:
    total = 0.0
    for p in mix:
        mins = p.audio_min * AUDIO_SEASON[cm]
        drafts = p.drafts_per_sem * DRAFT_SHARE.get(cm, 0.0)
        students = p.students
        if caps.stt_min_per_month is not None:
            mins = min(mins, caps.stt_min_per_month)
        if caps.drafts_per_month is not None:
            drafts = min(drafts, caps.drafts_per_month)
        if caps.summary_students is not None:
            students = min(students, caps.summary_students)
        summ = cost.summary_cost(students, cm)
        # 학기말(초안 달)에는 학생별 전체 요약 1회를 초안 모델로 재생성
        summ += students * DRAFT_SHARE.get(cm, 0.0) * cost.llm(cost.draft_model, SUMMARY_FULL_TOK)
        total += p.share * (mins * cost.per_audio_min + drafts * cost.per_draft + summ)
    return total + cost.infra_per_payer


# ---------------------------------------------------------------------------
# 3. 가격 구조 (쓰담 플러스)
# ---------------------------------------------------------------------------
@dataclass
class PriceStructure:
    key: str
    name: str
    monthly: float | None
    semester: float | None
    annual: float | None
    mix: tuple[float, float, float] = (0.45, 0.35, 0.20)

    def norm_mix(self):
        m, s, a = self.mix
        m = m if self.monthly else 0
        s = s if self.semester else 0
        a = a if self.annual else 0
        t = m + s + a
        return m / t, s / t, a / t

    def price_index(self) -> float:
        m, s, a = self.norm_mix()
        return m * (self.monthly or 0) + s * (self.semester or 0) / 6 + a * (self.annual or 0) / 12


STRUCTURES = {
    "A": PriceStructure("A", "저가: 월 4,900 / 학기 19,900 / 연 34,900", 4900, 19900, 34900),
    "B": PriceStructure("B", "중간: 월 6,900 / 학기 24,900 / 연 44,000", 6900, 24900, 44000),
    "C": PriceStructure("C", "고가: 월 9,900 / 학기 34,900 / 연 49,000", 9900, 34900, 49000),
    "D": PriceStructure("D", "초저가 패스: 학기 9,900 / 연 15,900 (월 없음)", None, 9900, 15900, (0, 0.6, 0.4)),
    "E": PriceStructure("E", "학기 중심: 월 6,900 / 학기 19,900 / 연 34,900", 6900, 19900, 34900, (0.30, 0.50, 0.20)),
}
REF_INDEX = STRUCTURES["B"].price_index()


@dataclass
class Channel:
    store_share: float = 0.85
    store_fee: float = 0.15
    pg_fee: float = 0.035
    vat: float = 0.10

    def net(self, gross: float) -> float:
        base = gross / (1 + self.vat)
        return base * (self.store_share * (1 - self.store_fee) + (1 - self.store_share) * (1 - self.pg_fee))


# ---------------------------------------------------------------------------
# 4. 시나리오
# ---------------------------------------------------------------------------
@dataclass
class Scenario:
    key: str
    name: str
    signup_init: float
    signup_growth: float
    signup_cap: float
    conv: float                 # 평상월 'AI 기능을 원하게 되는' 활성 무료 사용자 비율(월)
    free_churn: float = 0.06
    sem_renew: float = 0.50
    ann_renew: float = 0.60
    lapsed_to_free: float = 0.6
    base_monthly_churn: float = 0.10
    mix: list[Profile] = field(default_factory=lambda: MIX_BASE)
    # BYOK (내 API 키)
    byok_offered: bool = True
    byok_share: float = 0.30     # AI 원하는 사용자 중 BYOK 선택 비율 (B 가격 기준)
    byok_cannibal: float = 0.40  # BYOK가 없을 때 그중 플러스로 갈 비율 (나머지는 무료 잔류)
    byok_fee: float = 0.0        # 1회 잠금해제 요금(부가세 포함)
    byok_churn: float = 0.04
    byok_upgrade: float = 0.01   # BYOK → 플러스 월 전환 (성수기 계수 곱함)
    # 학원
    academy: bool = True
    academy_start: int = 13
    academy_new_init: float = 3
    academy_growth: float = 0.03
    academy_churn: float = 0.04
    marketing_monthly: float = 0.0


SCENARIOS = {
    "cons": Scenario("cons", "보수", 150, 0.03, 10_000, 0.004, academy_new_init=1, academy_growth=0.02),
    "base": Scenario("base", "기준", 400, 0.06, 30_000, 0.007),
    "opt": Scenario("opt", "낙관", 1000, 0.08, 80_000, 0.010, academy_new_init=6, academy_growth=0.05),
}

ACADEMY_SEAT_PRICE = 9900
ACADEMY_SEATS = 4
ACADEMY_AUDIO_MIN = 300
ACADEMY_REPORTS = 60
ACADEMY_STUDENTS = 40

FIXED_MONTHLY = {
    "Apple Developer (129,000/년)": 129000 / 12,
    "Cloudflare Workers Paid ($5)": 5 * 1400,
    "DB·인증 (Supabase Pro 등 $25)": 25 * 1400,
    "모니터링·로그·메일": 15000,
    "도메인": 2500,
    "세무 기장(간편)": 50000,
}
ONE_TIME_M1 = {
    "Google Play 등록 ($25)": 25 * 1400,
    "약관·개인정보처리방침 법률 검토": 1_000_000,
    "사업자·통신판매업 등 행정": 50_000,
}


def cal_month(t: int, start_month: int) -> int:
    return (start_month - 1 + t) % 12 + 1


def simulate(ps: PriceStructure, sc: Scenario, cost: CostConfig = COST_BASE, caps: Caps = Caps(),
             months: int = 36, start_month: int = 3, elasticity: float | None = 0.8,
             channel: Channel = Channel(), conv_override: float | None = None):
    m_share, s_share, a_share = ps.norm_mix()
    conv = conv_override if conv_override is not None else sc.conv
    rel = ps.price_index() / REF_INDEX
    byok_share = min(0.8, sc.byok_share * rel ** 0.5) if sc.byok_offered else 0.0
    if elasticity is not None:
        conv *= max(0.3, min(2.5, rel ** -elasticity))
    if sc.byok_offered:
        plus_frac = 1 - byok_share
    else:
        plus_frac = 1 - sc.byok_share * (1 - sc.byok_cannibal)

    free = cum_signups = monthly_subs = academies = cash = byok = 0.0
    new_sem = [0.0] * months
    new_ann = [0.0] * months
    rows = []
    fixed = sum(FIXED_MONTHLY.values())

    for t in range(months):
        cm = cal_month(t, start_month)
        signups = sc.signup_init * (1 + sc.signup_growth) ** t * SIGNUP_SEASON[cm]
        signups *= max(0.0, 1 - cum_signups / sc.signup_cap)
        cum_signups += signups

        lapsed = 0.0
        if t >= 6:
            lapsed += new_sem[t - 6] * (1 - sc.sem_renew)
            new_sem[t] += new_sem[t - 6] * sc.sem_renew
        if t >= 12:
            lapsed += new_ann[t - 12] * (1 - sc.ann_renew)
            new_ann[t] += new_ann[t - 12] * sc.ann_renew
        churned = monthly_subs * MONTHLY_CHURN.get(cm, sc.base_monthly_churn)
        monthly_subs -= churned
        lapsed += churned

        ai_intent = free * conv * CONV_SEASON[cm]
        plus_new = ai_intent * plus_frac
        byok_new = ai_intent * byok_share
        byok_up = byok * sc.byok_upgrade * CONV_SEASON[cm]
        byok = byok * (1 - sc.byok_churn) - byok_up + byok_new
        conversions = plus_new + byok_up
        free = free * (1 - sc.free_churn) + signups + lapsed * sc.lapsed_to_free - plus_new - byok_new
        monthly_subs += conversions * m_share
        new_sem[t] += conversions * s_share
        new_ann[t] += conversions * a_share

        sem_active = sum(new_sem[max(0, t - 5): t + 1])
        ann_active = sum(new_ann[max(0, t - 11): t + 1])
        payers = monthly_subs + sem_active + ann_active

        gross = monthly_subs * (ps.monthly or 0) + new_sem[t] * (ps.semester or 0) + new_ann[t] * (ps.annual or 0)
        plus_net = channel.net(gross)
        byok_net = channel.net(byok_new * sc.byok_fee)

        ac_net = ac_cost = seats = 0.0
        if sc.academy and t >= sc.academy_start:
            k = t - sc.academy_start
            academies = academies * (1 - sc.academy_churn) + sc.academy_new_init * (1 + sc.academy_growth) ** k
            seats = academies * ACADEMY_SEATS
            ac_net = seats * ACADEMY_SEAT_PRICE / (1 + channel.vat) * (1 - channel.pg_fee)
            a_season = 0.7 if cm in (1, 2, 8) else 1.0
            mins = ACADEMY_AUDIO_MIN * a_season
            if caps.stt_min_per_month is not None:
                mins = min(mins, caps.stt_min_per_month)
            ac_cost = seats * (mins * cost.per_audio_min
                               + ACADEMY_REPORTS * cost.per_draft * REPORT_COST_RATIO
                               + cost.summary_cost(ACADEMY_STUDENTS, 4) + cost.infra_per_payer)

        var_cost = payers * payer_cost(cm, cost, sc.mix, caps) + signups * cost.trial_cost_per_signup + ac_cost
        fixed_cost = fixed + sc.marketing_monthly + (sum(ONE_TIME_M1.values()) if t == 0 else 0)
        revenue = plus_net + byok_net + ac_net
        profit = revenue - var_cost - fixed_cost
        cash += profit
        support_h = 8.7 + 0.02 * payers + 0.03 * byok + 0.005 * signups + 0.1 * academies
        rows.append(dict(t=t + 1, cm=cm, signups=signups, free=free, payers=payers, byok=byok,
                         monthly=monthly_subs, sem=sem_active, ann=ann_active, seats=seats,
                         plus_net=plus_net, byok_net=byok_net, ac_net=ac_net, revenue=revenue,
                         var_cost=var_cost, fixed=fixed_cost, profit=profit, cash=cash, support_h=support_h))
    return rows


def summarize(rows):
    rev = sum(r["revenue"] for r in rows)
    var = sum(r["var_cost"] for r in rows)
    be = None
    for i in range(2, len(rows)):
        if all(sum(r["profit"] for r in rows[j - 2:j + 1]) > 0 for j in range(i, len(rows))):
            be = rows[i]["t"]
            break

    def at(m, k):
        return rows[min(m, len(rows)) - 1][k]
    return dict(rev=rev, var=var, gm=(rev - var) / rev if rev else 0.0, be=be,
                min_cash=min(r["cash"] for r in rows), at=at,
                plus_rev=sum(r["plus_net"] for r in rows), ac_rev=sum(r["ac_net"] for r in rows),
                byok_rev=sum(r["byok_net"] for r in rows),
                support_h=sum(r["support_h"] for r in rows) / len(rows))


# ---------------------------------------------------------------------------
# 5. 출력
# ---------------------------------------------------------------------------
def w(x):
    return f"{x / 10000:,.0f}만"


def n(x):
    return f"{x:,.0f}"


def table(headers, data):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in data]
    return "\n".join(out)


def report(months: int):
    ch = Channel()
    M = months
    print(f"## 0. 단가 (환율 {COST_BASE.fx:,.0f}원/USD)\n")
    print(table(["항목", "기본 구성", "고품질 구성(최악)"], [
        ["서버 전사+정리, 오디오 1분", f"{COST_BASE.per_audio_min:.1f}원", f"{COST_PREMIUM.per_audio_min:.1f}원"],
        ["생기부 초안 1건(1.5회 호출)", f"{COST_BASE.per_draft:.1f}원", f"{COST_PREMIUM.per_draft:.1f}원"],
        [f"학생 요약 전체 재생성 1회 (입력 {SUMMARY_FULL_TOK[0]:,}/출력 {SUMMARY_FULL_TOK[1]} tok)",
         f"{COST_BASE.llm(COST_BASE.summary_model, SUMMARY_FULL_TOK):.2f}원 (Flash-Lite)",
         f"{COST_PREMIUM.llm(COST_PREMIUM.summary_model, SUMMARY_FULL_TOK):.2f}원 (Haiku)"],
        [f"학생 요약 증분 갱신 1회 (입력 {SUMMARY_INCR_TOK[0]:,}/출력 {SUMMARY_INCR_TOK[1]} tok)",
         f"{COST_BASE.llm(COST_BASE.summary_model, SUMMARY_INCR_TOK):.2f}원 (배치 {COST_BASE.llm(COST_BASE.summary_model, SUMMARY_INCR_TOK, True):.2f}원)",
         f"{COST_PREMIUM.llm(COST_PREMIUM.summary_model, SUMMARY_INCR_TOK):.2f}원"],
    ]))

    print("\n## 0-1. 학생별 AI 요약: 교사 1인 월 비용 (학기 중 평상월, 원)\n")
    data = []
    for mode, desc in SUMMARY_MODES.items():
        for model in ("gemini-2.5-flash-lite", "gemini-2.5-flash", "claude-haiku-4.5"):
            c = replace(COST_BASE, summary_model=model, summary_mode=mode)
            data.append([desc, model] + [f"{c.summary_cost(s, 4):,.0f}" for s in (30, 90, 150)])
    print(table(["갱신 방식", "모델", "학생 30명", "학생 90명", "학생 150명"], data))

    print("\n## 1. 플러스 사용자 1인 월 변동비 (기본 단가, 요약 포함)\n")
    data = []
    for p in MIX_BASE:
        for caps in (NO_CAPS, Caps()):
            one = [replace(p, share=1.0)]
            data.append([p.name, caps.name] + [n(payer_cost(m, COST_BASE, one, caps)) for m in (4, 7, 12)]
                        + [n(sum(payer_cost(m, COST_BASE, one, caps) for m in range(1, 13)) / 12)])
    for caps in (NO_CAPS, Caps()):
        data.append(["**가중평균**", caps.name] + [n(payer_cost(m, COST_BASE, MIX_BASE, caps)) for m in (4, 7, 12)]
                    + [n(sum(payer_cost(m, COST_BASE, MIX_BASE, caps) for m in range(1, 13)) / 12)])
    print(table(["사용 유형", "상한", "4월(평상)", "7월(성수기)", "12월(성수기)", "연평균/월"], data))

    print("\n## 2. 요금별 1인 월 순수입 (부가세·수수료 차감, 스토어 85%/웹 15%)\n")
    print(table(["안", "가격", "월권", "학기권 월환산", "연간권 월환산"], [
        [ps.key, ps.name, n(ch.net(ps.monthly)) if ps.monthly else "-",
         n(ch.net(ps.semester) / 6) if ps.semester else "-", n(ch.net(ps.annual) / 12) if ps.annual else "-"]
        for ps in STRUCTURES.values()]))

    print(f"\n## 3. 시나리오별 결과 (가격안 B, BYOK 무료·선택 30%, 권장 상한, {M}개월, 2027년 3월 시작)\n")
    data = []
    for sc in SCENARIOS.values():
        s = summarize(simulate(STRUCTURES["B"], sc, months=M))
        data.append([sc.name, n(s["at"](12, "payers")), n(s["at"](24, "payers")), n(s["at"](M, "payers")),
                     n(s["at"](24, "byok")), n(s["at"](24, "free")), n(s["at"](24, "seats")),
                     w(s["plus_rev"]), w(s["ac_rev"]), f"{s['gm'] * 100:.0f}%", s["be"] or "미도달",
                     w(s["min_cash"]), w(s["at"](12, "cash")), w(s["at"](24, "cash")), w(s["at"](M, "cash")),
                     f"{s['support_h']:.0f}h"])
    print(table(["시나리오", "플러스 12개월", "플러스 24개월", f"플러스 {M}개월", "BYOK 24개월", "활성무료 24개월",
                 "학원 좌석 24개월", "누적 플러스 순매출", "누적 학원 순매출", "총이익률", "흑자전환(월)",
                 "최저 누적현금", "현금 12", "현금 24", f"현금 {M}", "월 지원시간"], data))

    print("\n## 3-1. 학원 플랜 제외 (교사 개인만)\n")
    data = []
    for sc in SCENARIOS.values():
        s = summarize(simulate(STRUCTURES["B"], replace(sc, academy=False), months=M))
        data.append([sc.name, w(s["rev"]), f"{s['gm'] * 100:.0f}%", s["be"] or "미도달", w(s["min_cash"]),
                     w(s["at"](12, "cash")), w(s["at"](24, "cash")), w(s["at"](M, "cash"))])
    print(table(["시나리오", "누적 순매출", "총이익률", "흑자전환(월)", "최저 누적현금", "현금 12", "현금 24",
                 f"현금 {M}"], data))

    print("\n## 4. BYOK(내 API 키) 정책 비교 (기준 시나리오, 가격안 B)\n")
    variants = [
        ("BYOK 미제공 (선호층 40%만 플러스로)", dict(byok_offered=False)),
        ("BYOK 무료, 선택 20%", dict(byok_share=0.20)),
        ("BYOK 무료, 선택 30% (기준)", dict(byok_share=0.30)),
        ("BYOK 무료, 선택 50%", dict(byok_share=0.50)),
        ("BYOK 1회 9,900원, 선택 22%", dict(byok_share=0.22, byok_fee=9900)),
        ("BYOK 1회 9,900원, 선택 35%", dict(byok_share=0.35, byok_fee=9900)),
    ]
    data = []
    for label, kw in variants:
        s = summarize(simulate(STRUCTURES["B"], replace(SCENARIOS["base"], **kw), months=M))
        data.append([label, n(s["at"](24, "payers")), n(s["at"](24, "byok")), w(s["plus_rev"]), w(s["byok_rev"]),
                     w(s["var"]), w(s["at"](24, "cash")), w(s["at"](M, "cash")), f"{s['support_h']:.0f}h"])
    print(table(["정책", "플러스 24개월", "BYOK 활성 24개월", "누적 플러스 순매출", "누적 BYOK 순매출",
                 "누적 변동비", "현금 24", f"현금 {M}", "월 지원시간"], data))

    print("\n## 5. 가격안 비교 (기준 시나리오, 가격탄력성 0.8, BYOK 선택률은 가격에 따라 변동)\n")
    data = []
    for ps in STRUCTURES.values():
        s = summarize(simulate(ps, SCENARIOS["base"], months=M))
        data.append([ps.key, ps.name, n(s["at"](24, "payers")), n(s["at"](24, "byok")), w(s["rev"]),
                     f"{s['gm'] * 100:.0f}%", s["be"] or "미도달", w(s["at"](12, "cash")),
                     w(s["at"](24, "cash")), w(s["at"](M, "cash"))])
    print(table(["안", "가격", "플러스 24개월", "BYOK 24개월", "누적 순매출", "총이익률", "흑자전환",
                 "현금 12", "현금 24", f"현금 {M}"], data))

    print("\n## 6. 민감도: 가격 × 평상월 AI 전환율 → 24개월 누적 현금 (기준 유입, 학원 제외, 탄력성 미적용)\n")
    convs = [0.002, 0.004, 0.007, 0.010, 0.014]
    data = []
    for key in ("D", "A", "B", "C"):
        ps = STRUCTURES[key]
        row = [f"{key} ({ps.monthly or '-'}/{ps.semester}/{ps.annual})"]
        for c in convs:
            rows = simulate(ps, replace(SCENARIOS["base"], academy=False), months=24, elasticity=None,
                            conv_override=c)
            row.append(w(rows[-1]["cash"]))
        data.append(row)
    print(table(["가격안 (월/학기/연)"] + [f"{c * 100:.1f}%/월" for c in convs], data))
    r = simulate(STRUCTURES["B"], SCENARIOS["base"], months=24)[-1]
    tot = r["payers"] + r["free"] + r["byok"]
    print(f"\n참고(기준): 24개월 시점 플러스 {n(r['payers'])}명 / BYOK {n(r['byok'])}명 / 활성 무료 {n(r['free'])}명 "
          f"→ 플러스 비중 {r['payers'] / tot * 100:.1f}%, BYOK {r['byok'] / tot * 100:.1f}%")

    print("\n## 7. 최악의 경우 (보수 유입, AI 전환 0.2%/월, 헤비 비중 40%, 학원 없음)\n")
    worst = replace(SCENARIOS["cons"], mix=MIX_HEAVY, conv=0.002, academy=False)
    data = []
    for ps_key in ("A", "B"):
        for caps in (NO_CAPS, Caps()):
            for cost in (COST_BASE, COST_PREMIUM):
                rows = simulate(STRUCTURES[ps_key], worst, cost=cost, caps=caps, months=M)
                s = summarize(rows)
                peak = max(rows, key=lambda x: x["var_cost"])
                data.append([ps_key, caps.name, cost.name, n(s["at"](24, "payers")), w(s["rev"]),
                             f"{s['gm'] * 100:.0f}%", f"{w(peak['var_cost'])}({peak['cm']}월)",
                             w(s["min_cash"]), w(s["at"](M, "cash"))])
    print(table(["안", "상한", "단가", "플러스 24개월", "누적 순매출", "총이익률", "최대 월 변동비",
                 "최저 누적현금", f"현금 {M}"], data))
    print("\n극단 사용자 1명(상한 없음, 고품질 단가) 12월 비용: "
          f"{n(payer_cost(12, COST_PREMIUM, [replace(MIX_BASE[3], share=1.0)], NO_CAPS))}원 / "
          f"권장 상한 적용 시 {n(payer_cost(12, COST_PREMIUM, [replace(MIX_BASE[3], share=1.0)], Caps()))}원")

    print("\n## 8. 학원 플랜 단위경제 (강사 1석 월 9,900원, 웹결제)\n")
    seat_net = ACADEMY_SEAT_PRICE / 1.1 * (1 - ch.pg_fee)
    def seat_cost(c):
        return (min(ACADEMY_AUDIO_MIN, 400) * c.per_audio_min + ACADEMY_REPORTS * c.per_draft * REPORT_COST_RATIO
                + c.summary_cost(ACADEMY_STUDENTS, 4) + c.infra_per_payer)
    print(table(["항목", "기본 단가", "고품질 단가"], [
        ["석당 월 순수입", n(seat_net), n(seat_net)],
        ["석당 월 변동비 (전사 300분+리포트 60건+요약 40명)", n(seat_cost(COST_BASE)), n(seat_cost(COST_PREMIUM))],
        ["석당 공헌이익", n(seat_net - seat_cost(COST_BASE)), n(seat_net - seat_cost(COST_PREMIUM))],
    ]))

    print("\n## 9. 고정비\n")
    print(table(["항목", "금액(원)"], [[k, n(v)] for k, v in FIXED_MONTHLY.items()]
                + [["**월 합계**", n(sum(FIXED_MONTHLY.values()))]]
                + [[k + " (첫 달 1회)", n(v)] for k, v in ONE_TIME_M1.items()]))


def detail(sc_key: str, ps_key: str, months: int):
    rows = simulate(STRUCTURES[ps_key], SCENARIOS[sc_key], months=months)
    print(table(["월", "달", "신규가입", "활성무료", "플러스", "BYOK", "월권", "학기권", "연간권", "학원석",
                 "순매출", "변동비", "고정비", "손익", "누적현금"],
                [[r["t"], r["cm"], n(r["signups"]), n(r["free"]), n(r["payers"]), n(r["byok"]), n(r["monthly"]),
                  n(r["sem"]), n(r["ann"]), n(r["seats"]), w(r["revenue"]), w(r["var_cost"]), w(r["fixed"]),
                  w(r["profit"]), w(r["cash"])] for r in rows]))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="쓰담 수익모델 시뮬레이션")
    ap.add_argument("--months", type=int, default=36)
    ap.add_argument("--detail", nargs=2, metavar=("SCENARIO", "PRICE"), help="예: --detail base B")
    a = ap.parse_args()
    if a.detail:
        detail(a.detail[0], a.detail[1], a.months)
    else:
        report(a.months)
