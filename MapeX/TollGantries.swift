// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import MapKit
import CoreLocation

// ============================================================================
// MARK: - Gişeler ve Ülke Kuralları
// ============================================================================
//
// NEDEN GİŞE GÖSTERMEK ÖNEMLİ
// ---------------------------
// "Kuzey Marmara Otoyolu ≈ 110 ₺" cümlesi doğrulanamaz. Kullanıcı ne bu
// rakamın nereden geldiğini bilir, ne yanlışsa nerede yanlış olduğunu.
// Oysa "Kınalı → Odayeri" yazdığında:
//
//   • kullanıcı rotayı tanır ve doğru gişelerden bahsedildiğini görür
//   • yanlışsa NEREDE yanlış olduğu belli olur (yanlış çıkış gişesi seçilmiş)
//   • gerçek ücreti girdiğinde düzeltme O GİŞE ÇİFTİNE bağlanır
//
// Yani gişe adı göstermek, kozmetik değil DOĞRULANABİLİRLİK meselesidir.
//
// KOORDİNAT VERİSİ — İSTANBUL ÖNCELİKLİ
// -------------------------------------
// Aşağıdaki gişeler kavşak konumlarına göre yerleştirilmiştir. Öncelik
// İstanbul ve Marmara; sonra Türkiye genelindeki ana koridorlar. Liste
// uzatılabilir ve uzaktan tarife JSON'uyla da genişletilebilir.
//
// Gişe tespiti, rotanın gişeye 2 km'den fazla yaklaşıp yaklaşmadığına bakar
// (bağlantı yolları ve gişe sapakları için geniş tutuldu). Rotanın hangi
// gişeye ÖNCE, hangisine SONRA uğradığı, rota üzerindeki mesafeyle belirlenir —
// yani giriş ve çıkış kesin olarak sıralanır.
// ============================================================================

struct TollGantry: Identifiable, Codable {
    var id: String { key }
    let key: String
    let name: String
    let corridor: String        // TollCorridor.key
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

enum TollGantries {

    /// Yakalama yarıçapı (m). Gişeler kavşaklarda ve bağlantı yollarının
    /// ucundadır; rota ana hattan geçerken gişeye 1–1.5 km kalabilir.
    static let captureRadius: Double = 2000

    static let all: [TollGantry] = [

        // ── Kuzey Marmara Otoyolu · Avrupa (Kınalı – Odayeri) ────────────────
        TollGantry(key: "kmo_kinali",     name: "Kınalı",        corridor: "kmo_avrupa", latitude: 41.0430, longitude: 28.1980),
        TollGantry(key: "kmo_silivri",    name: "Silivri",       corridor: "kmo_avrupa", latitude: 41.1160, longitude: 28.2600),
        TollGantry(key: "kmo_catalca",    name: "Çatalca",       corridor: "kmo_avrupa", latitude: 41.1700, longitude: 28.4300),
        TollGantry(key: "kmo_nakkas",     name: "Nakkaş",        corridor: "kmo_avrupa", latitude: 41.2000, longitude: 28.5600),
        TollGantry(key: "kmo_tayakadin",  name: "Tayakadın",     corridor: "kmo_avrupa", latitude: 41.2600, longitude: 28.7300),
        TollGantry(key: "kmo_odayeri",    name: "Odayeri",       corridor: "kmo_avrupa", latitude: 41.2200, longitude: 28.8500),
        TollGantry(key: "kmo_hasdal",     name: "Hasdal",        corridor: "kmo_avrupa", latitude: 41.1200, longitude: 28.9200),

        // ── Kuzey Marmara Otoyolu · Anadolu (Kurtköy – Akyazı) ───────────────
        TollGantry(key: "kmo_kurtkoy",    name: "Kurtköy",       corridor: "kmo_anadolu", latitude: 40.9080, longitude: 29.3100),
        TollGantry(key: "kmo_kurnakoy",   name: "Kurnaköy",      corridor: "kmo_anadolu", latitude: 41.0500, longitude: 29.3400),
        TollGantry(key: "kmo_ipark",      name: "İstanbul Park", corridor: "kmo_anadolu", latitude: 40.9500, longitude: 29.4100),
        TollGantry(key: "kmo_izmitk",     name: "İzmit Kuzey",   corridor: "kmo_anadolu", latitude: 40.8400, longitude: 29.9200),
        TollGantry(key: "kmo_adapazari",  name: "Adapazarı",     corridor: "kmo_anadolu", latitude: 40.7900, longitude: 30.4000),
        TollGantry(key: "kmo_karasu",     name: "Karasu",        corridor: "kmo_anadolu", latitude: 41.0300, longitude: 30.6300),
        TollGantry(key: "kmo_akyazi",     name: "Akyazı",        corridor: "kmo_anadolu", latitude: 40.6900, longitude: 30.6200),

        // ── Anadolu Otoyolu (O-4 / TEM) ──────────────────────────────────────
        TollGantry(key: "o4_mahmutbey",   name: "Mahmutbey",     corridor: "o4_anadolu", latitude: 41.0450, longitude: 28.8100),
        TollGantry(key: "o4_kurtkoy",     name: "Kurtköy (TEM)", corridor: "o4_anadolu", latitude: 40.9100, longitude: 29.3050),
        TollGantry(key: "o4_gebze",       name: "Gebze",         corridor: "o4_anadolu", latitude: 40.8000, longitude: 29.4300),
        TollGantry(key: "o4_izmit",       name: "İzmit",         corridor: "o4_anadolu", latitude: 40.7800, longitude: 29.9500),
        TollGantry(key: "o4_bolu",        name: "Bolu Dağı",     corridor: "o4_anadolu", latitude: 40.7300, longitude: 31.3700),
        TollGantry(key: "o4_gerede",      name: "Gerede",        corridor: "o4_anadolu", latitude: 40.7900, longitude: 32.1900),
        TollGantry(key: "o4_kazan",       name: "Kazan",         corridor: "o4_anadolu", latitude: 40.2200, longitude: 32.6800),

        // ── Gebze – İzmir Otoyolu (O-5) ──────────────────────────────────────
        TollGantry(key: "o5_gebze",       name: "Gebze",         corridor: "o5_gebze_izmir", latitude: 40.7900, longitude: 29.4200),
        TollGantry(key: "o5_orhangazi",   name: "Orhangazi",     corridor: "o5_gebze_izmir", latitude: 40.4900, longitude: 29.3100),
        TollGantry(key: "o5_bursa",       name: "Bursa",         corridor: "o5_gebze_izmir", latitude: 40.2300, longitude: 28.9500),
        TollGantry(key: "o5_balikesir",   name: "Balıkesir",     corridor: "o5_gebze_izmir", latitude: 39.6500, longitude: 27.9000),
        TollGantry(key: "o5_manisa",      name: "Manisa",        corridor: "o5_gebze_izmir", latitude: 38.6200, longitude: 27.4300),
        TollGantry(key: "o5_izmir",       name: "İzmir",         corridor: "o5_gebze_izmir", latitude: 38.4500, longitude: 27.2000),

        // ── Ankara – Niğde (O-21) ────────────────────────────────────────────
        TollGantry(key: "o21_ankara",     name: "Ankara",        corridor: "o21_ankara_nigde", latitude: 39.8300, longitude: 32.8000),
        TollGantry(key: "o21_kirikkale",  name: "Kırıkkale",     corridor: "o21_ankara_nigde", latitude: 39.8400, longitude: 33.5100),
        TollGantry(key: "o21_aksaray",    name: "Aksaray",       corridor: "o21_ankara_nigde", latitude: 38.3700, longitude: 33.9900),
        TollGantry(key: "o21_nigde",      name: "Niğde",         corridor: "o21_ankara_nigde", latitude: 37.9700, longitude: 34.6800),

        // ── İzmir – Çeşme (O-32) ─────────────────────────────────────────────
        TollGantry(key: "o32_izmir",      name: "İzmir",         corridor: "o32_izmir_cesme", latitude: 38.4200, longitude: 27.0900),
        TollGantry(key: "o32_urla",       name: "Urla",          corridor: "o32_izmir_cesme", latitude: 38.3300, longitude: 26.7600),
        TollGantry(key: "o32_cesme",      name: "Çeşme",         corridor: "o32_izmir_cesme", latitude: 38.3200, longitude: 26.3400),

        // ── İzmir – Aydın (O-31) ─────────────────────────────────────────────
        TollGantry(key: "o31_izmir",      name: "İzmir",         corridor: "o31_izmir_aydin", latitude: 38.3800, longitude: 27.2000),
        TollGantry(key: "o31_selcuk",     name: "Selçuk",        corridor: "o31_izmir_aydin", latitude: 37.9500, longitude: 27.3700),
        TollGantry(key: "o31_aydin",      name: "Aydın",         corridor: "o31_izmir_aydin", latitude: 37.8500, longitude: 27.8400)
    ]

    /// Rotanın bir koridorda hangi gişeden girip hangisinden çıktığını bulur.
    ///
    /// Yalnızca yakınlık yetmez — SIRA da gerekir. Rota üzerindeki kat edilen
    /// mesafeye (along-track) göre sıralayarak giriş ve çıkışı kesin olarak
    /// ayırt ediyoruz. Aksi hâlde İstanbul'dan Ankara'ya giden bir rotada
    /// "Gerede → Mahmutbey" gibi ters bir sonuç çıkabilirdi.
    nonisolated static func entryExit(for corridor: String,
                                      profile: CurveGeometry.Profile) -> (entry: TollGantry, exit: TollGantry)? {
        let candidates = all.filter { $0.corridor == corridor }
        guard candidates.count >= 2, !profile.points.isEmpty else { return nil }

        var hits: [(gantry: TollGantry, along: Double)] = []
        for g in candidates {
            let gp = MKMapPoint(g.coordinate)
            var bestDistance = Double.infinity
            var bestAlong: Double = 0
            for (i, p) in profile.points.enumerated() where i % 5 == 0 {
                let d = p.distance(to: gp)
                if d < bestDistance {
                    bestDistance = d
                    bestAlong = profile.cumulative[i]
                }
            }
            if bestDistance < captureRadius {
                hits.append((g, bestAlong))
            }
        }

        guard hits.count >= 2 else { return nil }
        hits.sort { $0.along < $1.along }
        return (hits.first!.gantry, hits.last!.gantry)
    }
}

// ============================================================================
// MARK: - Ülke Bazlı Ücret Kuralları
// ============================================================================
//
// Rota Türkiye dışına çıkabilir; o zaman KGM tarifesini uygulamak anlamsızdır.
// Her ülkenin otoyol ücreti farklı bir MODELE dayanır ve bunları karıştırmak
// tamamen yanlış rakam üretir:
//
//   MESAFE BAZLI (gişe)   Türkiye, Fransa, İtalya, İspanya, Yunanistan, Hırvatistan
//   VİNYET (süreli etiket) Avusturya, İsviçre, Slovenya, Çekya, Macaristan, Bulgaristan
//   ÜCRETSİZ (otomobil)   ALMANYA, Belçika, Hollanda, Danimarka, İsveç
//
// Almanya özellikle önemli: Alman otoyolları OTOMOBİL için ücretsizdir
// (kamyonlarda LKW-Maut vardır, otomobilde yoktur; 2019'da planlanan otomobil
// ücreti Avrupa Adalet Divanı kararıyla iptal edilmiştir). Yani Almanya'ya
// giren bir rotada doğru cevap "ücret yok"tur — sıfır göstermek burada bir
// eksiklik değil, DOĞRU bilgidir.
//
// İsviçre ve Avusturya'da ise mesafeden bağımsız olarak vinyet zorunludur;
// kısa bir transit geçiş bile tam vinyet bedeli demektir. Bunu km ile
// çarpmak ciddi biçimde yanlış olurdu.
// ============================================================================

struct CountryTollRule {
    let code: String            // ISO 3166-1 alpha-2
    let name: String
    let model: Model
    /// Vinyet ülkelerinde en kısa süreli vinyet bedeli (₺ karşılığı yaklaşık).
    let vignetteApproxTL: Double?
    let note: String

    enum Model {
        case distanceBased      // gişeli, mesafeye göre
        case vignette           // süreli etiket
        case freeForCars        // otomobil için ücretsiz
    }

    static let rules: [String: CountryTollRule] = [
        "TR": .init(code: "TR", name: "Türkiye", model: .distanceBased,
                    vignetteApproxTL: nil,
                    note: "Gişe bazlı (HGS). Köprü ve tüneller ayrı ücretlidir."),

        "DE": .init(code: "DE", name: "Almanya", model: .freeForCars,
                    vignetteApproxTL: nil,
                    note: "Otomobiller için otoyol ücretsizdir. Ücret yalnızca ağır ticari araçlara (LKW-Maut) uygulanır."),

        "BE": .init(code: "BE", name: "Belçika", model: .freeForCars,
                    vignetteApproxTL: nil, note: "Otomobil için otoyol ücretsiz."),
        "NL": .init(code: "NL", name: "Hollanda", model: .freeForCars,
                    vignetteApproxTL: nil, note: "Otomobil için otoyol ücretsiz; bazı tüneller ücretli."),

        "AT": .init(code: "AT", name: "Avusturya", model: .vignette,
                    vignetteApproxTL: 450,
                    note: "10 günlük vinyet zorunlu. Kısa geçişte de tam bedel ödenir; ayrıca bazı tüneller ek ücretlidir."),
        "CH": .init(code: "CH", name: "İsviçre", model: .vignette,
                    vignetteApproxTL: 1600,
                    note: "Yıllık vinyet zorunlu — daha kısa süreli seçenek yoktur."),
        "SI": .init(code: "SI", name: "Slovenya", model: .vignette,
                    vignetteApproxTL: 700, note: "Haftalık vinyet zorunlu."),
        "HU": .init(code: "HU", name: "Macaristan", model: .vignette,
                    vignetteApproxTL: 350, note: "Haftalık e-vinyet zorunlu."),
        "CZ": .init(code: "CZ", name: "Çekya", model: .vignette,
                    vignetteApproxTL: 400, note: "10 günlük e-vinyet zorunlu."),
        "BG": .init(code: "BG", name: "Bulgaristan", model: .vignette,
                    vignetteApproxTL: 300, note: "Haftalık e-vinyet zorunlu."),

        "GR": .init(code: "GR", name: "Yunanistan", model: .distanceBased,
                    vignetteApproxTL: nil, note: "Gişe bazlı."),
        "IT": .init(code: "IT", name: "İtalya", model: .distanceBased,
                    vignetteApproxTL: nil, note: "Gişe bazlı (Telepass)."),
        "FR": .init(code: "FR", name: "Fransa", model: .distanceBased,
                    vignetteApproxTL: nil, note: "Gişe bazlı."),
        "ES": .init(code: "ES", name: "İspanya", model: .distanceBased,
                    vignetteApproxTL: nil, note: "Kısmen gişe bazlı; birçok otoyol ücretsizdir."),
        "HR": .init(code: "HR", name: "Hırvatistan", model: .distanceBased,
                    vignetteApproxTL: nil, note: "Gişe bazlı."),
        "RO": .init(code: "RO", name: "Romanya", model: .vignette,
                    vignetteApproxTL: 200, note: "Rovinieta (e-vinyet) zorunlu.")
    ]

    static func rule(for code: String) -> CountryTollRule? {
        rules[code.uppercased()]
    }
}

// MARK: - Rotanın geçtiği ülkeler

enum RouteCountries {

    /// Rotanın geçtiği ülke kodları (yaklaşık, sırayla).
    ///
    /// Ters geokodlama pahalıdır; bu yüzden rota boyunca yalnızca birkaç örnek
    /// nokta sorgulanır. Şehirlerarası bir rotada ülke sınırını kaçırmamak için
    /// örnekler eşit aralıklıdır.
    static func detect(profile: CurveGeometry.Profile, samples: Int = 6) async -> [String] {
        guard !profile.points.isEmpty else { return [] }
        let step = max(1, profile.points.count / max(samples, 1))

        var codes: [String] = []
        for i in Swift.stride(from: 0, to: profile.points.count, by: step) {
            let c = profile.points[i].coordinate
            let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
            guard let req = MKReverseGeocodingRequest(location: loc),
                  let items = try? await req.mapItems,
                  let item = items.first else { continue }
            // MKAddressRepresentations doğrudan ülke kodu vermiyor; tam adresin
            // son bileşeni ülke adıdır. Bilinen ülke adlarıyla eşleştiriyoruz.
            let full = item.address?.fullAddress ?? ""
            if let code = countryCode(fromAddress: full), codes.last != code {
                codes.append(code)
            }
        }
        return codes
    }

    /// Adres metninden ülke kodu.
    ///
    /// Apple ülke adını cihazın diline göre döndürür, bu yüzden hem Türkçe hem
    /// İngilizce hem yerel yazımı tanıyoruz. Eşleşme yoksa nil döner ve o örnek
    /// atlanır — yanlış ülke tahmini yapmaktansa hiç tahmin etmemek doğrudur.
    private static let countryNames: [String: [String]] = [
        "TR": ["türkiye", "turkiye", "turkey"],
        "DE": ["almanya", "germany", "deutschland"],
        "AT": ["avusturya", "austria", "österreich", "osterreich"],
        "CH": ["isviçre", "isvicre", "switzerland", "schweiz", "suisse"],
        "BG": ["bulgaristan", "bulgaria", "българия"],
        "GR": ["yunanistan", "greece", "ελλάδα", "ellada"],
        "RO": ["romanya", "romania", "românia"],
        "HU": ["macaristan", "hungary", "magyarország"],
        "SI": ["slovenya", "slovenia", "slovenija"],
        "HR": ["hırvatistan", "hirvatistan", "croatia", "hrvatska"],
        "IT": ["italya", "i̇talya", "italy", "italia"],
        "FR": ["fransa", "france"],
        "ES": ["ispanya", "i̇spanya", "spain", "españa"],
        "BE": ["belçika", "belcika", "belgium", "belgique"],
        "NL": ["hollanda", "netherlands", "nederland"],
        "CZ": ["çekya", "cekya", "czechia", "czech republic"]
    ]

    static func countryCode(fromAddress address: String) -> String? {
        let lower = address.lowercased()
        for (code, names) in countryNames where names.contains(where: { lower.contains($0) }) {
            return code
        }
        return nil
    }
}
