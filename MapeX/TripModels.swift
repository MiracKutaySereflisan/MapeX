import SwiftUI

// MARK: - Sürüş Modları

enum DrivingMode: String, Codable, CaseIterable {
    case calm = "Sakin"
    case normal = "Normal"
    case aggressive = "Agresif"

    // NOT: Buradaki eski `toleranceRatio` KALDIRILDI. Modun hız üzerindeki
    // etkisi tek bir yerde — `SpeedModel.safeSpeed`in `speedMargin`ında —
    // uygulanır. İkinci bir mod katsayısı, göstergeyi uygulamanın kendi sesli
    // tavsiyesiyle çelişir hâle getiriyordu (bkz. SpeedModel > "Oran Ölçeği").

    var icon: String {
        switch self {
        case .calm: return "tortoise.fill"
        case .normal: return "car.fill"
        case .aggressive: return "hare.fill"
        }
    }
}

// MARK: - Gösterge Rengi

/// Anlık hızın virajın tavsiye hızına göre rengi.
///
/// Eşikler `SpeedModel.thresholds`ten gelir — çevresel auranın ve Dinamik
/// Ada'nın kullandığı eşiklerin AYNISI. İkisi ayrı ölçek kullandığı sürece
/// aynı anda "Tehlikeli" ve "Güvenli" diyebiliyorlardı.
///
/// Mod burada YOK: `safeSpeedKmh` zaten moda göre kişiselleştirilmiş hedeftir.
/// Agresif sürücü daha yüksek hedef aldığı için aynı fiziksel hızda daha uzun
/// yeşil görür — ama eşikler kaza sınırıyla tavanlandığı için bu ayrıcalık
/// yol tutuşunun bittiği noktayı asla geçemez.
/// NOT — `beyondLimit` isim düzenini bilerek bozuyor.
///
/// Diğer kademeler renk adı taşır; bu taşımaz, çünkü bir renk değil bir DURUM
/// anlatır: yol tutuşunun tahmini olarak bittiği bölge. Renk adıyla ("koyu
/// kırmızı") çağırmak, onu kırmızının biraz daha koyusu gibi gösterirdi; oysa
/// aradaki fark derece değil, tür farkı.
///
/// Ham değerler DEĞİŞMEDİ — `TripResult.curveColors` UserDefaults'ta saklanıyor
/// ve eski yolculuk kayıtları çözümlenmeye devam etmeli.
enum GaugeColor: String, Codable, CaseIterable {
    case white, green, yellow, orange, red, beyondLimit

    static func from(speedKmh: Double, thresholds t: SpeedModel.Thresholds) -> GaugeColor {
        // Sınır önce kontrol edilir: aşağıdaki bantların hiçbiri oraya ulaşmaz
        // ama kural açıkça yazılsın ki ileride eşikler değişse de bozulmasın.
        if speedKmh >= t.limit, t.limit > 0 { return .beyondLimit }
        switch speedKmh {
        case ..<t.cautious: return .white   // gereksiz temkinli
        case ..<t.safe:     return .green   // ideal — tavsiyeye uyuluyor
        case ..<t.warn:     return .yellow  // dikkatli
        case ..<t.critical: return .orange  // riskli
        default:            return .red     // tehlikeli — sınıra yaklaşıldı
        }
    }

    var color: Color {
        switch self {
        case .white: return .white
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        // Kırmızıdan AYIRT EDİLEBİLİR olmalı: aynı kırmızının tonu olsaydı
        // sürücü iki durumu birbirinden ayıramazdı. Mor, hem kırmızıdan uzak
        // hem de kırmızı-yeşil renk körlüğünde de kırmızıdan farklı okunuyor.
        case .beyondLimit: return Color(red: 0.62, green: 0.11, blue: 0.78)
        }
    }

    var puan: Int {
        switch self {
        case .white: return 90
        case .green: return 100
        case .yellow: return 70
        case .orange: return 40
        case .red: return 10
        case .beyondLimit: return 0
        }
    }

    var etiket: String {
        switch self {
        case .white: return "Temkinli"
        case .green: return "İdeal"
        case .yellow: return "Dikkatli"
        case .orange: return "Riskli"
        case .red: return "Tehlikeli"
        // Risk dili DEĞİL. "Riskli/tehlikeli" hâlâ pazarlık payı varmış hissi
        // verir; burada model, tutuşun çoktan bittiğini söylüyor.
        case .beyondLimit: return "SINIR AŞILDI"
        }
    }

    /// Dinamik Ada'ya gönderilen seviye.
    /// Widget'taki `riskColor` bu değerleri karşılamalı — 4 eklenirken orası da
    /// güncellendi, yoksa en kötü durum `default` dalına düşüp BEYAZ görünürdü.
    var level: Int {
        switch self {
        case .white, .green: return 0
        case .yellow: return 1
        case .orange: return 2
        case .red: return 3
        case .beyondLimit: return 4
        }
    }
}

// ============================================================================
// MARK: - Yolculuk Sonucu
// ============================================================================
//
// SKOR ARTIK İKİ BİLEŞENLİ
// ------------------------
// Eski skor yalnızca virajlardaki hıza bakıyordu; virajsız bir rotada otomatik
// 100 çıkıyordu. Artık:
//
//     Toplam = %55 viraj disiplini + %45 sürüş düzgünlüğü
//
// Viraj disiplini yoksa (düz rota) ağırlık tamamen düzgünlüğe geçer; düzgünlük
// verisi yoksa (CoreMotion kapalı) tamamen virajlara. Böylece hiçbir rota
// "bedava 100" vermez.
// ============================================================================

struct TripResult: Codable, Identifiable {
    var id = UUID()
    var curveColors: [GaugeColor] = []
    var events: [DrivingEvent] = []
    var smoothnessScore: Int = 100
    var startSemt: String = "?"
    var endSemt: String = "?"
    var distance: Double = 0
    var duration: TimeInterval = 0
    var timestamp: Date = Date()
    var drivingMode: DrivingMode = .normal
    var roadCondition: RoadCondition = .dry
    var tollPaid: Double = 0
    var fuelUsed: Double = 0

    /// Yalnızca virajlardan gelen puan.
    var curveScore: Int {
        guard !curveColors.isEmpty else { return 100 }
        return curveColors.map(\.puan).reduce(0, +) / curveColors.count
    }

    var hasCurveData: Bool { !curveColors.isEmpty }

    var score: Int {
        if hasCurveData {
            return Int((Double(curveScore) * 0.55 + Double(smoothnessScore) * 0.45).rounded())
        }
        return smoothnessScore
    }

    var dagilim: [(GaugeColor, Int)] {
        GaugeColor.allCases.compactMap { c in
            let n = curveColors.filter { $0 == c }.count
            return n > 0 ? (c, n) : nil
        }
    }

    var formattedDuration: String {
        let total = Int(duration)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) sa \(m) dk" : "\(m) dk \(total % 60) sn"
    }

    var formattedDistance: String {
        distance >= 10_000 ? String(format: "%.0f km", distance / 1000)
                           : String(format: "%.1f km", distance / 1000)
    }

    var averageSpeedKmh: Int {
        guard duration > 0 else { return 0 }
        return Int((distance / 1000) / (duration / 3600))
    }

    var eventSummary: (braking: Int, accel: Int, cornering: Int) {
        (events.filter { $0.kind == .harshBraking }.count,
         events.filter { $0.kind == .harshAccel }.count,
         events.filter { $0.kind == .harshCornering }.count)
    }
}

// MARK: - Rozetler

struct Badge: Identifiable {
    let id = UUID()
    let title: String
    let level: Int
    let icon: String
}

enum BadgeStore {
    static func award(for trip: TripResult) -> [Badge] {
        var badges: [Badge] = []
        let defaults = UserDefaults.standard
        var counts = defaults.dictionary(forKey: "semtSayaclari") as? [String: Int] ?? [:]

        // Semt bazlı rozetler — yalnızca iyi sürüşte
        if trip.score >= 70 {
            let items: [(String, String, String)] = [
                ("cikis", trip.startSemt, "\(trip.startSemt)'den güvenli çıkış"),
                ("varis", trip.endSemt, "\(trip.endSemt)'e güvenli varış")
            ]
            for (tur, semt, baslik) in items where semt != "?" {
                let key = "\(tur)-\(semt)"
                let n = (counts[key] ?? 0) + 1
                counts[key] = n
                let level = n >= 5 ? 3 : (n >= 3 ? 2 : 1)
                badges.append(Badge(title: level >= 3 ? "\(semt) Ustası" : baslik,
                                    level: level, icon: "medal.fill"))
            }
            defaults.set(counts, forKey: "semtSayaclari")
        }

        // Davranış rozetleri
        if trip.distance > 20_000, trip.events.isEmpty {
            badges.append(Badge(title: "Pürüzsüz Sürüş — hiç sert olay yok",
                                level: 3, icon: "leaf.fill"))
        }
        if trip.hasCurveData, trip.curveColors.allSatisfy({ $0 == .green || $0 == .white }) {
            badges.append(Badge(title: "Viraj Disiplini — hepsi ideal hızda",
                                level: 3, icon: "checkmark.seal.fill"))
        }
        if trip.eventSummary.braking == 0, trip.distance > 10_000 {
            badges.append(Badge(title: "Öngörülü Sürüş — sert fren yok",
                                level: 2, icon: "eye.fill"))
        }
        return badges
    }
}
