import Foundation
import MapKit
import CoreLocation

// ============================================================================
// MARK: - Geçiş Ücreti Modeli
// ============================================================================
//
// ÜÇ KATMANLI TASARIM
// -------------------
//   ① GÖMÜLÜ TARİFE   Uygulamayla gelen `TollTariff` — internet yokken de
//                      çalışır. Sürüm ve geçerlilik tarihi taşır.
//   ② UZAKTAN TARİFE   `TollTariffStore.refresh(from:)` bir JSON URL'inden
//                      günceli çeker, cihaza yazar, gömülünün yerine geçer.
//                      KGM tarifesini JSON'a çeviren scraper bu URL'i besler
//                      (uygulama İÇİNDE PDF ayrıştırmak kırılgandır — tarife
//                      yılda 1–2 kez değişiyor, sunucuda bir kez işlemek doğru
//                      yerdir).
//   ③ CANLI API        Kullanıcı/geliştirici TollGuru veya benzeri bir anahtar
//                      girerse, rota gerçek gişe matrisiyle fiyatlanır ve yerel
//                      hesabın yerini alır. Anahtar yoksa ② ile devam edilir.
//
// Her tahminin yanında `source` alanı taşınır; arayüz kullanıcıya "bu rakam
// nereden geldi ve ne kadar güvenilir" bilgisini gösterir. Tahmini kesin gibi
// sunmak, yanlış rakamdan daha kötüdür.
//
// ---------------------------------------------------------------------------
// OTOYOL ÜCRETİ NEDEN "km × sabit ₺" DEĞİL
// ---------------------------------------------------------------------------
// Eski kod tüm ücretli yollara tek bir ₺/km uyguluyordu. Türkiye'de her otoyol
// AYRI tarifelidir ve aralarındaki fark 5 katı bulur:
//
//     Ankara – Niğde (O-21)    ≈ 2.2 ₺/km
//     Kuzey Marmara (Avrupa)   ≈ 3.2 ₺/km
//     Gebze – İzmir (O-5)      ≈ 3.2 ₺/km   (köprü hariç)
//     Kuzey Marmara (Anadolu)  ≈ 3.5 ₺/km
//     İzmir – Çeşme (O-32)     ≈ 12.9 ₺/km  ← YİD modeli, çok pahalı
//
// Tek oran kullanmak İzmir–Çeşme'yi 4 kat ucuz gösterir. Bu yüzden koridor
// bazlı tarife kullanıyoruz: rota adımlarının yol adı ve coğrafi kutusu
// eşleştirilerek hangi otoyolda kaç km gidildiği bulunur.
//
// KALİBRASYON NOTU: Kuzey Marmara oranları başlangıçta 1.6 / 2.8 ₺/km idi ve
// sahada ciddi biçimde düşük çıktı (gerçek 110 ₺ olan bir geçiş 35 ₺ tahmin
// edildi). Temmuz 2026 tam güzergâh fiyatından (Kurtköy–Akyazı 600 ₺ / ~170 km)
// yeniden türetildi. Yine de bunlar TAHMİNDİR — kesin doğruluk yalnızca
// öğrenme katmanından (kullanıcının girdiği gerçek tutarlar) gelir.
// ============================================================================

// MARK: - Araç sınıfı

/// KGM araç sınıfları. Ücret sınıfa göre değişir; 1. sınıf dışındaki araçlar
/// için çarpan uygulanır.
enum TollVehicleClass: String, Codable, CaseIterable, Identifiable {
    case motorcycle = "Motosiklet"
    case class1     = "1. Sınıf (Otomobil)"
    case class2     = "2. Sınıf (Kamyonet/Otobüs)"
    case class3     = "3. Sınıf (3 akslı)"
    case class4     = "4. Sınıf (4-5 akslı)"
    case class5     = "5. Sınıf (6+ akslı)"

    var id: String { rawValue }

    /// 1. sınıfa göre yaklaşık ücret çarpanı.
    ///
    /// DİKKAT: Gerçek tarifede her sınıfın ücreti ayrı ayrı ilan edilir; bunlar
    /// oran YAKLAŞIMIDIR ve tarife JSON'unda sınıf bazlı gerçek değerler varsa
    /// onlar kullanılır (`TollTariff.classFees`). Çarpan yalnızca sınıf verisi
    /// bulunmayan kalemler için devreye girer.
    var approximateMultiplier: Double {
        switch self {
        case .motorcycle: return 0.60
        case .class1:     return 1.00
        case .class2:     return 1.50
        case .class3:     return 2.05
        case .class4:     return 3.00
        case .class5:     return 3.70
        }
    }

    var icon: String {
        switch self {
        case .motorcycle: return "bicycle"
        case .class1:     return "car.fill"
        case .class2:     return "bus.fill"
        case .class3, .class4, .class5: return "truck.box.fill"
        }
    }
}

// MARK: - Tarife veri modeli

/// Sabit ücretli geçiş (köprü / tünel).
struct TollCrossing: Codable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let latitude: Double
    let longitude: Double
    /// Sınıf bazlı ücretler. Anahtar `TollVehicleClass.rawValue`.
    /// Yalnızca 1. sınıf biliniyorsa diğerleri çarpanla türetilir.
    var fees: [String: Double]
    /// Gece indirimi uygulayan geçişler (Avrasya Tüneli) için gece ücreti.
    var nightFees: [String: Double]?
    /// Tek yön mü ücretlendiriliyor (15 Temmuz / FSM: yalnız Anadolu→Avrupa).
    var oneWayOnly: Bool = false

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    func fee(for vClass: TollVehicleClass, atNight: Bool = false) -> Double {
        let table = (atNight ? nightFees : nil) ?? fees
        if let exact = table[vClass.rawValue] { return exact }
        let base = table[TollVehicleClass.class1.rawValue] ?? 0
        return (base * vClass.approximateMultiplier).rounded()
    }
}

/// Ücretli otoyol koridoru. Rota bu koridorda kaç km gittiyse `ratePerKm` ile
/// çarpılır.
struct TollCorridor: Codable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    /// Rota adımı metninde aranan yol kodları/adları ("O-5", "Kuzey Marmara").
    let matchPatterns: [String]
    /// Koridorun kaba coğrafi sınırı — isim eşleşmesi yanlış pozitif vermesin.
    let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    /// 1. sınıf için ₺/km.
    let ratePerKm: Double
    /// Minimum geçiş ücreti (kısa mesafede taban ücret alınır).
    var minimumFee: Double = 0

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= minLat && c.latitude <= maxLat &&
        c.longitude >= minLon && c.longitude <= maxLon
    }

    func matches(instruction: String) -> Bool {
        let lower = instruction.lowercased()
        return matchPatterns.contains { lower.contains($0.lowercased()) }
    }
}

/// Bir tarife sürümü.
struct TollTariff: Codable {
    var version: String
    var validFrom: Date
    var sourceNote: String
    var crossings: [TollCrossing]
    var corridors: [TollCorridor]
    /// Koridor eşleşmesi olmayan ücretli yollar için son çare ₺/km.
    var fallbackRatePerKm: Double

    /// Tarife eskidi mi? KGM yılda 1–2 kez zam yapıyor.
    var isStale: Bool {
        Date().timeIntervalSince(validFrom) > 60 * 60 * 24 * 210   // ~7 ay
    }

    var validFromText: String {
        validFrom.formatted(date: .abbreviated, time: .omitted)
    }
}

// ============================================================================
// MARK: - Gömülü tarife (① katman)
// ============================================================================

extension TollTariff {

    /// 1 Temmuz 2026 tarifesi.
    ///
    /// Köprü ücretleri doğrulandı (bkz. `sourceNote`). Otoyol koridor oranları,
    /// yayımlanmış TAM GÜZERGÂH fiyatlarının koridor uzunluğuna bölünmesiyle
    /// türetilmiştir — gerçek tarife giriş/çıkış gişesi çiftine göre kademelidir,
    /// bu yüzden koridor içi kısa mesafelerde sapma olabilir. Kesin rakam için
    /// ② uzaktan tarife veya ③ canlı API kullanılmalıdır.
    static let bundled = TollTariff(
        version: "2026.07",
        validFrom: DateComponents(calendar: .current, year: 2026, month: 7, day: 1).date ?? Date(),
        sourceNote: "KGM 1 Temmuz 2026 tarifesi. Köprü/tünel ücretleri doğrulanmıştır (kesin). Otoyol ₺/km değerleri yayımlanmış tam güzergâh fiyatlarından türetilmiş TAHMİNLERDİR — gerçek tarife giriş/çıkış gişesi çiftine göre kademelidir ve işletmeciler kendi araç sınıflandırmalarını kullanır (Kuzey Marmara'da otomobil 2. sınıftır). Ödediğin tutarı girdikçe oranlar kendini düzeltir.",
        crossings: [
            TollCrossing(key: "temmuz15", name: "15 Temmuz Şehitler Köprüsü",
                         latitude: 41.0407, longitude: 29.0345,
                         fees: [TollVehicleClass.class1.rawValue: 59,
                                TollVehicleClass.motorcycle.rawValue: 35],
                         nightFees: nil, oneWayOnly: true),

            TollCrossing(key: "fsm", name: "Fatih Sultan Mehmet Köprüsü",
                         latitude: 41.0911, longitude: 29.0616,
                         fees: [TollVehicleClass.class1.rawValue: 59,
                                TollVehicleClass.motorcycle.rawValue: 35],
                         nightFees: nil, oneWayOnly: true),

            TollCrossing(key: "yss", name: "Yavuz Sultan Selim Köprüsü",
                         latitude: 41.2073, longitude: 29.1113,
                         fees: [TollVehicleClass.class1.rawValue: 110],
                         nightFees: nil, oneWayOnly: false),

            TollCrossing(key: "osmangazi", name: "Osmangazi Köprüsü",
                         latitude: 40.7561, longitude: 29.5158,
                         fees: [TollVehicleClass.class1.rawValue: 1170],
                         nightFees: nil, oneWayOnly: false),

            TollCrossing(key: "canakkale1915", name: "1915 Çanakkale Köprüsü",
                         latitude: 40.3130, longitude: 26.4520,
                         fees: [TollVehicleClass.class1.rawValue: 1170],
                         nightFees: nil, oneWayOnly: false),

            // Avrasya Tüneli: işletmeci ATAŞ, gece tarifesi yarı fiyat.
            TollCrossing(key: "avrasya", name: "Avrasya Tüneli",
                         latitude: 40.9990, longitude: 28.9990,
                         fees: [TollVehicleClass.class1.rawValue: 330],
                         nightFees: [TollVehicleClass.class1.rawValue: 165],
                         oneWayOnly: false)
        ],
        corridors: [
            TollCorridor(key: "kmo_avrupa", name: "Kuzey Marmara Otoyolu (Avrupa)",
                         matchPatterns: ["kuzey marmara", "o-7", "o7"],
                         minLat: 40.90, maxLat: 41.45, minLon: 27.70, maxLon: 29.15,
                         ratePerKm: 3.20, minimumFee: 25),

            TollCorridor(key: "kmo_anadolu", name: "Kuzey Marmara Otoyolu (Anadolu)",
                         matchPatterns: ["kuzey marmara", "o-7", "o7"],
                         minLat: 40.55, maxLat: 41.30, minLon: 29.15, maxLon: 31.20,
                         ratePerKm: 3.53, minimumFee: 25),

            TollCorridor(key: "o5_gebze_izmir", name: "Gebze – İzmir Otoyolu (O-5)",
                         matchPatterns: ["o-5", "o5", "gebze", "i̇zmir otoyolu", "izmir otoyolu"],
                         minLat: 38.20, maxLat: 40.90, minLon: 26.90, maxLon: 29.95,
                         ratePerKm: 3.20, minimumFee: 40),

            TollCorridor(key: "o4_anadolu", name: "Anadolu Otoyolu (O-4 / TEM)",
                         matchPatterns: ["o-4", "o4", "anadolu otoyolu", "tem"],
                         minLat: 39.50, maxLat: 41.30, minLon: 28.50, maxLon: 33.50,
                         ratePerKm: 1.95, minimumFee: 20),

            TollCorridor(key: "o21_ankara_nigde", name: "Ankara – Niğde Otoyolu (O-21)",
                         matchPatterns: ["o-21", "o21", "niğde", "nigde"],
                         minLat: 37.60, maxLat: 40.10, minLon: 32.20, maxLon: 35.20,
                         ratePerKm: 2.25, minimumFee: 25),

            TollCorridor(key: "o32_izmir_cesme", name: "İzmir – Çeşme Otoyolu (O-32)",
                         matchPatterns: ["o-32", "o32", "çeşme", "cesme"],
                         minLat: 38.20, maxLat: 38.55, minLon: 26.28, maxLon: 27.25,
                         ratePerKm: 12.90, minimumFee: 60),

            TollCorridor(key: "o31_izmir_aydin", name: "İzmir – Aydın Otoyolu (O-31)",
                         matchPatterns: ["o-31", "o31", "aydın otoyolu", "aydin otoyolu"],
                         minLat: 37.70, maxLat: 38.55, minLon: 27.20, maxLon: 28.00,
                         ratePerKm: 3.40, minimumFee: 30),

            TollCorridor(key: "o33_izmir_ankara", name: "İzmir – Ankara Otoyolu",
                         matchPatterns: ["o-33", "o33"],
                         minLat: 38.20, maxLat: 39.60, minLon: 27.10, maxLon: 32.90,
                         ratePerKm: 3.00, minimumFee: 30)
        ],
        fallbackRatePerKm: 2.20
    )
}

// ============================================================================
// MARK: - Tarife deposu (② katman)
// ============================================================================

@MainActor
final class TollTariffStore: ObservableObject {
    static let shared = TollTariffStore()

    @Published private(set) var tariff: TollTariff
    @Published private(set) var lastRefresh: Date?
    @Published var isRefreshing = false
    @Published var lastError: String?

    /// Güncel tarife JSON'unun adresi. KGM tablosunu işleyen scraper burayı
    /// besler. Kullanıcı kendi sunucusunu da girebilir.
    @Published var tariffURL: String {
        didSet { UserDefaults.standard.set(tariffURL, forKey: "tollTariffURL") }
    }

    /// Araç sınıfı — ücret bunun üzerinden hesaplanır.
    @Published var vehicleClass: TollVehicleClass {
        didSet { UserDefaults.standard.set(vehicleClass.rawValue, forKey: "tollVehicleClass") }
    }

    private static let cacheKey = "tollTariffCache"

    private init() {
        tariffURL = UserDefaults.standard.string(forKey: "tollTariffURL") ?? ""
        vehicleClass = UserDefaults.standard.string(forKey: "tollVehicleClass")
            .flatMap(TollVehicleClass.init(rawValue:)) ?? .class1

        // Önbellekteki tarife gömülüden yeniyse onu kullan
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder.tollDecoder.decode(TollTariff.self, from: data),
           cached.validFrom >= TollTariff.bundled.validFrom {
            tariff = cached
        } else {
            tariff = .bundled
        }
        lastRefresh = UserDefaults.standard.object(forKey: "tollTariffRefreshedAt") as? Date
    }

    /// Uzaktan tarife çeker. Başarısız olursa mevcut tarife korunur.
    func refresh() async {
        let trimmed = tariffURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            lastError = "Tarife adresi girilmemiş."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "Sunucu yanıt vermedi."
                return
            }
            let fresh = try JSONDecoder.tollDecoder.decode(TollTariff.self, from: data)
            tariff = fresh
            lastRefresh = Date()
            lastError = nil
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            UserDefaults.standard.set(lastRefresh, forKey: "tollTariffRefreshedAt")
        } catch {
            lastError = "Tarife okunamadı: \(error.localizedDescription)"
        }
    }

    /// Gömülü tarifeye geri dön.
    func resetToBundled() {
        tariff = .bundled
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        lastRefresh = nil
        lastError = nil
    }

    /// Kullanıcının elle güncellediği tek kalem ücret (tarife eskiyse pratik çözüm).
    func overrideFee(_ value: Double, forCrossing key: String) {
        guard let i = tariff.crossings.firstIndex(where: { $0.key == key }) else { return }
        tariff.crossings[i].fees[TollVehicleClass.class1.rawValue] = value
        if let data = try? JSONEncoder.tollEncoder.encode(tariff) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

extension JSONDecoder {
    static var tollDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var tollEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

// ============================================================================
// MARK: - Öğrenen Düzeltme Katmanı
// ============================================================================
//
// NEDEN GEREKLİ — SOMUT BİR HATA
// ------------------------------
// Kullanıcı bir güzergâhta 110 ₺ ödedi; uygulama 35 ₺ tahmin etti. Sebep:
// koridor ₺/km oranı, yayımlanmış "tam güzergâh" fiyatından bölünerek
// türetilmişti ve gerçek tarife böyle çalışmıyor.
//
// Türkiye'de otoyol ücreti GİŞE ÇİFTİ bazlıdır: giriş gişesi ve çıkış gişesi
// belirlenir, tarife tablosundan o çiftin fiyatı okunur. Fiyat mesafeyle
// doğru orantılı DEĞİLDİR — kısa kesimlerde taban ücret, uzun kesimlerde
// kademeli indirim vardır. Ayrıca işletmeciler kendi araç sınıflandırmalarını
// kullanır (Kuzey Marmara'da 1. sınıf MOTOSİKLET, otomobil 2. sınıftır) — bu
// tek başına 3 katı hataya yol açabilir.
//
// Gerçek matrisler yalnızca resmî PDF'lerde yayımlanıyor ve makine tarafından
// güvenilir biçimde okunamıyor. Bu durumda dürüst çözüm, tahmini kesin gibi
// sunmak değil ÖĞRENMEKTİR:
//
//      tahmin göster  →  kullanıcı ödediğini girer  →  düzeltme kaydedilir
//                     →  aynı güzergâhta bir daha yanılma
//
// Düzeltme, güzergâhın "ücret parmak izi"ne bağlanır: hangi koridorlardan
// kaç km gidildiği + hangi sabit geçişlerden geçildiği. Aynı parmak izine
// sahip bir sonraki rota, tahmin yerine ÖLÇÜLMÜŞ tutarı gösterir.
//
// Ek olarak koridor ₺/km oranı da her düzeltmede güncellenir; böylece tam aynı
// olmayan ama aynı otoyolu kullanan rotalar da giderek doğrulaşır.
// ============================================================================

struct TollCorrection: Codable, Identifiable {
    var id: String { fingerprint }
    /// Güzergâhın ücret parmak izi.
    let fingerprint: String
    let actualAmount: Double
    let estimatedAmount: Double
    let routeDescription: String
    let vehicleClass: String
    let recordedAt: Date
    /// Koridor → o rotada kat edilen km. Oran öğrenmesi bunu kullanır.
    let corridorKm: [String: Double]
    /// Sabit geçişlerin toplamı (bunlar zaten kesin, öğrenmeye dahil edilmez).
    let fixedCrossingTotal: Double
}

@MainActor
final class TollLearningStore: ObservableObject {
    static let shared = TollLearningStore()

    @Published private(set) var corrections: [TollCorrection] = []
    /// Öğrenilmiş koridor oranları (₺/km), gömülü tarifenin yerine geçer.
    @Published private(set) var learnedRates: [String: Double] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: "tollCorrections"),
           let c = try? JSONDecoder.tollDecoder.decode([TollCorrection].self, from: d) {
            corrections = c
        }
        learnedRates = UserDefaults.standard.dictionary(forKey: "tollLearnedRates") as? [String: Double] ?? [:]
    }

    /// Kullanıcının ödediği gerçek tutarı kaydeder.
    func record(actual: Double, for estimate: TollEstimator.Estimate, routeDescription: String,
                vehicleClass: TollVehicleClass) {
        let correction = TollCorrection(
            fingerprint: estimate.fingerprint,
            actualAmount: actual,
            estimatedAmount: estimate.total,
            routeDescription: routeDescription,
            vehicleClass: vehicleClass.rawValue,
            recordedAt: Date(),
            corridorKm: estimate.corridorKm,
            fixedCrossingTotal: estimate.fixedTotal)

        corrections.removeAll { $0.fingerprint == correction.fingerprint }
        corrections.append(correction)
        if corrections.count > 300 { corrections.removeFirst(corrections.count - 300) }

        relearnRates()
        persist()
    }

    /// Bu parmak izi için daha önce ölçülmüş tutar.
    func knownAmount(for fingerprint: String) -> Double? {
        corrections.first { $0.fingerprint == fingerprint }?.actualAmount
    }

    /// Koridor oranlarını tüm düzeltmelerden yeniden türetir.
    ///
    /// Her düzeltmede otoyol payı = ödenen − sabit geçişler. Bu, o rotadaki
    /// koridor kilometrelerine oranla dağıtılır ve koridor başına ağırlıklı
    /// ortalama alınır. Tek koridorlu rotalar (çoğu durum) doğrudan kesin oran
    /// verir; çok koridorlu rotalar mevcut oranlarla ağırlıklandırılarak
    /// paylaştırılır.
    private func relearnRates() {
        var totals: [String: (paid: Double, km: Double)] = [:]

        for c in corrections {
            let highwayPortion = max(0, c.actualAmount - c.fixedCrossingTotal)
            let totalKm = c.corridorKm.values.reduce(0, +)
            guard totalKm > 0.5, highwayPortion > 0 else { continue }

            for (key, km) in c.corridorKm where km > 0 {
                // Çok koridorlu rotada payı km oranına göre böl
                let share = highwayPortion * (km / totalKm)
                var acc = totals[key] ?? (0, 0)
                acc.paid += share
                acc.km += km
                totals[key] = acc
            }
        }

        var rates: [String: Double] = [:]
        for (key, v) in totals where v.km > 0.5 {
            rates[key] = (v.paid / v.km * 100).rounded() / 100
        }
        learnedRates = rates
    }

    func clear() {
        corrections = []
        learnedRates = [:]
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder.tollEncoder.encode(corrections) {
            UserDefaults.standard.set(d, forKey: "tollCorrections")
        }
        UserDefaults.standard.set(learnedRates, forKey: "tollLearnedRates")
    }
}

// ============================================================================
// MARK: - Hesaplayıcı
// ============================================================================

enum TollEstimator {

    struct Estimate {
        var items: [Item] = []
        var source: Source = .local
        var isStaleTariff = false

        /// Koridor anahtarı → o rotada kat edilen km. Öğrenme katmanı kullanır.
        var corridorKm: [String: Double] = [:]
        /// Sabit geçişlerin (köprü/tünel) toplamı — bunlar kesindir.
        var fixedTotal: Double = 0
        /// Kullanıcı bu güzergâh için gerçek tutarı girdiyse, o tutar.
        var measuredTotal: Double?
        /// Koridor → "Giriş → Çıkış" gişe metni.
        var gantryPairs: [String: String] = [:]
        /// Yurt dışı kesimleri için ülke bazlı notlar.
        var countryNotes: [CountryNote] = []

        struct CountryNote: Identifiable {
            let id = UUID()
            let country: String
            let model: String
            let amount: Double
            let note: String
        }

        struct Item: Identifiable {
            let id = UUID()
            let name: String
            let amount: Double
            let detail: String?
            var isEstimated: Bool = true
        }

        enum Source: String {
            case local    = "Yerel tarife"
            case remote   = "Güncellenmiş tarife"
            case learned  = "Senin kaydettiğin tutar"
            case api      = "Canlı API"
        }

        /// Güzergâhın ücret parmak izi.
        ///
        /// Aynı köprülerden geçen ve aynı koridorlarda (10 km'ye yuvarlanmış)
        /// benzer mesafe kat eden rotalar aynı parmak izini alır. Yuvarlama
        /// olmadan her rota benzersiz olurdu ve öğrenme hiç işe yaramazdı.
        var fingerprint: String {
            let crossings = items.filter { !$0.isEstimated }.map(\.name).sorted().joined(separator: "|")
            let corridors = corridorKm
                .map { key, km in
                    let gate = gantryPairs[key] ?? ""
                    return "\(key):\(gate):\(Int((km / 10).rounded()) * 10)"
                }
                .sorted().joined(separator: "|")
            return "\(crossings)#\(corridors)"
        }

        var crossingNames: [String] { items.map(\.name) }

        /// Gösterilecek tutar — ölçülmüş varsa o, yoksa tahmin.
        var total: Double { measuredTotal ?? items.reduce(0) { $0 + $1.amount } }
        var estimatedTotal: Double { items.reduce(0) { $0 + $1.amount } }
        var hasAny: Bool { total > 0.5 }
        var isMeasured: Bool { measuredTotal != nil }

        /// Kullanıcıya güven seviyesi. Tahmini kesin gibi sunmamak için.
        var confidence: String {
            if isMeasured { return "kaydettiğin tutar" }
            if corridorKm.isEmpty { return "kesin" }        // yalnızca sabit geçişler
            return "tahmini"
        }

        var summary: String { String(format: "%.0f ₺", total) }
    }

    /// Ana hesap.
    ///
    /// - Parameters:
    ///   - route: rota
    ///   - profile: 10 m aralıklı örneklenmiş profil. Sabit geçiş yakalama bunun
    ///     üzerinden yapılır — ham polyline'da nokta aralığı 1 km'yi bulabildiği
    ///     için köprü SESSİZCE kaçabiliyordu (eski koddaki hata). 10 m aralıkla
    ///     bu imkânsız hâle gelir.
    ///   - vehicleClass: araç sınıfı
    nonisolated static func estimate(for route: MKRoute,
                                     profile: CurveGeometry.Profile,
                                     vehicleClass: TollVehicleClass,
                                     tariff: TollTariff = TollTariff.bundled,
                                     learnedRates: [String: Double] = [:],
                                     knownAmounts: [String: Double] = [:],
                                     at date: Date = Date()) -> Estimate {
        var est = Estimate()
        est.isStaleTariff = tariff.isStale

        // ── 1) Sabit geçişler ────────────────────────────────────────────────
        // Rota, geçiş noktasının 250 m yakınından geçiyor mu? Profil 10 m
        // aralıklı olduğu için yakınlık eşiği dar tutulabilir — geniş eşik
        // köprüye paralel giden sahil yolunu da köprü sanardı.
        let isNight = Calendar.current.component(.hour, from: date) >= 22
                   || Calendar.current.component(.hour, from: date) < 6

        for crossing in tariff.crossings {
            let cp = MKMapPoint(crossing.coordinate)
            let hit = profile.points.contains { $0.distance(to: cp) < 250 }
            guard hit else { continue }
            let fee = crossing.fee(for: vehicleClass, atNight: isNight)
            guard fee > 0 else { continue }
            // Sabit geçişler KESİNDİR (ilan edilmiş tek fiyat) — tahmin değil.
            est.items.append(.init(name: crossing.name,
                                   amount: fee,
                                   detail: isNight && crossing.nightFees != nil ? "gece tarifesi" : nil,
                                   isEstimated: false))
            est.fixedTotal += fee
        }

        // ── 2) Otoyol koridorları ────────────────────────────────────────────
        // Adım adım gidilir: adımın talimat metni koridor adıyla eşleşiyor ve
        // adım koridorun coğrafi kutusunda ise, o adımın mesafesi koridora yazılır.
        guard route.hasTolls else {
            est.measuredTotal = knownAmounts[est.fingerprint]
            return est
        }

        var kmByCorridor: [String: Double] = [:]
        for step in route.steps {
            guard step.distance > 50 else { continue }
            let coords = GeoMath.coordinates(of: step.polyline)
            guard let mid = coords.middle else { continue }
            let text = step.instructions

            if let corridor = tariff.corridors.first(where: { $0.matches(instruction: text) && $0.contains(mid) }) {
                kmByCorridor[corridor.key, default: 0] += step.distance / 1000
            }
        }
        est.corridorKm = kmByCorridor

        var matchedKm: Double = 0
        for corridor in tariff.corridors {
            guard let km = kmByCorridor[corridor.key], km > 0.5 else { continue }
            matchedKm += km
            // ÖĞRENİLMİŞ oran varsa gömülü tarifenin önüne geçer — kullanıcının
            // fiilen ödediği tutarlardan türetildiği için daha güvenilirdir.
            let learned = learnedRates[corridor.key]
            let rate = learned ?? corridor.ratePerKm
            let raw = km * rate * (learned != nil ? 1.0 : vehicleClass.approximateMultiplier)
            let fee = max(raw, corridor.minimumFee * vehicleClass.approximateMultiplier).rounded()

            // Giriş ve çıkış gişesi — rakamı DOĞRULANABİLİR kılan bilgi.
            // "Kuzey Marmara ≈ 110 ₺" denetlenemez; "Kınalı → Odayeri, 110 ₺"
            // denetlenebilir ve yanlışsa nerede yanlış olduğu görülür.
            var gateText = ""
            if let pair = TollGantries.entryExit(for: corridor.key, profile: profile) {
                gateText = "\(pair.entry.name) → \(pair.exit.name) · "
                est.gantryPairs[corridor.key] = "\(pair.entry.name) → \(pair.exit.name)"
            }

            est.items.append(.init(
                name: corridor.name,
                amount: fee,
                detail: gateText + String(format: "%.0f km × %.2f ₺/km%@", km, rate,
                                          learned != nil ? " (öğrenildi)" : " (tahmini)")))
        }

        // ── 3) Eşleşmeyen ücretli kesim ──────────────────────────────────────
        // Rota ücretli yol içeriyor ama hiçbir koridora oturmadıysa, otoban
        // payını son çare oranla fiyatla. Bu kalem açıkça "tahmini" etiketlenir.
        let highwayKm = (route.distance / 1000) * RouteEngine.highwayRatio(of: route)
        let unmatched = highwayKm - matchedKm
        if unmatched > 5 {
            let fee = (unmatched * tariff.fallbackRatePerKm * vehicleClass.approximateMultiplier).rounded()
            if fee > 1 {
                est.items.append(.init(name: "Diğer ücretli kesim",
                                       amount: fee,
                                       detail: String(format: "≈%.0f km, tahmini", unmatched)))
                est.corridorKm["_diger", default: 0] += unmatched
            }
        }

        // ── 4) Daha önce ölçülmüşse tahmini ez ───────────────────────────────
        est.measuredTotal = knownAmounts[est.fingerprint]
        if est.measuredTotal != nil { est.source = .learned }

        return est
    }

}

private extension Array where Element == CLLocationCoordinate2D {
    var middle: CLLocationCoordinate2D? { isEmpty ? nil : self[count / 2] }
}
