import Foundation

enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case sage, lavender, sky, peach, rose

    var id: String { rawValue }
    var name: String {
        switch self {
        case .sage: "세이지"
        case .lavender: "라벤더"
        case .sky: "스카이"
        case .peach: "피치"
        case .rose: "로즈"
        }
    }

    var subtitle: String {
        switch self {
        case .sage: "차분한 세이지와 안개빛 블루"
        case .lavender: "은은한 라일락과 포근한 로즈"
        case .sky: "맑은 하늘빛과 부드러운 라벤더"
        case .peach: "따뜻한 살구와 산뜻한 아쿠아"
        case .rose: "말린 장미와 싱그러운 민트"
        }
    }

    // Source swatches are adapted for UI contrast; see docs/color-palettes.md.
    func palette(dark: Bool) -> ThemePalette {
        switch (self, dark) {
        case (.sage, false):
            ThemePalette(canvas: 0xF4FBF3, card: 0xFFFFFF, soft: 0x95D2B3, accent: 0x247A58,
                         companionSoft: 0xD5EFF3, companion: 0x2F7080, time: 0xB34F62,
                         text: 0x203E32, muted: 0x516F60)
        case (.lavender, false):
            ThemePalette(canvas: 0xF5F2F8, card: 0xFDFBFE, soft: 0xD3BBDD, accent: 0x705583,
                         companionSoft: 0xF3E1E5, companion: 0x875366, time: 0xA05748,
                         text: 0x382F40, muted: 0x6C6073)
        case (.sky, false):
            ThemePalette(canvas: 0xF1F6F9, card: 0xFBFDFE, soft: 0xB1D4E0, accent: 0x426A84,
                         companionSoft: 0xE8E2F2, companion: 0x6C5C88, time: 0xA35459,
                         text: 0x2D3944, muted: 0x566875)
        case (.peach, false):
            ThemePalette(canvas: 0xFBF5EF, card: 0xFFFCF8, soft: 0xFAC590, accent: 0x8D5637,
                         companionSoft: 0xDDECEF, companion: 0x446F78, time: 0xA34F61,
                         text: 0x44362D, muted: 0x716155)
        case (.rose, false):
            ThemePalette(canvas: 0xFAF2F4, card: 0xFFFBFC, soft: 0xD8A7B1, accent: 0x884E63,
                         companionSoft: 0xE0EFE8, companion: 0x4D7064, time: 0x9A5D38,
                         text: 0x422F38, muted: 0x74616B)
        case (.sage, true):
            ThemePalette(canvas: 0x19221F, card: 0x222D28, soft: 0x425D51, accent: 0xBFD9CA,
                         companionSoft: 0x2B3C47, companion: 0xB0CEDD, time: 0xE5ABA7,
                         text: 0xE6EFE9, muted: 0xA4B4AA)
        case (.lavender, true):
            ThemePalette(canvas: 0x211E28, card: 0x2B2634, soft: 0x584461, accent: 0xD9C3E6,
                         companionSoft: 0x44313D, companion: 0xE4B7C6, time: 0xE6B09D,
                         text: 0xEFE8F4, muted: 0xB5A8BF)
        case (.sky, true):
            ThemePalette(canvas: 0x1A222A, card: 0x242E38, soft: 0x3B5668, accent: 0xB1D4E0,
                         companionSoft: 0x373246, companion: 0xCBBDE1, time: 0xE5ABB4,
                         text: 0xE7EEF4, muted: 0xA5B4C2)
        case (.peach, true):
            ThemePalette(canvas: 0x28211D, card: 0x332A24, soft: 0x644A36, accent: 0xF0C59E,
                         companionSoft: 0x293E43, companion: 0xAED4D9, time: 0xEDB0C1,
                         text: 0xF5ECE2, muted: 0xC0AFA1)
        case (.rose, true):
            ThemePalette(canvas: 0x281F24, card: 0x34282F, soft: 0x644451, accent: 0xE4B7C6,
                         companionSoft: 0x2C3F37, companion: 0xB2D8C8, time: 0xEAC29C,
                         text: 0xF5E7EE, muted: 0xC0ABB5)
        }
    }
}

struct ThemePalette: Sendable {
    let canvas: UInt32
    let card: UInt32
    let soft: UInt32
    let accent: UInt32
    let companionSoft: UInt32
    let companion: UInt32
    let time: UInt32
    let text: UInt32
    let muted: UInt32
}
