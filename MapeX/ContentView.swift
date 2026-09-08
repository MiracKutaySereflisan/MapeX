// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import SwiftUI
import MapKit
import CoreLocation

// ============================================================================
// MARK: - Ana Ekran
// ============================================================================
//
// ERGONOMİ İLKELERİ
// -----------------
// • GÜN/GECE. Eski kod `.preferredColorScheme(.dark)` ile koyu temayı
//   zorluyordu. Öğlen güneşinde siyah ekran okunmaz. Artık sistem temasına
//   uyulur; harita da otomatik gece moduna geçer.
// • DOKUNMA HEDEFLERİ. Sürüş sırasındaki düğmeler en az 56 pt — araçta,
//   titreşim altında, göz atmadan basılabilmeli (Apple'ın 44 pt tabanı masaüstü
//   koşulu içindir).
// • BİLGİ SIRALAMASI. Sürüşte ekranın üstü SAPAK, altı HIZ. Göz doğal olarak
//   önce yukarı bakar; en acil bilgi (nereye döneceğim) orada olmalı.
// • SERBEST GEZİNME. Sürüş sırasında harita kilitli değil; kullanıcı rotayı
//   inceleyebilir, "Ortala" ile takibe döner.
// ============================================================================

struct ContentView: View {
    // Konum ve sürüş beyni PAYLAŞILAN örneklerdir — CarPlay aynı ikisini
    // okur (bkz. DriveViewModel.shared). Arama tamamlayıcı ekrana özgü
    // olduğu için `@StateObject` kalır.
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var vm = DriveViewModel.shared
    @StateObject private var completer = SearchCompleter()
    @ObservedObject private var display = DisplayPreferences.shared

    @State private var menuOpen = false
    @State private var showRouteSheet = false
    @State private var menuDestination: MenuDestination?
    @State private var confirmFinish = false
    @State private var alertMessage: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Harita ayrı bir alt görünüm: kamera 60 Hz yayın yaptığı için
            // yalnızca BURASI o hızda yeniden çizilir. Paneller, düğmeler ve
            // listeler kameraya abone değildir.
            NavMapView(camera: vm.camera,
                       phase: vm.phase,
                       routeOptions: vm.routeOptions,
                       selectedOptionID: vm.selectedOptionID,
                       activeRoute: vm.route,
                       curves: visibleCurves,
                       destination: vm.destination,
                       markerColor: vm.gaugeColor.color)

            VStack(spacing: 0) {
                switch vm.phase {
                case .driving:  navigationBanner
                default:        topBar
                }

                // Hava çipi — üstteki neyse onun altında, solda. Harita
                // alanının bu köşesi her iki fazda da boş kalıyor.
                HStack {
                    WeatherChip(vm: vm)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer(minLength: 0)
                bottomArea
            }

            // Çevresel risk aurası — kritik durumda ekran çeperinde nabız.
            // Merkeze değil KENARA konur: sürücünün odağı yolda kalır, uyarı
            // çevresel görüşe düşer. Ekranın ortasını kapatan bir uyarı,
            // tam da bakılması gereken anda haritayı gizlerdi.
            PeripheralRiskAura(risk: vm.risk)
                .allowsHitTesting(false)

            // Konum izni yoksa uygulama SESSİZCE çalışmıyordu: harita boş,
            // arama sonuç veriyor ama rota çizilmiyordu. Kullanıcı nedenini
            // anlayamıyordu. Artık açıkça söyleniyor ve tek dokunuşla
            // Ayarlar'a gidiliyor.
            if !location.authorized && location.authorization != .notDetermined {
                LocationPermissionOverlay(status: location.authorization) {
                    location.start()
                }
            }

            SideMenuView(isOpen: $menuOpen) { dest in
                menuDestination = dest
            }
        }
        .onAppear {
            location.start()
            AudioSessionManager.shared.configure()
        }
        // NOT: Konum akışının sürüş beynine bağlanması buradan ALINDI.
        // Bu ekran görünmediğinde (CarPlay, arka plan) navigasyonun durmaması
        // için bağ artık `DriveViewModel.init` içinde kuruluyor.
        .onChange(of: vm.query) { _, q in
            completer.update(query: q, around: location.location?.coordinate)
        }
        .onChange(of: vm.selectedOptionID) { _, _ in
            if let r = vm.route, vm.phase == .routeReady {
                vm.camera.showOverview(r.polyline.boundingMapRect)
            }
        }
        .onChange(of: vm.phase) { _, p in
            if p == .idle { vm.camera.position = .userLocation(fallback: .automatic) }
        }
        // Menü ekranları TAM SAYFA açılır. Önceden menünün 300 puntoluk
        // NavigationStack'i içinde açıldıkları için form alanları
        // kullanılamaz haldeydi.
        .sheet(item: $menuDestination) { dest in
            NavigationStack {
                Group {
                    switch dest {
                    case .vehicle:   VehicleView()
                    case .settings:  SettingsView()
                    case .history:   TripHistoryView()
                    case .badges:    BadgesView()
                    case .help:      HelpView()
                    case .favorites:
                        FavoritesView(onSelectRoute: { fav in
                            menuDestination = nil
                            Task {
                                guard let c = location.location?.coordinate else { return }
                                await vm.loadRoute(to: fav.endCoord.coordinate, from: c)
                            }
                        })
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Bitti") { menuDestination = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showRouteSheet) {
            RouteComparisonView(vm: vm)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { vm.phase == .finished }, set: { _ in })) {
            TripSummaryView(vm: vm).interactiveDismissDisabled()
        }
        .confirmationDialog("Yolculuğu bitir?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Bitir ve özeti gör", role: .destructive) {
                if let l = location.location { vm.finish(at: l, location: location) }
            }
            Button("Sürüşe devam et", role: .cancel) {}
        } message: {
            Text("Yolculuk kaydedilecek ve puanın hesaplanacak.")
        }
        .alert("Bilgi", isPresented: Binding(get: { alertMessage != nil },
                                             set: { if !$0 { alertMessage = nil } })) {
            Button("Tamam") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    /// Sonraki virajlar — hem haritadaki noktalar hem önizleme şeridi bunu okur.
    private var upcomingCurves: [(curve: Curve, distance: Double)] {
        vm.upcomingCurves(for: location.location)
    }

    /// Sürüşte tüm virajları çizmek 500 km'lik rotada yüzlerce annotation demek.
    /// Sürüşte yalnızca yakındakiler, planlamada hepsi (ama en fazla 150).
    private var visibleCurves: [Curve] {
        guard vm.phase == .driving else { return Array(vm.curves.prefix(150)) }
        return upcomingCurves.map(\.curve)
    }

    // ========================================================================
    // MARK: Üst bar (planlama)
    // ========================================================================

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                circleButton("line.3.horizontal") {
                    withAnimation(.snappy) { menuOpen.toggle() }
                }
                .accessibilityLabel("Menü")

                // Hedef seçildikten sonra arama alanı, seçilen yeri gösteren
                // KOMPAKT bir çipe dönüşür. Öneri listesi de kapanır — yoksa
                // rota alternatiflerini incelemek isteyen kullanıcının önünü
                // kapatıyordu (haritanın yarısı öneri kutusuydu).
                if vm.phase == .routeReady, let dest = vm.destination {
                    destinationChip(dest)
                } else {
                    searchField
                }

                Menu {
                    Picker("Sürüş Modu", selection: $vm.drivingMode) {
                        ForEach(DrivingMode.allCases, id: \.self) { m in
                            Label("\(m.rawValue) — \(m.aciklama)", systemImage: m.icon).tag(m)
                        }
                    }

                    // Zemin artık Picker DEĞİL: "otomatik" bir RoadCondition
                    // değeri değil, bir kaynak seçimi. Picker'a sığdırmak için
                    // sahte bir case uydurmak yerine açık düğmeler kullanılıyor.
                    Section("Zemin") {
                        Button {
                            vm.useAutomaticRoadCondition()
                        } label: {
                            Label(vm.roadConditionIsManual
                                  ? "Otomatik — hava durumundan"
                                  : "✓ Otomatik — \(vm.roadCondition.rawValue)",
                                  systemImage: "cloud.sun.fill")
                        }
                        ForEach(RoadCondition.allCases, id: \.self) { c in
                            Button {
                                vm.setManualRoadCondition(c)
                            } label: {
                                Label(vm.roadConditionIsManual && vm.roadCondition == c
                                      ? "✓ \(c.rawValue)" : c.rawValue,
                                      systemImage: c.icon)
                            }
                        }
                    }

                    Toggle("Ücretli yollardan kaçın", isOn: $vm.avoidTolls)
                } label: {
                    Image(systemName: vm.drivingMode.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .clipShape(Circle())
            }

            // Ev / İş kısayolları — günlük kullanımın büyük kısmı bu iki hedef.
            if vm.phase == .idle, !searchFocused {
                PlaceShortcutsRow(currentLocation: location.location) { coord in
                    Task {
                        guard let c = location.location?.coordinate else { return }
                        await vm.loadRoute(to: coord, from: c)
                    }
                }
            }

            // Öneriler yalnızca hedef HENÜZ SEÇİLMEMİŞKEN görünür.
            if vm.phase != .routeReady {
                suggestionList
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .animation(.snappy, value: vm.phase)
    }

    /// Seçili hedef çipi — tek satır, haritayı kapatmaz.
    ///
    /// DÜZELTİLEN HATA: Bu çip önce yalnızca BİLGİ gösteriyordu ve tek çıkışı
    /// sağdaki minik X'ti. Kullanıcı çipe dokunuyor, hiçbir şey olmuyordu;
    /// arama alanı da yerini çipe bıraktığı için başka bir adres yazmak
    /// imkânsızdı — rotadan vazgeçilemiyordu.
    ///
    /// Artık ÇİPİN TAMAMI dokunulabilir ve tek bir iş yapıyor: rotayı bırakıp
    /// aramaya döner, klavyeyi de açar. Yaşlı kullanıcı için tek davranış, tek
    /// büyük hedef — X'i bulmaya çalışmaktan iyidir.
    private func destinationChip(_ dest: MKMapItem) -> some View {
        Button {
            withAnimation(.snappy) { vm.reset() }
            // Sıfırlama ekranı yeniden kurduktan sonra odaklan
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                    .font(.footnote)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dest.name ?? vm.query)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("değiştirmek için dokun")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .adaptiveGlass(in:.capsule)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Nereye gidiyoruz?", text: $vm.query)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit {
                    Task {
                        await vm.search(near: location.location?.coordinate)
                        if vm.results.isEmpty && !vm.query.isEmpty {
                            alertMessage = "\"\(vm.query)\" için sonuç bulunamadı. Daha kısa yazmayı veya şehir adı eklemeyi dene."
                        }
                    }
                }
            if vm.isAnalyzing {
                ProgressView().controlSize(.small)
            } else if !vm.query.isEmpty || vm.route != nil {
                Button {
                    vm.reset(); searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .adaptiveGlass(in:.capsule)
    }

    @ViewBuilder
    private var suggestionList: some View {
        // Boş alan + odak → favoriler
        if searchFocused, vm.query.isEmpty, vm.phase == .idle {
            let favs = Array(StorageManager.loadFavorites().prefix(4))
            if !favs.isEmpty {
                listCard {
                    ForEach(favs) { fav in
                        rowButton(icon: "star.fill", tint: .orange,
                                  title: fav.name,
                                  subtitle: String(format: "%.0f km", fav.distance / 1000)) {
                            searchFocused = false
                            Task {
                                guard let c = location.location?.coordinate else { return }
                                await vm.loadRoute(to: fav.endCoord.coordinate, from: c)
                            }
                        }
                    }
                }
            }
        }

        // Yazarken canlı tahminler
        if !vm.query.isEmpty, !completer.suggestions.isEmpty, vm.results.isEmpty {
            listCard {
                ForEach(completer.suggestions, id: \.self) { s in
                    rowButton(icon: "mappin.circle.fill", tint: .accentColor,
                              title: s.title, subtitle: s.subtitle.isEmpty ? nil : s.subtitle) {
                        searchFocused = false
                        Task {
                            guard let item = await SearchCompleter.resolve(s),
                                  let c = location.location?.coordinate else { return }
                            vm.query = s.title
                            await vm.selectDestination(item, from: c)
                        }
                    }
                }
            }
        }

        // Enter'la yapılan arama sonuçları
        if !vm.results.isEmpty {
            listCard {
                ForEach(vm.results.prefix(8), id: \.self) { item in
                    rowButton(icon: "mappin.circle.fill", tint: .accentColor,
                              title: item.name ?? "?",
                              subtitle: item.address?.fullAddress) {
                        guard let c = location.location?.coordinate else { return }
                        searchFocused = false
                        Task { await vm.selectDestination(item, from: c) }
                    }
                }
            }
        }
    }

    // ========================================================================
    // MARK: Navigasyon şeridi (sürüş)
    // ========================================================================

    @ViewBuilder
    private var navigationBanner: some View {
        if let g = vm.guidance {
            VStack(spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    TurnGlyph(angle: g.turnAngle)
                        .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatMeters(g.distanceToTurn))
                            .drivingNumber(size: 30, relativeTo: .largeTitle)
                            .contentTransition(.numericText())
                            .monospacedDigit()
                        Text(g.instruction)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(display.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                // VoiceOver tek cümle duysun: parça parça "300", "m", "sağa
                // dönün" yerine anlamlı bir talimat.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(formatMeters(g.distanceToTurn)) sonra \(g.instruction)")

                if let next = g.nextInstruction {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.right").font(.caption2)
                        Text("sonra \(next)").font(.caption).lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(display.tertiaryText)
                }

                Divider()

                HStack(spacing: 14) {
                    Label("\(Int(g.remainingTime / 60)) dk", systemImage: "clock")
                    Label(formatMeters(g.remainingDistance), systemImage: "arrow.left.and.right")
                    Text(arrivalText(g.remainingTime))
                        .foregroundStyle(display.secondaryText)
                    Spacer()
                    if vm.isRerouting {
                        Label("yeniden", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption.weight(.medium))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Kalan \(Int(g.remainingTime / 60)) dakika, \(formatMeters(g.remainingDistance)). Varış \(arrivalText(g.remainingTime)).")

                ProgressView(value: g.progress)
                    .tint(.accentColor)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .adaptiveGlass(in: .rect(cornerRadius: 24))
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
    }

    // ========================================================================
    // MARK: Alt alan
    // ========================================================================

    @ViewBuilder
    private var bottomArea: some View {
        VStack(spacing: 10) {
            // Ortala düğmesi — takip modunda değilsek görünür.
            // Sürüş sırasında da görünür: kullanıcı rotayı inceledikten sonra
            // tek dokunuşla GPS takibine döner.
            if !vm.cameraFollowing, vm.phase != .idle {
                HStack {
                    Spacer()
                    Button {
                        vm.camera.recenter()
                    } label: {
                        Label("Ortala", systemImage: "location.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 18)
                            .frame(height: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .clipShape(Capsule())
                    .accessibilityLabel("Haritayı ortala")
                    .accessibilityHint("Kamerayı konumunuzu takip etmeye döndürür")
                }
                .padding(.horizontal, 16)
                .transition(.scale.combined(with: .opacity))
            }

            switch vm.phase {
            case .routeReady: routeReadyPanel
            case .driving:    drivingPanel
            default:          EmptyView()
            }
        }
        .animation(.snappy, value: vm.cameraFollowing)
        .padding(.bottom, 6)
    }

    // MARK: Rota hazır

    @ViewBuilder
    private var routeReadyPanel: some View {
        if let opt = vm.selectedOption {
            VStack(spacing: 12) {
                // Kaydırma tutamağı + sayfa göstergesi.
                // Paneli yukarı/aşağı sürükleyince sıradaki rotaya geçilir —
                // haritadan gözü ayırmadan alternatifleri gezmenin en hızlı yolu.
                if vm.routeOptions.count > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.up").font(.caption2)
                        ForEach(Array(vm.routeOptions.enumerated()), id: \.element.id) { i, o in
                            Capsule()
                                .fill(o.id == vm.selectedOptionID ? o.color : Color.secondary.opacity(0.3))
                                .frame(width: o.id == vm.selectedOptionID ? 18 : 7, height: 5)
                        }
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    .animation(.snappy, value: vm.selectedOptionID)
                }

                // Seçili rota özeti
                Button { showRouteSheet = true } label: {
                    HStack(alignment: .top, spacing: 12) {
                        // Rota rengi şeridi — haritadaki çizgiyle eşleşir
                        Capsule().fill(opt.color).frame(width: 5, height: 42)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(opt.durationText)
                                    .font(.title2.bold())
                                Text("• \(opt.distanceText)")
                                    .foregroundStyle(.secondary)
                                if let t = opt.trafficText {
                                    Text("• \(t)")
                                        .font(.caption.bold())
                                        .foregroundStyle(opt.trafficLevel.color)
                                }
                            }
                            // Etiketler tek satırda kalmalı. Sabit genişlikte
                            // sıkışınca SwiftUI kelimeyi ortadan bölüyordu
                            // ("Giş / esiz", "En az viraj / lı"). fixedSize +
                            // lineLimit bunu engeller; sığmayan etiketler yatay
                            // kaydırmayla erişilir.
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    if opt.trafficLevel != .unknown {
                                        Label(opt.trafficLevel.label, systemImage: opt.trafficLevel.icon)
                                            .font(.caption2.bold())
                                            .foregroundStyle(opt.trafficLevel.color)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    ForEach(opt.tags) { t in
                                        Label(t.rawValue, systemImage: t.icon)
                                            .font(.caption2.bold())
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(.tint.opacity(0.15), in: Capsule())
                                    }
                                }
                                .padding(.trailing, 4)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if vm.routeOptions.count > 1 {
                                Text("\(vm.selectedIndex + 1)/\(vm.routeOptions.count) rota")
                                    .font(.caption.bold())
                            }
                            Image(systemName: "list.bullet.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                RouteFactsRow(option: opt)

                HStack(spacing: 10) {
                    Button {
                        // GPS fix'i olmadan sürüş başlatmak, kamera takibi ve
                        // viraj eşlemesi çalışmadığı için sessiz bir hataya
                        // dönüşüyordu. Artık sebebi söylüyoruz.
                        guard location.location != nil else {
                            alertMessage = "Konum henüz alınamadı. Açık gökyüzü altında birkaç saniye bekleyip tekrar dene."
                            return
                        }
                        vm.startDriving(from: location.location, location: location)
                    } label: {
                        Label("BAŞLAT", systemImage: "location.north.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    // Büyük harf yazılmış etiketi VoiceOver harf harf okuyabilir.
                    .accessibilityLabel("Başlat")
                    .accessibilityHint("Seçili rotayla yol göstermeye başlar")

                    Button {
                        saveFavorite(opt)
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.title3)
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.glass)
                    .tint(.orange)
                }
            }
            .padding(16)
            .adaptiveGlass(in:.rect(cornerRadius: 26))
            .padding(.horizontal, 12)
            // Dikey sürükleme rotalar arasında gezinir.
            // 30 pt eşik: paneldeki düğmelere basarken yanlışlıkla rota
            // değiştirmeyi önleyecek kadar büyük, tek hareketle yapılacak
            // kadar küçük.
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onEnded { value in
                        guard abs(value.translation.height) > 30,
                              abs(value.translation.height) > abs(value.translation.width)
                        else { return }
                        withAnimation(.snappy) {
                            vm.cycleRoute(forward: value.translation.height < 0)
                        }
                    }
            )
        }
    }

    // MARK: Sürüş paneli

    private var drivingPanel: some View {
        VStack(spacing: 12) {
            // Viraj geri sayımı — en kritik bilgi, en büyük punto
            if let a = vm.curveAlert, a.level != .none {
                CurveWarningStrip(alert: a, currentSpeed: location.speedKmh)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 14) {
                SpeedGauge(color: vm.gaugeColor.color,
                           speed: Int(location.speedKmh),
                           target: vm.curveAlert.map { Int($0.curve.safeSpeedKmh) },
                           big: vm.curveAlert?.level ?? .none >= .prepare)

                VStack(alignment: .leading, spacing: 6) {
                    Label(vm.roadCondition.rawValue, systemImage: vm.roadCondition.icon)
                        .font(.caption.bold())
                        .foregroundStyle(vm.roadCondition == .dry ? display.secondaryText : Color.orange)

                    if vm.motion.motionAvailable {
                        GForceReadout(longitudinal: vm.motion.longitudinalG,
                                      lateral: vm.motion.lateralG)
                    }

                    Text(vm.curveAlert != nil ? vm.gaugeColor.etiket : "Düz yol")
                        .font(.caption)
                        .foregroundStyle(display.secondaryText)
                }

                Spacer()

                // Onaysız bitirme, yanlışlıkla dokunuşta bütün yolculuk
                // kaydını (skor, olaylar, rozetler) siliyordu. Araçta,
                // titreşim altında bu kolayca olur.
                Button {
                    confirmFinish = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "stop.fill").font(.title3)
                        Text("Bitir").font(.caption2.bold())
                    }
                    .frame(width: 62, height: 62)
                }
                .buttonStyle(.glass)
                .tint(.red)
                .accessibilityLabel("Yolculuğu bitir")
                .accessibilityHint("Onay istenir, sonra yolculuk özeti gösterilir")
            }

            // Yol önizlemesi en altta: yukarıdan aşağı aciliyet azalır —
            // önce "şimdi yavaşla", sonra "şu an neredesin", en sonra
            // "sırada ne var".
            if display.showCurvePreview, !upcomingCurves.isEmpty {
                CurvePreviewStrip(items: upcomingCurves)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .adaptiveGlass(in:.rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .animation(.snappy, value: vm.curveAlert?.level)
    }

    // ========================================================================
    // MARK: Yardımcılar
    // ========================================================================

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
    }

    @ViewBuilder
    private func listCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .adaptiveGlass(in:.rect(cornerRadius: 18))
    }

    private func rowButton(icon: String, tint: Color, title: String,
                           subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func formatMeters(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f km", m / 1000) : "\(Int(m / 10) * 10) m"
    }

    private func arrivalText(_ remaining: TimeInterval) -> String {
        let arrival = Date().addingTimeInterval(remaining)
        return arrival.formatted(date: .omitted, time: .shortened)
    }

    private func saveFavorite(_ opt: RouteOption) {
        guard let userLoc = location.location, let dest = vm.destination else { return }
        Task {
            let s = await RouteEngine.semt(of: userLoc)
            let e = await RouteEngine.semt(of: dest.location)
            StorageManager.saveFavoriteRoute(s, e,
                                             from: userLoc.coordinate,
                                             to: dest.location.coordinate,
                                             distance: opt.route.distance)
            SpeechManager.shared.speak("Rota favorilere eklendi.")
        }
    }
}

// ============================================================================
// MARK: - Harita Katmanı
// ============================================================================
//
// Kamerayı `@ObservedObject` olarak alan AYRI görünüm. Böylece kameranın
// 60 Hz'lik `position` yayını yalnızca haritayı yeniden çizer; ana ekranın
// panelleri, düğmeleri ve listeleri bu döngünün dışında kalır.
// ============================================================================

struct NavMapView: View {
    @ObservedObject var camera: NavigationCamera

    let phase: DrivePhase
    let routeOptions: [RouteOption]
    let selectedOptionID: UUID?
    let activeRoute: MKRoute?
    let curves: [Curve]
    let destination: MKMapItem?
    let markerColor: Color

    var body: some View {
        Map(position: $camera.position) {
            // Araç işareti — YUMUŞATILMIŞ konumu kullanır, ham GPS'i değil.
            // Ham konum kullanılsaydı işaret saniyede bir sıçrar, kamera akıcı
            // olduğu için ikisi birbirinden ayrı düşerdi.
            if let c = camera.smoothedCoordinate, phase == .driving {
                Annotation("", coordinate: c) {
                    VehicleMarker(heading: camera.smoothedHeading, color: markerColor)
                }
                .annotationTitles(.hidden)
            } else {
                UserAnnotation()
            }

            if phase == .routeReady {
                // Seçili olmayanlar ÖNCE çizilir ki seçili olan üstte kalsın.
                // Her rota kendi rengiyle — hangisinin nereden gittiği tek
                // bakışta görülsün.
                ForEach(routeOptions.filter { $0.id != selectedOptionID }) { opt in
                    MapPolyline(opt.route.polyline)
                        .stroke(opt.color.opacity(0.55),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                if let sel = routeOptions.first(where: { $0.id == selectedOptionID }) {
                    // Beyaz alt kontur: renkli çizgi trafik katmanının üstünde
                    // de okunur kalsın
                    MapPolyline(sel.route.polyline)
                        .stroke(.white.opacity(0.9),
                                style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    MapPolyline(sel.route.polyline)
                        .stroke(sel.color,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
            } else if let r = activeRoute {
                MapPolyline(r.polyline)
                    .stroke(.white.opacity(0.9),
                            style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(r.polyline)
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }

            ForEach(curves) { c in
                Annotation("", coordinate: c.coordinate) {
                    CurveDot(severity: c.severity)
                }
                .annotationTitles(.hidden)
            }

            if let dest = destination {
                Annotation(dest.name ?? "Hedef", coordinate: dest.location.coordinate) {
                    Image(systemName: "flag.checkered.circle.fill")
                        .font(.title)
                        .foregroundStyle(.red)
                        .background(Circle().fill(.background))
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic,
                            pointsOfInterest: phase == .driving ? .excludingAll : .all,
                            showsTraffic: true))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        // Kullanıcı haritaya dokunduğu an takip modundan çıkılır — kamera artık
        // onundur. Bu `onMapCameraChange` ile yapılamaz: bizim programatik
        // kamera yazmalarımızı da tetikler, ikisi ayırt edilemez.
        .onMapUserInteraction { camera.userDidInteract() }
        .ignoresSafeArea()
    }
}

// ============================================================================
// MARK: - Bileşenler
// ============================================================================

/// Çevresel risk parlaması.
///
/// `.warning`da sabit sarı bir kenar, `.critical`da nabız atan kırmızı.
/// Nabız 0.7 sn periyotlu — insan tepki eşiğinin biraz üstünde, panik
/// yaratmadan "şimdi" hissi veren aralık.
struct PeripheralRiskAura: View {
    let risk: SpeedModel.RiskStatus
    @State private var pulse = false

    private var color: Color {
        switch risk {
        case .exceeded: return GaugeColor.beyondLimit.color
        case .critical: return .red
        case .warning:  return .orange
        default:        return .clear
        }
    }

    /// Nabız yalnızca en üst iki basamakta atar.
    /// `== .critical` yazılsaydı `.exceeded` — yani EN KÖTÜ durum — sabit
    /// kalırdı; bir Comparable enum'a yeni ve daha yüksek bir case eklendiğinde
    /// eşitlik kontrolleri sessizce yanlış tarafa düşer.
    private var pulses: Bool { risk >= .critical }

    /// Sınır aşıldığında nabız hızlanır. Aynı hızda atan bir uyarı, iki farklı
    /// durumu ayırt edilemez kılardı.
    private var pulsePeriod: Double { risk == .exceeded ? 0.22 : 0.35 }

    var body: some View {
        if risk >= .warning {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .strokeBorder(
                    RadialGradient(colors: [color.opacity(0), color.opacity(0.9)],
                                   center: .center, startRadius: 60, endRadius: 420),
                    lineWidth: risk == .exceeded ? 34 : (risk == .critical ? 26 : 14))
                .blur(radius: 14)
                .opacity(pulses ? (pulse ? 1.0 : 0.30) : 0.55)
                .ignoresSafeArea()
                .onAppear { syncPulse() }
                // DÜZELTİLEN HATA: nabız yalnızca `onAppear`da kuruluyordu.
                // Aura sarıda belirip sonra kırmızıya yükselirse görünüm zaten
                // ekranda olduğu için `onAppear` bir daha çalışmıyor, nabız hiç
                // başlamıyordu — yani uyarı, tam da şiddetlendiği anda
                // hareketsiz kalıyordu.
                .onChange(of: risk) { _, _ in syncPulse() }
                .onDisappear { pulse = false }
                .transition(.opacity)
                .animation(.easeOut(duration: 0.25), value: risk)
        }
    }

    private func syncPulse() {
        guard pulses else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: pulsePeriod).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// Araç işareti — yumuşatılmış yöne göre döner.
struct VehicleMarker: View {
    let heading: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.22)).frame(width: 52, height: 52)
            Image(systemName: "location.north.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .padding(9)
                .background(color.gradient, in: Circle())
                .shadow(color: color.opacity(0.5), radius: 6)
                .rotationEffect(.degrees(heading))
        }
        .allowsHitTesting(false)
    }
}

extension Curve.Severity {
    /// Keskinliğin arayüz rengi. Model katmanı SwiftUI'a bağımlı olmasın diye
    /// `Severity.color` metin döndürür; görsel eşleme burada.
    var uiColor: Color {
        switch self {
        case .gentle: return .green
        case .moderate: return .yellow
        case .sharp: return .orange
        case .verySharp, .hairpin: return .red
        }
    }
}

/// Haritadaki viraj noktası.
struct CurveDot: View {
    let severity: Curve.Severity

    private var color: Color { severity.uiColor }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: severity == .gentle ? 7 : 10,
                   height: severity == .gentle ? 7 : 10)
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
            .allowsHitTesting(false)
    }
}

/// Dönüş açısına göre eğilen ok.
struct TurnGlyph: View {
    let angle: Double

    private var symbol: String {
        switch angle {
        case ..<(-135): return "arrow.uturn.left"
        case ..<(-35):  return "arrow.turn.up.left"
        case ..<(-12):  return "arrow.up.left"
        case ..<12:     return "arrow.up"
        case ..<35:     return "arrow.up.right"
        case ..<135:    return "arrow.turn.up.right"
        default:        return "arrow.uturn.right"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 32, weight: .bold))
            .foregroundStyle(.tint)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Virajda büyüyen hız göstergesi.
///
/// Çap da rakamla birlikte ölçeklenir: yalnızca punto büyütülseydi, "büyük
/// rakamlar" veya iOS metin boyutu açık olan kullanıcıda sayı halkanın dışına
/// taşardı.
struct SpeedGauge: View {
    let color: Color
    let speed: Int
    let target: Int?
    let big: Bool

    @ObservedObject private var display = DisplayPreferences.shared
    @ScaledMetric(relativeTo: .title) private var baseDiameter: CGFloat = 96
    @ScaledMetric(relativeTo: .title) private var bigDiameter: CGFloat = 118

    private var diameter: CGFloat {
        (big ? bigDiameter : baseDiameter) * display.drivingScale
    }

    /// VoiceOver tek cümle duysun. Ham hâlinde "49", "→", "44" diye üç ayrı
    /// parça okunuyordu — bağlamsız ve anlamsız.
    private var voiceLabel: String {
        var s = "Hız \(speed) kilometre"
        if let t = target { s += ". Viraj için tavsiye \(t)" }
        return s
    }

    var body: some View {
        ZStack {
            Circle().fill(.clear).adaptiveGlass(in: .circle)
            Circle().stroke(color.gradient, lineWidth: big ? 9 : 5)
            VStack(spacing: 0) {
                Text("\(speed)")
                    .drivingNumber(size: big ? 40 : 30, relativeTo: .largeTitle)
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                if let t = target {
                    Text("→ \(t)")
                        .font(.caption2.bold())
                        .foregroundStyle(display.secondaryText)
                } else {
                    Text("km/s").font(.caption2).foregroundStyle(display.secondaryText)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.snappy(duration: 0.3), value: big)
        .animation(.easeInOut(duration: 0.3), value: color)
        .animation(.easeInOut(duration: 0.2), value: speed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceLabel)
    }
}

/// Viraj uyarı şeridi — mesafe geri sayımı ve hedef hız.
struct CurveWarningStrip: View {
    let alert: CurveTracker.Alert
    /// Yalnızca "yol tutuşu sınırına ne kadar yakınız" sorusu için.
    let currentSpeed: Double

    @ObservedObject private var display = DisplayPreferences.shared

    /// Sınır AŞILDI — model bu hızda yol tutuşunun bittiğini söylüyor.
    private var beyondLimit: Bool {
        currentSpeed >= alert.curve.limitSpeedKmh && alert.curve.limitSpeedKmh > 0
    }

    /// Sınıra YAKLAŞILDI ama henüz aşılmadı.
    ///
    /// `.critical` seviyesi tek başına bunu göstermez — kuru asfaltta kritik
    /// uyarı, yol tutuşunun bittiği hızın %74'ünde bile gelebilir. Sınırı
    /// orada göstermek onu bir HEDEFE dönüştürürdü ("demek 82'ye kadar var").
    private var nearGripLimit: Bool {
        !beyondLimit && alert.level == .critical
            && currentSpeed >= alert.curve.limitSpeedKmh * 0.85
    }

    private var distanceText: String {
        alert.distance >= 1000
            ? String(format: "%.1f km", alert.distance / 1000)
            : "\(Int(alert.distance / 10) * 10) m"
    }

    private var tint: Color {
        if beyondLimit { return GaugeColor.beyondLimit.color }
        switch alert.level {
        case .critical: return .red
        case .prepare:  return .orange
        case .headsUp:  return .yellow
        case .none:     return .secondary
        }
    }

    private var actionText: String {
        if beyondLimit { return "FRENE BAS" }
        switch alert.level {
        case .critical: return "YAVAŞLA"
        case .prepare:  return "Hızını düşür"
        case .headsUp:  return "Viraj yaklaşıyor"
        case .none:     return ""
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.curve.direction.icon)
                .drivingNumber(size: 26, weight: .black, design: .default, relativeTo: .title2)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(actionText)
                    .font(.headline)
                    .foregroundStyle(tint)
                if beyondLimit {
                    // Sınırın ÜSTÜ risk dili almaz — "riskli/tehlikeli" hâlâ
                    // pazarlık payı varmış hissi verir. Burada söylenen şey
                    // bir olasılık değil, modelin en iyi tahminine göre olmuş
                    // bir durumdur.
                    Label("SINIR AŞILDI · tutuş ~\(Int(alert.curve.limitSpeedKmh))'te biter",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(GaugeColor.beyondLimit.color)
                } else if nearGripLimit {
                    // Sınır TAHMİNDİR ve "~" ile öyle sunulur. Kesin bir sayı
                    // gibi göstermek, ölçemediğimiz iki şeye (gerçek apeks
                    // yarıçapı ve zeminin o günkü tutuşu) kesinlik atfetmek olur.
                    Label("yol tutuşu ~\(Int(alert.curve.limitSpeedKmh)) km/s'te biter",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                } else {
                    Text("\(alert.curve.severity.rawValue) \(alert.curve.direction.rawValue) viraj")
                        .font(.caption)
                        .foregroundStyle(display.secondaryText)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text(distanceText)
                    .drivingNumber(size: 22, relativeTo: .title2)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text("\(Int(alert.curve.safeSpeedKmh)) km/s")
                    .font(.caption.bold())
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // Yüksek kontrastta %12 opaklık güneş altında görünmüyordu.
        .background(tint.opacity(display.highContrast ? 0.28 : 0.12), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .stroke(tint.opacity(display.highContrast ? 0.9 : 0.45), lineWidth: 1.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(actionText). \(distanceText) sonra \(alert.curve.severity.rawValue) \(alert.curve.direction.rawValue) viraj, tavsiye edilen hız \(Int(alert.curve.safeSpeedKmh)) kilometre."
            + (beyondLimit ? " Sınır aşıldı. Yol tutuşu yaklaşık \(Int(alert.curve.limitSpeedKmh)) kilometrede biter."
               : nearGripLimit ? " Yol tutuşu yaklaşık \(Int(alert.curve.limitSpeedKmh)) kilometrede biter." : ""))
    }
}

// ============================================================================
// MARK: - Yol Önizleme Şeridi
// ============================================================================
//
// NEDEN VAR
// ---------
// Sesli uyarı ve gösterge rengi tek bir viraja odaklanır: en yakındakine. Ama
// sürücünün ritmi tek virajla kurulmaz. "Keskin sağ, hemen ardından uzun sol"
// bilgisi, o iki virajı ayrı ayrı duymaktan bambaşka bir şeydir — ralli seyir
// notlarının varlık sebebi tam olarak budur. Virajı ÖNCEDEN bilmek isteyen
// sürücü (uygulamanın bütün iddiası bu) sıradakini de görmek ister.
//
// Veri zaten hesaplanıyordu — `CurveTracker.upcoming` sonraki üç virajı
// döndürüyor ve `DriveViewModel.upcomingCurves`in yorumunda "yol önizleme
// şeridi için" yazıyordu — ama şerit hiç yapılmamıştı; sonuç yalnızca haritaya
// nokta koymak için kullanılıyordu.
//
// GÖSTERİM
// --------
// Her viraj: yön oku + ralli derecesi (1 en dar, 6 neredeyse düz) + mesafe +
// tavsiye hız. Derece yarıçaptan değil TAVSİYE HIZINDAN türetilir
// (bkz. `Curve.grade`), yani sürücü için doğrudan anlamlıdır.
//
// EN YAKIN OLAN VURGULU: ilk kart büyük ve dolgun, sonrakiler küçük ve soluk.
// Göz sıralamayı çözmek zorunda kalmasın; en acil olan kendini göstersin.
//
// KAPATILABİLİR: Ayarlar > Görünürlük > "Sonraki virajlar şeridi". Ekranı
// kalabalık bulan sürücü kapatır — sesli uyarı, gösterge rengi ve çevresel
// aura bundan etkilenmez, yani hiçbir uyarı susmaz.
// ============================================================================

struct CurvePreviewStrip: View {
    let items: [(curve: Curve, distance: Double)]

    @ObservedObject private var display = DisplayPreferences.shared

    private func distanceText(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f km", m / 1000) : "\(Int(m / 10) * 10) m"
    }

    /// VoiceOver için tek cümle. Kart kart okunması anlamsız olurdu.
    private var voiceLabel: String {
        let parts = items.prefix(3).map { item in
            "\(distanceText(item.distance)) sonra \(item.curve.gradeLabel), \(Int(item.curve.safeSpeedKmh)) kilometre"
        }
        return "Sonraki virajlar: " + parts.joined(separator: ". ")
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.curve.id) { i, item in
                card(item.curve, distance: item.distance, emphasis: i == 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceLabel)
    }

    private func card(_ c: Curve, distance: Double, emphasis: Bool) -> some View {
        let tint = c.severity.uiColor
        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: c.direction.icon)
                    .drivingNumber(size: emphasis ? 22 : 16, weight: .black,
                                   design: .default, relativeTo: .title3)
                Text("\(c.grade)")
                    .drivingNumber(size: emphasis ? 22 : 16, relativeTo: .title3)
                    .monospacedDigit()
            }
            .foregroundStyle(tint)

            Text(distanceText(distance))
                .scaledFont(size: emphasis ? 15 : 13, weight: .bold,
                            design: .rounded, relativeTo: .footnote)
                .monospacedDigit()

            Text("\(Int(c.safeSpeedKmh)) km/s")
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .foregroundStyle(display.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, emphasis ? 8 : 6)
        // Vurgulu kart dolgun zeminli; diğerleri yalnızca çerçeveli. Böylece
        // sıralama renkten değil AĞIRLIKTAN okunur — renk körlüğünde de çalışır.
        .background(tint.opacity(emphasis ? (display.highContrast ? 0.32 : 0.18)
                                          : (display.highContrast ? 0.14 : 0.07)),
                    in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(tint.opacity(emphasis ? 0.8 : 0.3), lineWidth: emphasis ? 1.5 : 1))
        .opacity(emphasis ? 1 : 0.85)
    }
}

// ============================================================================
// MARK: - Hava Çipi
// ============================================================================
//
// Derece + hava ikonu + (kuru değilse) zemin. Sürücünün "uygulama neden bu hızı
// söylüyor" sorusuna tek bakışta cevap veren yer burası: 28 km/s tavsiyesi tek
// başına saçma görünür, "Kar yağışlı · Karlı" yanındayken açıklanmış olur.
//
// Zemin KURU iken kasten sessiz kalır (yalnızca derece + ikon). Kuru zaten
// varsayılan hâldir; her açık havada "Kuru" yazmak, bilgi taşımayan bir etiketi
// sürekli ekranda tutmak olurdu. Etiket ancak bir şey DEĞİŞTİĞİNDE belirir.
//
// Veri yoksa (WeatherKit yetkisi kapalı, internet yok, ilk saniyeler) çip hiç
// görünmez — boş bir kutu veya "—" göstermek yerine yer kaplamaz.
// ============================================================================

struct WeatherChip: View {
    @ObservedObject var vm: DriveViewModel
    @ObservedObject private var weather = RoadWeatherService.shared
    @ObservedObject private var display = DisplayPreferences.shared

    var body: some View {
        if let s = weather.snapshot {
            Menu {
                Section("Zemin") {
                    Button {
                        vm.useAutomaticRoadCondition()
                    } label: {
                        Label(vm.roadConditionIsManual
                              ? "Otomatik — hava durumundan"
                              : "✓ Otomatik — \(vm.roadCondition.rawValue)",
                              systemImage: "cloud.sun.fill")
                    }
                    ForEach(RoadCondition.allCases, id: \.self) { c in
                        Button {
                            vm.setManualRoadCondition(c)
                        } label: {
                            Label(vm.roadConditionIsManual && vm.roadCondition == c
                                  ? "✓ \(c.rawValue)" : c.rawValue,
                                  systemImage: c.icon)
                        }
                    }
                }
                // Apple, WeatherKit kullanan uygulamalardan atıf ve yasal
                // bağlantı göstermelerini ŞART koşuyor.
                if let url = weather.attributionURL {
                    Section {
                        Link(" Weather", destination: url)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: s.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .font(.footnote)
                    Text(s.temperatureText)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()

                    if vm.roadCondition != .dry {
                        Text("·").foregroundStyle(display.tertiaryText)
                        Label(vm.roadCondition.rawValue, systemImage: vm.roadCondition.icon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    // Elle seçildiyse söyle — sürücü otomatik sandığı bir
                    // değerle yola çıkmasın.
                    if vm.roadConditionIsManual {
                        Image(systemName: "hand.tap.fill")
                            .font(.caption2)
                            .foregroundStyle(display.secondaryText)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .adaptiveGlass(in: .capsule)
            .accessibilityLabel(
                "Hava \(s.temperatureText), \(s.summary). Zemin \(vm.roadCondition.rawValue)"
                + (vm.roadConditionIsManual ? ", elle seçildi" : ", otomatik"))
            .accessibilityHint("Zemini elle değiştirmek için dokun")
            .transition(.opacity)
        }
    }
}

/// Anlık ivme göstergesi.
struct GForceReadout: View {
    let longitudinal: Double
    let lateral: Double

    private func bar(_ value: Double, symbol: String) -> some View {
        let magnitude = min(abs(value) / 0.45, 1)
        let color: Color = abs(value) > 0.30 ? .red : (abs(value) > 0.18 ? .orange : .green)
        return HStack(spacing: 4) {
            Image(systemName: symbol).scaledFont(size: 11, relativeTo: .caption2)
            Capsule()
                .fill(color)
                .frame(width: 4 + 26 * magnitude, height: 4)
            Text(String(format: "%.2fg", abs(value)))
                .scaledFont(size: 11, weight: .medium, design: .monospaced, relativeTo: .caption2)
        }
        .foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            bar(longitudinal, symbol: longitudinal < 0 ? "arrow.down" : "arrow.up")
            bar(lateral, symbol: "arrow.left.and.right")
        }
    }
}

/// Rota özet satırı: ücret + yakıt + viraj.
struct RouteFactsRow: View {
    let option: RouteOption

    @ObservedObject private var display = DisplayPreferences.shared

    var body: some View {
        HStack(spacing: 0) {
            fact(icon: "turkishlirasign.circle.fill",
                 tint: option.toll.hasAny ? .yellow : .green,
                 value: option.toll.hasAny ? "\(Int(option.toll.total)) ₺" : "Gişesiz",
                 label: "geçiş")

            Divider().frame(height: 30)

            if let f = option.fuel {
                fact(icon: "fuelpump.fill", tint: .orange,
                     value: "\(Int(f.costTL)) ₺",
                     label: String(format: "%.1f %@", f.amount, f.unit))
            } else {
                fact(icon: "fuelpump", tint: .secondary, value: "—", label: "araç ekle")
            }

            Divider().frame(height: 30)

            fact(icon: "arrow.triangle.turn.up.right.diamond.fill",
                 tint: option.sharpCurveCount > 0 ? .orange : .green,
                 value: "\(option.sharpCurveCount)",
                 label: "keskin viraj")

            if let t = option.tightestSafeSpeed {
                Divider().frame(height: 30)
                fact(icon: "gauge.with.dots.needle.33percent",
                     tint: t < 50 ? .red : (t < 70 ? .orange : .green),
                     value: "\(Int(t))",
                     label: "en yavaş")
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    }

    private func fact(icon: String, tint: Color, value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(value).font(.subheadline.bold()).monospacedDigit()
            Text(label).scaledFont(size: 11, relativeTo: .caption2)
                .foregroundStyle(display.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
