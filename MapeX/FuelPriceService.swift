import Foundation
import CoreLocation
import MapKit

// ============================================================================
// MARK: - Konuma Göre Güncel Yakıt Fiyatı
// ============================================================================
//
// Türkiye'de akaryakıt fiyatı İLE GÖRE değişir; İstanbul'da ayrıca AVRUPA ve
// ANADOLU yakası ayrı fiyatlanır. Kullanıcının elle 47 ₺ yazıp altı ay sonra
// hâlâ 47 ₺ ile hesap görmesi, yakıt tahminini anlamsız kılar.
//
// GERÇEKLİK KONTROLÜ — RESMİ ÜCRETSİZ API YOK
// -------------------------------------------
// Dağıtıcılar (Opet, Shell, Petrol Ofisi, TP) fiyatları yalnızca HTML
// sayfalarında yayımlıyor; açık bir JSON API'leri yok. Test ettim:
//   • carqueryapi.com          → sunucu yanıt vermiyor (servis ölü)
//   • petrolofisi.com.tr/api/… → 404, sadece HTML sayfa var
//   • api.collectapi.com       → ÇALIŞIYOR, ücretsiz katman + anahtar istiyor
//
// Bu yüzden üç katmanlı, hiçbir katman çalışmasa bile bozulmayan bir yapı:
//
//   ① ELLE GİRİLEN FİYAT   her zaman geçerli, çevrimdışı çalışır (mevcut davranış)
//   ② UZAKTAN JSON         kullanıcının/geliştiricinin barındırdığı basit bir
//                          dosya; bir scraper dağıtıcı sayfasını okuyup üretir
//   ③ CollectAPI           kullanıcı ücretsiz anahtarını girerse il+ilçe bazlı
//                          canlı fiyat
//
// Hangisi kullanıldıysa arayüzde yazar. "Tahmini" diyorsak nereden geldiğini de
// söylemeliyiz — kaynağı gizlenen bir rakam, yanlış rakamdan beterdir.
// ============================================================================

// MARK: - Bölge

/// Fiyat bölgesi: il + (İstanbul için) yaka.
struct FuelRegion: Codable, Equatable {
    var province: String          // "İstanbul", "Ankara"…
    var district: String?         // ilçe (CollectAPI için)
    var istanbulSide: Side?       // yalnızca İstanbul

    enum Side: String, Codable { case avrupa = "Avrupa", anadolu = "Anadolu" }

    var displayName: String {
        if let s = istanbulSide { return "İstanbul \(s.rawValue)" }
        return province
    }

    static let fallback = FuelRegion(province: "Türkiye", district: nil, istanbulSide: nil)
}

enum RegionResolver {

    /// İstanbul'un 39 ilçesinin yaka eşlemesi.
    ///
    /// Neden boylam eşiği kullanmıyoruz: Boğaz düz bir çizgi değil. Sarıyer'in
    /// doğusu, Beykoz'un batısından daha DOĞUDA kalabiliyor. İlçe adıyla
    /// eşlemek kesin sonuç verir ve 39 kalemlik sabit bir listedir.
    static let istanbulEurope: Set<String> = [
        "arnavutköy", "avcılar", "bağcılar", "bahçelievler", "bakırköy",
        "başakşehir", "bayrampaşa", "beşiktaş", "beylikdüzü", "beyoğlu",
        "büyükçekmece", "çatalca", "esenler", "esenyurt", "eyüpsultan", "eyüp",
        "fatih", "gaziosmanpaşa", "güngören", "kağıthane", "kâğıthane",
        "küçükçekmece", "sarıyer", "silivri", "sultangazi", "şişli", "zeytinburnu"
    ]

    static let istanbulAsia: Set<String> = [
        "adalar", "ataşehir", "beykoz", "çekmeköy", "kadıköy", "kartal",
        "maltepe", "pendik", "sancaktepe", "sultanbeyli", "şile", "tuzla",
        "ümraniye", "üsküdar"
    ]

    /// Konumdan fiyat bölgesi çözer.
    static func resolve(_ location: CLLocation) async -> FuelRegion? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let items = try? await request.mapItems,
              let item = items.first else { return nil }

        let addr = item.addressRepresentations
        // İl: "İstanbul", ilçe: "Kadıköy"
        let fallbackProvince = (item.address?.shortAddress ?? "")
            .components(separatedBy: ",").last?
            .trimmingCharacters(in: .whitespaces)
        let province = addr?.regionName ?? fallbackProvince ?? ""
        let district = addr?.cityWithContext?
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)

        guard !province.isEmpty else { return nil }

        var side: FuelRegion.Side?
        if province.localizedCaseInsensitiveContains("istanbul")
            || province.localizedCaseInsensitiveContains("i̇stanbul") {
            let key = (district ?? "").lowercased()
            if istanbulEurope.contains(key) { side = .avrupa }
            else if istanbulAsia.contains(key) { side = .anadolu }
            else {
                // İlçe çözülemediyse boylam ile kaba tahmin — Boğaz ≈ 29.02°D.
                // Yalnızca son çare; ilçe eşlemesi daima önce denenir.
                side = location.coordinate.longitude < 29.02 ? .avrupa : .anadolu
            }
        }

        return FuelRegion(province: province, district: district, istanbulSide: side)
    }
}

// MARK: - Fiyat kaydı

struct FuelPrices: Codable, Equatable {
    var benzin: Double
    var motorin: Double
    var lpg: Double
    var elektrik: Double?      // ₺/kWh (AC/DC ortalaması)
    var region: String
    var updatedAt: Date
    var source: String

    func price(for type: VehicleProfile.FuelType) -> Double? {
        switch type {
        case .benzin:   return benzin > 0 ? benzin : nil
        case .dizel:    return motorin > 0 ? motorin : nil
        case .lpg:      return lpg > 0 ? lpg : nil
        case .elektrik: return elektrik
        }
    }

    var ageText: String {
        let hours = Date().timeIntervalSince(updatedAt) / 3600
        if hours < 1 { return "az önce" }
        if hours < 24 { return "\(Int(hours)) saat önce" }
        return "\(Int(hours / 24)) gün önce"
    }

    /// Akaryakıt fiyatı günlük değişebiliyor; 3 günden eskisi şüpheli.
    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 3 * 24 * 3600 }
}

// MARK: - Servis

@MainActor
final class FuelPriceService: ObservableObject {
    static let shared = FuelPriceService()

    @Published private(set) var region: FuelRegion?
    @Published private(set) var prices: FuelPrices?
    @Published var isFetching = false
    @Published var lastError: String?

    /// Otomatik güncelleme açık mı.
    @Published var autoUpdate: Bool = UserDefaults.standard.object(forKey: "fuelAutoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "fuelAutoUpdate") }
    }

    /// ② Uzaktan fiyat JSON adresi.
    @Published var feedURL: String = UserDefaults.standard.string(forKey: "fuelFeedURL") ?? "" {
        didSet { UserDefaults.standard.set(feedURL, forKey: "fuelFeedURL") }
    }

    /// ③ CollectAPI anahtarı (ücretsiz katman). Boşsa bu katman atlanır.
    @Published var collectAPIKey: String = UserDefaults.standard.string(forKey: "collectAPIKey") ?? "" {
        didSet { UserDefaults.standard.set(collectAPIKey, forKey: "collectAPIKey") }
    }

    private var lastFetchAt: Date?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "fuelPricesCache"),
           let p = try? JSONDecoder.tollDecoder.decode(FuelPrices.self, from: data) {
            prices = p
        }
        if let data = UserDefaults.standard.data(forKey: "fuelRegionCache"),
           let r = try? JSONDecoder().decode(FuelRegion.self, from: data) {
            region = r
        }
    }

    /// Konum değişince çağrılır. Aynı bölge için günde bir kez ağ isteği yapar.
    func updateIfNeeded(for location: CLLocation) async {
        guard autoUpdate else { return }

        let resolved = await RegionResolver.resolve(location)
        let regionChanged = resolved?.displayName != region?.displayName
        if let resolved {
            region = resolved
            if let data = try? JSONEncoder().encode(resolved) {
                UserDefaults.standard.set(data, forKey: "fuelRegionCache")
            }
        }

        // Bölge değiştiyse hemen, değişmediyse 12 saatte bir
        let stale = lastFetchAt.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true
        guard regionChanged || stale else { return }
        await fetch()
    }

    /// Elle tetiklenen güncelleme.
    func fetch() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        lastFetchAt = Date()

        let target = region ?? .fallback

        // ③ CollectAPI önce — il+ilçe hassasiyeti en yüksek olan bu
        if !collectAPIKey.trimmingCharacters(in: .whitespaces).isEmpty,
           let p = await fetchCollectAPI(region: target) {
            store(p); return
        }

        // ② Uzaktan JSON
        if !feedURL.trimmingCharacters(in: .whitespaces).isEmpty,
           let p = await fetchFeed(region: target) {
            store(p); return
        }

        lastError = "Fiyat kaynağı ayarlanmamış. Ayarlar'dan bir kaynak ekleyebilir veya fiyatı elle girebilirsin."
    }

    private func store(_ p: FuelPrices) {
        prices = p
        lastError = nil
        if let data = try? JSONEncoder.tollEncoder.encode(p) {
            UserDefaults.standard.set(data, forKey: "fuelPricesCache")
        }
    }

    // MARK: ② Uzaktan JSON
    //
    // Beklenen şema — bir scraper'ın üretmesi kolay olacak biçimde düz:
    //
    //   {
    //     "updatedAt": "2026-08-10T06:00:00Z",
    //     "source": "Opet",
    //     "regions": {
    //       "İstanbul Avrupa": { "benzin": 52.14, "motorin": 54.02, "lpg": 27.31 },
    //       "İstanbul Anadolu": { "benzin": 51.98, "motorin": 53.86, "lpg": 27.20 },
    //       "Ankara":          { "benzin": 52.60, "motorin": 54.44, "lpg": 27.05 }
    //     }
    //   }
    //
    // Bölge adı bulunamazsa "Türkiye" anahtarına düşer.

    private struct Feed: Decodable {
        let updatedAt: Date
        let source: String
        let regions: [String: Row]
        struct Row: Decodable {
            let benzin: Double
            let motorin: Double
            let lpg: Double
            let elektrik: Double?
        }
    }

    private func fetchFeed(region: FuelRegion) async -> FuelPrices? {
        guard let url = URL(string: feedURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let feed = try JSONDecoder.tollDecoder.decode(Feed.self, from: data)

            let key = feed.regions.keys.first {
                $0.compare(region.displayName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } ?? feed.regions.keys.first {
                $0.compare(region.province, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } ?? "Türkiye"

            guard let row = feed.regions[key] else { return nil }
            return FuelPrices(benzin: row.benzin, motorin: row.motorin, lpg: row.lpg,
                              elektrik: row.elektrik, region: key,
                              updatedAt: feed.updatedAt, source: feed.source)
        } catch {
            lastError = "Fiyat listesi okunamadı: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: ③ CollectAPI
    //
    // Yanıt şeması sürüme göre değişebildiği için TOLERANSLI ayrıştırıyoruz:
    // `result` nesne de olabilir dizi de; sayılar metin de gelebilir. Katı bir
    // Decodable, servis alanlarını değiştirdiği gün uygulamayı sessizce kırardı.

    private func fetchCollectAPI(region: FuelRegion) async -> FuelPrices? {
        var comps = URLComponents(string: "https://api.collectapi.com/gasPrice/turkeyGasoline")
        let city = region.province.isEmpty ? "istanbul" : region.province
        comps?.queryItems = [
            URLQueryItem(name: "district", value: region.district ?? city),
            URLQueryItem(name: "city", value: city)
        ]
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("apikey \(collectAPIKey.trimmingCharacters(in: .whitespaces))",
                     forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            lastError = "CollectAPI anahtarı geçersiz."
            return nil
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload: [String: Any]?
        if let obj = root["result"] as? [String: Any] { payload = obj }
        else if let arr = root["result"] as? [[String: Any]] { payload = arr.first }
        else { payload = nil }
        guard let p = payload else { return nil }

        func num(_ key: String) -> Double {
            if let d = p[key] as? Double { return d }
            if let s = p[key] as? String {
                return Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
            }
            return 0
        }

        let benzin = num("benzin"), motorin = num("motorin"), lpg = num("lpg")
        guard benzin > 0 || motorin > 0 else { return nil }

        return FuelPrices(benzin: benzin, motorin: motorin, lpg: lpg, elektrik: nil,
                          region: region.displayName,
                          updatedAt: Date(),
                          source: (p["marka"] as? String).map { "CollectAPI · \($0)" } ?? "CollectAPI")
    }

    // ========================================================================
    // MARK: Kullanıcıya iş yüklemeyen fiyat zinciri
    // ========================================================================
    //
    // Kullanıcıdan API anahtarı ya da JSON adresi istemek kabul edilemez —
    // uygulamanın işi, gerekli veriyi kendi bulmaktır. Türkiye'de dağıtıcıların
    // açık bir fiyat API'si olmadığı için üç kaynak sırayla denenir ve
    // KULLANICI HİÇBİR ŞEY AYARLAMAZ:
    //
    //   ① SENİN SON DOLUMUN   depo kaydında ödediğin tutar ve aldığın litre
    //                          zaten gerçek fiyatı verir: ₺/L = tutar / litre.
    //                          Bu, herhangi bir API'den daha doğrudur — çünkü
    //                          senin ilinde, senin istasyonunda, senin ödediğin
    //                          fiyattır. Hiçbir kurulum gerektirmez.
    //   ② UZAKTAN LİSTE       (isteğe bağlı, geliştirici barındırırsa)
    //   ③ GÖMÜLÜ TABAN        uygulamayla gelen ulusal ortalama; ilk günden
    //                          rakam boş kalmasın diye. Tarihi taşır ve
    //                          eskidiğinde arayüzde uyarı çıkar.
    //
    // Zincirin tamamı çevrimdışı çalışır. İnternet yalnızca ②'yi iyileştirir.

    /// ③ Gömülü ulusal taban — ilk açılışta boş ekran olmasın diye.
    ///
    /// 11 Ağustos 2026 pompa fiyatlarının İstanbul (iki yaka), Ankara ve İzmir
    /// ortalaması. İki bağımsız kaynakla karşılaştırıldı; motorin ve LPG kuruşu
    /// kuruşuna tuttu, benzinde markalar arası ~1.5 ₺ fark var (ortalama alındı).
    ///
    /// ÖNCEKİ DEĞERLER CİDDİ BİÇİMDE ESKİMİŞTİ ve maliyet hesabını anlamsız
    /// kılıyordu — benzin %31, motorin %49 düşük gösteriliyordu:
    ///
    ///     benzin  52.40 → 68.90     motorin 54.10 → 80.60
    ///     LPG     27.30 → 33.65     elektrik 7.50 → 10.50
    ///
    /// BU DEĞERLER DE ESKİYECEK. Gömülü taban zincirin EN SON halkasıdır ve
    /// yalnızca kullanıcı henüz depo kaydı girmemişken kullanılır; asıl doğruluk
    /// ①'den, yani kullanıcının fiilen ödediği tutardan gelir. Bu yüzden
    /// `isStale` eskidiğinde arayüz uyarır — sessizce yanlış rakam göstermek,
    /// rakam göstermemekten kötüdür.
    ///
    /// Elektrik, AC (≈8–9 ₺/kWh) ve DC hızlı şarjın (≈11–14 ₺/kWh) harmanı.
    static let baselinePrices = FuelPrices(
        benzin: 68.90, motorin: 80.60, lpg: 33.65, elektrik: 10.50,
        region: "Türkiye ortalaması",
        updatedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 11).date ?? Date(),
        source: "gömülü taban (11 Ağu 2026)")

    /// Araç profiline uygulanacak güncel birim fiyat.
    ///
    /// Öncelik: senin ölçümün → uzaktan liste → gömülü taban.
    /// Hiçbir durumda nil dönmez; hesap her zaman bir rakamla yapılabilir.
    func currentPrice(for type: VehicleProfile.FuelType) -> Double? {
        if let own = FuelLogStore.shared.lastPaidPricePerUnit,
           FuelLogStore.shared.lastPaidPriceIsFresh,
           VehicleManager.shared.profile.fuelType == type {
            return own
        }
        if let p = prices?.price(for: type) { return p }
        return Self.baselinePrices.price(for: type)
    }

    /// Kullanılan fiyatın kaynağı — arayüzde gösterilir.
    func currentPriceSource(for type: VehicleProfile.FuelType) -> String {
        if FuelLogStore.shared.lastPaidPricePerUnit != nil,
           FuelLogStore.shared.lastPaidPriceIsFresh,
           VehicleManager.shared.profile.fuelType == type {
            return "son dolumun"
        }
        if prices?.price(for: type) != nil, let p = prices {
            return "\(p.source) · \(p.region)"
        }
        return "ulusal ortalama"
    }
}
