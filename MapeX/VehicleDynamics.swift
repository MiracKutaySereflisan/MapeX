import Foundation

// ============================================================================
// MARK: - Araç Dinamiği
// ============================================================================
//
// ARAÇ TİPİ VİRAJ HIZINI NEDEN ETKİLER
// ------------------------------------
// Aynı virajı bir sedan ile yüksek bir SUV aynı hızda almaz. Fark iki
// mekanizmadan gelir:
//
//   ① DEVRİLME MARJI. NHTSA'nın kullandığı ölçü Statik Kararlılık Faktörüdür:
//
//              SSF = T / (2·H)      T: iz genişliği, H: ağırlık merkezi yüksekliği
//
//      SSF, aracın devrilmeye başladığı yanal ivmeye (g cinsinden) yaklaşık
//      eşittir. NHTSA'nın yıldız derecelendirmesinde tipik değerler:
//
//              spor otomobil   1.45 – 1.55
//              sedan/hatchback 1.35 – 1.45
//              pikap           1.10 – 1.20
//              SUV/crossover   1.05 – 1.25
//              minivan / panelvan 1.00 – 1.15
//
//   ② YÜK TRANSFERİ VE TEPKİ. Yüksek ağırlık merkezli araçta viraj içinde
//      yük dış tekerleklere daha çok kayar; dış lastik doyuma erken girer,
//      araç savrulur veya kaldırıma çarpıp devrilir ("tripped rollover" —
//      ölümcül devrilmelerin büyük çoğunluğu budur).
//
// DÜRÜST OLMAK GEREKİRSE
// ----------------------
// Asfaltta lastik tutuşu (µ ≈ 0.8) SSF'in altında kaldığı için araç genelde
// DEVRİLMEDEN ÖNCE KAYAR — yani SSF tek başına viraj hızını belirlemez.
// Bu yüzden stabilite katsayısını fizik iddiası olarak değil, tavsiye hızına
// uygulanan SINIRLI bir güvenlik payı olarak kullanıyoruz:
//
//        • en fazla 1.05'e kadar YÜKSELTEBİLİR (spor araç)
//        • 0.80'e kadar DÜŞÜREBİLİR (yüklü panelvan)
//
// Bu tavan kritik: bir katsayının tavsiye hızını serbestçe yükseltmesine izin
// vermek, modelin bütün emniyet payını tek satırda silebilirdi.
// ============================================================================

enum VehicleBodyClass: String, Codable, CaseIterable, Identifiable {
    case hatchback  = "Hatchback"
    case sedan      = "Sedan"
    case sports     = "Spor"
    case crossover  = "Crossover"
    case suv        = "SUV"
    case pickup     = "Pikap"
    case van        = "Panelvan / Minibüs"
    case vanLoaded  = "Yüklü Panelvan"

    var id: String { rawValue }

    /// Temsili SSF (NHTSA sınıf ortalamaları).
    var typicalSSF: Double {
        switch self {
        case .sports:    return 1.50
        case .hatchback: return 1.40
        case .sedan:     return 1.40
        case .crossover: return 1.22
        case .suv:       return 1.12
        case .pickup:    return 1.15
        case .van:       return 1.08
        case .vanLoaded: return 0.98
        }
    }

    /// Tavsiye hızına uygulanan çarpan.
    ///
    /// Sedan (SSF 1.40) referans alınır ve fark KAREKÖKÜ ile ölçeklenir —
    /// çünkü hız, yanal ivmenin karekökü ile değişir (v ∝ √a). Doğrusal
    /// ölçekleme SUV'ları gereğinden fazla cezalandırırdı.
    ///
    /// Sonuç 0.80 – 1.05 aralığına kırpılır.
    var speedFactor: Double {
        let reference = 1.40
        let raw = (typicalSSF / reference).squareRoot()
        return min(1.05, max(0.80, raw))
    }

    var icon: String {
        switch self {
        case .sports: return "car.side.fill"
        case .hatchback, .sedan: return "car.fill"
        case .crossover, .suv: return "suv.side.fill"
        case .pickup: return "truck.pickup.side.fill"
        case .van, .vanLoaded: return "van.side.fill"
        }
    }

    var aciklama: String {
        String(format: "SSF ≈ %.2f • viraj hızı ×%.2f", typicalSSF, speedFactor)
    }

    /// NHTSA vPIC "Body Class" metninden eşleme.
    static func from(nhtsaBodyClass raw: String) -> VehicleBodyClass? {
        let s = raw.lowercased()
        if s.contains("hatchback") || s.contains("liftback") { return .hatchback }
        if s.contains("sedan") || s.contains("saloon") { return .sedan }
        if s.contains("coupe") || s.contains("convertible") || s.contains("roadster") { return .sports }
        if s.contains("crossover") || s.contains("cuv") { return .crossover }
        if s.contains("sport utility") || s.contains("suv") { return .suv }
        if s.contains("pickup") { return .pickup }
        if s.contains("van") || s.contains("minivan") { return .van }
        if s.contains("wagon") { return .sedan }
        return nil
    }
}

// ============================================================================
// MARK: - Ölçülmüş Araç Boyutları
// ============================================================================
//
// AĞIRLIK VİRAJ HIZINI ETKİLER Mİ? — HAYIR (ve bu önemli)
// -------------------------------------------------------
// Yaygın bir yanılgı: "ağır araba virajda daha zor tutar". Denkleme bakalım:
//
//        m · v² / R  =  µ · m · g        →        v² / R = µ · g
//                ↑              ↑
//              KÜTLE İKİ TARAFTA DA VAR VE SADELEŞİR
//
// Ağır araç daha büyük merkezcik kuvvetine ihtiyaç duyar, ama aynı oranda daha
// büyük normal kuvvet (dolayısıyla sürtünme) üretir. Net etki sıfırdır.
// (İkincil etkiler var — lastik yük duyarlılığı µ'yü %2–5 düşürür, fren ısınır —
// ama tavsiye hız için ihmal edilebilir. Bu yüzden ağırlığı doğrudan hıza
// çarpan olarak KULLANMIYORUZ; öyle yapan bir model fizik değil, uydurma olur.)
//
// PEKİ NE ETKİLER? — GEOMETRİ
// ---------------------------
// Devrilme eşiği kütleden bağımsızdır ama geometriye bağımlıdır:
//
//        SSF = T / (2 · H)
//
//   T : iz genişliği (tekerlek merkezleri arası)
//   H : ağırlık merkezi yüksekliği
//
// NHTSA'nın Kanada araç veri tabanı bu iki büyüklüğün İLKİNİ DOĞRUDAN veriyor
// (TWF/TWR = ön/arka iz genişliği) — tahmin değil, ölçüm. H yayımlanmaz, ama
// toplam yükseklikle güçlü ilişkilidir: H ≈ k · OH. `k` katsayıları, bilinen
// NHTSA SSF değerlerine göre kalibre edilmiştir (aşağıda).
//
// AĞIRLIK NEREDE DEVREYE GİRER? — YÜK DAĞILIMI
// --------------------------------------------
// Boş ağırlık (CW) tek başına hızı değiştirmez, ama YÜK EKLENDİĞİNDE ağırlık
// merkezinin nereye kaydığını hesaplamak için gereklidir:
//
//        H_yeni = (CW · H_boş + W_yük · H_yük) / (CW + W_yük)
//
// Bu yüzden aracın boş ağırlığını biliyor olmak gerçekten işe yarar: tavana
// 75 kg bagaj bağlamak, 300 kg yolcu almaktan daha çok SSF düşürür — ve model
// bunu doğru şekilde gösterir. Tavan yükünün tehlikesi tam olarak budur.
// ============================================================================

struct VehicleDimensions: Codable, Equatable {
    /// Toplam uzunluk (mm) — viraj hızına etkisi yok, dar sokak manevrası için.
    var lengthMM: Double = 0
    /// Toplam genişlik (mm).
    var widthMM: Double = 0
    /// Toplam yükseklik (mm) — ağırlık merkezi tahmininin temeli.
    var heightMM: Double = 0
    /// Dingil mesafesi (mm).
    var wheelbaseMM: Double = 0
    /// Ön iz genişliği (mm) — SSF'in payı.
    var trackFrontMM: Double = 0
    /// Arka iz genişliği (mm).
    var trackRearMM: Double = 0
    /// Boş (kerb) ağırlık (kg) — yük dağılımı hesabı için.
    var kerbWeightKg: Double = 0

    /// Veri kaynağı — kullanıcıya şeffaflık için.
    var source: String = ""

    var hasTrackAndHeight: Bool {
        heightMM > 500 && (trackFrontMM > 500 || trackRearMM > 500 || widthMM > 500)
    }

    /// Ortalama iz genişliği (mm).
    ///
    /// Ölçüm yoksa toplam genişlikten türetilir: iz genişliği, gövde
    /// genişliğinin tipik olarak %86'sıdır (aradaki fark çamurluk payı ve
    /// lastik yanağıdır).
    var effectiveTrackMM: Double {
        let measured = [trackFrontMM, trackRearMM].filter { $0 > 500 }
        if !measured.isEmpty { return measured.reduce(0, +) / Double(measured.count) }
        return widthMM > 500 ? widthMM * 0.86 : 0
    }

    var isEmpty: Bool { heightMM < 500 && widthMM < 500 }
}

/// Yük durumu — ağırlık merkezini yükselttiği için SSF'i düşürür.
enum LoadState: String, Codable, CaseIterable, Identifiable {
    case solo       = "Sadece sürücü"
    case passengers = "Dolu (4-5 kişi)"
    case cargo      = "Bagaj dolu"
    case roofLoad   = "Tavan yükü / port bagaj"

    var id: String { rawValue }

    /// Eklenen kütle (kg).
    var addedMassKg: Double {
        switch self {
        case .solo:       return 0
        case .passengers: return 300
        case .cargo:      return 200
        case .roofLoad:   return 75
        }
    }

    /// Eklenen kütlenin ağırlık merkezi yüksekliği, aracın toplam
    /// yüksekliğinin katı olarak.
    ///   • oturan yolcu: göğüs hizası ≈ %60
    ///   • bagajdaki yük: bagaj tabanı ≈ %40
    ///   • tavan yükü: tavanın hemen üstü ≈ %105
    var massHeightFactor: Double {
        switch self {
        case .solo:       return 0
        case .passengers: return 0.60
        case .cargo:      return 0.40
        case .roofLoad:   return 1.05
        }
    }

    var icon: String {
        switch self {
        case .solo:       return "person.fill"
        case .passengers: return "person.3.fill"
        case .cargo:      return "shippingbox.fill"
        case .roofLoad:   return "car.top.door.front.left.and.rear.left.open"
        }
    }
}

extension VehicleBodyClass {
    /// Ağırlık merkezi yüksekliğinin toplam yüksekliğe oranı.
    ///
    /// Bilinen NHTSA SSF değerlerinden geri hesaplanarak kalibre edildi:
    ///   kompakt sedan  T≈152, OH≈143, yayımlanan SSF≈1.41 → k = 0.377
    ///   orta SUV       T≈172, OH≈173, yayımlanan SSF≈1.20 → k = 0.414
    ///   minivan        T≈170, OH≈173, yayımlanan SSF≈1.21 → k = 0.406
    ///   pikap          T≈170, OH≈194, yayımlanan SSF≈1.14 → k = 0.384
    var cogHeightFactor: Double {
        switch self {
        case .sports:    return 0.365
        case .hatchback: return 0.378
        case .sedan:     return 0.377
        case .crossover: return 0.400
        case .suv:       return 0.414
        case .pickup:    return 0.384
        case .van:       return 0.406
        case .vanLoaded: return 0.450
        }
    }
}

enum StabilityCalculator {

    struct Result {
        let ssf: Double
        let cogHeightMM: Double
        let trackMM: Double
        let speedFactor: Double
        let isMeasured: Bool     // gerçek boyut verisinden mi, sınıf ortalamasından mı

        var summary: String {
            String(format: "SSF %.2f • iz %.0f cm • AM yük. %.0f cm • hız ×%.2f",
                   ssf, trackMM / 10, cogHeightMM / 10, speedFactor)
        }
    }

    /// Ölçülmüş boyutlardan (varsa) veya sınıf ortalamasından stabilite.
    static func compute(bodyClass: VehicleBodyClass,
                        dimensions: VehicleDimensions,
                        load: LoadState) -> Result {

        guard dimensions.hasTrackAndHeight, dimensions.effectiveTrackMM > 500 else {
            // Ölçüm yok → sınıf ortalaması
            let ssf = bodyClass.typicalSSF
            return Result(ssf: ssf,
                          cogHeightMM: 0,
                          trackMM: 0,
                          speedFactor: factor(from: ssf),
                          isMeasured: false)
        }

        let track = dimensions.effectiveTrackMM
        var cog = dimensions.heightMM * bodyClass.cogHeightFactor

        // Yük varsa ağırlık merkezini kütle-ağırlıklı ortalamayla kaydır
        let addedMass = load.addedMassKg
        if addedMass > 0 {
            let kerb = dimensions.kerbWeightKg > 200 ? dimensions.kerbWeightKg : 1400
            let loadHeight = dimensions.heightMM * load.massHeightFactor
            cog = (kerb * cog + addedMass * loadHeight) / (kerb + addedMass)
        }

        let ssf = track / (2 * cog)
        return Result(ssf: ssf,
                      cogHeightMM: cog,
                      trackMM: track,
                      speedFactor: factor(from: ssf),
                      isMeasured: true)
    }

    /// SSF → tavsiye hız çarpanı.
    ///
    /// Sedan referansı (SSF 1.40) üzerinden KAREKÖK ölçekleme — hız yanal
    /// ivmenin kareköküyle değişir (v ∝ √a). Sonuç 0.80–1.05 ile sınırlanır:
    /// hiçbir araç ayarı modelin emniyet payını silememelidir.
    static func factor(from ssf: Double) -> Double {
        min(1.05, max(0.80, (ssf / 1.40).squareRoot()))
    }
}

// ============================================================================
// MARK: - NHTSA vPIC Sorgusu
// ============================================================================
//
// NHTSA'nın vPIC servisi ücretsiz ve anahtarsızdır; marka/model/yıl ile araç
// gövde sınıfını verir. Amaç kullanıcıyı "SSF" gibi bir kavramla uğraştırmadan
// doğru katsayıyı seçmek: kullanıcı "Dacia Duster 2021" yazar, uygulama
// "Sport Utility Vehicle (SUV)" görür ve katsayıyı kendisi ayarlar.
//
// SINIR: veri tabanı ABD pazarı odaklıdır; Türkiye'ye özgü modeller (Egea,
// Şahin, bazı Dacia/Renault varyantları) bulunmayabilir. Bu yüzden sorgu
// YARDIMCIDIR, zorunlu değildir — bulunamazsa kullanıcı sınıfı elle seçer ve
// hiçbir şey bozulmaz.
// ============================================================================

enum NHTSAService {

    struct Result {
        let bodyClass: VehicleBodyClass?
        let rawBodyClass: String
        let make: String
        let model: String
    }

    private struct Response: Decodable {
        let Results: [Row]
        struct Row: Decodable {
            let Make_Name: String?
            let Model_Name: String?
            let BodyClass: String?
        }
    }

    /// Marka + model + yıl ile gövde sınıfı sorgusu.
    static func lookup(make: String, model: String, year: Int) async -> Result? {
        let m = make.trimmingCharacters(in: .whitespaces)
        let mo = model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, !mo.isEmpty else { return nil }

        var comps = URLComponents(string:
            "https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMakeYear/make/\(m)/modelyear/\(year)")
        comps?.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = comps?.url else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        let match = decoded.Results.first {
            ($0.Model_Name ?? "").lowercased().contains(mo.lowercased())
        } ?? decoded.Results.first

        guard let match else { return nil }
        let raw = match.BodyClass ?? ""
        return Result(bodyClass: VehicleBodyClass.from(nhtsaBodyClass: raw),
                      rawBodyClass: raw,
                      make: match.Make_Name ?? m,
                      model: match.Model_Name ?? mo)
    }

    // ------------------------------------------------------------------------
    // MARK: Boyut / ağırlık verisi
    // ------------------------------------------------------------------------
    //
    // NHTSA'nın "Canadian Vehicle Specifications" veri tabanı, vPIC'in aksine
    // FİZİKSEL ÖLÇÜLERİ verir ve ücretsiz/anahtarsızdır:
    //
    //      OL  toplam uzunluk (cm)      TWF  ön iz genişliği (cm)
    //      OW  toplam genişlik (cm)     TWR  arka iz genişliği (cm)
    //      OH  toplam yükseklik (cm)    CW   boş ağırlık (kg)
    //      WB  dingil mesafesi (cm)     WD   ağırlık dağılımı ön/arka
    //
    // TWF/TWR tam olarak SSF'in payıdır — yani stabilite hesabı tahmine değil
    // ölçüme dayanır.
    //
    // KAPSAM SINIRI (dürüstçe): Kanada pazarı veri tabanıdır. Fiat, Volkswagen,
    // Toyota, Hyundai, Ford, Renault-dışı markalar iyi kapsanır; Dacia ve bazı
    // Türkiye'ye özgü modeller BULUNMAZ. Bu yüzden sorgu yardımcıdır — sonuç
    // gelmezse kullanıcı genişlik/yükseklik değerlerini elle girer (ruhsatta ve
    // kullanım kılavuzunda yazar) ve model aynı doğrulukla çalışır.

    private struct SpecResponse: Decodable {
        let Results: [Entry]
        struct Entry: Decodable {
            let Specs: [Spec]
            struct Spec: Decodable { let Name: String; let Value: String? }
        }
    }

    struct SpecMatch {
        let modelName: String
        let dimensions: VehicleDimensions
    }

    /// Marka/model/yıl ile fiziksel ölçüler.
    static func specifications(make: String, model: String, year: Int) async -> [SpecMatch] {
        let m = make.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return [] }

        var comps = URLComponents(string:
            "https://vpic.nhtsa.dot.gov/api/vehicles/GetCanadianVehicleSpecifications/")
        comps?.queryItems = [
            URLQueryItem(name: "year", value: String(year)),
            URLQueryItem(name: "make", value: m),
            URLQueryItem(name: "model", value: ""),
            URLQueryItem(name: "units", value: ""),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = comps?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(SpecResponse.self, from: data)
        else { return [] }

        let wanted = model.trimmingCharacters(in: .whitespaces).lowercased()

        return decoded.Results.compactMap { entry -> SpecMatch? in
            var map: [String: String] = [:]
            for s in entry.Specs { if let v = s.Value, !v.isEmpty { map[s.Name] = v } }

            let name = map["Model"] ?? ""
            guard wanted.isEmpty || name.lowercased().contains(wanted) else { return nil }

            // Değerler SANTİMETRE cinsinden gelir → mm'ye çevir
            func cm(_ key: String) -> Double { (Double(map[key] ?? "") ?? 0) * 10 }

            var d = VehicleDimensions()
            d.lengthMM      = cm("OL")
            d.widthMM       = cm("OW")
            d.heightMM      = cm("OH")
            d.wheelbaseMM   = cm("WB")
            d.trackFrontMM  = cm("TWF")
            d.trackRearMM   = cm("TWR")
            d.kerbWeightKg  = Double(map["CW"] ?? "") ?? 0
            d.source = "NHTSA Canadian Vehicle Specifications \(year)"

            guard d.heightMM > 500 else { return nil }
            return SpecMatch(modelName: name, dimensions: d)
        }
    }
}
