import SwiftUI

struct SettingsView: View {
    @Environment(\.cocountTheme) private var theme
    @ObservedObject var store: UsageStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("나에게 맞게").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button("완료") { store.showSettings = false }
                        .buttonStyle(.borderless).foregroundStyle(theme.accent)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("새로고침 간격").font(.system(size: 12, weight: .medium))
                    Picker("새로고침 간격", selection: $store.refreshMinutes) {
                        Text("1분").tag(1)
                        Text("5분").tag(5)
                        Text("15분").tag(15)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("화면 모드").font(.system(size: 12, weight: .medium))
                    Picker("화면 모드", selection: $store.appearance) {
                        Text("시스템").tag("system")
                        Text("라이트").tag("light")
                        Text("다크").tag("dark")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Toggle("사용량 카드 표시", isOn: $store.showTokens)
                Picker("카드 기본 표시", selection: $store.usageCardMode) {
                    ForEach(UsageCardMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Divider()
                ThemePicker(selection: $store.themePreset)
                Divider()
                Toggle("샘플 데이터로 미리 보기", isOn: $store.isDemo)
                    .onChange(of: store.isDemo) { _, _ in store.changeMode() }
                Text("샘플 모드에서는 예시 수치가 표시돼요. 실제 사용량을 보려면 꺼 주세요.")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Co-Count 0.1.0 · 나만의 작은 사용량 카운터")
                    .font(.system(size: 10)).foregroundStyle(theme.muted)
            }
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}
