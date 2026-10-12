import SwiftUI

/// 처음 안내 3장 + 컴퓨터 고르기
struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                slide(mood: .happy, title: "말로 담고,\n글로 써요",
                      text: "수업 중에 학생을 보며 한마디만 남기세요.\n쓰담이 차곡차곡 담아 둘게요.",
                      example: nil).tag(0)
                slide(mood: .listening, title: "이렇게 말하면\n학생별로 정리돼요",
                      text: "학년·반·이름을 먼저 말하면 컴퓨터가\n알아서 그 학생 기록으로 넣어요.",
                      example: "“2학년 3반 김민수, 토론에서 근거를\n세 가지 들어 반론을 폈음”").tag(1)
                slide(mood: .calm, title: "학기말엔\n초안까지 한 번에",
                      text: "모인 기록으로 세특·행동특성·창체 초안을\n만들고 NEIS 글자 수도 맞춰 줘요.",
                      example: nil).tag(2)
                computerSlide.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 3 { withAnimation { page += 1 } } else { store.onboarded = true }
            } label: {
                Text(page < 3 ? "다음" : "시작하기").font(Theme.font(18, .bold))
                    .frame(maxWidth: 420).padding(.vertical, 16)
                    .background(Theme.brand, in: Capsule()).foregroundStyle(.white)
            }
            .buttonStyle(Squishy())
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .softBackground()
    }

    func slide(mood: Dami.Mood, title: String, text: String, example: String?) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Dami(size: 120, mood: mood)
            Text(title).font(Theme.font(30, .heavy)).multilineTextAlignment(.center)
            Text(text).font(Theme.font(16)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
            if let ex = example {
                Text(ex).font(Theme.font(16, .semibold)).multilineTextAlignment(.center)
                    .padding(16).frame(maxWidth: 420)
                    .background(Theme.peach.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            Spacer(); Spacer()
        }.padding(.horizontal, 28)
    }

    var computerSlide: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("기록을 정리할\n컴퓨터는 무엇인가요?").font(Theme.font(28, .heavy)).multilineTextAlignment(.center)
            Text("고른 컴퓨터에 맞는 연결 방법을 알려 드릴게요.\n나중에 ‘연결’에서 바꿀 수 있어요.")
                .font(Theme.font(15)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                pick("mac", "맥", "laptopcomputer", "iCloud로 자동")
                pick("windows", "윈도우", "desktopcomputer", "구글 드라이브로 자동")
            }.frame(maxWidth: 420)
            Spacer(); Spacer()
        }.padding(.horizontal, 28)
    }

    func pick(_ id: String, _ title: String, _ icon: String, _ sub: String) -> some View {
        Button { withAnimation(.spring(response: 0.3)) { store.computer = id } } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 36, weight: .semibold))
                Text(title).font(Theme.font(18, .bold))
                Text(sub).font(Theme.font(12)).opacity(0.85)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22)
            .foregroundStyle(store.computer == id ? .white : Theme.ink)
            .background(store.computer == id ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.card),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        }.buttonStyle(Squishy())
    }
}

/// "?" 사용 방법
struct TipsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tip("1", "학년·반·이름 먼저", "“2학년 3반 김민수, …”처럼 말하면 컴퓨터가 그 학생에게 바로 넣어요. 같은 반이면 이름만 말해도 돼요.", Theme.blue)
                    tip("2", "있었던 일 그대로", "‘무엇을 했는지 + 어땠는지’를 짧게. 예) “발표에서 자료 세 개로 근거를 댐, 친구 질문에도 차분히 답함”", Theme.lavender)
                    tip("3", "여러 학생을 한 번에", "한 녹음에 여러 학생을 이어서 말해도 돼요. 이름이 나오는 곳에서 알아서 나눠요.", Theme.mint)
                    tip("4", "상담은 ‘상담’으로", "상담 기록은 유형을 ‘상담’으로 두면 담임 기록(행동특성)으로 정리돼요.", Theme.coral)
                    tip("5", "말하기 어려우면 한 줄로", "‘한 줄로 남기기’에 적거나 키보드의 🎤로 받아쓰기해도 똑같이 정리돼요.", Theme.butter)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("그다음은요?").font(Theme.font(17, .bold))
                        Text("담은 기록은 컴퓨터로 자동으로 넘어가고, 컴퓨터의 쓰담이 글자로 바꾸고(외부로 안 나가요) 학생별로 정리해요. 학기말에는 쓰담에서 세특·행동특성 초안을 만들면 끝!")
                            .font(Theme.font(14)).foregroundStyle(Theme.soft)
                    }.card()
                }
                .padding(18).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .softBackground()
            .navigationTitle("이렇게 써 보세요")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
    }

    func tip(_ n: String, _ title: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(n).font(Theme.font(17, .heavy)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(color, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.font(17, .bold))
                Text(text).font(Theme.font(14)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
}
