import Foundation

// ============================================================================
// MARK: - Viraj Güvenli Hız Modeli
// ============================================================================
//
// ÖZET
// ----
// Bu dosya "bu virajda kaç km/s?" sorusunu, karayolu mühendisliğinin viraj
// tasarımında kullandığı denklemi TERSİNE çözerek yanıtlar. Yani virajın
// yarıçapından, o virajın hangi hız için inşa edilmiş olabileceğini bulur —
// karayollarındaki sarı "tavsiye hız" levhalarının dayandığı mantığın aynısı.
//
// ---------------------------------------------------------------------------
// 1) TEMEL DENKLEM
// ---------------------------------------------------------------------------
// Yarıçapı R olan bir virajı v hızıyla dönen araca etki eden merkezcik ivmesi:
//
//                        a_c = v² / R
//
// Bu ivmeyi karşılayan iki kuvvet var: yolun enine eğimi (dever, e) ve
// lastik–asfalt arasındaki yanal sürtünme (f). Nokta-kütle modelinde
// (AASHTO Green Book, Bölüm 3 — "Horizontal Alignment"):
//
//                     v² / (g·R) = e + f
//
// v'yi m/s yerine km/s cinsinden (V) yazarsak, v = V/3.6 ve g = 9.81 m/s²:
//
//                V² / (3.6² · 9.81 · R) = e + f
//
//                ┌────────────────────────────────┐
//                │      R = V² / (127 · (e + f))  │   ← "viraj denklemi"
//                │  ⇔   V = √(127 · R · (e + f))  │
//                └────────────────────────────────┘
//
//        127 ≈ 3.6² × 9.81 = 127.14   (birim dönüşüm sabiti)
//
// Bu denklem AASHTO "A Policy on Geometric Design of Highways and Streets"
// (Green Book) Eşitlik 3-8'dir; Türkiye'de KGM "Karayolu Tasarım El Kitabı" ve
// TS 7249 aynı bağıntıyı kullanır.
//
// ---------------------------------------------------------------------------
// 2) f NEDEN SABİT DEĞİL — ESKİ MODELİN HATASI
// ---------------------------------------------------------------------------
// Projenin önceki hâli f + e yerine SABİT 0.20 kullanıyordu. Oysa tasarımda
// kullanılan yanal sürtünme katsayısı, lastiğin fiziksel tutuş sınırı DEĞİL,
// sürücünün rahatsız olmadan katlanabildiği yanal ivme eşiğidir — ve bu eşik
// hız arttıkça DÜŞER (yüksek hızda aynı yanal ivme çok daha ürkütücüdür).
//
//   AASHTO Green Book, Tablo 3-7 — viraj tasarımı için maksimum f:
//
//        Hız (km/s)   30    40    50    60    70    80    90   100   110   120   130
//        f          0.28  0.23  0.19  0.17  0.15  0.14  0.13  0.12  0.11  0.09  0.08
//
// Sabit 0.20 kullanmanın somut sonucu (e = 0 varsayımıyla):
//
//        R = 400 m  →  eski model 101 km/s   |  bu model  84 km/s
//        R =  30 m  →  eski model  28 km/s   |  bu model  32 km/s
//
// Yani eski model, en tehlikeli yerde — yüksek hızlı geniş virajda — 17 km/s
// FAZLA hız öneriyordu; buna karşılık dar dönüşlerde gereksiz yere yavaşlatıp
// kullanıcıyı uyarı körlüğüne itiyordu. İkisi de yanlış yönde hata.
//
// Not: f hıza bağlı olduğu ve biz hızı ARADIĞIMIZ için denklem kapalı formda
// çözülmez. Sabit nokta iterasyonu kullanıyoruz; 3–4 adımda 0.1 km/s altına
// yakınsar (aşağıda `safeSpeed`).
//
// ---------------------------------------------------------------------------
// 3) DEVER (e) VARSAYIMI
// ---------------------------------------------------------------------------
// Apple Haritalar bize yolun enine eğimini vermiyor. Bilinmeyen bir yol için
// e = 0 (deversiz) varsaymak DAİMA güvenli taraftır:
//   • Yol gerçekten deverliyse → gerçek güvenli hız bizim dediğimizden yüksek
//     olur, biz sadece temkinli kalmış oluruz.
//   • Ters varsayım (dever var demek, aslında yoksa) → fazla hız önerisi, yani
//     doğrudan tehlike.
// Ayrıca asfaltın drenaj için verilen %2 sırt eğimi, virajın dış şeridinde
// TERS dever gibi davranır. Bu yüzden varsayılan `assumedSuperelevation = 0`.
//
// ---------------------------------------------------------------------------
// 4) HAVA / ZEMİN — SÜRTÜNME ÇEMBERİ
// ---------------------------------------------------------------------------
// Tablodaki f değerleri konfor kaynaklıdır ve kuru/ıslak asfaltta mevcut
// tutuşun (µ ≈ 0.8 kuru, ≈ 0.45 ıslak) çok altındadır — yani normal şartlarda
// zaten geniş bir emniyet payı vardır. Ancak karda/buzda mevcut tutuş
// (µ ≈ 0.20 / 0.10) konfor eşiğinin ALTINA düşer; orada sınırı belirleyen artık
// konfor değil, fiziktir.
//
// Bu yüzden iki sınırın küçüğünü alıyoruz:
//
//        f_etkin = min( f_konfor × havaFaktörü , µ_mevcut × lateralPay )
//
// `lateralPay = 0.6`: Kamm/sürtünme çemberi gereği tutuşun tamamı yanal
// kuvvete harcanamaz — fren ve direksiyon düzeltmesi için pay bırakılmalıdır.
//
// ---------------------------------------------------------------------------
// 5) UYARI MESAFESİ — "ÖNCEDEN" GERÇEKTEN ÖNCEDEN OLSUN
// ---------------------------------------------------------------------------
// Eski kod virajı SABİT 300 m kala haber veriyordu. 130 km/s'te 300 m = 8.3 sn;
// algı-reaksiyon payı düşünce fren için 5 sn kalıyor — 130'dan 60'a inmek için
// yeterli değil. Uyarı, en gerekli olduğu anda en geç geliyordu.
//
// Doğrusu klasik yavaşlama denklemidir:
//
//        d = v · t_algı-reaksiyon  +  (v² − v_güvenli²) / (2 · a)
//            └── reaksiyon yolu ─┘   └──── fren/yavaşlama yolu ────┘
//
//   t_algı-reaksiyon : AASHTO durma görüş mesafesinde 2.5 sn kullanır
//                      (beklenmedik olay). Bizimki HABER VERİLMİŞ bir olay
//                      olduğu için modda göre 1.5–2.5 sn alıyoruz.
//   a                : AASHTO 3.4 m/s²'yi "sürücülerin %90'ının ıslak zeminde
//                      rahatça uygulayabildiği yavaşlama" olarak tanımlar.
//                      Bu bizim KRİTİK eşiğimiz. Konforlu (planlı) yavaşlama
//                      için 1.2–2.4 m/s² kullanıyoruz.
//
// 130 → 60 km/s, Normal mod (t=2.0 sn, a=1.8 m/s²):
//        v = 36.1 m/s, v_s = 16.7 m/s
//        d = 36.1×2.0 + (36.1² − 16.7²)/(2×1.8) = 72 + 285 = 357 m
// Yani 130'da giden birine viraj **~360 m** kala söylemek gerekir; 300 m sabit
// eşik geç kalıyordu. 50 km/s'te aynı hesap ~55 m verir — düşük hızda gereksiz
// erken bağırmaz. Uyarı mesafesinin hıza bağlı olmasının anlamı budur.
// ============================================================================

// MARK: - Zemin / hava koşulu

enum RoadCondition: String, Codable, CaseIterable {
    case dry        = "Kuru"
    case wet        = "Islak"
    case heavyRain  = "Şiddetli Yağmur"
    case snow       = "Karlı"
    case ice        = "Buzlu"

    /// Konfor kaynaklı f'ye uygulanan çarpan.
    var comfortFactor: Double {
        switch self {
        case .dry:       return 1.00
        case .wet:       return 0.90
        case .heavyRain: return 0.80
        case .snow:      return 0.65
        case .ice:       return 0.45
        }
    }

    /// Zeminde fiilen mevcut olan TİPİK tepe sürtünme katsayısı (µ), iyi lastik.
    var availableFriction: Double {
        switch self {
        case .dry:       return 0.80
        case .wet:       return 0.45
        case .heavyRain: return 0.35
        case .snow:      return 0.22
        case .ice:       return 0.12
        }
    }

    /// MUHAFAZAKÂR (düşük yüzdelik) tepe sürtünme katsayısı — kaza sınırı için.
    ///
    /// `availableFriction` TİPİK bir değerdir: iyi lastik, temiz ve ısınmış
    /// asfalt. Kaza sınırı hesaplanırken tipik değeri kullanmak ölümcül bir
    /// hatadır, çünkü sınır YUKARIDAN tahmin edilmiş olur — sürücüye
    /// gerçekte olmayan bir pay vaat eder.
    ///
    /// Bu değerler yolun BEKLENENDEN KÖTÜ çıktığı hâli temsil eder: yarı
    /// aşınmış lastik, cilalanmış veya tozlu asfalt, soğuk lastik, yamalı
    /// zemin. Sınırı alttan tahmin etmek yalnızca temkinli olmaya yol açar;
    /// üstten tahmin etmek yoldan çıkmaya.
    var limitFriction: Double {
        switch self {
        case .dry:       return 0.65
        case .wet:       return 0.35
        case .heavyRain: return 0.25
        case .snow:      return 0.15
        case .ice:       return 0.08
        }
    }

    /// Tavsiye hızın kaza sınırına göre çıkabileceği EN YÜKSEK pay.
    ///
    /// Agresif mod kuru asfaltta sınırın %92'sine kadar çıkabilir. Karda aynı
    /// ayrıcalığı vermek iki nedenle yanlış olurdu:
    ///
    ///   • TAHMİN ORADA DAHA ZAYIF. Zemini ölçmüyoruz, havadan çıkarıyoruz.
    ///     Kuru asfaltın µ'sü dar bir aralıkta; karın µ'sü 0.10 ile 0.30
    ///     arasında oynar (yeni kar, sıkışmış kar, ıslak kar). Sınıra yakın
    ///     bir tavsiye, en belirsiz olduğumuz yerde en cesur olmak demektir.
    ///   • HATANIN BEDELİ ORADA BÜYÜK. Kuru asfaltta tutuşu aşmak genelde
    ///     düzeltilebilir bir kaymadır; buzda düzeltme şansı yoktur.
    ///
    /// Bu tavan sayesinde agresif mod karda/buzda kendiliğinden normale iner —
    /// kullanıcı modu değiştirmese bile. Fizik sürüş tarzıyla pazarlık etmez.
    var maxAdvisoryShare: Double {
        switch self {
        case .dry:       return 0.92
        case .wet:       return 0.85
        case .heavyRain: return 0.80
        case .snow:      return 0.75
        case .ice:       return 0.70
        }
    }

    /// Boyuna (fren) yavaşlamaya uygulanan çarpan — uyarı mesafesi hesabında.
    var brakingFactor: Double {
        switch self {
        case .dry:       return 1.00
        case .wet:       return 0.85
        case .heavyRain: return 0.70
        case .snow:      return 0.50
        case .ice:       return 0.30
        }
    }

    var icon: String {
        switch self {
        case .dry:       return "sun.max.fill"
        case .wet:       return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .snow:      return "snowflake"
        case .ice:       return "thermometer.snowflake"
        }
    }
}

// MARK: - Sürüş modu parametreleri

extension DrivingMode {
    /// Algı–reaksiyon süresi (sn). AASHTO durma görüş mesafesi 2.5 sn kullanır;
    /// bizimki önceden haber verilmiş bir manevra olduğu için biraz kısadır.
    var perceptionReactionTime: Double {
        switch self {
        case .calm:       return 2.5
        case .normal:     return 2.0
        case .aggressive: return 1.5
        }
    }

    /// Planlı, konforlu yavaşlama ivmesi (m/s²). Yolcuyu rahatsız etmeyen
    /// aralık literatürde 1.0–2.5 m/s² olarak geçer.
    var comfortableDeceleration: Double {
        switch self {
        case .calm:       return 1.2
        case .normal:     return 1.8
        case .aggressive: return 2.4
        }
    }

    /// Konfor modeline uygulanan kişisel pay (yalnızca sakin/normal).
    var speedMargin: Double {
        switch self {
        case .calm:       return 0.88
        case .normal:     return 1.00
        case .aggressive: return 1.08
        }
    }

    // ------------------------------------------------------------------------
    // MODLAR ARTIK SINIRA GÖRE TANIMLI
    // ------------------------------------------------------------------------
    // ESKİ HÂLİ: mod, tavsiye hızı yalnızca ±%8–12 oynatıyordu (R=100 kuruda
    // 44 / 49 / 53). Üç mod arasındaki toplam fark 9 km/s, kaza sınırı ise 82.
    // Yani "sürüş modu" aslında hızı değil UYARI ZAMANLAMASINI ayarlıyordu;
    // agresif seçen sürücü, virajı daha seri alma imkânı değil yalnızca daha
    // geç bir uyarı alıyordu. Modun adı yaptığı işi anlatmıyordu.
    //
    // YENİ HÂLİ: her mod, tavsiye hızını KAZA SINIRINA GÖRE bir payla tanımlar.
    //
    //     Sakin   → sınırın %60'ı   savrulma belirgin az, ama sürüş akıyor
    //     Normal  → sınırın %70'i   mühendislik tavsiyesi
    //     Agresif → sınırın %92'si  sınırın hemen altı, seri viraj alma
    //
    // R = 100 m kuru asfaltta: 44 / 49 / 75 km/s → 0.15 / 0.19 / 0.44 g yanal.
    // Agresifin 0.44 g'si, iyi lastiğin gerçek sınırının (~0.85 g) yarısı
    // civarıdır — çünkü `limitSpeed` zaten muhafazakâr kurulmuştur.
    var advisoryShare: Double {
        switch self {
        case .calm:       return 0.60
        case .normal:     return 0.70
        case .aggressive: return 0.92
        }
    }

    /// Kırmızı uyarının sınıra göre tavanı. Tavsiye payı yükseldikçe bu da
    /// yükselmek zorunda, yoksa kırmızı tavsiyenin ALTINA düşerdi.
    var criticalShare: Double {
        switch self {
        case .calm:       return 0.80
        case .normal:     return 0.90
        case .aggressive: return 0.97
        }
    }

    /// Konfor tavanı uygulanmasın mı?
    ///
    /// Konfor modeli (AASHTO f) sürücünün RAHATSIZ OLMADAN katlanabildiği
    /// yanal ivmedir. Agresif modu seçen sürücü tam olarak bundan feragat
    /// ediyor; konfor tavanını ona uygulamak, istediği şeyi vermemek olurdu
    /// (kuruda 53'te kalırdı, 75 değil).
    var ignoresComfortCeiling: Bool { self == .aggressive }

    var aciklama: String {
        switch self {
        case .calm:       return "Temkinli — sınırın %60'ı, erken ve bol uyarı"
        case .normal:     return "Dengeli — mühendislik tavsiye hızı"
        case .aggressive: return "Deneyimli — sınırın hemen altı, dar uyarı bandı"
        }
    }
}

// MARK: - Model

enum SpeedModel {

    /// Birim dönüşüm sabiti: 3.6² × 9.81
    static let K = 127.14

    /// AASHTO'nun sert fren referansı (m/s²) — kritik uyarı eşiğinde kullanılır.
    static let aashtoDeceleration = 3.4

    /// Sürtünme çemberi gereği yanal kuvvete ayrılabilen tutuş oranı.
    static let lateralGripShare = 0.60

    /// Bilinmeyen yol için dever varsayımı. 0 = deversiz (güvenli taraf).
    static var assumedSuperelevation: Double = 0.0

    // MARK: - Yanal sürtünme katsayısı

    /// AASHTO Green Book Tablo 3-7 — tasarım hızına karşılık maksimum f.
    /// Ara değerler doğrusal enterpolasyonla bulunur.
    private static let frictionTable: [(speed: Double, f: Double)] = [
        (20, 0.35), (30, 0.28), (40, 0.23), (50, 0.19), (60, 0.17),
        (70, 0.15), (80, 0.14), (90, 0.13), (100, 0.12), (110, 0.11),
        (120, 0.09), (130, 0.08)
    ]

    static func sideFriction(atSpeed kmh: Double) -> Double {
        guard let first = frictionTable.first, let last = frictionTable.last else { return 0.15 }
        if kmh <= first.speed { return first.f }
        if kmh >= last.speed { return last.f }
        for i in 0..<(frictionTable.count - 1) {
            let a = frictionTable[i], b = frictionTable[i + 1]
            if kmh >= a.speed && kmh <= b.speed {
                let t = (kmh - a.speed) / (b.speed - a.speed)
                return a.f + t * (b.f - a.f)
            }
        }
        return last.f
    }

    // MARK: - Güvenli viraj hızı

    /// Verilen yarıçap için tavsiye edilen viraj hızı (km/s).
    ///
    /// V = √(127 · R · (e + f(V))) denklemi f hıza bağlı olduğu için kapalı
    /// formda çözülmez; sabit nokta iterasyonuyla çözülür. Fonksiyon monoton ve
    /// büzüşen olduğu için birkaç adımda yakınsar.
    ///
    /// - Parameters:
    ///   - radius: viraj yarıçapı (m)
    ///   - condition: zemin durumu
    ///   - mode: sürüş modu (kişisel pay)
    ///   - superelevation: dever oranı (m/m); nil → `assumedSuperelevation`
    // ========================================================================
    // MARK: - Kaza Sınırı (yol tutuşunun bittiği hız)
    // ========================================================================
    //
    // DÜZELTİLEN HATA — UYGULAMANIN UÇURUMDAN HABERİ YOKTU
    // ----------------------------------------------------
    // Model yalnızca KONFOR hızını biliyordu. Kırmızı uyarı, o konfor hızının
    // sabit 1.25 katıydı. Konfor eşiği ile fiziksel sınır arasındaki mesafe ise
    // zemine göre uçurum kadar değişir: kuru asfaltta çok geniş, karda yok.
    // Sabit bir katsayının her zeminde sınırın altında kalması için hiçbir
    // sebep yoktu — ve kalmıyordu:
    //
    //   R = 100 m, sedan, 15 zemin×mod bileşiminin 9'unda KIRMIZI UYARI,
    //   yol tutuşunun bittiği hızdan SONRA geliyordu.
    //
    //     Karlı, Normal:  tavsiye 41 · kırmızı 51 · sınır ≈ 39
    //                     → 41'de zaten sınırdasın, uygulama "güvenli" diyor;
    //                       51'e kadar da "riskli" demiyor.
    //     Buzlu, Normal:  tavsiye 30 · kırmızı 38 · sınır ≈ 29
    //     Islak, Agresif: tavsiye 52 · kırmızı 65 · sınır ≈ 60
    //
    // Yani TAVSİYE HIZIN KENDİSİ sınırın üstündeydi. Uyarının geç kalması
    // ikincil sorun; asıl sorun tavsiyenin kendisiydi.
    //
    // ÇÖZÜM — İKİ AYRI SORU, İKİ AYRI HESAP
    // -------------------------------------
    //   `safeSpeed`  : "bu virajı rahat ve güvenli nasıl dönerim"  (konfor)
    //   `limitSpeed` : "bu virajda yol tutuşu nerede biter"        (fizik)
    //
    // ve aralarında iki değişmez kural:
    //   ① tavsiye  ≤ sınır × mod payı × zemin tavanı
    //   ② kırmızı  ≤ sınır × modun kırmızı payı  — uyarı daima sınırdan önce
    //
    // Modun kendisi bu paylarla TANIMLIDIR (sakin %60, normal %70, agresif
    // %92); zemin tavanı ise düşük tutuşta agresif ayrıcalığını kendiliğinden
    // geri alır. Karda üç mod da neredeyse aynı sonucu verir — fizik sürüş
    // tarzıyla pazarlık etmez.
    //
    // SINIR NEDEN "MUHAFAZAKÂR"
    // -------------------------
    // Sınır ALTTAN tahmin edilir; üstten tahmin edilen bir sınır, olmayan bir
    // pay vaat eder. Üç ayrı temkin uygulanır:
    //   • µ tipik değil düşük yüzdelik (`limitFriction`) — aşınmış lastik,
    //     cilalı/tozlu asfalt
    //   • ×0.90 dinamik pay — yük transferi, lastiğin yük duyarlılığı, virajın
    //     sabit hızda dönülmemesi (fren/gaz düzeltmesi)
    //   • ×0.90 yarıçap belirsizliği — MKRoute polyline'ı genelleştirilmiştir,
    //     gerçek apeks yarıçapı daha küçük olabilir
    //
    // Sahadan gelen doğrulama: kullanıcı bir virajda 65 km/s ile kaydı.
    // Bu, R ≈ 60 m kuru VEYA R ≈ 100 m ıslak bileşimine karşılık gelir — yani
    // yarıçap ya da zemin sanılandan kötüydü. İkisi de bizim ölçemediğimiz
    // şeyler; bu yüzden sınır kesin bir sayı gibi DEĞİL, yaklaşık sunulur.

    /// Sınır hesabında kullanılan temkin payları.
    ///
    /// NOT: Tavsiye ve kırmızı payları BURADA DEĞİL. Onlar moda göre değiştiği
    /// için `DrivingMode.advisoryShare` / `.criticalShare`de, zemin tavanı ise
    /// `RoadCondition.maxAdvisoryShare`da. Buraya sabit olarak konsalardı mod
    /// tanımı iki yere bölünmüş olurdu.
    enum Limit {
        /// Yük transferi + lastik yük duyarlılığı + sabit olmayan viraj alma.
        static let dynamicPenalty = 0.90
        /// Polyline genelleştirmesinden gelen yarıçap belirsizliği.
        static let radiusUncertainty = 0.90
    }

    /// Yol tutuşunun bittiği hız (km/s) — muhafazakâr tahmin.
    ///
    /// İki mekanizmanın önce geleni belirleyicidir:
    ///   • KAYMA    — yanal ivme mevcut sürtünmeyi aşar
    ///   • DEVRİLME — yanal ivme SSF'yi aşar (uzun/yüklü araçta öne geçebilir)
    ///
    /// - Parameter ssf: Statik devrilme faktörü (T/2H). Sedan ≈ 1.40,
    ///   SUV ≈ 1.12, yüklü panelvan ≈ 0.98.
    static func limitSpeed(radius: Double,
                           condition: RoadCondition = .dry,
                           ssf: Double = 1.40,
                           superelevation: Double? = nil) -> Double {
        guard radius.isFinite, radius > 0 else { return 130 }
        let e = superelevation ?? assumedSuperelevation

        let mu = condition.limitFriction * Limit.dynamicPenalty
        // Kayma mı devrilme mi — hangisi önce geliyorsa sınır odur.
        let lateralCap = min(mu + e, ssf)
        let effectiveRadius = radius * Limit.radiusUncertainty

        return (K * effectiveRadius * max(0.01, lateralCap)).squareRoot()
    }

    static func safeSpeed(radius: Double,
                          condition: RoadCondition = .dry,
                          mode: DrivingMode = .normal,
                          stabilityFactor: Double = 1.0,
                          ssf: Double = 1.40,
                          superelevation: Double? = nil) -> Double {
        guard radius.isFinite, radius > 0 else { return 130 }

        let e = superelevation ?? assumedSuperelevation
        // Fizik tavanı: mevcut tutuşun yanal kuvvete ayrılabilen kısmı
        let frictionCeiling = condition.availableFriction * lateralGripShare

        var v = 60.0                      // başlangıç tahmini
        for _ in 0..<8 {
            let fComfort = sideFriction(atSpeed: v) * condition.comfortFactor
            let f = min(fComfort, frictionCeiling)
            let next = (K * radius * max(0.01, e + f)).squareRoot()
            if abs(next - v) < 0.1 { v = next; break }
            v = next
        }

        v *= mode.speedMargin
        // Araç stabilite payı (SSF tabanlı, 0.80–1.05 ile sınırlı)
        v *= min(1.05, max(0.80, stabilityFactor))

        // DEĞİŞMEZ KURAL ①: tavsiye, kaza sınırının moda göre belirlenen
        // payını asla aşmaz. Pay hem moddan hem ZEMİNDEN gelir; zemin tavanı
        // düşük tutuşta agresif ayrıcalığını kendiliğinden geri alır.
        let limit = limitSpeed(radius: radius, condition: condition,
                               ssf: ssf, superelevation: e)
        let share = min(mode.advisoryShare, condition.maxAdvisoryShare)
        let byLimit = limit * share

        // Agresif modda konfor tavanı UYGULANMAZ — sürücü zaten ondan feragat
        // ediyor. Diğer modlarda ikisinin küçüğü alınır.
        v = mode.ignoresComfortCeiling ? byLimit : min(v, byLimit)

        // 15 km/s altı öneri anlamsız (park manevrası); 130 üstü zaten serbest
        // sürüş bölgesi, viraj kısıtı değil.
        return min(max(v.rounded(), 15), 130)
    }

    /// Ters yön: bu hızda güvenle dönülebilen minimum yarıçap (m).
    /// Hız limiti verisi olmadığı için "bu viraj bu hıza uygun mu?" kontrolünde
    /// ve test amaçlı kullanılır.
    static func minimumRadius(forSpeed kmh: Double,
                              condition: RoadCondition = .dry,
                              superelevation: Double? = nil) -> Double {
        let e = superelevation ?? assumedSuperelevation
        let f = min(sideFriction(atSpeed: kmh) * condition.comfortFactor,
                    condition.availableFriction * lateralGripShare)
        return (kmh * kmh) / (K * max(0.01, e + f))
    }

    /// Belirli bir hızda o virajda oluşacak yanal ivme (g cinsinden).
    /// Gösterge rengi ve sürüş skoru için ham fiziksel ölçü.
    static func lateralG(speedKmh: Double, radius: Double) -> Double {
        guard radius > 0 else { return 0 }
        let v = speedKmh / 3.6
        return (v * v / radius) / 9.81
    }

    // ========================================================================
    // MARK: - Oran Ölçeği (TEK KAYNAK)
    // ========================================================================
    //
    // DÜZELTİLEN HATA — GÖSTERGE TAVSİYESİNİ YALANLIYORDU
    // ---------------------------------------------------
    // Aynı soruya ("bu hız bu viraj için nasıl?") üç ayrı ölçek cevap veriyordu:
    //
    //   1. `safeSpeed`  × mode.speedMargin      → sesli söylenen hedef hız
    //   2. `GaugeColor` × mode.toleranceRatio   → göstergenin halka rengi
    //   3. `risk()`     sabit 1.05 / 1.25       → çevresel aura + Dinamik Ada
    //
    // (1) modu ZATEN hesaba katıyordu; (2) modu İKİNCİ KEZ uyguluyordu. Sakin ve
    // Normal modda `toleranceRatio` 1'in altında olduğu için kırmızı eşiği,
    // uygulamanın az önce tavsiye ettiği hızın ALTINA düşüyordu:
    //
    //   R = 100 m, Normal mod, kuru zemin
    //     • uygulama sesli olarak "Tavsiye edilen hız 49" diyor
    //     • sürücü 49'a uyuyor
    //     • gösterge 47'den itibaren KIRMIZI — "Tehlikeli"
    //     • aynı anda çevresel aura "Güvenli" diyor            ← açık çelişki
    //
    //   Sakin modda daha kötü: söylenen 44, kırmızı 37'de başlıyordu.
    //
    // Yan etkisi skora da yansıyordu: `GaugeColor.puan` kırmızıya 10 puan verir,
    // yani yolculuk skoru sürücüyü UYGULAMANIN KENDİ TAVSİYESİNE UYDUĞU İÇİN
    // cezalandırıyordu.
    //
    // ÇÖZÜM
    // -----
    // Mod kişiselleştirmesi TEK YERDE kalır: `safeSpeed`. Agresif sürücü zaten
    // daha yüksek bir hedef alır (R=100'de 53 yerine 49), dolayısıyla aynı
    // fiziksel hızda oranı düşer ve yeşili daha uzun görür — kişiselleştirme
    // kaybolmaz, sadece iki kez uygulanmaz.
    //
    // Oran eşikleri artık aşağıdaki TEK ölçekten okunur; gösterge ile aura
    // yapısal olarak çelişemez.
    enum Ratio {
        /// Altında: virajın gerektirdiğinden belirgin yavaş.
        static let overlyCautious = 0.60
        /// Buraya kadar tavsiyeye uyulmuş sayılır (%5 pay ölçüm gürültüsü içindir).
        static let safeCeiling = 1.05
        static let warnCeiling = 1.15
        /// Üstünde: ciddi aşım.
        static let criticalFloor = 1.25
    }

    // ========================================================================
    // MARK: - Risk Durumu
    // ========================================================================
    //
    // Anlık hızın tavsiye hızına oranından türetilen dört durum. Gösterge
    // rengi, Dinamik Ada halkası ve çevresel aura hep bunu okur.
    //
    // NEDEN `.neutral` VAR
    // --------------------
    // Şehir içinde 15 km/s ile ilerlerken her hafif kavis için renk değiştiren
    // bir gösterge, sürücüyü uyarıya karşı körleştirir. İki durumda uyarı
    // mantığı devre dışı kalır:
    //   • hız 20 km/s altındaysa (trafik, park, dar sokak)
    //   • viraj yeterince genişse (tavsiye hız 100 km/s üstü) — kimseyi
    //     kısıtlamayan bir "viraj" için gösterge yakmanın anlamı yok
    //
    // EŞİKLER
    // -------
    // Tavsiye hız, kayma sınırı değil KONFOR sınırıdır ve gerçek tutuşun çok
    // altındadır (bkz. bölüm 4). Bu yüzden %5 aşım hâlâ güvenli, %25 aşım
    // "ciddi uyarı" sayılır. Eğer tavsiye hız kayma sınırı olsaydı bu eşikler
    // ölümcül olurdu — modelin tamamı bu ayrımın üstünde duruyor.
    // DÜZELTİLEN HATA — MERDİVENİN SON BASAMAĞI YOKTU
    // ------------------------------------------------
    // `critical` hem sınırın %90'ını hem %200'ünü kapsıyordu: yol tutuşunun
    // bitmesine az kalmışken de, çoktan kaymışken de aynı kelime ("TEHLİKE").
    //
    // Oysa bunlar aynı şey değil. Sınırın ALTINDA olan her şey bir RİSKTİR —
    // olabilir, olmayabilir. Sınırın ÜSTÜ risk değildir; modelin en iyi
    // tahminine göre yol tutuşu orada zaten bitmiştir. Riskin dili ("riskli",
    // "tehlikeli") o basamakta yanlış dildir ve sürücüye hâlâ pazarlık payı
    // varmış hissi verir.
    enum RiskStatus: Int, Comparable {
        case neutral  = 0   // beyaz   — kısıt yok
        case safe     = 1   // yeşil   — tavsiyeye uyuluyor
        case warning  = 2   // sarı    — pay yeniyor
        case critical = 3   // kırmızı — sınıra yaklaşıldı
        case exceeded = 4   // sınır aşıldı — tahmini tutuş bitti

        static func < (a: RiskStatus, b: RiskStatus) -> Bool { a.rawValue < b.rawValue }

        var etiket: String {
            switch self {
            case .neutral:  return "Serbest"
            case .safe:     return "Güvenli"
            case .warning:  return "Yavaşla"
            case .critical: return "TEHLİKE"
            case .exceeded: return "SINIR AŞILDI"
            }
        }
    }

    // ========================================================================
    // MARK: - Eşikler (mutlak hız karşılıkları)
    // ========================================================================
    //
    // Renk ve risk artık ORAN üzerinden değil, MUTLAK HIZ eşikleri üzerinden
    // hesaplanır. Sebep: eşiklerin kaza sınırıyla tavanlanabilmesi gerekiyor,
    // oran ölçeğinde bunu ifade etmek mümkün değil (sınır, tavsiyenin kaç katı
    // olduğu zemine göre değişir).
    //
    // Sıralama YAPISAL olarak korunur (her eşik bir üsttekiyle kırpılır), yani
    // "sarı > kırmızı" gibi bozuk bir durum oluşamaz.
    struct Thresholds {
        let cautious: Double   // altında  → beyaz (gereksiz temkinli)
        let safe: Double       // buraya kadar → yeşil
        let warn: Double       // buraya kadar → sarı
        let critical: Double   // buraya kadar → turuncu, üstü → kırmızı
        /// Yol tutuşunun bittiği tahmini hız — arayüzde gösterilir.
        let limit: Double
    }

    /// Tavsiye ve sınır hızından renk/risk eşiklerini üretir.
    ///
    /// DEĞİŞMEZ KURAL ②: `critical`, sınırın moda göre belirlenen payını asla
    /// aşamaz. Kırmızı, yoldan çıkmadan ÖNCE gelmek zorundadır.
    ///
    /// EŞİKLER NEDEN ORANTILI DA OLMALI
    /// --------------------------------
    /// Sabit çarpanlar (×1.05 / ×1.15 / ×1.25) pay genişken doğru çalışır ama
    /// pay daraldığında ÜST ÜSTE BİNER. Agresif modda tavsiye sınırın %92'si
    /// olduğu için tavsiye ile sınır arası yalnızca %8'dir; sabit çarpanlarla
    /// yeşil 79'da biterken kırmızı da 79'da başlıyor, yani sarı ve turuncu
    /// tamamen kayboluyordu — merdiven iki basamağa düşüyordu.
    ///
    /// Bu yüzden her eşik İKİ ŞEKİLDE sınırlanır ve küçüğü alınır:
    ///   • sabit çarpan       (pay genişken bağlar → normal/sakin değişmez)
    ///   • payın bir kesri    (pay darken bağlar → agresifte bant açılır)
    static func thresholds(safeSpeedKmh: Double,
                           limitSpeedKmh: Double,
                           mode: DrivingMode = .normal) -> Thresholds {
        let gap = max(0, limitSpeedKmh - safeSpeedKmh)

        let critical = min(safeSpeedKmh * Ratio.criticalFloor,
                           safeSpeedKmh + gap * 0.75,
                           limitSpeedKmh * mode.criticalShare)
        // Aşağı doğru kırparak sıralamayı garanti et — hiçbir eşik bir
        // üstekini geçemez, dolayısıyla "sarı > kırmızı" oluşamaz.
        let warn = min(safeSpeedKmh * Ratio.warnCeiling,
                       safeSpeedKmh + gap * 0.45, critical)
        let safe = min(safeSpeedKmh * Ratio.safeCeiling,
                       safeSpeedKmh + gap * 0.15, warn)
        let cautious = min(safeSpeedKmh * Ratio.overlyCautious, safe)

        return Thresholds(cautious: cautious, safe: safe, warn: warn,
                          critical: critical, limit: limitSpeedKmh)
    }

    static func risk(speedKmh: Double, thresholds t: Thresholds) -> RiskStatus {
        // Şehir içi sürünme hızında ve kimseyi kısıtlamayan geniş virajda
        // gösterge sessiz kalır (bkz. yukarıdaki `.neutral` gerekçesi).
        //
        // TEK İSTİSNA: sınır aşıldıysa susulmaz. 20 km/s eşiği "şehir içinde
        // gereksiz uyarma" içindir; buzda 15 km/s ile sınırı aşmak mümkündür
        // ve orada susmak sessizliğin en pahalı olduğu andır.
        if speedKmh >= t.limit, t.limit > 0 { return .exceeded }
        guard speedKmh >= 20, t.safe <= 100 * Ratio.safeCeiling else { return .neutral }
        switch speedKmh {
        case ..<t.safe:     return .safe
        case ..<t.critical: return .warning
        default:            return .critical
        }
    }

    // MARK: - Uyarı mesafesi

    enum WarningLevel: Int, Comparable {
        case none = 0
        case headsUp = 1     // "ileride keskin viraj var" — bilgilendirme
        case prepare = 2     // "hızını düşürmeye başla" — konforlu yavaşlama penceresi açıldı
        case critical = 3    // "şimdi frene bas" — sert fren gerekiyor

        static func < (a: WarningLevel, b: WarningLevel) -> Bool { a.rawValue < b.rawValue }
    }

    /// v_şimdi hızından v_hedef hızına inmek için gereken toplam yol (m).
    ///
    ///     d = v·t_reaksiyon + (v² − v_hedef²) / (2·a)
    ///
    /// Zaten hedefin altındaysak 0 döner.
    static func decelerationDistance(fromKmh v0: Double,
                                     toKmh v1: Double,
                                     reactionTime: Double,
                                     deceleration a: Double) -> Double {
        let vi = v0 / 3.6, vf = v1 / 3.6
        guard vi > vf, a > 0 else { return 0 }
        return vi * reactionTime + (vi * vi - vf * vf) / (2 * a)
    }

    /// Viraja `distance` metre kala, `speedKmh` hızla giden sürücü için uyarı
    /// seviyesi.
    ///
    /// Üç eşik:
    ///  • kritik  : AASHTO 3.4 m/s² (× zemin çarpanı) ile bile ancak yetişilir
    ///  • hazırlan: modun konforlu yavaşlamasıyla tam yetişilir
    ///  • bilgi   : hazırlan mesafesinin 1.8 katı — sürücü zihnen hazırlansın
    ///
    /// Ek olarak düşük hızlarda mesafe küçüldüğü için minimum 4 saniyelik ön
    /// süre ve 40 m taban uygulanır; yoksa 30 km/s'te viraj 8 m kala haber
    /// verilirdi.
    static func warningLevel(distanceToCurve distance: Double,
                             speedKmh: Double,
                             safeSpeedKmh: Double,
                             mode: DrivingMode,
                             condition: RoadCondition = .dry) -> WarningLevel {
        guard speedKmh > safeSpeedKmh else { return .none }

        let aCritical = aashtoDeceleration * condition.brakingFactor
        let aComfort  = mode.comfortableDeceleration * condition.brakingFactor

        let dCritical = decelerationDistance(fromKmh: speedKmh, toKmh: safeSpeedKmh,
                                             reactionTime: min(1.0, mode.perceptionReactionTime),
                                             deceleration: aCritical)

        var dPrepare = decelerationDistance(fromKmh: speedKmh, toKmh: safeSpeedKmh,
                                            reactionTime: mode.perceptionReactionTime,
                                            deceleration: aComfort)
        // Taban: en az 4 sn'lik yol, en az 40 m
        dPrepare = max(dPrepare, speedKmh / 3.6 * 4.0, 40)

        let dHeadsUp = min(dPrepare * 1.8, 1500)

        if distance <= dCritical { return .critical }
        if distance <= dPrepare  { return .prepare }
        if distance <= dHeadsUp  { return .headsUp }
        return .none
    }

    /// "Hazırlan" uyarısının tetikleneceği mesafe — kamera zoom'u ve arayüz
    /// geri sayımı bunu kullanır.
    static func prepareDistance(speedKmh: Double,
                                safeSpeedKmh: Double,
                                mode: DrivingMode,
                                condition: RoadCondition = .dry) -> Double {
        let a = mode.comfortableDeceleration * condition.brakingFactor
        let d = decelerationDistance(fromKmh: speedKmh, toKmh: safeSpeedKmh,
                                     reactionTime: mode.perceptionReactionTime,
                                     deceleration: a)
        return max(d, speedKmh / 3.6 * 4.0, 40)
    }
}
