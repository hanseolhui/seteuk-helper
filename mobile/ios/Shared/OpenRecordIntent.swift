import AppIntents

/// 제어 센터 · 잠금 화면 버튼에서 쓰는 "쓰담 녹음" 인텐트.
/// 앱과 위젯 확장 양쪽에 함께 컴파일된다. 위젯 확장에는 Nav가 없으므로
/// 앱 전용 코드는 WIDGET_EXTENSION 조건으로 감싼다.
/// (openAppWhenRun = true 이므로 실제 perform()은 앱 프로세스에서 실행된다.)
struct OpenRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "쓰담 녹음"
    static var description = IntentDescription("쓰담을 열고 바로 녹음을 시작해요.")
    static var openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        Nav.shared.tab = .home
        Nav.shared.startRecordingRequest += 1
        #endif
        return .result()
    }
}
