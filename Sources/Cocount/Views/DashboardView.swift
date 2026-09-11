import CocountCore
import SwiftUI

struct DashboardView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject var store: UsageStore
    var now: Date = .now
    var quit: () -> Void = { NSApplication.shared.terminate(nil) }
    var constrainHeight = true
    @State private var calendarFocus: Date?
    @State private var showThemePicker = false

    private var theme: Theme {
        Theme(preset: store.themePreset, scheme: store.colorScheme ?? systemColorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if constrainHeight {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }.frame(height: contentHeightLimit)
                }
                .frame(maxHeight: contentHeightLimit)
            } else {
                content
            }
            footer
        }
        .frame(width: Theme.width)
        .background(theme.canvas)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .environment(\.cocountTheme, theme)
        .environment(\.colorScheme, theme.scheme)
        .environment(\.locale, Locale(identifier: "ko_KR"))
        .preferredColorScheme(store.colorScheme)
        .onChange(of: store.isDemo) { _, _ in calendarFocus = nil }
    }

    private var contentHeightLimit: CGFloat {
        max(280, min(650, (NSScreen.main?.visibleFrame.height ?? 900) - 150))
    }

    private var content: some View {
        VStack(spacing: 10) {
            if store.isDemo {
                HStack(spacing: 6) {
                    Image(systemName: "paintpalette")
                    Text("디자인 미리 보기 · 샘플 데이터")
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 4)
            }
            if store.showSettings {
                SettingsView(store: store)
            } else {
                if let snapshot = store.snapshot {
                    let displayNow = max(now, snapshot.fetchedAt)
                    QuotaCard(limits: snapshot.limits, now: displayNow, history: store.history,
                              credits: snapshot.resetCredits?.available ?? [], calendarFocus: $calendarFocus)
                    if store.showTokens {
                        if store.usageCardMode == .limits {
                            LimitUsageCard(limits: snapshot.limits, history: store.limitHistory,
                                           now: displayNow, mode: $store.usageCardMode)
                        } else {
                            TokenCard(usage: snapshot.tokens, issue: snapshot.tokenIssue, now: displayNow,
                                      todayEstimate: store.todayEstimate, mode: $store.usageCardMode)
                        }
                    }
                    ResetCreditsView(summary: snapshot.resetCredits, now: displayNow, calendarFocus: $calendarFocus)
                } else {
                    emptyState
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, Theme.pagePadding).padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: CocountIcon.image)
                .resizable()
                .scaledToFit()
                .foregroundStyle(theme.accent)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Co-Count").font(.system(size: 18, weight: .bold, design: .rounded)).tracking(-0.5)
                Text("나의 Codex 사용량").font(.system(size: 10)).foregroundStyle(theme.muted)
            }
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    .accessibilityLabel("사용량 새로고침 중")
            } else {
                IconButton(symbol: "arrow.clockwise", label: "새로고침") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            IconButton(symbol: "paintpalette", label: "컬러 프리셋 · \(store.themePreset.name)", selected: showThemePicker) {
                showThemePicker.toggle()
            }
            .popover(isPresented: $showThemePicker, arrowEdge: .top) {
                ThemePicker(selection: $store.themePreset)
                    .padding(Theme.cardPadding)
                    .frame(width: Theme.width - Theme.pagePadding * 2)
                    .foregroundStyle(theme.text)
                    .background(theme.canvas)
                    .environment(\.cocountTheme, theme)
                    .environment(\.colorScheme, theme.scheme)
            }
            IconButton(symbol: "slider.horizontal.3", label: "설정", selected: store.showSettings) {
                store.showSettings.toggle()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var emptyState: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: store.isLoading ? "ellipsis.circle" : "link.circle")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(theme.accent)
                Text(store.isLoading ? "Codex에 연결하는 중" : "Codex 연결을 기다려요")
                    .font(.system(size: 15, weight: .semibold))
                Text("이 Mac에 로그인된 Codex의\n사용량을 여기에 보여드려요.")
                    .font(.system(size: 12)).foregroundStyle(theme.muted).multilineTextAlignment(.center)
                if !store.isLoading {
                    Button("다시 연결") { store.refresh() }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isDemo || store.errorMessage != nil || store.historyIssue != nil ? theme.warning : theme.accent)
                .frame(width: 5, height: 5).accessibilityHidden(true)
            Text(statusText).font(.system(size: 10)).foregroundStyle(theme.muted)
                .help(store.historyIssue ?? statusText)
            Spacer()
            Button("종료", action: quit)
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(theme.muted)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var statusText: String {
        if store.isDemo { return "샘플 모드" }
        if store.isLoading { return "사용량 확인 중…" }
        guard let snapshot = store.snapshot else { return "연결 안 됨" }
        let time = snapshot.fetchedAt.formatted(.dateTime.hour().minute())
        if store.errorMessage != nil { return "이전 데이터 · \(time)" }
        if store.historyIssue != nil { return "\(time) 업데이트 · 이력 저장 재시도 필요" }
        return "\(time) 업데이트"
    }
}
