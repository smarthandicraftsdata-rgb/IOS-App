import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(openDevices: { selectedTab = 1 }) }
                .tabItem { Label("Home", systemImage: "house") }.tag(0)
            NavigationStack { DevicesView() }
                .tabItem { Label("Devices", systemImage: "lightbulb.2") }.tag(1)
            NavigationStack { CareView() }
                .tabItem { Label("Care", systemImage: "heart.text.square") }.tag(2)
            NavigationStack { MenuView(openDevices: { selectedTab = 1 }, openCare: { selectedTab = 2 }) }
                .tabItem { Label("Menu", systemImage: "line.3.horizontal") }.tag(3)
        }
        .tint(SHLampTheme.primary)
        .sheet(isPresented: $model.showingAddLamp) { NavigationStack { AddLampView() } }
        .sheet(isPresented: $model.showingDiagnostics) { NavigationStack { DiagnosticsView() } }
        .task { model.startConnections() }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    let openDevices: () -> Void

    private var reachable: Int { model.lamps.filter { $0.reachable }.count }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.homeName).font(.largeTitle.bold()).foregroundStyle(SHLampTheme.textPrimary)
                        Text(model.lamps.isEmpty ? "Set up your first lamp" : "\(reachable) of \(model.lamps.count) lamps ready")
                            .font(.subheadline).foregroundStyle(SHLampTheme.textSecondary)
                    }
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    Button { model.showingAddLamp = true } label: { Image(systemName: "plus") }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your lighting at a glance").font(.title3.bold())
                            Text(model.cloudConnected ? "Cloud and local controls are active" : model.cloudStatus)
                                .font(.caption).foregroundStyle(SHLampTheme.textSecondary)
                        }
                        Spacer()
                        ZStack {
                            Circle().fill(SHLampTheme.primarySoft)
                            Image(systemName: "house.and.flag.fill").foregroundStyle(SHLampTheme.primary).font(.title2)
                        }.frame(width: 54, height: 54)
                    }
                    HStack(spacing: 20) {
                        metric("Devices", "\(model.lamps.count)")
                        metric("Ready", "\(reachable)")
                        metric("On", "\(model.lamps.filter { $0.state.power }.count)")
                    }
                }
                .shCard()

                if !model.notice.isEmpty { NoticeCard(text: model.notice, error: false) }
                if !model.errorMessage.isEmpty { NoticeCard(text: model.errorMessage, error: true) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick scenes").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            scene("Reading", subtitle: "100%", icon: "book.fill", color: SHLampTheme.secondary) { model.lamps.filter { $0.reachable }.forEach { model.setBrightness($0, value: 100) } }
                            scene("Relax", subtitle: "60%", icon: "sparkles", color: SHLampTheme.primary) { model.lamps.filter { $0.reachable }.forEach { model.setBrightness($0, value: 60) } }
                            scene("Night", subtitle: "20%", icon: "moon.fill", color: SHLampTheme.warmDeep) { model.lamps.filter { $0.reachable }.forEach { model.setBrightness($0, value: 20) } }
                            scene("All off", subtitle: "Home", icon: "power", color: SHLampTheme.textSecondary) { model.lamps.filter { $0.reachable }.forEach { model.setPower($0, on: false) } }
                        }
                    }
                }

                HStack {
                    Text("Favorite devices").font(.headline)
                    Spacer()
                    Button("View all", action: openDevices).font(.subheadline)
                }

                if model.lamps.isEmpty {
                    EmptyLampView()
                } else {
                    ForEach(model.lamps.prefix(4)) { lamp in
                        NavigationLink(value: lamp.id) { LampCard(lamp: lamp) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
        }
        .background(SHLampTheme.background)
        .navigationDestination(for: String.self) { LampControlView(lampID: $0) }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title2.bold()); Text(title).font(.caption).foregroundStyle(SHLampTheme.textSecondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scene(_ title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).font(.title3)
                Text(title).font(.subheadline.bold()).foregroundStyle(SHLampTheme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(SHLampTheme.textSecondary)
            }
            .frame(width: 116, alignment: .leading).padding(14)
            .background(color.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

struct DevicesView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var search = ""
    @State private var onlyOnline = false

    private var filtered: [LampRecord] {
        model.lamps.filter { lamp in
            (!onlyOnline || lamp.reachable) && (search.isEmpty || lamp.name.localizedCaseInsensitiveContains(search) || lamp.id.localizedCaseInsensitiveContains(search) || (lamp.roomName?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                TextField("Search lamps or rooms", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("Show reachable lamps only", isOn: $onlyOnline).font(.subheadline)
                if filtered.isEmpty { EmptyLampView(message: search.isEmpty ? "No lamps added yet." : "No matching lamps.") }
                ForEach(filtered) { lamp in
                    NavigationLink(value: lamp.id) { LampCard(lamp: lamp) }.buttonStyle(.plain)
                }
            }.padding(18)
        }
        .background(SHLampTheme.background)
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                Button { model.showingAddLamp = true } label: { Image(systemName: "plus") }
            }
        }
        .navigationDestination(for: String.self) { LampControlView(lampID: $0) }
    }
}

struct CareView: View {
    @EnvironmentObject private var model: AppViewModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Lamp health", systemImage: "heart.text.square.fill").font(.title2.bold()).foregroundStyle(SHLampTheme.primary)
                    Text("Check battery reporting, connection routes and lamps that need attention.").foregroundStyle(SHLampTheme.textSecondary)
                    Button("Run connection check") { model.showingDiagnostics = true }.buttonStyle(.borderedProminent).tint(SHLampTheme.primary)
                }.shCard()

                ForEach(model.lamps) { lamp in
                    HStack(spacing: 14) {
                        Image(systemName: lamp.reachable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.title2).foregroundStyle(lamp.reachable ? SHLampTheme.success : SHLampTheme.error)
                        VStack(alignment: .leading) {
                            Text(lamp.name).font(.headline)
                            Text(lamp.reachable ? "Connected through \(lamp.route.label)" : "Offline — move closer or check Wi-Fi")
                                .font(.caption).foregroundStyle(SHLampTheme.textSecondary)
                        }
                        Spacer()
                        if let value = lamp.state.batteryPercent { Text("\(value)%").font(.subheadline.bold()) }
                    }.shCard(padding: 14)
                }
            }.padding(18)
        }.background(SHLampTheme.background).navigationTitle("Care")
    }
}

struct MenuView: View {
    @EnvironmentObject private var model: AppViewModel
    let openDevices: () -> Void
    let openCare: () -> Void
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(SHLampTheme.primary)
                    VStack(alignment: .leading) { Text(model.currentUser?.name ?? "SH Lamp user").font(.headline); Text(model.currentUser?.email ?? "").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("My home") {
                Button(action: openDevices) { Label("Devices", systemImage: "lightbulb.2") }
                Button(action: openCare) { Label("Care and diagnostics", systemImage: "heart.text.square") }
                Button { model.showingAddLamp = true } label: { Label("Add lamp", systemImage: "plus.circle") }
                Button { model.refresh() } label: { Label("Refresh everything", systemImage: "arrow.clockwise") }
            }
            Section("Connections") {
                LabeledContent("Cloud", value: model.cloudStatus)
                LabeledContent("Bluetooth", value: model.bluetoothStatus)
                LabeledContent("Local network", value: model.localNetworkStatus)
            }
            Section {
                Button(role: .destructive) { model.signOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            Section { Text("SH Lamp iOS 1.3.1\nSmart Handicrafts®").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("Menu")
    }
}

struct EmptyLampView: View {
    @EnvironmentObject private var model: AppViewModel
    var message = "Add your first lamp to control it from this iPhone."
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.led").font(.system(size: 42)).foregroundStyle(SHLampTheme.primary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(SHLampTheme.textSecondary)
            Button("Add a lamp") { model.showingAddLamp = true }.buttonStyle(.borderedProminent).tint(SHLampTheme.primary)
        }.frame(maxWidth: .infinity).shCard()
    }
}

struct NoticeCard: View {
    let text: String
    let error: Bool
    var body: some View {
        Label(text, systemImage: error ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.footnote).foregroundStyle(error ? SHLampTheme.error : SHLampTheme.primary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(error ? SHLampTheme.errorSoft : SHLampTheme.primarySoft)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
