import SwiftUI

@main
struct SHLAMPApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        ZStack {
            if model.isSignedIn {
                MainTabView()
            } else {
                AccountView()
            }
            if model.busy && model.currentUser != nil {
                Color.black.opacity(0.12).ignoresSafeArea()
                ProgressView("Please wait…")
                    .padding(22)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
    }
}
