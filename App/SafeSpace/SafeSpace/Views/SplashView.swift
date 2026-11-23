import SwiftUI

/// Shown while the app opens and the saved rooms load. It continues the system launch screen
/// (`UILaunchScreen` in SafeSpace-Info.plist: the `LaunchBackground` green with the 220-pt
/// `LaunchIcon` centered), so the icon sits in exactly the same place and doesn't jump; only
/// the name and spinner fade in below it.
struct SplashView: View {
    @State private var showsDetails = false

    /// Same values as the `LaunchBackground` color asset and the app icon's background.
    static let iconGreen = Color(red: 0x8F / 255, green: 0x9C / 255, blue: 0x75 / 255)
    static let iconCream = Color(red: 0xFB / 255, green: 0xF2 / 255, blue: 0xE1 / 255)
    static let iconSide: CGFloat = 220

    var body: some View {
        ZStack {
            Self.iconGreen
            Image("LaunchIcon")
                .resizable()
                .frame(width: Self.iconSide, height: Self.iconSide)
            VStack(spacing: 20) {
                Text("SafeSpace")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Self.iconCream)
                ProgressView()
                    .tint(Self.iconCream)
            }
            .offset(y: Self.iconSide / 2 + 50)
            .opacity(showsDetails ? 1 : 0)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SafeSpace is loading")
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { showsDetails = true }
        }
    }
}

#Preview { SplashView() }
