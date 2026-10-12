import SwiftUI

/// 쓰담 디자인: 크림 배경 · 파스텔 · 둥근 글꼴 · 부드러운 카드
enum Theme {
    static let blue = Color(red: 0.36, green: 0.49, blue: 0.98)      // 말랑 블루 #5C7DFA
    static let lavender = Color(red: 0.65, green: 0.55, blue: 0.98)  // #A78BFA
    static let coral = Color(red: 1.00, green: 0.55, blue: 0.48)     // #FF8C7A
    static let mint = Color(red: 0.37, green: 0.82, blue: 0.65)      // #5FD1A5
    static let butter = Color(red: 1.00, green: 0.82, blue: 0.40)    // #FFD166
    static let peach = Color(red: 1.00, green: 0.87, blue: 0.80)

    static let bg = Color("Background")
    static let card = Color("Card")
    static let ink = Color.primary
    static let soft = Color.secondary

    static let brand = LinearGradient(colors: [blue, lavender], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warm = LinearGradient(colors: [coral, Color(red: 1, green: 0.66, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension View {
    /// 하얀 둥근 카드
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    func softBackground() -> some View {
        self.background(Theme.bg.ignoresSafeArea())
    }
}

/// 마스코트 '담이' — 말풍선 얼굴. mood: 기본·신남·잠
struct Dami: View {
    enum Mood { case calm, happy, listening }
    var size: CGFloat = 64
    var mood: Mood = .calm
    @State private var bob = false

    var body: some View {
        ZStack {
            // 말풍선 몸
            RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
                .fill(Theme.brand)
                .frame(width: size, height: size * 0.82)
            // 꼬리
            Triangle().fill(Theme.lavender)
                .frame(width: size * 0.22, height: size * 0.18)
                .rotationEffect(.degrees(-20))
                .offset(x: -size * 0.22, y: size * 0.45)
            // 눈
            HStack(spacing: size * 0.22) {
                eye; eye
            }.offset(y: -size * 0.04)
            // 볼
            HStack(spacing: size * 0.42) {
                Circle().fill(Theme.coral.opacity(0.55)).frame(width: size * 0.13)
                Circle().fill(Theme.coral.opacity(0.55)).frame(width: size * 0.13)
            }.offset(y: size * 0.1)
            // 입
            mouth.offset(y: size * 0.14)
        }
        .frame(width: size, height: size)
        .offset(y: bob ? -size * 0.04 : size * 0.02)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bob = true }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder var eye: some View {
        if mood == .happy {
            Arc().stroke(.white, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                .frame(width: size * 0.13, height: size * 0.07)
        } else {
            Capsule().fill(.white).frame(width: size * 0.09, height: mood == .listening ? size * 0.15 : size * 0.12)
        }
    }

    @ViewBuilder var mouth: some View {
        if mood == .listening {
            Circle().fill(.white).frame(width: size * 0.08)
        } else {
            Arc().stroke(.white, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round))
                .frame(width: size * 0.16, height: size * 0.06)
        }
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.closeSubpath() }
    }
}

/// 아래로 둥근 호 (웃는 눈·입)
private struct Arc: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 2))
        }
    }
}

/// 작은 상태 알약
struct Pill: View {
    var text: String
    var icon: String
    var color: Color
    var body: some View {
        Label(text, systemImage: icon)
            .font(Theme.font(12, .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// 꾹 누르는 느낌의 버튼 스타일
struct Squishy: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
