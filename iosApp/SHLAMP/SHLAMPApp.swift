import SwiftUI

@main
struct SHLAMPApp: App {
    @StateObject private var model = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && model.isSignedIn {
                        model.startConnections()
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var showSplash = true

    var body: some View {
        ZStack {
            Group {
                if model.isSignedIn {
                    MainTabView()
                } else {
                    AccountView()
                }
            }
            .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            }

            if model.busy && model.currentUser != nil {
                Color.black.opacity(0.12).ignoresSafeArea()
                ProgressView("Please wait…")
                    .padding(22)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
        .task {
            guard showSplash else { return }
            // Keep the branded opening visible long enough to feel intentional, then
            // avoid revealing the login screen while a saved session is still loading.
            try? await Task.sleep(for: .milliseconds(1_450))
            for _ in 0..<130 where model.busy && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) { showSplash = false }
        }
    }
}

struct SplashScreenView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [SHLampTheme.backgroundTop, SHLampTheme.background], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(SHLampTheme.primarySoft.opacity(animate ? 0.95 : 0.7))
                        .frame(width: animate ? 170 : 136, height: animate ? 170 : 136)
                        .blur(radius: animate ? 18 : 8)
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(.white.opacity(0.72))
                        .frame(width: 124, height: 124)
                        .shadow(color: .black.opacity(0.06), radius: 14, y: 8)
                    BrandLogoView(size: 78)
                        .scaleEffect(animate ? 1 : 0.82)
                }
                .scaleEffect(animate ? 1 : 0.9)

                VStack(spacing: 6) {
                    Text("Smart Handicrafts®")
                        .font(.title.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text("SH Lamp")
                        .font(.headline)
                        .foregroundStyle(SHLampTheme.primary)
                    Text("Connected lighting for modern homes")
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                .opacity(animate ? 1 : 0.55)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
