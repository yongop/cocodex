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
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("iCloud 사용량 동기화", isOn: $store.syncEnabled)
                    Text(store.syncStatus)
                        .font(.system(size: 11)).foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.syncEnabled && !store.isDemo {
                        ForEach(store.syncDevices) { device in
                            HStack {
                                Text(device.name + (device.isCurrentDevice ? " · 이 Mac" : ""))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(device.lastSeen, format: .dateTime.month().day().hour().minute())
                                    .monospacedDigit()
                            }
                            .font(.system(size: 10)).foregroundStyle(theme.muted)
                            .help("이 기기가 마지막으로 기록한 시각이에요. 꺼져 있으면 새 기록이 도착하지 않아요.")
                        }
                        if store.syncFolder != nil {
                            Button("iCloud 동기화 폴더 열기") { store.openSyncFolder() }
                                .buttonStyle(.borderless)
                        }
                        Text("두 Mac에서 같은 iCloud·Codex 계정으로 앱을 실행해 주세요. 대화 내용 없이 사용량 기록만 공유해요.")
                            .font(.system(size: 10)).foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
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
