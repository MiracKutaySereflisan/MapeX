// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import SwiftUI
import MapKit
import CoreLocation
import Combine

enum DrivePhase: Equatable { case idle, searching, routeReady, driving, finished }

// ============================================================================
// MARK: - Sürüş Beyni
// ============================================================================
//
// Bu sınıf, konum akışını alıp dört alt sisteme dağıtır ve çıktılarını arayüze
// tek bir tutarlı durum olarak sunar:
//
//     LocationManager ──▶ DriveViewModel ──┬──▶ TurnTracker    (sapak, ETA, sapma)
//                                          ├──▶ CurveTracker   (viraj uyarısı)
//                                          ├──▶ DrivingMonitor (sert olaylar)
//                                          └──▶ NavigationCamera (akıcı takip)
//
// ROTA ANALİZİ ARKA PLANDA
// ------------------------
// Viraj çıkarımı 500 km'lik dört alternatif için ~200 bin nokta işler. Bu iş
// ana iş parçacığında yapılırsa arayüz 1–2 saniye donar. `RouteRanker.analyze`
// bu yüzden `nonisolated` ve `Task.detached` içinde çağrılır; sonuç ana aktöre
// geri döner.
// ============================================================================

@MainActor
final class DriveViewModel: ObservableObject {

    // MARK: Durum

    @Published var phase: DrivePhase = .idle
    @Published var query = ""
    @Published var results: [MKMapItem] = []
    @Published var isAnalyzing = false

    @Published var routeOptions: [RouteOption] = []
    @Published var selectedOptionID: UUID?
    @Published var destination: MKMapItem?

    @Published var guidance: TurnTracker.Guidance?
    @Published var curveAlert: CurveTracker.Alert?
    @Published var gaugeColor: GaugeColor = .green
    @Published var risk: SpeedModel.RiskStatus = .neutral
    @Published var isRerouting = false

    @Published var trip = TripResult()
    @Published var badges: [Badge] = []
    @Published var tripHistory: [TripResult] = []

    /// Kullanıcı ayarları
    @Published var drivingMode: DrivingMode = UserDefaults.standard.string(forKey: "drivingMode")
        .flatMap(DrivingMode.init(rawValue:)) ?? .normal {
        didSet {
            UserDefaults.standard.set(drivingMode.rawValue, forKey: "drivingMode")
            reanalyzeIfNeeded()
        }
    }

    @Published var roadCondition: RoadCondition = UserDefaults.standard.string(forKey: "roadCondition")
        .flatMap(RoadCondition.init(rawValue:)) ?? .dry {
        didSet {
            UserDefaults.standard.set(roadCondition.rawValue, forKey: "roadCondition")
            reanalyzeIfNeeded()
        }
    }

    /// Zemin elle mi seçildi, yoksa hava durumundan mı geliyor?
    ///
    /// Varsayılan OTOMATİK. Kullanıcının seçmesini beklemek iki sessiz hataya
    /// yol açıyordu: yağmur başlayınca seçmeyi unutmak (model iyimserleşir) ve
    /// kışın seçip yazın geri almamak (model sürekli fazla temkinli olur,
    /// uyarılar anlamsızlaşır). Bkz. `RoadWeatherService`.
    @Published var roadConditionIsManual: Bool = UserDefaults.standard.bool(forKey: "roadConditionIsManual") {
        didSet {
            UserDefaults.standard.set(roadConditionIsManual, forKey: "roadConditionIsManual")
            if !roadConditionIsManual { applyWeatherCondition() }
        }
    }

    @Published var avoidTolls = UserDefaults.standard.bool(forKey: "avoidTolls") {
        didSet { UserDefaults.standard.set(avoidTolls, forKey: "avoidTolls") }
    }

    // MARK: Alt sistemler

    let camera = NavigationCamera()
    let motion = DrivingMonitor()
    private let turnTracker = TurnTracker()
    private let curveTracker = CurveTracker()

    /// Kamera modunun aynası.
    ///
    /// Kamera 60 Hz'de `position` yayınlıyor. Ana ekranın tamamı kameraya
    /// abone olsaydı saniyede 60 kez YENİDEN ÇİZİLİRDİ — panel, düğmeler,
    /// listeler dahil. Bu yüzden `position`a yalnızca harita alt görünümü
    /// abone; ana ekranın ihtiyacı olan tek bilgi ("takipte miyiz") buraya
    /// aynalanır ve saniyede en fazla birkaç kez değişir.
    @Published private(set) var cameraFollowing = true
    private var cancellables = Set<AnyCancellable>()

    private var tripStartTime: Date?
    private var lastCurveSpoken: UUID?
    /// Sınır aşımı anonsu bu viraj için yapıldı mı?
    ///
    /// AYRI TAKİP GEREKİYOR: `announceCurve` yalnızca `alert.isNew` iken, yani
    /// UYARI SEVİYESİ yükseldiğinde çağrılır. Ama seviye fren mesafesinden
    /// türer, hızdan değil — sürücü kritik seviyeye ulaştıktan SONRA gaza
    /// basıp sınırı aşarsa seviye değişmez, `isNew` false kalır ve en kritik
    /// an sessiz geçerdi.
    private var limitExceededSpoken: UUID?
    private var rawStartLocation: CLLocation?

    // MARK: Türetilmiş

    var selectedOption: RouteOption? {
        routeOptions.first { $0.id == selectedOptionID }
    }
    var route: MKRoute? { selectedOption?.route }
    var curves: [Curve] { selectedOption?.curves ?? [] }

    /// TEK ÖRNEK — telefon arayüzü ve CarPlay aynı beyni paylaşır.
    ///
    /// Eskiden `ContentView` kendi örneğini `@StateObject` olarak yaratıyordu.
    /// İki sorun vardı:
    ///
    ///   • CarPlay AYRI BİR SAHNE. O örneğe erişemez; kendi kopyasını yaratsa
    ///     iki ayrı rota, iki ayrı viraj takibi, iki ayrı yolculuk kaydı olurdu.
    ///   • Konum akışı `ContentView`in `.onChange`inden geçiyordu. Yani sürüş
    ///     beyni, telefon arayüzünün ekranda olmasına bağlıydı.
    ///
    /// Artık konum doğrudan modele akar; arayüzler yalnızca okur.
    static let shared = DriveViewModel()

    private init() {
        loadTripHistory()
        camera.$mode
            .map { $0 == .following }
            .removeDuplicates()
            .assign(to: &$cameraFollowing)

        // Konum akışı → sürüş beyni. Hangi ekranın açık olduğundan bağımsız.
        LocationManager.shared.$location
            .compactMap { $0 }
            .sink { loc in
                Task { @MainActor in
                    let lm = LocationManager.shared
                    DriveViewModel.shared.onLocationUpdate(loc, speedKmh: lm.speedKmh,
                                                           course: lm.course, location: lm)
                    // Yakıt fiyatı bölgeye bağlı; servis kendi içinde 12 saatte
                    // bir ve bölge değiştiğinde sorgular, her fix'te ağa çıkmaz.
                    await FuelPriceService.shared.updateIfNeeded(for: loc)
                    // Hava da aynı mantıkla: 20 dakikada bir veya 25 km sonra.
                    await RoadWeatherService.shared.updateIfNeeded(for: loc)
                    DriveViewModel.shared.applyWeatherCondition()
                }
            }
            .store(in: &cancellables)
    }

    // ========================================================================
    // MARK: - Arama & Rota
    // ========================================================================

    func search(near center: CLLocationCoordinate2D?) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        phase = .searching
        results = await RouteEngine.searchPlaces(q, near: center)
        if results.isEmpty { phase = .idle }
    }

    /// Hedef seç → tüm alternatifleri getir ve arka planda analiz et.
    func selectDestination(_ item: MKMapItem, from userLoc: CLLocationCoordinate2D) async {
        destination = item
        results = []
        isAnalyzing = true
        defer { isAnalyzing = false }

        let routes = await RouteEngine.allRoutes(from: userLoc, to: item.location.coordinate)
        guard !routes.isEmpty else {
            SpeechManager.shared.speak("Rota bulunamadı.")
            phase = .idle
            return
        }
        await analyze(routes)
        phase = .routeReady
    }

    /// Kayıtlı favoriden rota.
    func loadRoute(to coordinate: CLLocationCoordinate2D, from userLoc: CLLocationCoordinate2D) async {
        destination = RouteEngine.mapItem(for: coordinate)
        isAnalyzing = true
        defer { isAnalyzing = false }
        let routes = await RouteEngine.allRoutes(from: userLoc, to: coordinate)
        guard !routes.isEmpty else { return }
        await analyze(routes)
        phase = .routeReady
    }

    /// Ağır analiz — arka plan iş parçacığında.
    private func analyze(_ routes: [MKRoute]) async {
        let condition = roadCondition
        let mode = drivingMode
        let vehicle = VehicleManager.shared.hasVehicle ? VehicleManager.shared.profile : nil
        let vClass = TollTariffStore.shared.vehicleClass
        let stability = VehicleManager.shared.stability.speedFactor
        // Devrilme sınırı için ham SSF — `speedFactor` 0.80–1.05'e kırpılmış
        // bir tavsiye çarpanıdır, fiziksel eşik olarak kullanılamaz.
        let ssf = VehicleManager.shared.stability.ssf
        let fuelPrice = FuelPriceService.shared.currentPrice(for: VehicleManager.shared.profile.fuelType)
        let fuelSource = FuelPriceService.shared.currentPriceSource(for: VehicleManager.shared.profile.fuelType)
        let tariff = TollTariffStore.shared.tariff
        let learned = TollLearningStore.shared.learnedRates
        let known = Dictionary(uniqueKeysWithValues:
            TollLearningStore.shared.corrections.map { ($0.fingerprint, $0.actualAmount) })

        let analyzed = await Task.detached(priority: .userInitiated) {
            RouteRanker.analyze(routes, condition: condition, mode: mode,
                                vehicle: vehicle, vehicleClass: vClass,
                                stabilityFactor: stability, ssf: ssf,
                                fuelPrice: fuelPrice, fuelPriceSource: fuelSource,
                                tariff: tariff,
                                learnedRates: learned, knownAmounts: known)
        }.value

        routeOptions = analyzed
        if selectedOptionID == nil || !analyzed.contains(where: { $0.id == selectedOptionID }) {
            selectedOptionID = analyzed.first?.id
        }
        measureTraffic()
        detectCountries()
    }

    // ========================================================================
    // MARK: Yurt dışı kesimleri
    // ========================================================================
    //
    // Rota Türkiye dışına çıkıyorsa KGM tarifesini uygulamak yanlış olur.
    // Her ülkenin ücret MODELİ farklıdır: Almanya'da otomobil ücretsizdir,
    // Avusturya/İsviçre'de mesafeden bağımsız vinyet zorunludur, Yunanistan ve
    // İtalya'da gişe vardır. Bunları birbirine karıştırmak, rakamı tamamen
    // anlamsız kılar.
    private func detectCountries() {
        let snapshot = routeOptions
        guard !snapshot.isEmpty else { return }
        Task {
            for opt in snapshot {
                let codes = await RouteCountries.detect(profile: opt.profile)
                // Yalnızca Türkiye ise ek bir şey yapmaya gerek yok
                let foreign = codes.filter { $0 != "TR" }
                guard !foreign.isEmpty else { continue }

                var notes: [TollEstimator.Estimate.CountryNote] = []
                for code in Set(foreign) {
                    guard let rule = CountryTollRule.rule(for: code) else { continue }
                    switch rule.model {
                    case .freeForCars:
                        notes.append(.init(country: rule.name, model: "Ücretsiz",
                                           amount: 0, note: rule.note))
                    case .vignette:
                        notes.append(.init(country: rule.name, model: "Vinyet",
                                           amount: rule.vignetteApproxTL ?? 0, note: rule.note))
                    case .distanceBased:
                        notes.append(.init(country: rule.name, model: "Gişe bazlı",
                                           amount: 0,
                                           note: rule.note + " Tutar hesaplanamıyor; sınır ötesi tarife verisi yok."))
                    }
                }

                if let i = routeOptions.firstIndex(where: { $0.id == opt.id }) {
                    routeOptions[i].toll.countryNotes = notes
                }
            }
        }
    }

    /// Trafik gecikmesini arka planda ölç — rota gösterimini bekletmez.
    private func measureTraffic() {
        guard let from = routeOptions.first?.route.polyline.points()[0].coordinate,
              let dest = destination?.location.coordinate else { return }
        let snapshot = routeOptions
        Task {
            for opt in snapshot {
                guard let delay = await RouteEngine.trafficDelay(for: opt.route, from: from, to: dest)
                else { continue }
                if let i = routeOptions.firstIndex(where: { $0.id == opt.id }) {
                    routeOptions[i].trafficDelay = delay
                }
            }
        }
    }

    // MARK: Rota gezinme

    /// Alt paneli yukarı/aşağı kaydırınca sıradaki/önceki rotaya geç.
    func cycleRoute(forward: Bool) {
        guard routeOptions.count > 1,
              let current = routeOptions.firstIndex(where: { $0.id == selectedOptionID })
        else { return }
        let next = forward
            ? (current + 1) % routeOptions.count
            : (current - 1 + routeOptions.count) % routeOptions.count
        selectedOptionID = routeOptions[next].id
    }

    var selectedIndex: Int {
        routeOptions.firstIndex { $0.id == selectedOptionID } ?? 0
    }

    // ========================================================================
    // MARK: Zemin — otomatik / elle
    // ========================================================================

    /// Hava servisinden gelen zemini uygula.
    ///
    /// Bayat veriyle (2 saatten eski) zemin DEĞİŞTİRİLMEZ: eski bir gözlemle
    /// "artık kuru" demek, kullanıcının o an gördüğü kardan daha az güvenilir
    /// bir kaynağa güvenmek olurdu.
    func applyWeatherCondition() {
        guard !roadConditionIsManual,
              let s = RoadWeatherService.shared.snapshot,
              !s.isStale,
              s.roadCondition != roadCondition
        else { return }

        roadCondition = s.roadCondition   // didSet → kaydet + yeniden analiz

        // Sürüş sırasında zemin değişirse sürücü bunu BİLMELİ: hız tavsiyeleri
        // az önce sessizce değişti, sebebini duymadan fark etmesi zor.
        if phase == .driving {
            SpeechManager.shared.speak(
                "Hava değişti. \(s.roadCondition.rawValue) zemine göre hız önerileri güncellendi.")
        }
    }

    /// Kullanıcı zemini elle seçti.
    func setManualRoadCondition(_ condition: RoadCondition) {
        roadConditionIsManual = true
        roadCondition = condition
    }

    /// Otomatiğe dön.
    func useAutomaticRoadCondition() {
        roadConditionIsManual = false   // didSet → applyWeatherCondition()
    }

    /// Mod veya zemin değişince viraj hızları yeniden hesaplanır
    /// (aynı yarıçap, farklı tavsiye hız).
    private func reanalyzeIfNeeded() {
        switch phase {
        case .routeReady where !routeOptions.isEmpty:
            let routes = routeOptions.map(\.route)
            Task { await analyze(routes) }
        case .driving:
            recomputeCurvesInPlace()
        default:
            break
        }
    }

    /// Sürüş SIRASINDA zemin/mod değişimi — virajları yerinde günceller.
    ///
    /// DÜZELTİLEN HATA: `reanalyzeIfNeeded` yalnızca `.routeReady` fazında
    /// çalışıyordu. Hava sürüş sırasında değiştiğinde uygulama
    /// "hız önerileri güncellendi" diye anons ediyor ama virajların
    /// `safeSpeedKmh` / `limitSpeedKmh` değerleri rota kurulurkenki zemine göre
    /// KALIYORDU — yani söylediğini yapmıyordu. Üstelik hava en çok sürüş
    /// sırasında değişir; otomatik zemin tespitinin asıl işe yarayacağı an
    /// tam da buydu.
    ///
    /// Rota DEĞİŞMEZ, yalnızca virajlar yeniden hesaplanır: `turnTracker`a
    /// dokunulmaz, sapak takibi ve kalan mesafe bozulmaz.
    private func recomputeCurvesInPlace() {
        guard let option = selectedOption else { return }
        let condition = roadCondition
        let mode = drivingMode
        let stability = VehicleManager.shared.stability.speedFactor
        let ssf = VehicleManager.shared.stability.ssf
        let profile = option.profile
        let route = option.route
        let optionID = option.id

        Task {
            let fresh = await Task.detached(priority: .userInitiated) {
                CurveGeometry.removeManeuverCurves(
                    CurveGeometry.curves(from: profile, condition: condition, mode: mode,
                                         stabilityFactor: stability, ssf: ssf),
                    route: route)
            }.value

            // Hesap sürerken sürüş bitmiş veya rota değişmiş olabilir.
            guard phase == .driving,
                  let i = routeOptions.firstIndex(where: { $0.id == optionID })
            else { return }

            // Geçmiş viraj renklerini KAYBETME — yolculuk skoru sıfırlanmamalı.
            trip.curveColors.append(contentsOf: curveTracker.recordedColors)

            routeOptions[i].curves = fresh
            routeOptions[i].curviness = CurveGeometry.curvinessIndex(
                curves: fresh, routeLengthMeters: route.distance)

            curveTracker.reset(curves: fresh)
            // Yeni viraj kimlikleri üretildi; eski anons kayıtları geçersiz.
            lastCurveSpoken = nil
            limitExceededSpoken = nil
        }
    }

    func select(option: RouteOption) {
        selectedOptionID = option.id
    }

    // ========================================================================
    // MARK: - Sürüş
    // ========================================================================

    func startDriving(from loc: CLLocation?, location: LocationManager) {
        guard let option = selectedOption else { return }

        trip = TripResult(drivingMode: drivingMode, roadCondition: roadCondition)
        trip.distance = option.route.distance
        trip.tollPaid = option.toll.total
        tripStartTime = Date()
        rawStartLocation = loc
        lastCurveSpoken = nil
        limitExceededSpoken = nil
        curveAlert = nil
        guidance = nil

        turnTracker.reset(with: option.route, profile: option.profile)
        curveTracker.reset(curves: option.curves)
        motion.start()

        location.beginNavigationSession()
        AudioSessionManager.shared.configure()

        phase = .driving
        camera.startFollowing()
        if let loc { camera.ingest(location: loc, course: location.course) }

        SpeechManager.shared.speak(startAnnouncement(option))

        LiveActivityManager.shared.start(
            destinationName: destination?.name ?? "Hedef",
            initial: .init(speedKmh: 0, suggestedSpeed: nil, speedLevel: 0,
                           remainingMinutes: option.minutes,
                           distanceToTurn: 0, turnAngle: 0,
                           instruction: "Yola çıkılıyor…",
                           curveDistance: nil, curveIsLeft: nil, curveWarning: 0,
                           curveGrade: nil, riskLevel: 0))

        if let loc {
            Task { trip.startSemt = await RouteEngine.semt(of: loc) }
        }
    }

    /// Açılış anonsu — rotanın ne getireceğini önden söyler.
    private func startAnnouncement(_ option: RouteOption) -> String {
        var parts = ["Yolculuk başladı.", "\(option.durationText), \(option.distanceText)."]
        if let tightest = option.tightestSafeSpeed, tightest < 70 {
            parts.append("Rotada en keskin viraj \(Int(tightest)) kilometre hız istiyor.")
        }
        if option.toll.hasAny {
            parts.append("Tahmini geçiş ücreti \(Int(option.toll.total)) lira.")
        }
        if roadCondition != .dry {
            parts.append("\(roadCondition.rawValue) zemin için hız önerileri düşürüldü.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Konum döngüsü

    func onLocationUpdate(_ loc: CLLocation, speedKmh: Double, course: Double, location: LocationManager) {
        camera.ingest(location: loc, course: course)
        guard phase == .driving, let option = selectedOption else { return }

        motion.ingest(location: loc, speedKmh: speedKmh)

        // ── Varış ────────────────────────────────────────────────────────────
        if let dest = destination, loc.distance(from: dest.location) < 60 {
            finish(at: loc, location: location)
            return
        }

        // ── Sapak takibi ─────────────────────────────────────────────────────
        let g = turnTracker.update(location: loc, speedKmh: speedKmh, mode: drivingMode)
        guidance = g
        if let g, let announcement = g.announce {
            announceTurn(announcement, pan: g.turnPan)
        }

        // ── Viraj takibi ─────────────────────────────────────────────────────
        var alert: CurveTracker.Alert?
        if let travelled = turnTracker.alongTrack(for: loc) {
            alert = curveTracker.update(travelled: travelled, speedKmh: speedKmh,
                                        mode: drivingMode, condition: roadCondition)
        }
        curveAlert = alert

        if let a = alert {
            // Renk ve risk AYNI eşiklerden okur — ikisi de kaza sınırıyla
            // tavanlanmıştır, dolayısıyla kırmızı daima yoldan çıkmadan önce.
            let t = SpeedModel.thresholds(safeSpeedKmh: a.curve.safeSpeedKmh,
                                          limitSpeedKmh: a.curve.limitSpeedKmh,
                                          mode: drivingMode)
            gaugeColor = GaugeColor.from(speedKmh: speedKmh, thresholds: t)
            risk = SpeedModel.risk(speedKmh: speedKmh, thresholds: t)
            // Sınır aşımı uyarı seviyesinden BAĞIMSIZ tetiklenir (bkz.
            // `limitExceededSpoken`), yoksa en kritik an sessiz geçebilir.
            if risk == .exceeded { announceLimitExceeded(a.curve) }
            if a.isNew { announceCurve(a, speedKmh: speedKmh) }
        } else {
            gaugeColor = .green
            risk = .neutral
        }

        // ── Kamera çerçevesi ─────────────────────────────────────────────────
        let nearestEvent = [alert?.distance, g?.distanceToTurn].compactMap { $0 }.min()
        camera.updateFraming(distanceToEvent: nearestEvent, speedKmh: speedKmh)

        // ── Rotadan çıkış ────────────────────────────────────────────────────
        if turnTracker.isOffRoute(loc), !isRerouting, let dest = destination {
            performReroute(from: loc, to: dest)
        }

        // ── Dinamik Ada ──────────────────────────────────────────────────────
        updateLiveActivity(speedKmh: speedKmh, option: option, guidance: g, alert: alert)
    }

    // MARK: Anonslar

    private func announceTurn(_ a: TurnTracker.Announcement, pan: Float) {
        switch a {
        case .far(let text):
            SpeechManager.shared.speakDirectional(text, direction: pan, tone: .turn)
        case .near(let text):
            SpeechManager.shared.speakDirectional(text, direction: pan, tone: .turn)
        case .now(let text):
            ToneManager.shared.play(.turnNow, direction: pan)
            SpeechManager.shared.speak(text, interrupting: true)
        }
    }

    /// Viraj uyarısı — ses HER ZAMAN virajın yönünden gelir.
    ///
    /// Motif merkezde başlar, son notası sola/sağa kayar (bkz. ToneManager).
    /// Böylece sürücü kelimeyi işlemeden önce hangi tarafa döneceğini duyar.
    ///
    /// FREN FARKINDALIĞI
    /// -----------------
    /// Sürücü zaten belirgin biçimde yavaşlıyorsa (boyuna ivme < −1.5 m/s²,
    /// yani ≈ −0.15 g) uyarıyı tekrarlamak faydasızdır: mesajı almış ve gereğini
    /// yapıyordur. Üstüne bağırmak iki zarar verir — dikkati böler ve uyarıların
    /// güvenilirliğini aşındırır ("bu uygulama boşuna öter" algısı).
    ///
    /// Bu yüzden `.prepare` seviyesi, sürücü zaten frendeyse SESSİZ geçilir.
    /// `.critical` asla susturulmaz: orada yavaşlama YETERSİZ demektir, uyarı
    /// tam olarak o an gereklidir.
    private func announceCurve(_ a: CurveTracker.Alert, speedKmh: Double) {
        let c = a.curve
        let dir = c.direction.pan
        let hedef = Int(c.safeSpeedKmh)
        let alreadyBraking = motion.longitudinalG < -0.15
        /// Sınır aşıldı mı, yoksa yalnızca yaklaşıldı mı?
        ///
        /// `.critical` seviyesi tek başına ikisini de göstermez: kuru asfaltta
        /// kritik uyarı sınırın %74'ünde bile gelebilir. "Tutuş sınırındasın"
        /// cümlesini orada kurmak YALAN olur ve bir kez yalan söyleyen uyarı,
        /// gerçekten gerektiğinde inandırıcılığını kaybeder.
        let beyondLimit = c.limitSpeedKmh > 0 && speedKmh >= c.limitSpeedKmh
        let nearGripLimit = !beyondLimit && speedKmh >= c.limitSpeedKmh * 0.85

        switch a.level {
        case .headsUp:
            ToneManager.shared.play(.curveHeadsUp, direction: dir)
            guard lastCurveSpoken != c.id else { return }
            lastCurveSpoken = c.id
            let mesafe = formatMeters(a.distance)
            SpeechManager.shared.speak("\(mesafe) sonra \(c.gradeLabel), \(c.severity.rawValue.lowercased()) viraj. Tavsiye edilen hız \(hedef).")

        case .prepare:
            guard !alreadyBraking else { return }   // zaten yavaşlıyor, karışma
            ToneManager.shared.play(.curvePrepare, direction: dir)
            SpeechManager.shared.speak("Hızını \(hedef)'e düşür.")

        case .critical:
            // Fren yapıyor olsa bile susturulmaz — yeterli olmadığı için kritik.
            ToneManager.shared.play(.curveCritical, direction: dir)
            // SINIR SAYISI KASTEN SÖYLENMİYOR. Sesli verilen bir sayı hedefe
            // dönüşür — "demek 55'e kadar varmış" diye duyulur. Seste SONUÇ
            // söylenir, sayı ekranda bağlamıyla birlikte gösterilir.
            //
            // Üç ayrı cümle, çünkü üç ayrı durum: "yavaşla" (pay var),
            // "sınırdasın" (pay bitiyor), "frene bas" (pay bitti). Hepsine aynı
            // şeyi söylemek, en kötü durumu diğerlerinin arasında kaybederdi.
            //
            // Sınır aşıldıysa burada konuşulmaz: `announceLimitExceeded` zaten
            // söyledi. İki yerden birden söylemek üst üste binen konuşma olurdu.
            guard !beyondLimit else { return }
            let text = nearGripLimit
                ? "Yavaşla! Yol tutuşu sınırındasın. \(hedef)."
                : "Yavaşla. Viraj \(hedef)."
            SpeechManager.shared.speak(text, interrupting: true)

        case .none:
            break
        }
    }

    /// Yol tutuşu sınırı aşıldı — viraj başına bir kez.
    ///
    /// Tekrarlanmaz: sürücü sınırın üstünde birkaç saniye kalabilir ve her
    /// fix'te bağırmak, tam da direksiyon düzeltmesi gereken anda dikkatini
    /// böler. Görsel uyarı (mor aura, nabız) sınırın üstünde kaldığı sürece
    /// devam eder; ses bir kez söyler.
    private func announceLimitExceeded(_ c: Curve) {
        guard limitExceededSpoken != c.id else { return }
        limitExceededSpoken = c.id
        ToneManager.shared.play(.curveCritical, direction: c.direction.pan)
        SpeechManager.shared.speak("Frene bas! Yol tutuşu sınırını geçtin.", interrupting: true)
    }

    private func formatMeters(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f kilometre", m / 1000) : "\(Int(m / 50) * 50) metre"
    }

    // MARK: Yeniden rota

    private func performReroute(from loc: CLLocation, to dest: MKMapItem) {
        isRerouting = true
        ToneManager.shared.play(.reroute)
        SpeechManager.shared.speak("Rota yeniden hesaplanıyor.")

        Task {
            let condition = roadCondition
            let mode = drivingMode
            let vehicle = VehicleManager.shared.hasVehicle ? VehicleManager.shared.profile : nil
            let vClass = TollTariffStore.shared.vehicleClass
            let stability = VehicleManager.shared.stability.speedFactor
        // Devrilme sınırı için ham SSF — `speedFactor` 0.80–1.05'e kırpılmış
        // bir tavsiye çarpanıdır, fiziksel eşik olarak kullanılamaz.
        let ssf = VehicleManager.shared.stability.ssf
        let fuelPrice = FuelPriceService.shared.currentPrice(for: VehicleManager.shared.profile.fuelType)
        let fuelSource = FuelPriceService.shared.currentPriceSource(for: VehicleManager.shared.profile.fuelType)
            let tariff = TollTariffStore.shared.tariff
        let learned = TollLearningStore.shared.learnedRates
        let known = Dictionary(uniqueKeysWithValues:
            TollLearningStore.shared.corrections.map { ($0.fingerprint, $0.actualAmount) })

            guard let best = await RouteEngine.reroute(from: loc.coordinate,
                                                       to: dest.location.coordinate,
                                                       avoidTolls: avoidTolls) else {
                isRerouting = false
                return
            }

            let analyzed = await Task.detached(priority: .userInitiated) {
                RouteRanker.analyze([best], condition: condition, mode: mode,
                                    vehicle: vehicle, vehicleClass: vClass,
                                    stabilityFactor: stability, ssf: ssf,
                                fuelPrice: fuelPrice, fuelPriceSource: fuelSource,
                                tariff: tariff,
                                learnedRates: learned, knownAmounts: known)
            }.value

            guard let option = analyzed.first else { isRerouting = false; return }

            // Geçmiş viraj renklerini KAYBETME — yeni rota eskisinin devamı,
            // yolculuk skoru sıfırlanmamalı.
            let recorded = curveTracker.recordedColors
            trip.curveColors.append(contentsOf: recorded)

            routeOptions = [option]
            selectedOptionID = option.id
            turnTracker.reset(with: option.route, profile: option.profile)
            curveTracker.reset(curves: option.curves)
            lastCurveSpoken = nil
        limitExceededSpoken = nil
            isRerouting = false
        }
    }

    // MARK: Dinamik Ada

    private func updateLiveActivity(speedKmh: Double,
                                    option: RouteOption,
                                    guidance g: TurnTracker.Guidance?,
                                    alert: CurveTracker.Alert?) {
        guard let g else { return }
        LiveActivityManager.shared.update(.init(
            speedKmh: Int(speedKmh),
            suggestedSpeed: alert.map { Int($0.curve.safeSpeedKmh) },
            speedLevel: gaugeColor.level,
            remainingMinutes: max(0, Int(g.remainingTime / 60)),
            distanceToTurn: max(0, Int(g.distanceToTurn)),
            turnAngle: g.turnAngle,
            instruction: g.instruction,
            curveDistance: alert.map { Int($0.distance) },
            curveIsLeft: alert.map { $0.curve.direction == .left },
            curveWarning: alert?.level.rawValue ?? 0,
            curveGrade: alert.map(\.curve.grade),
            riskLevel: risk.rawValue))
    }

    // ========================================================================
    // MARK: - Bitiş
    // ========================================================================

    func finish(at loc: CLLocation, location: LocationManager) {
        guard phase == .driving else { return }
        phase = .finished

        trip.duration = Date().timeIntervalSince(tripStartTime ?? Date())
        trip.curveColors.append(contentsOf: curveTracker.recordedColors)
        trip.events = motion.events
        trip.smoothnessScore = motion.smoothnessScore
        if let fuel = selectedOption?.fuel { trip.fuelUsed = fuel.amount }

        motion.stop()
        camera.stop()
        location.endNavigationSession()

        ToneManager.shared.play(.arrive)
        LiveActivityManager.shared.end()
        SpeechManager.shared.speak("Yolculuk tamamlandı. Puanınız \(trip.score).")
        AudioSessionManager.shared.release(after: 4)

        Task {
            trip.endSemt = await RouteEngine.semt(of: loc)
            badges = BadgeStore.award(for: trip)
            saveTripHistory()
        }
    }

    func reset() {
        LiveActivityManager.shared.end()
        camera.stop()
        motion.stop()
        phase = .idle
        routeOptions = []
        selectedOptionID = nil
        destination = nil
        query = ""
        results = []
        badges = []
        guidance = nil
        curveAlert = nil
        gaugeColor = .green
        risk = .neutral
        lastCurveSpoken = nil
        limitExceededSpoken = nil
    }

    // MARK: Geçmiş

    private func saveTripHistory() {
        tripHistory.append(trip)
        // UserDefaults'ı şişirmemek için son 200 yolculuk tutulur.
        if tripHistory.count > 200 { tripHistory.removeFirst(tripHistory.count - 200) }
        if let data = try? JSONEncoder().encode(tripHistory) {
            UserDefaults.standard.set(data, forKey: "tripHistory")
        }
    }

    private func loadTripHistory() {
        if let data = UserDefaults.standard.data(forKey: "tripHistory"),
           let history = try? JSONDecoder().decode([TripResult].self, from: data) {
            tripHistory = history
        }
    }

    // MARK: Sürüş ekranı yardımcıları

    /// Sonraki virajlar — yol önizleme şeridi için.
    func upcomingCurves(for loc: CLLocation?) -> [(curve: Curve, distance: Double)] {
        guard let loc, let travelled = turnTracker.alongTrack(for: loc) else { return [] }
        return curveTracker.upcoming(from: travelled, count: 3)
    }
}
