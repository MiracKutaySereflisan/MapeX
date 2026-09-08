// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import SwiftUI
import MapKit
import CoreLocation

// MARK: - Canlı Arama Tahminleri
// MKLocalSearchCompleter: yazarken Apple'ın tahminleri gelir, uygulamayı kasmaz.
@MainActor
final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address, .query]
    }

    func update(query: String, around center: CLLocationCoordinate2D?) {
        if let c = center {
            completer.region = MKCoordinateRegion(center: c, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            suggestions = []
            completer.queryFragment = ""
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = Array(results.prefix(8)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }

    static func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let req = MKLocalSearch.Request(completion: completion)
        return (try? await MKLocalSearch(request: req).start())?.mapItems.first
    }
}

// ============================================================================
// MARK: - Rota Seçeneği
// ============================================================================
//
// Bir alternatifin kullanıcıya gösterilecek TÜM analizini taşır: süre, mesafe,
// viraj profili, ücret, yakıt ve türetilmiş "güvenlik/konfor" göstergesi.
// Ağır iş (viraj çıkarımı) arka planda yapılır; bu yapı sonucu taşır.
// ============================================================================

struct RouteOption: Identifiable {
    let id = UUID()
    let route: MKRoute
    let profile: CurveGeometry.Profile
    /// Zemin veya mod sürüş sırasında değişince yerinde güncellenir
    /// (bkz. `DriveViewModel.recomputeCurvesInPlace`), bu yüzden `var`.
    var curves: [Curve]
    var curviness: Double            // km başına viraj yükü
    var toll: TollEstimator.Estimate
    var fuel: FuelEstimate?
    var tags: [RouteTag] = []
    /// Haritadaki çizgi rengi — listedeki sırasına göre atanır.
    var colorIndex: Int = 0
    /// Trafiğin getirdiği ek süre (sn). Gece referansıyla karşılaştırmadan gelir.
    var trafficDelay: TimeInterval?

    var color: Color { RoutePalette.color(at: colorIndex) }

    /// Trafik yükü göstergesi.
    var trafficLevel: TrafficLevel {
        guard let d = trafficDelay, route.expectedTravelTime > 0 else { return .unknown }
        let ratio = d / route.expectedTravelTime
        switch ratio {
        case ..<0.05: return .free
        case ..<0.18: return .light
        case ..<0.40: return .heavy
        default:      return .jammed
        }
    }

    var trafficText: String? {
        guard let d = trafficDelay, d > 60 else { return nil }
        return "trafikten +\(Int(d / 60)) dk"
    }

    var minutes: Int { Int((route.expectedTravelTime / 60).rounded()) }
    var km: Double { route.distance / 1000 }
    var avgSpeedKmh: Int {
        guard route.expectedTravelTime > 0 else { return 0 }
        return Int(km / (route.expectedTravelTime / 3600))
    }

    /// En keskin virajın tavsiye hızı — "bu rotada en yavaş nereye ineceğim".
    var tightestSafeSpeed: Double? { curves.map(\.safeSpeedKmh).min() }

    var sharpCurveCount: Int {
        curves.filter { $0.severity == .sharp || $0.severity == .verySharp || $0.severity == .hairpin }.count
    }

    /// Toplam maliyet (yakıt + geçiş).
    var totalCostTL: Double { (fuel?.costTL ?? 0) + toll.total }

    var durationText: String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h) sa \(m) dk" : "\(m) dk"
    }

    var distanceText: String {
        km >= 10 ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
    }
}

// ============================================================================
// MARK: - Rota Renkleri
// ============================================================================
//
// Alternatifler haritada AYNI ANDA ve AYRI RENKLERDE çizilir; seçili olan kalın
// ve tam opak, diğerleri ince ve yarı saydam. Hepsini gri çizmek "hangisi
// nereden gidiyor" sorusunu cevapsız bırakıyordu — oysa kullanıcının rota
// seçerken bakmak istediği tam olarak bu.
//
// Palet, ardışık renkler birbirinden ton VE parlaklık olarak ayrılacak biçimde
// seçildi; kırmızı-yeşil ayrımına bağımlı değil, renk körlüğünde de çizgiler
// birbirinden ayırt edilebiliyor.
// ============================================================================

enum RoutePalette {
    static let colors: [Color] = [
        Color(red: 0.16, green: 0.50, blue: 0.98),   // mavi
        Color(red: 0.62, green: 0.25, blue: 0.90),   // mor
        Color(red: 0.00, green: 0.65, blue: 0.62),   // turkuaz
        Color(red: 0.95, green: 0.52, blue: 0.10),   // turuncu
        Color(red: 0.86, green: 0.22, blue: 0.52),   // fuşya
        Color(red: 0.30, green: 0.62, blue: 0.18),   // yeşil
        Color(red: 0.42, green: 0.36, blue: 0.78)    // indigo
    ]

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

enum RouteTag: String, Identifiable {
    case fastest      = "En hızlı"
    case shortest     = "En kısa"
    case calmest      = "En az virajlı"
    case cheapest     = "En ucuz"
    case noToll       = "Gişesiz"
    case scenic       = "Otoyolsuz"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fastest:  return "bolt.fill"
        case .shortest: return "arrow.left.and.right"
        case .calmest:  return "wind"
        case .cheapest: return "turkishlirasign.circle.fill"
        case .noToll:   return "checkmark.seal.fill"
        case .scenic:   return "leaf.fill"
        }
    }
}

// MARK: - Sıralama / etiketleme

enum RouteRanker {

    /// Rotaları analiz eder ve etiketler.
    ///
    /// Viraj çıkarımı CPU yoğundur (500 km'lik rota ≈ 50 bin nokta, dört
    /// alternatif = 200 bin nokta). Bu yüzden fonksiyon ana aktöre bağlı
    /// DEĞİLDİR ve arka planda çağrılmalıdır; tarife ile araç profili dışarıdan
    /// değer olarak geçirilir ki main actor'a dokunmak gerekmesin.
    nonisolated static func analyze(_ routes: [MKRoute],
                                    condition: RoadCondition,
                                    mode: DrivingMode,
                                    vehicle: VehicleProfile?,
                                    vehicleClass: TollVehicleClass,
                                    stabilityFactor: Double,
                                    ssf: Double,
                                    fuelPrice: Double?,
                                    fuelPriceSource: String?,
                                    tariff: TollTariff,
                                    learnedRates: [String: Double],
                                    knownAmounts: [String: Double]) -> [RouteOption] {
        guard !routes.isEmpty else { return [] }

        var options: [RouteOption] = routes.map { r in
            let prof = CurveGeometry.profile(of: r.polyline)
            // Kavşak dönüşleri viraj listesinden çıkarılır — sapak anonsu
            // zaten onları duyuruyor, ikinci kez uyarmak gürültü olur.
            let cs = CurveGeometry.removeManeuverCurves(
                CurveGeometry.curves(from: prof, condition: condition,
                                     mode: mode, stabilityFactor: stabilityFactor,
                                     ssf: ssf),
                route: r)
            return RouteOption(
                route: r,
                profile: prof,
                curves: cs,
                curviness: CurveGeometry.curvinessIndex(curves: cs, routeLengthMeters: r.distance),
                toll: TollEstimator.estimate(for: r, profile: prof,
                                             vehicleClass: vehicleClass, tariff: tariff,
                                             learnedRates: learnedRates,
                                             knownAmounts: knownAmounts),
                fuel: vehicle.flatMap {
                    FuelEstimate.make(for: r, profile: $0,
                                      livePrice: fuelPrice, priceSource: fuelPriceSource)
                })
        }

        func tag(_ t: RouteTag, at i: Int) {
            guard options.indices.contains(i), !options[i].tags.contains(t) else { return }
            options[i].tags.append(t)
        }

        if let i = options.indices.min(by: { options[$0].route.expectedTravelTime < options[$1].route.expectedTravelTime }) {
            tag(.fastest, at: i)
        }
        if let i = options.indices.min(by: { options[$0].route.distance < options[$1].route.distance }) {
            tag(.shortest, at: i)
        }
        if let i = options.indices.min(by: { options[$0].curviness < options[$1].curviness }) {
            tag(.calmest, at: i)
        }
        if let i = options.indices.min(by: { options[$0].totalCostTL < options[$1].totalCostTL }),
           options.contains(where: { $0.totalCostTL > options[i].totalCostTL + 1 }) {
            tag(.cheapest, at: i)
        }
        for i in options.indices where !options[i].toll.hasAny {
            tag(.noToll, at: i)
        }

        var sorted = options.sorted { $0.route.expectedTravelTime < $1.route.expectedTravelTime }
        for i in sorted.indices { sorted[i].colorIndex = i }
        return sorted
    }
}

/// Trafik yoğunluğu — gerçek ölçümden (gece referansı farkı) türetilir.
enum TrafficLevel {
    case unknown, free, light, heavy, jammed

    var label: String {
        switch self {
        case .unknown: return "—"
        case .free:    return "Akıcı"
        case .light:   return "Hafif yoğun"
        case .heavy:   return "Yoğun"
        case .jammed:  return "Tıkalı"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .free:    return .green
        case .light:   return .yellow
        case .heavy:   return .orange
        case .jammed:  return .red
        }
    }

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .free:    return "checkmark.circle.fill"
        case .light:   return "car.fill"
        case .heavy:   return "car.2.fill"
        case .jammed:  return "exclamationmark.triangle.fill"
        }
    }
}

// ============================================================================
// MARK: - Sürüş Sırasında Yol Takibi
// ============================================================================
//
// SORUN — ESKİ KODDAKİ SAPMA HATASI
// ---------------------------------
// Eski TurnTracker, rotayı 500 noktaya seyreltip aracın en yakın NOKTAYA olan
// uzaklığına bakıyordu. 300 km'lik bir rotada bu 600 m aralık demektir; araç
// rotanın tam üstündeyken bile en yakın örnek noktaya 300 m uzakta olabilir.
// Eşik 60 m olduğu için uzun yolda SÜREKLİ sahte "rotadan çıktınız" tetikleniyor,
// uygulama durmadan yeniden rota hesaplıyordu.
//
// ÇÖZÜM
// -----
// Artık `GeoMath.snap` ile SEGMENTE dik mesafe (cross-track) ölçülüyor. Araç
// rotanın üstündeyse, örnek noktalar ne kadar seyrek olursa olsun cross-track
// ≈ 0 çıkar. Ayrıca along-track ilerleme de bedavaya geliyor — kalan mesafe
// artık adım adım toplanmak yerine doğrudan okunuyor.
//
// ARAMA PENCERESİ
// ---------------
// Araç rotada ileri gittiği için her fix'te tüm rotayı taramak gereksiz.
// Son bilinen indeksin etrafında ±pencere taranır (O(n) → O(1)). Sapma
// büyürse pencere genişletilir, gerekirse tam tarama yapılır.
// ============================================================================

@MainActor
final class TurnTracker {

    // MARK: Çıktı

    struct Guidance {
        let instruction: String        // "D-100 yönünde sağa dönün"
        let nextInstruction: String?   // ondan sonraki manevra ("sonra sola")
        let distanceToTurn: Double     // m
        let remainingDistance: Double  // m
        let remainingTime: TimeInterval
        let turnPan: Float             // -1 sol .. +1 sağ (stereo ses için)
        let turnAngle: Double          // derece, + sağ
        let progress: Double           // 0..1 rota tamamlanma oranı
        let crossTrack: Double         // rotaya dik sapma (m) — şerit hissi
        let announce: Announcement?
    }

    /// Sesli anons kademesi. Mesafe eşikleri SABİT DEĞİL, hıza göre seçilir —
    /// 40 km/s'te 300 m çok erken, 120 km/s'te çok geçtir.
    enum Announcement: Equatable {
        case far(String)      // "1,2 km sonra …"
        case near(String)     // "300 metre sonra …"
        case now(String)      // "şimdi sağa dönün"
    }

    // MARK: Durum

    private(set) var stepIndex = 0
    private var steps: [MKRoute.Step] = []
    private var stepEndDistance: [Double] = []   // her adımın rota üzerindeki bitiş mesafesi

    private var points: [MKMapPoint] = []
    private var cumulative: [Double] = []
    private var totalLength: Double = 0
    private var lastSegmentIndex = 0

    private var offRouteStrikes = 0
    private var lastRerouteAt: Date = .distantPast
    private var announced: Set<String> = []      // "stepIndex-kademe"

    private var totalExpectedTime: TimeInterval = 0

    // MARK: Kurulum

    func reset(with route: MKRoute, profile: CurveGeometry.Profile? = nil) {
        let prof = profile ?? CurveGeometry.profile(of: route.polyline)
        points = prof.points
        cumulative = prof.cumulative
        totalLength = prof.totalLength
        totalExpectedTime = route.expectedTravelTime

        steps = route.steps
        lastSegmentIndex = 0
        stepIndex = steps.count > 1 ? 1 : 0
        offRouteStrikes = 0
        announced = []

        // Her adımın rota üzerindeki bitiş konumunu bir kez hesapla.
        // Sürüş sırasında "sapağa kalan mesafe" bundan çıkar; adım poligonlarını
        // her fix'te yeniden gezmek gerekmez.
        stepEndDistance = []
        var acc: Double = 0
        for s in steps {
            acc += s.distance
            stepEndDistance.append(min(acc, totalLength))
        }
    }

    // MARK: Güncelleme

    func update(location: CLLocation, speedKmh: Double, mode: DrivingMode) -> Guidance? {
        guard points.count >= 2, !steps.isEmpty else { return nil }

        let p = MKMapPoint(location.coordinate)

        // Arama penceresi: son bilinen konumun ±200 örnek çevresi (~±2 km).
        // Bulunamazsa (tünel çıkışı, uzun sinyal kaybı) tam tarama.
        let window = max(0, lastSegmentIndex - 40)..<min(points.count - 1, lastSegmentIndex + 200)
        var snap = GeoMath.snap(point: p, to: points, cumulative: cumulative, searchWindow: window)
        if snap == nil || (snap!.crossTrack > 120) {
            snap = GeoMath.snap(point: p, to: points, cumulative: cumulative)
        }
        guard let s = snap else { return nil }
        lastSegmentIndex = s.segmentIndex

        let travelled = s.alongTrack
        let remaining = max(0, totalLength - travelled)

        // Hangi adımdayız? İlerlemeye göre ileri sar.
        while stepIndex < stepEndDistance.count - 1, travelled >= stepEndDistance[stepIndex] - 15 {
            stepIndex += 1
        }

        let distanceToTurn = max(0, stepEndDistance[min(stepIndex, stepEndDistance.count - 1)] - travelled)

        // Talimat: mevcut adımın SONUNDA uygulanacak manevra bir sonraki adımın
        // talimatıdır (MapKit'te step.instructions o adıma GİRERKEN yapılan
        // manevrayı anlatır).
        let instruction = instructionText(at: stepIndex + 1)
            ?? instructionText(at: stepIndex)
            ?? "Varış noktanıza yaklaşıyorsunuz"
        let following = instructionText(at: stepIndex + 2)

        // Dönüş açısı
        let (angle, pan) = turnGeometry(at: stepIndex)

        // Kalan süre: kalan mesafe oranıyla değil, GEÇEN yolun gerçek hızıyla
        // düzeltilmiş tahmin. Rota %30'u bittiyse ve gerçek hız beklenenin
        // %80'iyse, kalan süre buna göre uzatılır.
        let remTime = estimateRemainingTime(travelled: travelled, remaining: remaining, speedKmh: speedKmh)

        // Sesli anons kademesi — mesafe eşikleri hıza bağlı
        let announcement = announcement(distanceToTurn: distanceToTurn,
                                        speedKmh: speedKmh,
                                        instruction: instruction,
                                        mode: mode)

        return Guidance(instruction: instruction,
                        nextInstruction: following,
                        distanceToTurn: distanceToTurn,
                        remainingDistance: remaining,
                        remainingTime: remTime,
                        turnPan: pan,
                        turnAngle: angle,
                        progress: totalLength > 0 ? min(1, travelled / totalLength) : 0,
                        crossTrack: s.crossTrack,
                        announce: announcement)
    }

    /// Aracın rota üzerinde kat ettiği mesafe — viraj eşlemesi bunu kullanır.
    func alongTrack(for location: CLLocation) -> Double? {
        guard points.count >= 2 else { return nil }
        let window = max(0, lastSegmentIndex - 40)..<min(points.count - 1, lastSegmentIndex + 200)
        let snap = GeoMath.snap(point: MKMapPoint(location.coordinate),
                                to: points, cumulative: cumulative, searchWindow: window)
            ?? GeoMath.snap(point: MKMapPoint(location.coordinate), to: points, cumulative: cumulative)
        return snap?.alongTrack
    }

    // MARK: - Rotadan çıkış

    /// Rotadan gerçekten çıkıldı mı?
    ///
    /// Eşik SABİT DEĞİL: GPS'in kendi bildirdiği yatay doğruluğa göre uyarlanır.
    /// Şehir içi kanyonda doğruluk 40 m'ye düşebilir; orada 30 m eşik sürekli
    /// yanlış alarm verir. Eşik = max(35 m, 3 × doğruluk), tavan 120 m.
    ///
    /// Ayrıca üst üste 4 ölçüm ve 20 sn soğuma şartı var — tek sıçrayan fix
    /// yeniden rota tetiklemesin.
    func isOffRoute(_ location: CLLocation) -> Bool {
        guard points.count >= 2 else { return false }
        let p = MKMapPoint(location.coordinate)
        let window = max(0, lastSegmentIndex - 100)..<min(points.count - 1, lastSegmentIndex + 300)
        guard let snap = GeoMath.snap(point: p, to: points, cumulative: cumulative, searchWindow: window)
                ?? GeoMath.snap(point: p, to: points, cumulative: cumulative) else { return false }

        let accuracy = max(5, location.horizontalAccuracy)
        let threshold = min(120, max(35, accuracy * 3))

        if snap.crossTrack > threshold {
            offRouteStrikes += 1
        } else {
            offRouteStrikes = 0
        }

        if offRouteStrikes >= 4, Date().timeIntervalSince(lastRerouteAt) > 20 {
            lastRerouteAt = Date()
            offRouteStrikes = 0
            return true
        }
        return false
    }

    // MARK: - Yardımcılar

    private func instructionText(at index: Int) -> String? {
        guard steps.indices.contains(index) else { return nil }
        let t = steps[index].instructions.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Kalan süre tahmini.
    ///
    /// Ham `expectedTravelTime × (kalan/toplam)` oranı, otoyoldan şehre girişte
    /// ciddi yanılır (kalan 20 km'nin hepsi şehir içi olabilir). Burada iki
    /// bilgiyi harmanlıyoruz:
    ///   • Apple'ın rota-bazlı tahmini (trafik dahil, yol tipini bilir)
    ///   • Sürücünün fiilî hızı (o an tıkanıklıkta mı?)
    /// Fiilî hız, tahminin en fazla ±%35'ini kaydırabilir — anlık duruşlar
    /// (kırmızı ışık) ETA'yı sonsuza fırlatmasın diye.
    private func estimateRemainingTime(travelled: Double, remaining: Double, speedKmh: Double) -> TimeInterval {
        guard totalLength > 0, totalExpectedTime > 0 else { return 0 }
        let base = totalExpectedTime * (remaining / totalLength)

        let plannedAvg = (totalLength / 1000) / (totalExpectedTime / 3600)   // km/s
        guard plannedAvg > 1, speedKmh > 5, travelled > 500 else { return base }

        let ratio = min(1.35, max(0.65, plannedAvg / speedKmh))
        return base * ratio
    }

    /// Dönüş açısı ve stereo pan.
    private func turnGeometry(at index: Int) -> (angle: Double, pan: Float) {
        guard steps.indices.contains(index), steps.indices.contains(index + 1),
              let before = endBearing(of: steps[index]),
              let after = startBearing(of: steps[index + 1]) else { return (0, 0) }
        let delta = GeoMath.normalizeAngle(after - before)
        let pan: Float = abs(delta) < 20 ? 0 : Float(max(-1, min(1, delta / 90)))
        return (delta, pan)
    }

    /// Anons kademesi. Eşikler hıza bağlı:
    ///   uzak  ≈ 25 sn'lik yol (en az 400 m, en fazla 2 km)
    ///   yakın ≈ 10 sn'lik yol (en az 120 m)
    ///   şimdi ≈ 3 sn'lik yol  (en az  30 m)
    /// Böylece 50 km/s'te "300 m sonra" yerine "140 m sonra" denir; 120 km/s'te
    /// ise ilk uyarı 830 m önceden gelir.
    private func announcement(distanceToTurn d: Double,
                              speedKmh: Double,
                              instruction: String,
                              mode: DrivingMode) -> Announcement? {
        let v = max(speedKmh, 20) / 3.6                       // m/s, taban 20 km/s
        let scale = mode == .calm ? 1.25 : (mode == .aggressive ? 0.8 : 1.0)

        let farD  = min(2000, max(400, v * 25 * scale))
        let nearD = max(120, v * 10 * scale)
        let nowD  = max(30,  v * 3)

        func once(_ key: String) -> Bool {
            let k = "\(stepIndex)-\(key)"
            guard !announced.contains(k) else { return false }
            announced.insert(k)
            return true
        }

        if d <= nowD, once("now") { return .now(instruction) }
        if d <= nearD, once("near") { return .near(instruction) }
        if d <= farD, once("far") { return .far(instruction) }
        return nil
    }

    private func startBearing(of step: MKRoute.Step) -> Double? {
        let c = GeoMath.coordinates(of: step.polyline)
        guard c.count >= 2 else { return nil }
        return GeoMath.bearing(from: c[0], to: c[1])
    }

    private func endBearing(of step: MKRoute.Step) -> Double? {
        let c = GeoMath.coordinates(of: step.polyline)
        guard c.count >= 2 else { return nil }
        return GeoMath.bearing(from: c[c.count - 2], to: c[c.count - 1])
    }
}

// ============================================================================
// MARK: - Viraj Takipçisi
// ============================================================================
//
// Virajları rota üzerindeki MESAFEYE göre takip eder (koordinat mesafesine
// göre değil). Neden: bir dağ yolunda 200 m ileride ve 200 m geride iki farklı
// viraj, kuş uçuşu 50 m olabilir. Kuş uçuşu mesafeyle çalışan eski kod,
// geçilmiş virajı "yaklaşıyor" sanabiliyordu. Rota mesafesi bu belirsizliği
// tamamen kaldırır.
// ============================================================================

@MainActor
final class CurveTracker {

    struct Alert {
        let curve: Curve
        let distance: Double            // viraj GİRİŞine kalan (m)
        let level: SpeedModel.WarningLevel
        let isNew: Bool                 // bu viraj için ilk kez bu seviyeye çıktık
    }

    private var curves: [Curve] = []
    private var index = 0                       // ilk henüz geçilmemiş viraj
    private var reachedLevel: [UUID: SpeedModel.WarningLevel] = [:]
    private(set) var worstColorByCurve: [UUID: GaugeColor] = [:]

    func reset(curves: [Curve]) {
        self.curves = curves.sorted { $0.entryDistance < $1.entryDistance }
        index = 0
        reachedLevel = [:]
        worstColorByCurve = [:]
    }

    /// Rota üzerinde `travelled` metrede, `speedKmh` hızla giderken durum.
    func update(travelled: Double,
                speedKmh: Double,
                mode: DrivingMode,
                condition: RoadCondition) -> Alert? {
        // Geçilmiş virajları atla
        while index < curves.count, curves[index].exitDistance < travelled - 10 {
            index += 1
        }
        guard index < curves.count else { return nil }

        let c = curves[index]
        let distance = c.entryDistance - travelled

        // Virajın İÇİNDEYSEK: hız kaydı tut, ama mesafe 0
        let inside = travelled >= c.entryDistance && travelled <= c.exitDistance
        let effectiveDistance = inside ? 0 : distance

        // Renk kaydı — yolculuk skoru için
        let color = GaugeColor.from(
            speedKmh: speedKmh,
            thresholds: SpeedModel.thresholds(safeSpeedKmh: c.safeSpeedKmh,
                                              limitSpeedKmh: c.limitSpeedKmh,
                                              mode: mode))
        if inside || distance < 60 {
            let previous = worstColorByCurve[c.id]
            if previous == nil || color.puan < previous!.puan {
                worstColorByCurve[c.id] = color
            }
        }

        let level = SpeedModel.warningLevel(distanceToCurve: max(effectiveDistance, 1),
                                            speedKmh: speedKmh,
                                            safeSpeedKmh: c.safeSpeedKmh,
                                            mode: mode,
                                            condition: condition)

        let previousLevel = reachedLevel[c.id] ?? .none
        let isNew = level > previousLevel
        if isNew { reachedLevel[c.id] = level }

        return Alert(curve: c, distance: max(0, distance), level: level, isNew: isNew)
    }

    /// Sonraki N virajı — sürüş ekranındaki "yol önizlemesi" şeridi için.
    func upcoming(from travelled: Double, count: Int = 3) -> [(curve: Curve, distance: Double)] {
        curves.lazy
            .filter { $0.entryDistance > travelled - 20 }
            .prefix(count)
            .map { ($0, max(0, $0.entryDistance - travelled)) }
    }

    var recordedColors: [GaugeColor] { Array(worstColorByCurve.values) }
}
