import SwiftUI
import UIKit

enum SafeSpaceTheme {
    static let tint = adaptive(0x3E6553, 0xA8C9B4)
    static let canvas = adaptive(0xF7F6F2, 0x151916)
    static let surface = adaptive(0xFFFFFF, 0x202622)
    static let border = adaptive(0xDEE5DF, 0x36423A)
    static let softSage = adaptive(0xE8EFE8, 0x2A382F)
    static let warning = adaptive(0xFFF3DF, 0x35291D)
    static let amber = adaptive(0x895211, 0xF4BA70)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct SafeSpaceIntro: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(eyebrow, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SafeSpaceTheme.tint)
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .safeSpaceCard(fill: SafeSpaceTheme.softSage)
    }
}

extension View {
    func safeSpaceCard(fill: Color = SafeSpaceTheme.surface,
                       border: Color = SafeSpaceTheme.border) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    func safeSpaceList() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SafeSpaceTheme.canvas)
    }
}
