// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import CoreMotion
import CoreLocation

// ============================================================================
// MARK: - Sürüş Kalitesi Ölçümü
// ============================================================================
//
// NEDEN GEREKLİ
// -------------
// Eski skor SADECE virajlardaki hıza bakıyordu. Sonuç: virajsız bir rotada
// (otoyol, düz şehir yolu) puan otomatik 100 oluyordu — sürücü ne kadar sert
// fren yapmış, ne kadar ani şerit değiştirmiş olursa olsun. Oysa uygulamanın
// hedef kitlesi "savrulmaması gereken" sürücü; onun için asıl tehlike
// göstergeleri şunlardır:
//
//     • sert fren        → takip mesafesi yetersiz, öngörü zayıf
//     • ani hızlanma     → yol tutuşunu gereksiz zorluyor
//     • sert viraj alma  → yanal ivme yüksek, savrulma riski
//     • yüksek jerk      → düzgün olmayan, ürkek/sinirli direksiyon-pedal kullanımı
//
// ---------------------------------------------------------------------------
// EŞİKLER NEREDEN GELİYOR
// ---------------------------------------------------------------------------
// Telematik / kullanım bazlı sigorta (UBI) literatüründe yerleşik eşikler:
//
//     Sert fren        : −0.30 g  (≈ −2.9 m/s²)   şiddetli: −0.45 g (−4.4 m/s²)
//     Ani hızlanma     : +0.25 g  (≈ +2.5 m/s²)   şiddetli: +0.35 g (+3.4 m/s²)
//     Sert viraj       :  0.30 g yanal (≈ 2.9 m/s²) şiddetli: 0.40 g (3.9 m/s²)
//
// Kıyas noktaları: normal şehir içi sürüşte fren ivmesi −1.5 m/s² civarındadır;
// AASHTO'nun "sürücülerin %90'ının rahatça uygulayabildiği" değeri 3.4 m/s²'dir
// (bkz. SpeedModel). Yani 0.30 g eşiği, "artık planlı değil tepkisel fren"
// sınırıdır — tam olarak yakalamak istediğimiz şey.
//
// ---------------------------------------------------------------------------
// ÖLÇÜM YÖNTEMİ — İKİ KAYNAK
// ---------------------------------------------------------------------------
// ① GPS (birincil, işaretli)
//      a_boyuna = dv/dt
//      a_yanal  = v · ω        (ω = kurs değişim hızı, rad/s)
//    Neden bu formül: sabit hızla R yarıçaplı yay çizen araçta v = ω·R olduğu
//    için a = v²/R = v·ω. Yarıçapı bilmeye gerek kalmaz, kurs değişimi yeter.
//    GPS 1 Hz olduğu için >1 sn süren olayları (gerçek fren, gerçek viraj)
//    güvenilir yakalar; işaret bilgisi (fren mi hızlanma mı) buradan gelir.
//
// ② CoreMotion (ikincil, işaretsiz, 20 Hz)
//    Cihazın hangi yöne baktığı bilinmediği için ivmenin YATAY BİLEŞENİNİN
//    BÜYÜKLÜĞÜ ölçülür — yerçekimi vektörüne dik izdüşüm alınarak. Bu, telefon
//    cepte de olsa, tutucuda da olsa, ters de dursa çalışır:
//
//        a_yatay = |a_kullanıcı − (a_kullanıcı · ĝ) ĝ|
//
//    GPS'in kaçırdığı kısa süreli sert olayları (yarım saniyelik panik freni)
//    yakalar. Yönü bilinmediği için tek başına sınıflandırmaz; GPS'in o andaki
//    baskın bileşenine göre etiketlenir.
//
// İki kaynağın birleşimi, tek başına hiçbirinin veremeyeceği güveni verir:
// GPS işareti ve bağlamı, CoreMotion çözünürlüğü sağlar.
// ============================================================================

// MARK: - Olay

struct DrivingEvent: Identifiable, Codable {
    let id: UUID
    let kind: Kind
    let severity: Severity
    let magnitude: Double          // m/s²
    let speedKmh: Double
    let timestamp: Date

    enum Kind: String, Codable {
        case harshBraking   = "Sert Fren"
        case harshAccel     = "Ani Hızlanma"
        case harshCornering = "Sert Viraj"

        var icon: String {
            switch self {
            case .harshBraking:   return "exclamationmark.brakesignal"
            case .harshAccel:     return "gauge.with.dots.needle.100percent"
            case .harshCornering: return "arrow.triangle.turn.up.right.diamond.fill"
            }
        }
    }

    enum Severity: String, Codable {
        case moderate = "Orta"
        case severe   = "Şiddetli"

        /// Puan cezası — şiddetli olay orta olayın üç katı ağırlıktadır.
        var penalty: Double { self == .severe ? 3.0 : 1.0 }
    }

    init(kind: Kind, severity: Severity, magnitude: Double, speedKmh: Double) {
        self.id = UUID()
        self.kind = kind
        self.severity = severity
        self.magnitude = magnitude
        self.speedKmh = speedKmh
        self.timestamp = Date()
    }
}

// MARK: - Eşikler

enum MotionThreshold {
    static let g = 9.81

    static let brakeModerate  = -0.30 * g   // −2.94 m/s²
    static let brakeSevere    = -0.45 * g   // −4.41
    static let accelModerate  =  0.25 * g   //  2.45
    static let accelSevere    =  0.35 * g   //  3.43
    static let cornerModerate =  0.30 * g   //  2.94
    static let cornerSevere   =  0.40 * g   //  3.92

    /// Ölçümün geçerli sayılacağı asgari hız. Dururken/park manevrasında GPS
    /// türevleri anlamsızdır ve sahte olay üretir.
    static let minimumSpeedKmh: Double = 15

    /// Aynı türden olayların art arda sayılmaması için soğuma (sn).
    /// Tek bir uzun frenleme, 4 ayrı "sert fren" olarak yazılmamalı.
    static let eventCooldown: TimeInterval = 4
}

// ============================================================================
// MARK: - İzleyici
// ============================================================================

@MainActor
final class DrivingMonitor: ObservableObject {

    @Published private(set) var events: [DrivingEvent] = []
    @Published private(set) var longitudinalG: Double = 0    // + hızlanma, − fren
    @Published private(set) var lateralG: Double = 0          // işaretli: + sağ
    @Published private(set) var smoothnessScore: Int = 100

    /// CoreMotion açık mı — cihaz desteklemiyorsa GPS'le devam edilir.
    private(set) var motionAvailable = false

    private let motion = CMMotionManager()
    private var lastLocation: CLLocation?
    private var lastEventAt: [DrivingEvent.Kind: Date] = [:]
    private var distanceMeters: Double = 0

    /// CoreMotion'dan gelen yatay ivme büyüklüğünün son tepe değeri.
    private var peakHorizontalAccel: Double = 0

    // MARK: Yaşam döngüsü

    func start() {
        events = []
        distanceMeters = 0
        lastLocation = nil
        lastEventAt = [:]
        smoothnessScore = 100
        startMotion()
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        motionAvailable = false
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            // Yerçekimine dik izdüşüm → yatay ivme büyüklüğü (g biriminde)
            let a = d.userAcceleration, gv = d.gravity
            let gLenSq = gv.x * gv.x + gv.y * gv.y + gv.z * gv.z
            guard gLenSq > 0.01 else { return }
            let dot = (a.x * gv.x + a.y * gv.y + a.z * gv.z) / gLenSq
            let hx = a.x - dot * gv.x
            let hy = a.y - dot * gv.y
            let hz = a.z - dot * gv.z
            let horizontal = (hx * hx + hy * hy + hz * hz).squareRoot() * MotionThreshold.g

            // Tepe tutucu — 1 Hz'lik GPS penceresinde en sert anı sakla
            self.peakHorizontalAccel = max(self.peakHorizontalAccel * 0.92, horizontal)
        }
        motionAvailable = true
    }

    // MARK: Konum güncellemesi

    /// Her GPS fix'inde çağrılır. Olay tespiti burada yapılır.
    func ingest(location: CLLocation, speedKmh: Double) {
        defer { lastLocation = location }

        guard let previous = lastLocation else { return }
        let dt = location.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0.2, dt < 5 else { return }

        distanceMeters += location.distance(from: previous)

        guard speedKmh >= MotionThreshold.minimumSpeedKmh else {
            longitudinalG = 0; lateralG = 0; return
        }

        // ── ① boyuna ivme: dv/dt ────────────────────────────────────────────
        let v0 = max(0, previous.speed)
        let v1 = max(0, location.speed)
        var aLong = (v1 - v0) / dt

        // ── ① yanal ivme: a = v·ω ───────────────────────────────────────────
        var aLat: Double = 0
        if previous.course >= 0, location.course >= 0, v1 > 4 {
            let dCourse = GeoMath.normalizeAngle(location.course - previous.course)
            let omega = (dCourse * .pi / 180) / dt          // rad/s
            aLat = v1 * omega
        }

        // ── ② CoreMotion tepe değeriyle güçlendirme ─────────────────────────
        // GPS 1 Hz olduğu için yarım saniyelik sert bir fren yumuşamış görünür.
        // CoreMotion'ın ölçtüğü yatay tepe, GPS'in gördüğünden belirgin
        // büyükse baskın bileşene yazılır.
        let peak = peakHorizontalAccel
        peakHorizontalAccel = 0
        if motionAvailable, peak > 0 {
            let gpsMagnitude = (aLong * aLong + aLat * aLat).squareRoot()
            if peak > gpsMagnitude * 1.4, peak > 2.0 {
                // Hangi eksene yazılacak: GPS'in gösterdiği baskın yön
                if abs(aLong) >= abs(aLat) {
                    aLong = aLong < 0 ? -peak : peak
                } else {
                    aLat = aLat < 0 ? -peak : peak
                }
            }
        }

        longitudinalG = aLong / MotionThreshold.g
        lateralG = aLat / MotionThreshold.g

        classify(aLong: aLong, aLat: aLat, speedKmh: speedKmh)
        recomputeScore()
    }

    // MARK: Sınıflandırma

    private func classify(aLong: Double, aLat: Double, speedKmh: Double) {
        if aLong <= MotionThreshold.brakeModerate {
            record(.harshBraking,
                   severity: aLong <= MotionThreshold.brakeSevere ? .severe : .moderate,
                   magnitude: abs(aLong), speedKmh: speedKmh)
        } else if aLong >= MotionThreshold.accelModerate {
            record(.harshAccel,
                   severity: aLong >= MotionThreshold.accelSevere ? .severe : .moderate,
                   magnitude: aLong, speedKmh: speedKmh)
        }

        if abs(aLat) >= MotionThreshold.cornerModerate {
            record(.harshCornering,
                   severity: abs(aLat) >= MotionThreshold.cornerSevere ? .severe : .moderate,
                   magnitude: abs(aLat), speedKmh: speedKmh)
        }
    }

    private func record(_ kind: DrivingEvent.Kind,
                        severity: DrivingEvent.Severity,
                        magnitude: Double,
                        speedKmh: Double) {
        if let last = lastEventAt[kind],
           Date().timeIntervalSince(last) < MotionThreshold.eventCooldown { return }
        lastEventAt[kind] = Date()
        events.append(DrivingEvent(kind: kind, severity: severity,
                                   magnitude: magnitude, speedKmh: speedKmh))
    }

    // MARK: Puanlama

    /// 100 km başına ağırlıklı olay sayısından düzgünlük puanı.
    ///
    /// Ölçek: 100 km'de 0 olay → 100 puan; 100 km'de 20 ağırlıklı olay → 0 puan.
    /// Doğrusal değil karekök ölçek kullanılıyor — ilk birkaç olay puanı sert
    /// düşürsün (fark edilir olsun), sonrakiler doygunlaşsın; yoksa kötü bir
    /// sürüşte puan hep 0'da kalır ve iyileşme görünmez.
    private func recomputeScore() {
        let km = max(distanceMeters / 1000, 0.5)
        let weighted = events.reduce(0.0) { $0 + $1.severity.penalty }
        let per100 = weighted / km * 100
        let normalized = min(1, (per100 / 20).squareRoot())
        smoothnessScore = Int(((1 - normalized) * 100).rounded())
    }

    // MARK: Özet

    var summary: (braking: Int, accel: Int, cornering: Int) {
        (events.filter { $0.kind == .harshBraking }.count,
         events.filter { $0.kind == .harshAccel }.count,
         events.filter { $0.kind == .harshCornering }.count)
    }

    var distanceKm: Double { distanceMeters / 1000 }
}
