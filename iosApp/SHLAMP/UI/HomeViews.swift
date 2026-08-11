import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(openDevices: { selectedTab = 1 }) }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(0)

            NavigationStack { DevicesView() }
                .tabItem { Label("Devices", systemImage: "lightbulb.2") }
                .tag(1)

            NavigationStack { CareView() }
                .tabItem { Label("Care", systemImage: "heart.text.square") }
                .tag(2)

            NavigationStack {
                MenuView(
                    openDevices: { selectedTab = 1 },
                    openCare: { selectedTab = 2 }
                )
            }
            .tabItem { Label("Menu", systemImage: "line.3.horizontal") }
            .tag(3)
        }
        .tint(SHLampTheme.primary)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .sheet(isPresented: $model.showingAddLamp) {
            NavigationStack { AddLampView() }
        }
        .sheet(isPresented: $model.showingDiagnostics) {
            NavigationStack { DiagnosticsView() }
        }
        .task { model.startConnections() }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppViewModel
    let openDevices: () -> Void

    private let grid = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var reachable: Int { model.lamps.filter(\.reachable).count }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                AppTopHeader(
                    title: model.homeName,
                    subtitle: homeSubtitle,
                    loading: model.busy,
                    onSearch: openDevices,
                    onRefresh: model.refresh,
                    onAdd: { model.showingAddLamp = true }
                )

                homeHero

                if !model.notice.isEmpty {
                    NoticeCard(text: model.notice, error: false)
                }
                if !model.errorMessage.isEmpty {
                    NoticeCard(text: model.errorMessage, error: true)
                }

                SectionHeader("Quick scenes")
                quickScenes

                SectionHeader(
                    "Favorite devices",
                    action: model.lamps.isEmpty ? "Add lamp" : "View all",
                    onAction: model.lamps.isEmpty ? { model.showingAddLamp = true } : openDevices
                )

                if model.lamps.isEmpty {
                    EmptyLampView()
                } else {
                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(model.lamps.prefix(4)) { lamp in
                            LampGridCell(lamp: lamp)
                        }
                    }
                }

                if !model.lamps.isEmpty {
                    roomsCard
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
        .navigationDestination(for: String.self) { LampControlView(lampID: $0) }
    }

    private var homeSubtitle: String {
        if model.lamps.isEmpty { return "Set up your first lamp" }
        if reachable == model.lamps.count { return "All lamps are ready" }
        if reachable > 0 { return "\(reachable) of \(model.lamps.count) lamps ready" }
        return model.cloudConnected ? "Remote connection is available" : model.cloudStatus
    }

    private var homeHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your lighting at a glance")
                        .font(.title3.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text(model.cloudConnected ? "Cloud and local controls are active" : model.cloudStatus)
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                Spacer()
                ZStack {
                    Circle().fill(SHLampTheme.primarySoft)
                    Image(systemName: "house.and.flag.fill")
                        .font(.title2)
                        .foregroundStyle(SHLampTheme.primary)
                }
                .frame(width: 54, height: 54)
            }

            HStack(spacing: 10) {
                MetricTile(value: "\(model.lamps.count)", label: "Devices", accent: SHLampTheme.primary, surface: SHLampTheme.primarySoft)
                MetricTile(value: "\(reachable)", label: "Ready", accent: SHLampTheme.success, surface: SHLampTheme.successSoft)
                MetricTile(value: "\(model.lamps.filter { $0.state.power }.count)", label: "On", accent: SHLampTheme.warmDeep, surface: SHLampTheme.warmSoft)
            }
        }
        .shGlassCard(padding: 18, radius: 28)
    }

    private var quickScenes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                SceneChip(title: "Reading", subtitle: "100%", systemName: "book.fill", accent: SHLampTheme.secondary) {
                    model.lamps.filter { $0.uiCanAttemptBasicControl }.forEach { model.setBrightness($0, value: 100) }
                }
                SceneChip(title: "Relax", subtitle: "60%", systemName: "sparkles", accent: SHLampTheme.primary) {
                    model.lamps.filter { $0.uiCanAttemptBasicControl }.forEach { model.setBrightness($0, value: 60) }
                }
                SceneChip(title: "Night", subtitle: "20%", systemName: "moon.fill", accent: SHLampTheme.warmDeep) {
                    model.lamps.filter { $0.uiCanAttemptBasicControl }.forEach { model.setBrightness($0, value: 20) }
                }
                SceneChip(title: "All off", subtitle: "Home", systemName: "power", accent: SHLampTheme.textSecondary) {
                    model.lamps.filter { $0.uiCanAttemptBasicControl }.forEach { model.setPower($0, on: false) }
                }
            }
        }
    }

    private var roomsCard: some View {
        let groups = Dictionary(grouping: model.lamps) { lamp in
            lamp.uiRoomName
        }

        return VStack(spacing: 0) {
            SectionHeader("Rooms", action: "Open devices", onAction: openDevices)
                .padding(.bottom, 10)

            ForEach(Array(groups.keys.sorted().prefix(4)).indices, id: \.self) { index in
                let name = Array(groups.keys.sorted().prefix(4))[index]
                let lamps = groups[name] ?? []
                Button(action: openDevices) {
                    HStack(spacing: 11) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(SHLampTheme.surfaceSoft)
                            Text(String(name.prefix(1)).uppercased())
                                .font(.headline)
                                .foregroundStyle(SHLampTheme.primary)
                        }
                        .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SHLampTheme.textPrimary)
                            Text("\(lamps.filter { $0.state.power }.count) on · \(lamps.count) total")
                                .font(.caption)
                                .foregroundStyle(SHLampTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SHLampTheme.textDisabled)
                    }
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)

                if index < min(groups.count, 4) - 1 {
                    Divider().overlay(SHLampTheme.divider)
                }
            }
        }
        .shCard(padding: 17, radius: 24)
    }
}

struct DevicesView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var search = ""
    @State private var selectedRoom = "All"

    private let grid = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var rooms: [String] {
        ["All"] + Array(Set(model.lamps.map { $0.uiRoomName })).sorted()
    }

    private var filtered: [LampRecord] {
        model.lamps.filter { lamp in
            let room = lamp.uiRoomName
            let roomMatches = selectedRoom == "All" || selectedRoom == room
            let searchMatches = search.isEmpty ||
                lamp.name.localizedCaseInsensitiveContains(search) ||
                lamp.id.localizedCaseInsensitiveContains(search) ||
                room.localizedCaseInsensitiveContains(search)
            return roomMatches && searchMatches
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                AppTopHeader(
                    title: "Devices",
                    subtitle: deviceSubtitle,
                    loading: model.busy,
                    onSearch: nil,
                    onRefresh: model.refresh,
                    onAdd: { model.showingAddLamp = true }
                )

                searchField
                roomFilters

                if filtered.isEmpty {
                    EmptyLampView(message: model.lamps.isEmpty ? "No lamps added yet." : "No matching lamps.")
                } else {
                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(filtered) { lamp in
                            LampGridCell(lamp: lamp)
                        }
                    }
                }

                Button {
                    model.showingAddLamp = true
                } label: {
                    Label("Add another lamp", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(SHLampTheme.primary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
        .navigationDestination(for: String.self) { LampControlView(lampID: $0) }
        .onChange(of: rooms) { _, availableRooms in
            if !availableRooms.contains(selectedRoom) { selectedRoom = "All" }
        }
    }

    private var deviceSubtitle: String {
        switch model.lamps.count {
        case 0: return "No lamps added"
        case 1: return "1 lamp in your home"
        default: return "\(model.lamps.count) lamps in your home"
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SHLampTheme.textSecondary)
            TextField("Search lamps or rooms", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button("Clear") { search = "" }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SHLampTheme.primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(SHLampTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(SHLampTheme.border, lineWidth: 1))
    }

    private var roomFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(rooms, id: \.self) { room in
                    Button(room) { selectedRoom = room }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedRoom == room ? Color.white : SHLampTheme.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(selectedRoom == room ? SHLampTheme.primary : SHLampTheme.surface, in: Capsule())
                        .overlay(Capsule().stroke(selectedRoom == room ? Color.clear : SHLampTheme.border, lineWidth: 1))
                }
            }
        }
    }
}

struct CareView: View {
    @EnvironmentObject private var model: AppViewModel

    private var online: Int { model.lamps.filter(\.reachable).count }
    private var offline: Int { model.lamps.count - online }
    private var linked: Int { model.lamps.filter(\.cloudClaimed).count }
    private var needsAttention: Bool { offline > 0 || (!model.cloudConnected && linked > 0) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                AppTopHeader(
                    title: "Care",
                    subtitle: "Lamp health, connectivity and support",
                    loading: model.busy,
                    onSearch: nil,
                    onRefresh: model.refresh,
                    onAdd: nil
                )

                careHero

                HStack(spacing: 10) {
                    MetricTile(value: "\(online)", label: "Ready", accent: SHLampTheme.success, surface: SHLampTheme.successSoft)
                    MetricTile(value: "\(linked)", label: "Cloud linked", accent: SHLampTheme.info, surface: SHLampTheme.infoSoft)
                    MetricTile(value: "\(offline)", label: "Offline", accent: offline > 0 ? SHLampTheme.error : SHLampTheme.textSecondary, surface: offline > 0 ? SHLampTheme.errorSoft : SHLampTheme.surfaceSoft)
                }

                SectionHeader("Device health")

                if model.lamps.isEmpty {
                    InfoPanel(title: "No lamps to check", text: "Add a lamp and its health information will appear here.", accent: SHLampTheme.info, surface: SHLampTheme.infoSoft)
                } else {
                    ForEach(model.lamps) { lamp in
                        NavigationLink(value: lamp.id) {
                            HealthRow(lamp: lamp)
                        }
                        .buttonStyle(.plain)
                    }
                }

                SectionHeader("Battery")
                let batteryLamps = model.lamps.filter { $0.state.batteryValid && $0.state.batteryPercent != nil }
                if batteryLamps.isEmpty {
                    InfoPanel(title: "Battery status unavailable", text: "Connect to the lamp to refresh its battery status.", accent: SHLampTheme.warmDeep, surface: SHLampTheme.warmSoft)
                } else {
                    ForEach(batteryLamps) { lamp in
                        NavigationLink(value: lamp.id) {
                            BatteryHealthRow(lamp: lamp)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    model.showingDiagnostics = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(SHLampTheme.primarySoft)
                            Image(systemName: "stethoscope")
                                .foregroundStyle(SHLampTheme.primary)
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connection diagnostics").font(.headline).foregroundStyle(SHLampTheme.textPrimary)
                            Text("Check Bluetooth, local Wi-Fi and cloud status").font(.caption).foregroundStyle(SHLampTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(SHLampTheme.textDisabled)
                    }
                    .shCard(padding: 15, radius: 21)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
        .navigationDestination(for: String.self) { LampControlView(lampID: $0) }
    }

    private var careHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.78))
                    Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(needsAttention ? SHLampTheme.warning : SHLampTheme.success)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(needsAttention ? "Some lamps need attention" : "Everything looks good")
                        .font(.title3.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text(careMessage)
                        .font(.subheadline)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
            }

            Button("Run Smart Check") { model.showingDiagnostics = true }
                .buttonStyle(PrimaryActionButtonStyle(color: needsAttention ? SHLampTheme.warning : SHLampTheme.success))
        }
        .padding(20)
        .background(needsAttention ? SHLampTheme.warningSoft : SHLampTheme.successSoft, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke((needsAttention ? SHLampTheme.warning : SHLampTheme.success).opacity(0.18), lineWidth: 1))
    }

    private var careMessage: String {
        if model.lamps.isEmpty { return "Add a lamp to begin health monitoring" }
        if offline > 0 { return "\(offline) lamp\(offline == 1 ? " is" : "s are") offline" }
        return "All \(model.lamps.count) lamps are responding normally"
    }
}

struct MenuView: View {
    @EnvironmentObject private var model: AppViewModel
    let openDevices: () -> Void
    let openCare: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Handicrafts®")
                        .font(.title2.bold())
                        .foregroundStyle(SHLampTheme.textPrimary)
                    Text("Account and product management")
                        .font(.subheadline)
                        .foregroundStyle(SHLampTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                accountCard

                MenuSectionCard(title: "Product management", rows: [
                    MenuRowData(title: "Devices", subtitle: "\(model.lamps.count) lamp\(model.lamps.count == 1 ? "" : "s"), rooms and access", systemName: "lightbulb.2", accent: SHLampTheme.primary, action: openDevices),
                    MenuRowData(title: "Care and diagnostics", subtitle: "Health, connection checks and support", systemName: "heart.text.square", accent: SHLampTheme.success, action: openCare),
                    MenuRowData(title: "Connection diagnostics", subtitle: "Detailed Bluetooth, Wi-Fi and cloud status", systemName: "stethoscope", accent: SHLampTheme.info, action: { model.showingDiagnostics = true }),
                    MenuRowData(title: "Add a lamp", subtitle: "Find a nearby SH Lamp and connect it", systemName: "plus", accent: SHLampTheme.secondary, action: { model.showingAddLamp = true })
                ])

                MenuSectionCard(title: "App", rows: [
                    MenuRowData(title: "Refresh home", subtitle: "Update device state and cloud connection", systemName: "arrow.clockwise", accent: SHLampTheme.primary, action: model.refresh)
                ])

                Button(role: .destructive) { model.signOut() } label: {
                    Text("Sign out")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(SHLampTheme.error)

                Text("\(Bundle.main.shLampVersionLabel) · Smart Handicrafts®")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textDisabled)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(SHLampTheme.background.ignoresSafeArea())
    }


    private var accountDisplayName: String {
        guard let name = model.currentUser?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return model.homeName
        }
        return name
    }

    private var accountCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(SHLampTheme.primarySoft)
                BrandLogoView(size: 34)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(accountDisplayName)
                    .font(.headline)
                    .foregroundStyle(SHLampTheme.textPrimary)
                Text(model.currentUser?.email ?? "")
                    .font(.caption)
                    .foregroundStyle(SHLampTheme.textSecondary)
                Text(model.cloudConnected ? "Account connected" : "Reconnecting to account")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.cloudConnected ? SHLampTheme.success : SHLampTheme.warning)
            }
            Spacer()
        }
        .shCard(padding: 18, radius: 24)
    }
}

struct EmptyLampView: View {
    @EnvironmentObject private var model: AppViewModel
    var message = "Add your first lamp to control it from this iPhone."

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(SHLampTheme.primarySoft)
                Image(systemName: "lightbulb.led")
                    .font(.system(size: 34))
                    .foregroundStyle(SHLampTheme.primary)
            }
            .frame(width: 72, height: 72)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(SHLampTheme.textSecondary)
            Button("Add a lamp") { model.showingAddLamp = true }
                .buttonStyle(PrimaryActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .shCard()
    }
}

private struct AppTopHeader: View {
    let title: String
    let subtitle: String
    let loading: Bool
    let onSearch: (() -> Void)?
    let onRefresh: () -> Void
    let onAdd: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(SHLampTheme.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(SHLampTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if let onSearch {
                RoundIconButton(systemName: "magnifyingglass", action: onSearch)
            }
            RoundIconButton(systemName: "arrow.clockwise", loading: loading, action: onRefresh)
            if let onAdd {
                RoundIconButton(systemName: "plus", filled: true, action: onAdd)
            }
        }
    }
}

private struct MetricTile: View {
    let value: String
    let label: String
    let accent: Color
    let surface: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(accent)
            Text(label)
                .font(.caption2)
                .foregroundStyle(SHLampTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SceneChip: View {
    let title: String
    let subtitle: String
    let systemName: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(accent.opacity(0.12))
                    Image(systemName: systemName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(SHLampTheme.textPrimary)
                    Text(subtitle).font(.caption2).foregroundStyle(SHLampTheme.textSecondary)
                }
            }
            .frame(width: 132, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(SHLampTheme.surface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(SHLampTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct InfoPanel: View {
    let title: String
    let text: String
    let accent: Color
    let surface: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline).foregroundStyle(SHLampTheme.textPrimary)
            Text(text).font(.subheadline).foregroundStyle(SHLampTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(accent.opacity(0.18), lineWidth: 1))
    }
}

private struct HealthRow: View {
    let lamp: LampRecord

    var body: some View {
        HStack(spacing: 12) {
            MiniLampGlyph(isOn: lamp.state.power)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(lamp.name).font(.headline).foregroundStyle(SHLampTheme.textPrimary)
                Text(lamp.reachable ? "Working normally" : "Connection needs attention")
                    .font(.caption)
                    .foregroundStyle(lamp.reachable ? SHLampTheme.success : SHLampTheme.error)
            }
            Spacer()
            StatusPill(text: lamp.route.label, color: lamp.reachable ? SHLampTheme.success : SHLampTheme.error)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(SHLampTheme.textDisabled)
        }
        .shCard(padding: 15, radius: 21)
    }
}

private struct BatteryHealthRow: View {
    let lamp: LampRecord

    var body: some View {
        let percent = lamp.state.batteryPercent ?? 0
        let charging = lamp.state.batteryCharging == true
        let low = percent <= 20
        let accent = charging ? SHLampTheme.success : (low ? SHLampTheme.error : SHLampTheme.textPrimary)
        let surface = charging ? SHLampTheme.successSoft : (low ? SHLampTheme.errorSoft : SHLampTheme.surface)

        HStack(spacing: 13) {
            ZStack {
                Circle().stroke(accent.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: Double(percent) / 100)
                    .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if charging {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(accent)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(lamp.name).font(.headline).foregroundStyle(SHLampTheme.textPrimary)
                Text(charging ? "Charging" : (low ? "Low battery" : "Battery healthy"))
                    .font(.caption)
                    .foregroundStyle(accent)
            }
            Spacer()
            Text("\(percent)%").font(.headline).foregroundStyle(accent)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(accent)
        }
        .padding(15)
        .background(surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(accent.opacity(0.22), lineWidth: 1))
    }
}

private struct MenuRowData: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemName: String
    let accent: Color
    let action: () -> Void
}

private struct MenuSectionCard: View {
    let title: String
    let rows: [MenuRowData]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SHLampTheme.textSecondary)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    Button(action: row.action) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(row.accent.opacity(0.12))
                                Image(systemName: row.systemName)
                                    .foregroundStyle(row.accent)
                            }
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(.subheadline.weight(.semibold)).foregroundStyle(SHLampTheme.textPrimary)
                                Text(row.subtitle).font(.caption).foregroundStyle(SHLampTheme.textSecondary).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(SHLampTheme.textDisabled)
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    if index < rows.count - 1 {
                        Divider().overlay(SHLampTheme.divider)
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(SHLampTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(SHLampTheme.border, lineWidth: 1))
        }
    }
}
