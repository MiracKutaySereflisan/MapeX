// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import MapKit
import CoreLocation

// ============================================================================
// MARK: - Viraj Geometrisi Çıkarımı
// ============================================================================
//
// PROBLEM
// -------
// Eski `detectCurves`, ardışık ÜÇ ham polyline noktasından çevrel çember
// yarıçapı hesaplıyordu. Bunun iki ölümcül kusuru var:
//
//  1) ÖRNEKLEME BAĞIMLILIĞI. MapKit noktaları düzgün aralıklı değildir.
//     Aynı fiziksel viraj, otoyolda 150 m arayla 3 nokta ile temsil edilirse
//     "geniş", şehir içi kavşakta 4 m arayla temsil edilirse "keskin" görünür.
//     Yarıçap, yolun geometrisi kadar Apple'ın nokta sıklığına bağlı çıkar.
//
//  2) GÜRÜLTÜ YÜKSELTME. Yarıçap üç noktanın oluşturduğu üçgenin alanına
//     BÖLÜNEREK bulunur (R = abc/4A). Noktalar birbirine yakınken alan sıfıra
//     yaklaşır, yarıçap patlar veya çöker. Birkaç metrelik bir sapma, düz yolda
//     "40 m yarıçaplı viraj" uydurur → uygulama sebepsiz bağırır, kullanıcı
//     uyarıları ciddiye almayı bırakır.
//
// ÇÖZÜM — DÖRT AŞAMA
// ------------------
//   ① YENİDEN ÖRNEKLE   sabit 10 m yay aralığı → geometri artık Apple'ın nokta
//                        dağılımından bağımsız
//   ② DÜZLEŞTİR          konum dizisine kayan ortalama → tekil sapmalar sönür,
//                        gerçek viraj (onlarca metre süren yapı) korunur
//   ③ EĞRİLİK            κ = Δθ/Δs  (kerteriz değişim hızı) — yarıçap yerine
//                        eğrilikle çalışmak sayısal olarak çok daha kararlı,
//                        çünkü düz yolda κ→0'dır, R→∞ gibi patlamaz
//   ④ SEGMENTLE          eğrilik profilinde eşik üstü kesintisiz bölgeler tek
//                        bir "viraj"tır; tepe noktası apeks, en büyük eğrilik
//                        o virajın belirleyici yarıçapı
//
// NEDEN κ = Δθ/Δs
// ---------------
// Bir eğrinin eğriliği, yay uzunluğuna göre teğet açısının değişim hızıdır:
//
//        κ = dθ/ds        ve        R = 1/κ
//
// Sabit Δs ile örneklediğimiz için Δθ'yı doğrudan ölçüp bölmek yeterli.
// Bu tanım üçgen alanına bölme içermediğinden, üç-nokta çevrel çemberinin
// aksine gürültüde patlamaz.
//
// PENCERE SEÇİMİ
// --------------
// Δs = 10 m tek adımda ölçülen açı farkı, GPS/generalization gürültüsüne hâlâ
// duyarlıdır. Bunun yerine ±3 örnek (≈60 m'lik kiriş) üzerinden açı farkı
// alıyoruz. 60 m, bir karayolu virajının anlamlı en küçük ölçeğidir; daha kısa
// pencere gürültü, daha uzun pencere keskin virajları yumuşatıp gizler.
//
// DOĞRULUK SINIRI — DÜRÜST OLMAK GEREKİRSE
// ----------------------------------------
// MKRoute polyline'ı GENELLEŞTİRİLMİŞ (basitleştirilmiş) geometridir; keskin
// dönüşlerin köşesi bir miktar kesilmiş olabilir. Bu, gerçek yarıçapı OLDUĞUNDAN
// BÜYÜK gösterme eğilimindedir, yani güvenli hızı biraz yüksek tahmin ederiz.
// Bunu telafi etmek için `generalizationMargin` ile yarıçapa %10 muhafazakâr
// düzeltme uygulanır. Yine de bu bir TAHMİNDİR; uygulamanın feragatnamesi bu
// yüzden vardır.
// ============================================================================

// MARK: - Viraj

struct Curve: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D   // apeks (en keskin nokta)
    let entryDistance: Double                // rota başından viraj GİRİŞİne (m)
    let apexDistance: Double                 // rota başından apekse (m)
    let exitDistance: Double                 // rota başından viraj ÇIKIŞına (m)
    let radius: Double                       // belirleyici yarıçap (m)
    let direction: Direction                 // sağ / sol
    let safeSpeedKmh: Double                 // tavsiye hız (kuru zemin, normal mod)
    /// Yol tutuşunun bittiği tahmini hız (km/s) — muhafazakâr.
    /// Tavsiye hızdan FARKLI bir soruya cevap verir: "rahat nasıl dönerim"
    /// değil, "nerede yoldan çıkarım". Bkz. `SpeedModel.limitSpeed`.
    let limitSpeedKmh: Double
    let severity: Severity
    /// Geometriden çıkarılan yol sınıfı — dever varsayımını belirler.
    var roadClass: RoadClass = .urban

    var length: Double { exitDistance - entryDistance }

    enum Direction: String, Codable {
        case left = "sol", right = "sağ"
        var icon: String { self == .left ? "arrow.turn.up.left" : "arrow.turn.up.right" }
        /// Ralli not defterlerindeki ok işaretleri.
        var arrow: String { self == .left ? "↰" : "↱" }
        /// Stereo pan yönü.
        var pan: Float { self == .left ? -1 : 1 }
    }

    // ------------------------------------------------------------------------
    // RALLİ DERECESİ
    // ------------------------------------------------------------------------
    // Ralli seyir notlarında virajlar 1–6 arası derecelendirilir; 1 en dar
    // (neredeyse firketa), 6 neredeyse düz. Bu gösterim iki nedenle iyi:
    //
    //   • TEK KARAKTER. Dinamik Ada'nın sıkışık sol bölgesine "Sol 2" sığar,
    //     "Çok Keskin Sol Viraj" sığmaz.
    //   • ÖĞRENİLEBİLİR. Sürücü birkaç yolculukta "3 rahat, 1 ciddi" ölçeğini
    //     içselleştirir; kilometre/saat rakamını her seferinde yorumlamak
    //     zorunda kalmaz.
    //
    // Derece, yarıçaptan değil TAVSİYE HIZINDAN türetilir — sürücü için anlamlı
    // olan, virajın kaç km/s istediğidir.
    var grade: Int {
        switch safeSpeedKmh {
        case ..<30:  return 1
        case ..<45:  return 2
        case ..<60:  return 3
        case ..<80:  return 4
        case ..<100: return 5
        default:     return 6
        }
    }

    /// "Sol 2" — Dinamik Ada ve sesli anons için kısa gösterim.
    var gradeLabel: String { "\(direction.rawValue.capitalized) \(grade)" }

    /// Keskinlik, yarıçaptan değil TAVSİYE HIZINDAN türetilir — sürücü için
    /// anlamlı olan budur. 400 m yarıçaplı bir viraj otoyolda "hafif"ken aynı
    /// yarıçap dar bir dağ yolunda da hafiftir; belirleyici olan hızdır.
    enum Severity: String, Codable, CaseIterable {
        case gentle   = "Hafif"        // ≥ 90 km/s
        case moderate = "Orta"         // 70–90
        case sharp    = "Keskin"       // 50–70
        case verySharp = "Çok Keskin"  // 30–50
        case hairpin  = "Firketa"      // < 30

        static func from(safeSpeed v: Double) -> Severity {
            switch v {
            case ..<30:  return .hairpin
            case ..<50:  return .verySharp
            case ..<70:  return .sharp
            case ..<90:  return .moderate
            default:     return .gentle
            }
        }

        var color: String {
            switch self {
            case .gentle: return "green"
            case .moderate: return "yellow"
            case .sharp: return "orange"
            case .verySharp, .hairpin: return "red"
            }
        }
    }

    static func == (a: Curve, b: Curve) -> Bool { a.id == b.id }
}

// ============================================================================
// MARK: - Yol Sınıfı ve Dever
// ============================================================================
//
// SAHADA ÇIKAN SİSTEMATİK HATA
// ----------------------------
// Model başlangıçta her yol için dever e = 0 (deversiz) varsayıyordu. Bilinmeyen
// bir yol için bu doğru ve güvenli taraftır — AMA otoyolda değildir:
//
//     450 m yarıçaplı bir otoyol virajı
//        e = 0 varsayımıyla   →   86 km/s tavsiye
//        gerçek e ≈ 0.07 ile  →  107 km/s tavsiye
//
// Otoyollar KGM standardına göre %6–8 deverle inşa edilir; viraj zaten hızı
// taşıyacak biçimde yatırılmıştır. Deveri yok saymak, 120'lik yolda 86 demeye
// yol açar — kullanıcı haklı olarak "bu uygulama saçmalıyor" der ve uyarıların
// TAMAMINA güvenmemeye başlar. Fazla temkinli olmak da bir hatadır.
//
// YOL SINIFINI NASIL ANLIYORUZ — GEOMETRİDEN
// ------------------------------------------
// Yol adı metnine bakmak kırılgan (dil, kısaltma, Apple'ın ifadesi değişir).
// Bunun yerine YOLUN KENDİ GEOMETRİSİNİ okuyoruz: bir yol hangi hız için
// inşa edilmişse, çevresindeki eğrilik ona göredir.
//
// Her virajın ±1 km çevresindeki tipik yarıçapa bakılır:
//
//      çevre yarıçapı > 1200 m  →  otoyol sınıfı      e = 0.06
//      600 – 1200 m             →  bölünmüş devlet yolu e = 0.045
//      300 – 600 m              →  şehirlerarası yol   e = 0.030
//      < 300 m                  →  şehir içi / dağ yolu e = 0.0
//
// Neden bu işe yarar: otoyol 500 m'lik tek bir virajı olsa bile öncesi ve
// sonrası kilometrelerce geniş kavistir. Dağ yolunda ise HER YER dardır, o
// yüzden e = 0 (dağ yolları çoğu zaman yeterince deverli değildir) — ve orada
// temkinli olmak zaten doğrudur.
//
// Değerler KGM azami dever sınırlarının (%8 kırsal, %6 kar bölgesi, %4 kentsel)
// ALTINDA seçilmiştir: gerçek dever daha yüksekse biz sadece temkinli kalırız,
// tersi olmaz.
// ============================================================================

enum RoadClass: String {
    case motorway   = "Otoyol"
    case divided    = "Bölünmüş yol"
    case rural      = "Şehirlerarası"
    case urban      = "Şehir içi / dağ"

    var superelevation: Double {
        switch self {
        case .motorway: return 0.060
        case .divided:  return 0.045
        case .rural:    return 0.030
        case .urban:    return 0.0
        }
    }

    static func from(contextRadius r: Double) -> RoadClass {
        switch r {
        case 1200...:   return .motorway
        case 600..<1200: return .divided
        case 300..<600: return .rural
        default:        return .urban
        }
    }
}

// MARK: - Çıkarım motoru

enum CurveGeometry {

    /// Yeniden örnekleme adımı (m). 10 m: şehir içi kavşak yarıçaplarını (R≈10 m)
    /// yakalayacak kadar sık, 500 km'lik rotada 50 bin nokta ile sınırlı kalacak
    /// kadar seyrek.
    static let sampleSpacing: Double = 10

    /// Eğrilik penceresinin yarı genişliği (örnek sayısı). 3 → ±30 m, 60 m kiriş.
    static let curvatureHalfWindow = 3

    /// Konum düzleştirme penceresi (tek sayı olmalı).
    static let smoothingWindow = 5

    /// Polyline genelleştirmesinin yarıçapı büyük göstermesine karşı muhafazakâr
    /// düzeltme. 0.90 → hesaplanan yarıçapın %90'ı kullanılır.
    static let generalizationMargin: Double = 0.90

    // ------------------------------------------------------------------------
    // BİR VİRAJ NE ZAMAN "ANLAMLI"DIR
    // ------------------------------------------------------------------------
    // Tek bir mutlak eşik (ör. "95 km/s altındaki her viraj") iki yönde de
    // yanılır:
    //
    //   • 120'lik otoyolda 400 m yarıçaplı viraj 93 km/s tavsiye alır ve
    //     listeye girer → kullanıcı otoyolda sürekli viraj uyarısı görür,
    //     uyarılara güvenmeyi bırakır.
    //   • Dağ yolunda zaten her şey 40–50 km/s'tir; mutlak eşiğe göre hepsi
    //     "anlamlı"dır, ama hangisinin GERÇEKTEN dikkat istediği kaybolur.
    //
    // Bu yüzden iki ölçüt birleştirilir — biri sağlanırsa viraj kaydedilir:
    //
    //   ① MUTLAK   tavsiye hız < 70 km/s
    //              Yavaş viraj her koşulda önemlidir; dağ yolunda da öyle.
    //
    //   ② GÖRECELİ tavsiye hız < yolun tasarım hızı × 0.80
    //              Yolun kendi geometrisinden çıkarılan tasarım hızına göre
    //              belirgin biçimde daha yavaş olan viraj, o yolda SÜRPRİZDİR —
    //              asıl uyarılması gereken budur.
    //
    // Sonuç: otoyolun 800 m'lik kavisi (118 km/s, tasarım 130) sessiz geçer;
    // aynı otoyoldaki 400 m'lik viraj (93 km/s) uyarılır. Dağ yolunun 60 m'lik
    // virajı (40 km/s) mutlak ölçütle yakalanır.
    static let absoluteInterestSpeed: Double = 70
    static let relativeInterestRatio: Double = 0.80

    /// Üst sınır — bunun üstü hiçbir koşulda kaydedilmez.
    static let maxInterestingSafeSpeed: Double = 110

    // MARK: - Örneklenmiş rota profili

    /// Rotanın metrik profili. Hem viraj çıkarımı hem sürüş sırasında konum
    /// eşleme (snap) bu yapıyı kullanır — polyline iki kez işlenmez.
    struct Profile {
        let points: [MKMapPoint]        // 10 m aralıklı, düzleştirilmiş
        let cumulative: [Double]        // kümülatif mesafe (m)
        let curvature: [Double]         // 1/m, işaretli (+ sağ, − sol)
        var totalLength: Double { cumulative.last ?? 0 }

        func coordinate(at index: Int) -> CLLocationCoordinate2D {
            points[min(max(0, index), points.count - 1)].coordinate
        }
    }

    /// ① + ② + ③ : polyline → düzleştirilmiş, sabit aralıklı, eğrilikli profil.
    static func profile(of polyline: MKPolyline) -> Profile {
        let raw = GeoMath.points(of: polyline)
        guard raw.count >= 2 else {
            return Profile(points: raw, cumulative: GeoMath.cumulativeDistances(of: raw), curvature: [])
        }

        // ① sabit yay uzunluğu
        let resampled = GeoMath.resample(raw, spacing: sampleSpacing)
        // ② düzleştirme
        let smooth = movingAverage(resampled, window: smoothingWindow)
        let cumulative = GeoMath.cumulativeDistances(of: smooth)
        // ③ eğrilik
        let curvature = signedCurvature(smooth, cumulative: cumulative)

        return Profile(points: smooth, cumulative: cumulative, curvature: curvature)
    }

    /// ④ : eğrilik profilinden viraj listesi.
    static func curves(from profile: Profile,
                       condition: RoadCondition = .dry,
                       mode: DrivingMode = .normal,
                       stabilityFactor: Double = 1.0,
                       ssf: Double = 1.40) -> [Curve] {
        let k = profile.curvature
        guard k.count > 2 * curvatureHalfWindow else { return [] }

        // İlgi eşiği: bu eğriliğin üstü, tavsiye hızın 95 km/s altına indiği bölge.
        // κ_eşik = 1 / R_min(95 km/s)
        let thresholdRadius = SpeedModel.minimumRadius(forSpeed: maxInterestingSafeSpeed,
                                                       condition: .dry)
        let thresholdCurvature = 1.0 / max(thresholdRadius, 1)

        var out: [Curve] = []
        var i = curvatureHalfWindow

        while i < k.count - curvatureHalfWindow {
            guard abs(k[i]) >= thresholdCurvature else { i += 1; continue }

            // Eşik üstü kesintisiz bölge — AYNI YÖNDE olduğu sürece tek viraj.
            // Yön değişimi (S virajı) ayrı virajlar demektir; birleştirilirse
            // sürücüye "tek bir keskin viraj" denir, oysa iki ayrı manevra var.
            let sign = k[i] > 0 ? 1.0 : -1.0
            var j = i
            var peakIndex = i
            var peak = abs(k[i])

            while j < k.count - curvatureHalfWindow,
                  abs(k[j]) >= thresholdCurvature * 0.6,   // histerezis: viraj erken kesilmesin
                  (k[j] > 0 ? 1.0 : -1.0) == sign {
                if abs(k[j]) > peak { peak = abs(k[j]); peakIndex = j }
                j += 1
            }

            // Çok kısa bölgeler gürültüdür (< 20 m süren "viraj" yoktur).
            let entry = profile.cumulative[min(i, profile.cumulative.count - 1)]
            let exit  = profile.cumulative[min(j, profile.cumulative.count - 1)]
            if exit - entry >= 20, peak > 0 {
                let radius = (1.0 / peak) * generalizationMargin
                // Yol sınıfı → dever. Otoyol virajı deverlidir ve daha yüksek
                // hız taşır; bunu yok saymak 120'lik yolda 86 demeye yol açıyordu.
                let context = contextRadius(around: peakIndex, in: k)
                let roadClass = RoadClass.from(contextRadius: context)
                let v = SpeedModel.safeSpeed(radius: radius, condition: condition,
                                             mode: mode, stabilityFactor: stabilityFactor,
                                             ssf: ssf,
                                             superelevation: roadClass.superelevation)

                // Yol tutuşunun bittiği hız — tavsiyeden ayrı hesaplanır ve
                // kritik uyarıda sürücüye gösterilir.
                let limit = SpeedModel.limitSpeed(radius: radius, condition: condition,
                                                  ssf: ssf,
                                                  superelevation: roadClass.superelevation)

                // "Bu viraj anlamlı mı" testi MODDAN BAĞIMSIZ yapılır.
                //
                // DÜZELTİLEN HATA: test, moda göre ayarlanmış `v` üzerinden
                // yapılıyordu. Agresif mod tavsiye hızı sınırın %92'sine
                // çıkarınca R=200'lük bir viraj 106 km/s alıyor, 95 km/s'lik
                // ilgi eşiğini aşıyor ve viraj listeden TAMAMEN düşüyordu.
                // Yani agresif sürücü — virajı önceden bilmeyi en çok isteyen
                // kullanıcı — virajların çoğu için hiç uyarı almayacaktı.
                //
                // Virajın var olup olmadığı sürüş tarzına bağlı değildir.
                // Hangi virajlar ANLATILIR sorusu normal modun gözüyle,
                // o virajda KAÇ KM/S sorusu kullanıcının moduyla cevaplanır.
                let vNeutral = SpeedModel.safeSpeed(radius: radius, condition: condition,
                                                    mode: .normal, stabilityFactor: stabilityFactor,
                                                    ssf: ssf,
                                                    superelevation: roadClass.superelevation)
                let designSpeed = SpeedModel.safeSpeed(radius: max(context, radius),
                                                       condition: condition, mode: .normal,
                                                       stabilityFactor: stabilityFactor,
                                                       ssf: ssf,
                                                       superelevation: roadClass.superelevation)
                let isInteresting = vNeutral <= maxInterestingSafeSpeed
                    && (vNeutral < absoluteInterestSpeed
                        || vNeutral < designSpeed * relativeInterestRatio)

                if isInteresting {
                    out.append(Curve(
                        coordinate: profile.coordinate(at: peakIndex),
                        entryDistance: entry,
                        apexDistance: profile.cumulative[min(peakIndex, profile.cumulative.count - 1)],
                        exitDistance: exit,
                        radius: radius,
                        direction: sign > 0 ? .right : .left,
                        safeSpeedKmh: v,
                        limitSpeedKmh: limit,
                        severity: Curve.Severity.from(safeSpeed: v),
                        roadClass: roadClass))
                }
            }
            i = max(j, i + 1)
        }

        return mergeAdjacent(out)
    }

    // ------------------------------------------------------------------------
    // MARK: Manevra ile çakışan virajları ayıkla
    // ------------------------------------------------------------------------
    //
    // Şehir içinde her kavşak dönüşü geometrik olarak 15–25 m yarıçaplı bir
    // "viraj"dır ve model haklı olarak 25–30 km/s tavsiye eder. Ama bu dönüş
    // ZATEN navigasyon manevrasıdır: "200 metre sonra sağa dönün" anonsu
    // yapılmıştır. Üstüne bir de "keskin sağ viraj, hızını 26'ya düşür" demek
    // aynı olayı iki kez duyurmaktır — sürücü bunu gürültü olarak algılar ve
    // asıl önemli viraj uyarılarını da dinlemeyi bırakır.
    //
    // Bu yüzden apeksi bir manevra noktasına 45 m'den yakın olan virajlar
    // listeden çıkarılır. Sapak yönlü sesi ve şeridi zaten yönlendirmeyi yapar.
    //
    // 45 m eşiği: tipik bir kavşak dönüşünün yay uzunluğu 20–40 m'dir; daha
    // geniş bir eşik, kavşaktan hemen sonra gelen GERÇEK virajı da yutardı.
    static func removeManeuverCurves(_ curves: [Curve], route: MKRoute) -> [Curve] {
        // Manevra noktalarının rota üzerindeki mesafeleri
        var maneuverAt: [Double] = []
        var acc: Double = 0
        for step in route.steps {
            acc += step.distance
            maneuverAt.append(acc)
        }
        guard !maneuverAt.isEmpty else { return curves }

        return curves.filter { curve in
            !maneuverAt.contains { abs($0 - curve.apexDistance) < 45 }
        }
    }

    /// Kısayol: polyline → virajlar.
    static func detectCurves(in polyline: MKPolyline,
                             condition: RoadCondition = .dry,
                             mode: DrivingMode = .normal,
                             stabilityFactor: Double = 1.0) -> [Curve] {
        curves(from: profile(of: polyline), condition: condition,
               mode: mode, stabilityFactor: stabilityFactor)
    }

    /// Virajın çevresindeki tipik yarıçap — yol sınıfı göstergesi.
    ///
    /// ±1 km (±100 örnek) penceredeki eğriliklerin 70. YÜZDELİĞİNİN tersi
    /// alınır. Neden ortalama değil yüzdelik: ortalamayı tek bir keskin viraj
    /// aşağı çeker ve otoyolu "dar yol" gibi gösterirdi. Neden 70. yüzdelik:
    /// yolun rahat kesimlerini temsil eder ama tamamen düz parçaların (κ≈0,
    /// R→∞) egemenliğine de girmez.
    ///
    /// Virajın kendi bölgesi pencereden ÇIKARILIR — yoksa her viraj kendi
    /// darlığıyla kendini "şehir içi" ilan ederdi.
    private static func contextRadius(around index: Int, in curvature: [Double]) -> Double {
        let span = 100                                   // ±100 örnek ≈ ±1 km
        let exclude = 8                                  // virajın kendi çevresi ≈ ±80 m
        let lo = max(0, index - span), hi = min(curvature.count - 1, index + span)
        guard hi > lo else { return 0 }

        var samples: [Double] = []
        samples.reserveCapacity(hi - lo)
        for i in lo...hi where abs(i - index) > exclude {
            samples.append(abs(curvature[i]))
        }
        guard samples.count > 10 else { return 0 }

        samples.sort()
        let k = samples[Int(Double(samples.count - 1) * 0.70)]
        return k > 1e-6 ? 1.0 / k : 5000                 // κ≈0 → pratikte düz
    }

    // MARK: - Yardımcılar

    /// ② Kayan ortalama ile konum düzleştirme.
    /// Uçlar pencereyi doldurmadığı için olduğu gibi bırakılır — kısaltmak
    /// rotanın başını/sonunu kaybettirir.
    private static func movingAverage(_ pts: [MKMapPoint], window: Int) -> [MKMapPoint] {
        guard window > 1, pts.count > window else { return pts }
        let half = window / 2
        var out = pts
        for i in half..<(pts.count - half) {
            var sx = 0.0, sy = 0.0
            for j in (i - half)...(i + half) { sx += pts[j].x; sy += pts[j].y }
            let n = Double(window)
            out[i] = MKMapPoint(x: sx / n, y: sy / n)
        }
        return out
    }

    /// ③ İşaretli eğrilik: κ = Δθ / Δs.
    /// İşaret dönüş yönünü taşır (+ sağ, − sol) — hem S virajı ayrımı hem de
    /// sesli uyarının stereo yönü için gerekli.
    private static func signedCurvature(_ pts: [MKMapPoint], cumulative: [Double]) -> [Double] {
        let n = pts.count
        var out = [Double](repeating: 0, count: n)
        guard n > 2 * curvatureHalfWindow else { return out }

        let w = curvatureHalfWindow
        for i in w..<(n - w) {
            let bIn  = GeoMath.planarBearing(from: pts[i - w], to: pts[i])
            let bOut = GeoMath.planarBearing(from: pts[i], to: pts[i + w])
            let dTheta = GeoMath.normalizeAngle(bOut - bIn) * .pi / 180   // radyan
            let ds = cumulative[i + w] - cumulative[i - w]
            out[i] = ds > 0.5 ? dTheta / (ds / 2) : 0
            // ds/2 : dTheta, merkezi noktanın iki yanındaki kirişler arasında
            // ölçüldüğü için etkin yay uzunluğu pencerenin yarısıdır.
        }
        // Uçları komşusundan doldur
        for i in 0..<w { out[i] = out[w] }
        for i in (n - w)..<n { out[i] = out[n - w - 1] }
        return out
    }

    /// Birbirine 40 m'den yakın, aynı yönlü virajları tek yapıda birleştirir.
    /// Aksi hâlde uzun bir kavis, art arda 3–4 uyarı üretir.
    private static func mergeAdjacent(_ curves: [Curve]) -> [Curve] {
        guard curves.count > 1 else { return curves }
        var out: [Curve] = []
        var current = curves[0]

        for next in curves.dropFirst() {
            let gap = next.entryDistance - current.exitDistance
            if gap < 40, next.direction == current.direction {
                // En kısıtlayıcı (en yavaş) olanı temsilci al
                let tighter = next.safeSpeedKmh < current.safeSpeedKmh ? next : current
                current = Curve(coordinate: tighter.coordinate,
                                entryDistance: current.entryDistance,
                                apexDistance: tighter.apexDistance,
                                exitDistance: next.exitDistance,
                                radius: tighter.radius,
                                direction: current.direction,
                                safeSpeedKmh: tighter.safeSpeedKmh,
                                limitSpeedKmh: tighter.limitSpeedKmh,
                                severity: tighter.severity,
                                roadClass: tighter.roadClass)
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }

    // MARK: - Rota geneli güvenlik ölçüsü

    /// Rotanın "virajlılık" göstergesi: kilometre başına ağırlıklı viraj yükü.
    /// Alternatif rotaları karşılaştırırken viraj SAYISI yanıltıcıdır (100 hafif
    /// viraj, 1 firketadan zararsızdır). Ağırlık, virajın hız kaybettirme
    /// gücünden gelir.
    static func curvinessIndex(curves: [Curve], routeLengthMeters: Double) -> Double {
        guard routeLengthMeters > 0 else { return 0 }
        let load = curves.reduce(0.0) { acc, c in
            // 90 km/s referansına göre hız kaybı, virajın uzunluğuyla ölçekli
            let deficit = max(0, 90 - c.safeSpeedKmh) / 90
            return acc + deficit * deficit * max(c.length, 20)
        }
        return load / (routeLengthMeters / 1000)
    }
}
