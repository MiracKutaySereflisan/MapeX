// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import SwiftUI

// ============================================================================
// MARK: - Türkiye Araç Kataloğu
// ============================================================================
//
// NEDEN ABD KAYNAĞINI BIRAKTIK
// ----------------------------
// Katalog önce EPA (fueleconomy.gov) üzerinden çalışıyordu. Test edildi ve
// Türkiye için kullanılamaz olduğu görüldü:
//
//      Škoda / Dacia / SEAT / Opel  →  EPA'da HİÇ YOK (ABD'de satılmıyorlar)
//      Nissan                        →  var, ama Türkiye'de olmayan modellerle
//
// Yani liste hem eksik hem şişkindi. Üstelik motor adı "Auto (S8), 4 cyl,
// 1.4 L, Turbo" geliyordu; hiçbir sürücü arabasını böyle tanımaz. Türkiye'de
// herkes "1.4 TSI", "1.6 TDI", "1.5 dCi", "1.3 MultiJet" der.
//
// MOTORLAR PAYLAŞILIR — KÜTÜPHANEDEN GELİR
// ----------------------------------------
// VAG'ın 1.4 TDI'ı Polo'da da, Fabia'da da, Ibiza'da da, A1'de de aynıdır ve
// aşağı yukarı aynı yakar. Bu yüzden motorlar `EngineLibrary.swift` içinde BİR
// KEZ tanımlanır; modeller onlara referans verir. Bir motorun rakamını
// düzeltmek, o motoru kullanan bütün araçları düzeltir.
//
// Gövde etkisi ayrı uygulanır: aynı 1.5 TSI, Golf'te ve Tiguan'da farklı
// tüketir çünkü alın alanı ve ağırlık farklıdır.
//
// TÜKETİM DEĞERLERİNİN DÜRÜSTLÜĞÜ
// -------------------------------
// Her değerin yanında kaynağı taşınır ve arayüzde gösterilir:
//      .classTypical   motor sınıfı tipiği — fabrika değerinden gerçekçi,
//                      ama yine de TAHMİN
//      .measured       KULLANICININ KENDİ ölçümü (depo kaydından)
//
// İkincisi hedeftir. Birkaç depo dolumundan sonra uygulama kullanıcının kendi
// gerçek tüketimini bilir ve katalog değerini bırakır (bkz. FuelLog.swift).
// Yüzlerce rakamı tek tek doğrulamadan "gerçek" diye sunmak dürüst olmazdı.
//
// KAPSAM: 2015 ve sonrası Türkiye pazarı. Daha eski nesiller, hâlâ yaygın
// olanlar ölçüsünde dahil.
// ============================================================================

// MARK: - Veri modeli

enum ConsumptionSource: String, Codable {
    case manufacturer = "üretici bildirimi"
    case classTypical = "motor sınıfı tipiği"
    case measured     = "senin ölçümün"

    var isEstimate: Bool { self != .measured }
    var icon: String {
        switch self {
        case .manufacturer: return "doc.text"
        case .classTypical: return "chart.bar"
        case .measured:     return "checkmark.seal.fill"
        }
    }
}

enum Gearbox: String, Codable, CaseIterable {
    case manual    = "Manuel"
    case automatic = "Otomatik"

    /// Otomatik şanzıman şehir içinde biraz daha çok yakar; tork
    /// konvertörlü/çift kavramalı fark ~%5–8'dir.
    var cityPenalty: Double { self == .automatic ? 1.06 : 1.0 }
    var highwayPenalty: Double { self == .automatic ? 1.02 : 1.0 }
    var short: String { self == .manual ? "M" : "O" }
}

struct TREngine: Identifiable, Hashable {
    let name: String                // "1.4 TDI"
    let power: Int
    let fuel: VehicleProfile.FuelType
    let gearbox: Gearbox
    let city: Double
    let highway: Double
    let source: ConsumptionSource

    var id: String { "\(name)-\(power)-\(gearbox.rawValue)" }
    var displayName: String { "\(name) · \(power) hp · \(gearbox.rawValue)" }
    var shortName: String { "\(name) \(power) hp" }
}

struct TRModel: Identifiable, Hashable {
    let name: String
    /// Türkiye'de satıldığı yıl aralığı — kullanıcı nesli tanısın.
    let years: String
    let bodyClass: VehicleBodyClass
    let widthMM: Double
    let heightMM: Double
    let kerbWeightKg: Double
    let engines: [TREngine]

    var id: String { "\(name) \(years)" }
    var displayName: String { years.isEmpty ? name : "\(name) (\(years))" }
}

struct TRBrand: Identifiable, Hashable {
    let name: String
    /// Marka rozeti için karakteristik renk.
    let colorHex: String
    let models: [TRModel]

    var id: String { name }

    /// Rozette görünen harfler.
    var initials: String {
        let cleaned = name.replacingOccurrences(of: "-", with: " ")
        let words = cleaned.split(separator: " ")
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return "\(a)\(b)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var color: Color { Color(hex: colorHex) }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}

// ============================================================================
// MARK: - Tüketim tahmin modeli
// ============================================================================
//
// Katalogdaki değerler elde uydurulmadı; motor sınıfından türetildi.
// Bir aracın tüketimi ağırlıklı olarak şunlara bağlıdır:
//   • motor hacmi ve doldurma (turbo/atmosferik)
//   • yakıt tipi (dizel aynı işte ~%20–25 daha az litre yakar)
//   • gövde (alın alanı ve ağırlık; otoban ve şehir içi ayrı etkilenir)
//   • şanzıman
// ============================================================================

enum ConsumptionModel {

    static func typical(displacement: Double,
                        turbo: Bool,
                        fuel: VehicleProfile.FuelType,
                        body: VehicleBodyClass,
                        gearbox: Gearbox) -> (city: Double, highway: Double) {

        // Taban: hacim başına tüketim. Turbo küçük motorlar şehir içinde
        // hacminin üstünde yakar (dolum), otobanda avantajlıdır.
        var city = 3.2 + displacement * 3.6
        var highway = 2.4 + displacement * 2.1
        if turbo {
            city *= 1.06
            highway *= 0.94
        }

        switch fuel {
        case .dizel:    city *= 0.78; highway *= 0.76
        case .lpg:      city *= 1.25; highway *= 1.25    // düşük enerji yoğunluğu
        case .elektrik, .benzin: break
        }

        let (c, h): (Double, Double)
        switch body {
        case .hatchback: (c, h) = (0.96, 0.96)
        case .sedan:     (c, h) = (1.00, 1.00)
        case .sports:    (c, h) = (1.02, 1.00)
        case .crossover: (c, h) = (1.10, 1.10)
        case .suv:       (c, h) = (1.18, 1.18)
        case .pickup:    (c, h) = (1.26, 1.24)
        case .van:       (c, h) = (1.22, 1.22)
        case .vanLoaded: (c, h) = (1.34, 1.32)
        }
        city *= c; highway *= h
        city *= gearbox.cityPenalty
        highway *= gearbox.highwayPenalty

        return ((city * 10).rounded() / 10, (highway * 10).rounded() / 10)
    }
}

// ============================================================================
// MARK: - Katalog
// ============================================================================

enum TurkeyVehicleCatalog {

    /// Model tanımını kısaltan yardımcı.
    private static func m(_ name: String, _ years: String, _ body: VehicleBodyClass,
                          _ w: Double, _ h: Double, _ kg: Double,
                          _ specs: [EngineSpec]) -> TRModel {
        TRModel(name: name, years: years, bodyClass: body,
                widthMM: w, heightMM: h, kerbWeightKg: kg,
                engines: expand(specs, body: body))
    }

    private static func mEV(_ name: String, _ years: String, _ body: VehicleBodyClass,
                            _ w: Double, _ h: Double, _ kg: Double,
                            _ engines: [TREngine]) -> TRModel {
        TRModel(name: name, years: years, bodyClass: body,
                widthMM: w, heightMM: h, kerbWeightKg: kg, engines: engines)
    }

    static let brands: [TRBrand] = [

        // ── Fiat ─────────────────────────────────────────────────────────────
        TRBrand(name: "Fiat", colorHex: "8B1A2B", models: [
            m("Egea Sedan", "2015–", .sedan, 1792, 1497, 1265,
              [FiatEng.fire14_95, FiatEng.etorq16_110, FiatEng.mjet13_95, FiatEng.mjet16_120]),
            m("Egea Hatchback", "2016–", .hatchback, 1792, 1495, 1250,
              [FiatEng.fire14_95, FiatEng.firefly10_100, FiatEng.mjet13_95, FiatEng.mjet16_130]),
            m("Egea Cross", "2020–", .crossover, 1811, 1550, 1320,
              [FiatEng.firefly10_100, FiatEng.hyb15_130, FiatEng.mjet16_130]),
            m("Egea Station Wagon", "2016–", .sedan, 1792, 1514, 1300,
              [FiatEng.fire14_95, FiatEng.mjet13_95, FiatEng.mjet16_120]),
            m("Doblo", "2015–", .van, 1832, 1845, 1470,
              [FiatEng.mjet13_95, FiatEng.mjet16_120, PSA.bh15_130]),
            m("Fiorino", "2015–", .van, 1716, 1721, 1205,
              [FiatEng.fire14_77, FiatEng.mjet13_95]),
            m("500", "2015–", .hatchback, 1627, 1488, 940,
              [FiatEng.fire14_95, FiatEng.firefly10_100]),
            m("500L", "2015–2022", .van, 1784, 1667, 1320,
              [FiatEng.firefly10_100, FiatEng.mjet13_95]),
            m("Linea", "2015–2017", .sedan, 1730, 1490, 1195,
              [FiatEng.fire14_77, FiatEng.mjet13_95]),
            m("Punto", "2015–2018", .hatchback, 1687, 1490, 1085,
              [FiatEng.fire14_77, FiatEng.mjet13_95]),
            m("Panda", "2015–", .hatchback, 1643, 1551, 940,
              [FiatEng.fire12_69, FiatEng.twinair09_85]),
            m("Ducato", "2015–", .vanLoaded, 2050, 2524, 2100,
              [FiatEng.mjet23_130, FiatEng.mjet23_160])
        ]),

        // ── Renault ──────────────────────────────────────────────────────────
        TRBrand(name: "Renault", colorHex: "C8A02A", models: [
            m("Clio", "2019–", .hatchback, 1798, 1440, 1178,
              [RN.sce10_65, RN.tce10_90, RN.tce13_140, RN.dci15_110, RN.hyb16_145]),
            m("Clio", "2015–2019", .hatchback, 1732, 1448, 1090,
              [RN.sce12_75, RN.tce09_90, RN.dci15_90]),
            m("Megane Sedan", "2016–", .sedan, 1814, 1447, 1290,
              [RN.tce13_140, RN.tce13_160, RN.dci15_110, RN.dci15_115]),
            m("Megane Hatchback", "2016–", .hatchback, 1814, 1447, 1280,
              [RN.tce13_140, RN.dci15_110, RN.dci16_130]),
            m("Captur", "2020–", .crossover, 1797, 1576, 1289,
              [RN.tce10_90, RN.tce13_140, RN.hyb16_145]),
            m("Captur", "2015–2019", .crossover, 1778, 1566, 1230,
              [RN.tce09_90, RN.dci15_90]),
            m("Taliant", "2021–", .sedan, 1758, 1501, 1128,
              [RN.sce10_72, RN.tce10_90]),
            m("Symbol", "2015–2021", .sedan, 1735, 1467, 1100,
              [RN.sce12_75, RN.tce09_90, RN.dci15_90]),
            m("Kadjar", "2015–2022", .suv, 1836, 1613, 1380,
              [RN.tce13_140, RN.dci15_110, RN.dci16_130]),
            m("Austral", "2023–", .suv, 1825, 1618, 1470,
              [RN.tce13_160, RN.hyb12_200]),
            m("Koleos", "2017–2022", .suv, 1843, 1678, 1560,
              [RN.dci16_130]),
            m("Fluence", "2015–2016", .sedan, 1809, 1479, 1300,
              [RN.sce16_110, RN.dci15_110]),
            m("Trafic", "2015–", .vanLoaded, 1956, 1971, 1850,
              [RN.dci16_120, RN.dci16_145]),
            m("Master", "2015–", .vanLoaded, 2070, 2307, 2050,
              [RN.dci23_130, RN.dci23_145])
        ]),

        // ── Dacia ────────────────────────────────────────────────────────────
        TRBrand(name: "Dacia", colorHex: "1C5C3C", models: [
            m("Duster", "2018–", .suv, 1804, 1693, 1320,
              [RN.tce10_90, RN.lpg10_100, RN.tce13_150, RN.dci15_115]),
            m("Duster", "2015–2017", .suv, 1822, 1625, 1290,
              [RN.sce12_75, RN.dci15_90]),
            m("Sandero", "2021–", .hatchback, 1848, 1499, 1165,
              [RN.sce10_65, RN.tce10_90, RN.lpg10_100]),
            m("Sandero", "2015–2020", .hatchback, 1733, 1519, 1070,
              [RN.sce12_75, RN.tce09_90, RN.dci15_90]),
            m("Sandero Stepway", "2021–", .crossover, 1848, 1535, 1195,
              [RN.tce10_90, RN.lpg10_100]),
            m("Jogger", "2022–", .van, 1784, 1674, 1245,
              [RN.tce10_110, RN.hyb16_140]),
            m("Logan", "2015–", .sedan, 1733, 1517, 1075,
              [RN.sce12_75, RN.tce10_90, RN.dci15_90]),
            m("Lodgy", "2015–2022", .van, 1751, 1682, 1210,
              [RN.tce12_120, RN.dci15_90])
        ]),

        // ── Volkswagen ───────────────────────────────────────────────────────
        TRBrand(name: "Volkswagen", colorHex: "0A3D7A", models: [
            m("Golf", "2020–", .hatchback, 1789, 1456, 1285, VAG.compact),
            m("Golf", "2015–2019", .hatchback, 1799, 1442, 1250,
              [VAG.tsi12_110, VAG.tsi14_125, VAG.tsi14_150, VAG.tdi16_110, VAG.tdi20_150]),
            m("Passat", "2015–", .sedan, 1832, 1456, 1450, VAG.midsize),
            m("Polo", "2018–", .hatchback, 1751, 1446, 1105, VAG.smallCar),
            m("Polo", "2015–2017", .hatchback, 1682, 1462, 1070,
              [VAG.mpi10_60, VAG.tsi12_90, VAG.tdi14_75, VAG.tdi14_90]),
            m("T-Roc", "2018–", .crossover, 1819, 1573, 1355,
              [VAG.tsi10_110, VAG.tsi15_150, VAG.tdi20_150]),
            m("T-Cross", "2019–", .crossover, 1760, 1584, 1215,
              [VAG.tsi10_95, VAG.tsi10_110, VAG.tsi15_150]),
            m("Tiguan", "2016–", .suv, 1839, 1658, 1560, VAG.suv),
            m("Touareg", "2018–", .suv, 1984, 1717, 1995,
              [VAG.tdi20_190, VAG.tsi20_245]),
            m("Arteon", "2017–", .sedan, 1871, 1450, 1520,
              [VAG.tsi15_150, VAG.tsi20_190, VAG.tdi20_190]),
            m("Jetta", "2015–2018", .sedan, 1778, 1453, 1310,
              [VAG.tsi12_110, VAG.tsi14_125, VAG.tdi16_110]),
            m("Caddy", "2015–", .van, 1855, 1797, 1490,
              [VAG.tdi20_150, VAG.tsi15_150, VAG.tdi16_110]),
            m("Transporter", "2015–", .vanLoaded, 1904, 1990, 1950,
              [VAG.tdi20_150, VAG.tdi20_200]),
            m("Amarok", "2015–", .pickup, 1954, 1834, 2050,
              [VAG.tdi20_180]),
            m("Crafter", "2017–", .vanLoaded, 2040, 2355, 2100,
              [VAG.tdi20_150, VAG.tdi20_200]),
            m("Touran", "2015–", .van, 1829, 1659, 1450,
              [VAG.tsi15_150, VAG.tdi16_115, VAG.tdi20_150]),
            m("Scirocco", "2015–2017", .sports, 1810, 1404, 1330,
              [VAG.tsi14_150, VAG.tsi20_190]),
            m("Sharan", "2015–2021", .van, 1904, 1720, 1750,
              [VAG.tdi20_150, VAG.tsi14_150])
        ]),

        // ── Škoda ────────────────────────────────────────────────────────────
        TRBrand(name: "Škoda", colorHex: "0E6B4B", models: [
            m("Octavia", "2020–", .sedan, 1829, 1470, 1330, VAG.compact),
            m("Octavia", "2015–2019", .sedan, 1814, 1461, 1280,
              [VAG.tsi12_110, VAG.tsi14_150, VAG.tsi18_180,
               VAG.tdi16_110, VAG.tdi16_115, VAG.tdi20_150]),
            m("Superb", "2015–", .sedan, 1864, 1469, 1480, VAG.midsize),
            m("Fabia", "2021–", .hatchback, 1780, 1459, 1150, VAG.smallCar),
            m("Fabia", "2015–2020", .hatchback, 1732, 1467, 1065,
              [VAG.mpi10_60, VAG.mpi10_75, VAG.tsi10_95, VAG.tsi10_110,
               VAG.tsi12_90, VAG.tdi14_75, VAG.tdi14_90]),
            m("Scala", "2019–", .hatchback, 1793, 1471, 1235,
              [VAG.tsi10_95, VAG.tsi10_110, VAG.tsi15_150, VAG.tdi16_115]),
            m("Rapid", "2015–2019", .hatchback, 1706, 1459, 1145,
              [VAG.tsi10_95, VAG.tsi12_90, VAG.tdi14_90, VAG.tdi16_90]),
            m("Kamiq", "2019–", .crossover, 1793, 1553, 1280,
              [VAG.tsi10_95, VAG.tsi10_110, VAG.tsi15_150, VAG.tdi16_115]),
            m("Karoq", "2017–", .suv, 1841, 1603, 1420,
              [VAG.tsi10_110, VAG.tsi15_150, VAG.tdi20_150, VAG.tdi16_115]),
            m("Kodiaq", "2016–", .suv, 1882, 1681, 1650,
              [VAG.tsi15_150, VAG.tdi20_150, VAG.tdi20_200]),
            m("Yeti", "2015–2017", .crossover, 1793, 1691, 1355,
              [VAG.tsi12_110, VAG.tdi16_110, VAG.tdi20_150])
        ]),

        // ── SEAT ─────────────────────────────────────────────────────────────
        TRBrand(name: "SEAT", colorHex: "8C1F2F", models: [
            m("Leon", "2020–", .hatchback, 1800, 1442, 1310, VAG.compact),
            m("Leon", "2015–2019", .hatchback, 1816, 1459, 1270,
              [VAG.tsi12_110, VAG.tsi14_150, VAG.tdi16_110, VAG.tdi20_150]),
            m("Ibiza", "2017–", .hatchback, 1780, 1444, 1145, VAG.smallCar),
            m("Ibiza", "2015–2016", .hatchback, 1693, 1445, 1070,
              [VAG.mpi10_75, VAG.tsi12_90, VAG.tdi14_90]),
            m("Arona", "2017–", .crossover, 1780, 1552, 1220,
              [VAG.tsi10_95, VAG.tsi10_110, VAG.tsi15_150, VAG.tdi16_115]),
            m("Ateca", "2016–", .suv, 1841, 1615, 1400,
              [VAG.tsi10_110, VAG.tsi15_150, VAG.tdi20_150]),
            m("Toledo", "2015–2019", .hatchback, 1706, 1461, 1140,
              [VAG.tsi10_95, VAG.tsi12_90, VAG.tdi14_90])
        ]),

        // ── Audi ─────────────────────────────────────────────────────────────
        TRBrand(name: "Audi", colorHex: "9B1B26", models: [
            m("A3 Sedan", "2015–", .sedan, 1816, 1425, 1350,
              [VAG.tfsi30_110, VAG.tfsi35_150, VAG.atdi30_116, VAG.atdi35_150]),
            m("A1", "2015–", .hatchback, 1740, 1420, 1130,
              [VAG.tfsi30_110, VAG.tdi14_90]),
            m("A4", "2015–", .sedan, 1847, 1428, 1530,
              [VAG.tfsi35_150, VAG.tfsi40_190, VAG.atdi35_150, VAG.atdi40_190]),
            m("A6", "2018–", .sedan, 1886, 1457, 1700,
              [VAG.tfsi40_190, VAG.atdi40_190]),
            m("Q2", "2016–", .crossover, 1794, 1508, 1280,
              [VAG.tfsi30_110, VAG.tfsi35_150, VAG.atdi30_116]),
            m("Q3", "2018–", .suv, 1856, 1616, 1560,
              [VAG.tfsi35_150, VAG.atdi35_150]),
            m("Q5", "2017–", .suv, 1893, 1659, 1770,
              [VAG.tfsi40_190, VAG.atdi40_190]),
            m("A5", "2016–", .sports, 1846, 1371, 1520,
              [VAG.tfsi40_190, VAG.atdi40_190]),
            m("Q7", "2015–", .suv, 1968, 1741, 2070,
              [VAG.atdi40_190])
        ]),

        // ── Opel ─────────────────────────────────────────────────────────────
        TRBrand(name: "Opel", colorHex: "C8A21C", models: [
            m("Corsa", "2019–", .hatchback, 1765, 1433, 1165,
              [PSA.opel12_75, PSA.opel12_100, PSA.opel12_130, PSA.opel15_102]),
            m("Corsa", "2015–2019", .hatchback, 1736, 1479, 1165,
              [PSA.opel12_75, PSA.opel14_140, PSA.opel16_110]),
            m("Astra", "2021–", .hatchback, 1860, 1470, 1320,
              [PSA.opel12_130, PSA.opel15_130]),
            m("Astra", "2015–2021", .hatchback, 1809, 1485, 1280,
              [PSA.opel14_140, PSA.opel16_110, PSA.opel16_136]),
            m("Mokka", "2020–", .crossover, 1791, 1531, 1280,
              [PSA.opel12_100, PSA.opel12_130, PSA.opel15_130]),
            m("Crossland", "2017–", .crossover, 1765, 1605, 1240,
              [PSA.opel12_110, PSA.opel15_102]),
            m("Grandland", "2018–", .suv, 1856, 1609, 1440,
              [PSA.opel12_130, PSA.opel15_130]),
            m("Insignia", "2017–2022", .sedan, 1863, 1455, 1495,
              [PSA.opel14_140, PSA.opel16_136]),
            m("Zafira", "2015–2019", .van, 1884, 1685, 1600,
              [PSA.opel14_140, PSA.opel16_136]),
            m("Combo", "2018–", .van, 1848, 1796, 1420,
              [PSA.opel15_102, PSA.opel15_130]),
            m("Vivaro", "2019–", .vanLoaded, 1920, 1935, 1800,
              [PSA.bh15_130, PSA.bh20_150])
        ]),

        // ── Ford ─────────────────────────────────────────────────────────────
        TRBrand(name: "Ford", colorHex: "0B4C97", models: [
            m("Focus", "2018–", .hatchback, 1825, 1471, 1320,
              [FordEng.eb10_125, FordEng.eb10h_155, FordEng.ecb15_120]),
            m("Focus", "2015–2018", .hatchback, 1823, 1469, 1300,
              [FordEng.eb10_125, FordEng.tdci15_95, FordEng.ecb15_120]),
            m("Fiesta", "2017–", .hatchback, 1735, 1476, 1130,
              [FordEng.eb10_100, FordEng.eb10_125, FordEng.ecb15_100]),
            m("Puma", "2020–", .crossover, 1805, 1537, 1280,
              [FordEng.eb10h_125, FordEng.eb10h_155]),
            m("Kuga", "2020–", .suv, 1883, 1661, 1600,
              [FordEng.eb15_150, FordEng.hyb25_190, FordEng.ecb20_150]),
            m("Kuga", "2015–2019", .suv, 1838, 1689, 1580,
              [FordEng.eb15_150, FordEng.ecb20_150]),
            m("EcoSport", "2015–2022", .crossover, 1765, 1653, 1280,
              [FordEng.eb10_125, FordEng.ecb15_100]),
            m("Courier", "2015–", .van, 1787, 1740, 1310,
              [FordEng.ecb15_100, FordEng.eb10_125]),
            m("Transit Custom", "2015–", .vanLoaded, 1986, 1966, 1950,
              [FordEng.ecb20_136, FordEng.ecb20_170]),
            m("Ranger", "2015–", .pickup, 1860, 1815, 2100,
              [FordEng.ecb20_170]),
            m("Mondeo", "2015–2022", .sedan, 1852, 1482, 1550,
              [FordEng.tdci20_150, FordEng.tdci20_180, FordEng.eb15_182]),
            m("Tourneo Connect", "2015–", .van, 1835, 1827, 1500,
              [FordEng.ecb15_100, FordEng.ecb15_120]),
            m("Tourneo Courier", "2015–", .van, 1787, 1740, 1310,
              [FordEng.ecb15_100, FordEng.eb10_125]),
            m("Transit", "2015–", .vanLoaded, 2059, 2532, 2200,
              [FordEng.ecb20_130, FordEng.ecb20_170])
        ]),

        // ── Toyota ───────────────────────────────────────────────────────────
        TRBrand(name: "Toyota", colorHex: "B01824", models: [
            m("Corolla Sedan", "2019–", .sedan, 1780, 1435, 1320,
              [ToyotaEng.vvti16_132, ToyotaEng.hyb18_140]),
            m("Corolla Sedan", "2015–2018", .sedan, 1776, 1465, 1290,
              [ToyotaEng.vvti133_99, ToyotaEng.vvti16_132, ToyotaEng.d4d14_90]),
            m("Corolla Hatchback", "2019–", .hatchback, 1790, 1435, 1310,
              [ToyotaEng.hyb18_140, ToyotaEng.hyb20_196]),
            m("C-HR", "2016–", .crossover, 1832, 1564, 1440,
              [ToyotaEng.hyb18_122, ToyotaEng.hyb18_140, ToyotaEng.hyb20_196]),
            m("Yaris", "2020–", .hatchback, 1745, 1500, 1085,
              [ToyotaEng.hyb15_116]),
            m("Yaris", "2015–2019", .hatchback, 1695, 1510, 1055,
              [ToyotaEng.vvti133_99, ToyotaEng.hyb15_116]),
            m("RAV4", "2019–", .suv, 1855, 1685, 1650,
              [ToyotaEng.hyb25_218]),
            m("Hilux", "2015–", .pickup, 1855, 1815, 2015,
              [ToyotaEng.d4d24_150, ToyotaEng.d4d28_204]),
            m("Auris", "2015–2018", .hatchback, 1760, 1475, 1275,
              [ToyotaEng.vvti133_99, ToyotaEng.hyb18_122, ToyotaEng.d4d14_90]),
            m("Verso", "2015–2018", .van, 1790, 1620, 1440,
              [ToyotaEng.vvti18_147, ToyotaEng.d4d16_112]),
            m("Avensis", "2015–2018", .sedan, 1810, 1480, 1420,
              [ToyotaEng.vvti16_132, ToyotaEng.d4d16_112, ToyotaEng.d4d20_143]),
            m("Camry", "2019–", .sedan, 1840, 1445, 1620,
              [ToyotaEng.hyb25_218]),
            m("Proace City", "2020–", .van, 1848, 1796, 1420,
              [PSA.bh15_100, PSA.bh15_130]),
            m("Land Cruiser", "2015–", .suv, 1885, 1845, 2200,
              [ToyotaEng.d4d28_204])
        ]),

        // ── Hyundai ──────────────────────────────────────────────────────────
        TRBrand(name: "Hyundai", colorHex: "0A3C6E", models: [
            m("i20", "2020–", .hatchback, 1775, 1450, 1145,
              [HK.mpi14_100, HK.tgdi10_100, HK.tgdi10_120]),
            m("i20", "2015–2020", .hatchback, 1734, 1474, 1120,
              [HK.mpi12_84, HK.mpi14_100, HK.crdi14_90]),
            m("i10", "2015–", .hatchback, 1680, 1483, 1000,
              [HK.mpi10_67, HK.mpi12_84]),
            m("i30", "2017–", .hatchback, 1795, 1455, 1290,
              [HK.tgdi10_120, HK.tgdi14_140, HK.crdi16_115, HK.crdi16_136]),
            m("Elantra", "2016–", .sedan, 1825, 1420, 1300,
              [HK.mpi16_123, HK.mpi16_132, HK.crdi16_136]),
            m("Accent Blue", "2015–2019", .sedan, 1700, 1455, 1130,
              [HK.mpi14_100, HK.crdi14_90]),
            m("Bayon", "2021–", .crossover, 1775, 1500, 1180,
              [HK.mpi14_100, HK.tgdi10_100, HK.tgdi10_120]),
            m("Kona", "2017–", .crossover, 1800, 1565, 1300,
              [HK.tgdi10_120, HK.tgdi16_177, HK.hyb16_141]),
            m("Tucson", "2020–", .suv, 1865, 1650, 1520,
              [HK.tgdi16_150, HK.crdi16_136, HK.hyb16_230]),
            m("Tucson", "2015–2020", .suv, 1850, 1655, 1500,
              [HK.mpi16_132, HK.tgdi16_177, HK.crdi16_115, HK.crdi16_136]),
            m("Santa Fe", "2015–", .suv, 1890, 1685, 1800,
              [HK.crdi20_185, HK.crdi22_200]),
            m("H-1", "2015–2021", .vanLoaded, 1920, 1925, 2100,
              [HK.crdi25_170]),
            m("i20 Active", "2015–2020", .crossover, 1750, 1510, 1150,
              [HK.mpi14_100, HK.crdi14_90])
        ]),

        // ── Kia ──────────────────────────────────────────────────────────────
        TRBrand(name: "Kia", colorHex: "9E1B32", models: [
            m("Rio", "2017–", .hatchback, 1725, 1450, 1130,
              [HK.mpi14_100, HK.tgdi10_100, HK.crdi14_90]),
            m("Picanto", "2017–", .hatchback, 1595, 1485, 960,
              [HK.mpi10_67, HK.mpi12_84]),
            m("Ceed", "2018–", .hatchback, 1800, 1447, 1310,
              [HK.tgdi10_120, HK.tgdi15_160, HK.crdi16_136]),
            m("Sportage", "2021–", .suv, 1865, 1660, 1530,
              [HK.tgdi16_150, HK.crdi16_136, HK.hyb16_230]),
            m("Sportage", "2016–2021", .suv, 1855, 1635, 1500,
              [HK.mpi16_132, HK.crdi16_115, HK.crdi16_136]),
            m("Stonic", "2017–", .crossover, 1760, 1520, 1180,
              [HK.mpi14_100, HK.tgdi10_120, HK.crdi14_90]),
            m("Cerato", "2015–2018", .sedan, 1780, 1435, 1280,
              [HK.mpi16_132, HK.crdi16_136]),
            m("Soul", "2015–2019", .crossover, 1800, 1600, 1300,
              [HK.mpi16_132, HK.crdi16_115]),
            m("Niro", "2017–", .crossover, 1805, 1545, 1425,
              [HK.hyb16_141]),
            m("Venga", "2015–2019", .van, 1765, 1600, 1250,
              [HK.mpi14_100, HK.crdi14_90]),
            m("Optima", "2016–2020", .sedan, 1860, 1465, 1500,
              [HK.mpi20_155, HK.crdi16_136])
        ]),

        // ── Peugeot ──────────────────────────────────────────────────────────
        TRBrand(name: "Peugeot", colorHex: "1B3A63", models: [
            m("208", "2019–", .hatchback, 1745, 1430, 1165,
              [PSA.pt12_100, PSA.pt12_130, PSA.bh15_100]),
            m("208", "2015–2019", .hatchback, 1739, 1460, 1090,
              [PSA.pt12_82, PSA.pt12_110, PSA.bh16_100]),
            m("301", "2015–", .sedan, 1748, 1476, 1145,
              [PSA.pt12_82, PSA.bh15_102, PSA.bh16_100]),
            m("308", "2021–", .hatchback, 1852, 1441, 1320,
              [PSA.pt12_130, PSA.bh15_130]),
            m("308", "2015–2021", .hatchback, 1804, 1457, 1230,
              [PSA.pt12_110, PSA.pt12_130, PSA.bh16_120]),
            m("2008", "2019–", .crossover, 1815, 1550, 1265,
              [PSA.pt12_100, PSA.pt12_130, PSA.bh15_130]),
            m("3008", "2016–", .suv, 1841, 1620, 1460,
              [PSA.pt12_130, PSA.pt12_155, PSA.bh15_130, PSA.bh16_120]),
            m("5008", "2017–", .suv, 1844, 1646, 1520,
              [PSA.pt12_130, PSA.bh15_130]),
            m("Partner", "2015–", .van, 1848, 1796, 1420,
              [PSA.bh15_100, PSA.bh15_130, PSA.bh16_100]),
            m("508", "2018–", .sedan, 1859, 1403, 1450,
              [PSA.pt16_180, PSA.bh15_130, PSA.bh20_177]),
            m("Rifter", "2018–", .van, 1848, 1796, 1440,
              [PSA.bh15_100, PSA.bh15_130]),
            m("Expert", "2016–", .vanLoaded, 1920, 1935, 1800,
              [PSA.bh16_120, PSA.bh20_150]),
            m("108", "2015–2021", .hatchback, 1615, 1460, 840,
              [PSA.vti10_72])
        ]),

        // ── Citroën ──────────────────────────────────────────────────────────
        TRBrand(name: "Citroën", colorHex: "9B1C2E", models: [
            m("C3", "2016–", .hatchback, 1749, 1474, 1120,
              [PSA.pt12_82, PSA.pt12_110, PSA.bh15_102, PSA.bh16_100]),
            m("C-Elysée", "2015–2022", .sedan, 1748, 1466, 1130,
              [PSA.pt12_82, PSA.bh15_102, PSA.bh16_100]),
            m("C4", "2020–", .crossover, 1800, 1525, 1320,
              [PSA.pt12_130, PSA.bh15_130]),
            m("C4 Cactus", "2015–2020", .crossover, 1729, 1480, 1120,
              [PSA.pt12_110, PSA.bh16_100]),
            m("C5 Aircross", "2018–", .suv, 1859, 1670, 1450,
              [PSA.pt12_130, PSA.bh15_130]),
            m("Berlingo", "2015–", .van, 1848, 1844, 1440,
              [PSA.bh15_100, PSA.bh15_130, PSA.bh16_100]),
            m("C1", "2015–2021", .hatchback, 1615, 1460, 840,
              [PSA.vti10_72]),
            m("C4 Picasso", "2015–2018", .van, 1826, 1610, 1400,
              [PSA.pt12_130, PSA.bh16_120]),
            m("Jumpy", "2016–", .vanLoaded, 1920, 1935, 1800,
              [PSA.bh16_120, PSA.bh20_150])
        ]),

        // ── Honda ────────────────────────────────────────────────────────────
        TRBrand(name: "Honda", colorHex: "0E4E9B", models: [
            m("Civic Sedan", "2021–", .sedan, 1800, 1416, 1315,
              [HondaEng.turbo15_182, HondaEng.hev20_184]),
            m("Civic Sedan", "2016–2021", .sedan, 1799, 1416, 1300,
              [HondaEng.vtec16_125, HondaEng.turbo15_182, HondaEng.idtec16_120]),
            m("Civic Sedan", "2015–2016", .sedan, 1752, 1435, 1250,
              [HondaEng.vtec16_125, HondaEng.idtec16_120]),
            m("HR-V", "2021–", .crossover, 1790, 1590, 1380,
              [HondaEng.hev15_131]),
            m("HR-V", "2015–2021", .crossover, 1772, 1605, 1300,
              [HondaEng.vtec15_130, HondaEng.idtec16_120]),
            m("CR-V", "2018–", .suv, 1866, 1681, 1620,
              [HondaEng.hev20_184, HondaEng.turbo15_182]),
            m("Jazz", "2015–", .hatchback, 1694, 1525, 1090,
              [HondaEng.vtec13_102, HondaEng.hev15_131]),
            m("City", "2015–2020", .sedan, 1695, 1495, 1120,
              [HondaEng.vtec15_120]),
            m("Civic Hatchback", "2017–", .hatchback, 1799, 1434, 1300,
              [HondaEng.vtec16_125, HondaEng.turbo15_182, HondaEng.idtec16_120]),
            m("Accord", "2015–2018", .sedan, 1849, 1465, 1560,
              [HondaEng.hev20_184])
        ]),

        // ── Nissan ───────────────────────────────────────────────────────────
        TRBrand(name: "Nissan", colorHex: "8C1620", models: [
            m("Qashqai", "2021–", .suv, 1835, 1625, 1450,
              [RN.digt13_140, RN.digt13_158, RN.epower_190]),
            m("Qashqai", "2015–2021", .suv, 1806, 1590, 1400,
              [RN.digt12_115, RN.digt13_140, RN.dci15_110, RN.dci16_130]),
            m("Juke", "2020–", .crossover, 1800, 1595, 1250,
              [RN.digt10_114, RN.njuke_hyb]),
            m("Juke", "2015–2019", .crossover, 1765, 1565, 1180,
              [RN.digt12_115, RN.dci15_110]),
            m("X-Trail", "2022–", .suv, 1840, 1725, 1650,
              [RN.epower_204]),
            m("X-Trail", "2015–2022", .suv, 1830, 1710, 1560,
              [RN.dci16_130]),
            m("Pulsar", "2015–2018", .hatchback, 1768, 1520, 1230,
              [RN.digt12_115, RN.digt16_190, RN.dci15_110]),
            m("Note", "2015–2018", .hatchback, 1695, 1535, 1120,
              [RN.digt12_115, RN.dci15_90]),
            m("Navara", "2016–", .pickup, 1850, 1804, 1950,
              [RN.dci23_130, RN.dci23_145]),
            m("Micra", "2017–2022", .hatchback, 1743, 1455, 1050,
              [RN.tce09_90, RN.dci15_90])
        ]),

        // ── Mercedes-Benz ────────────────────────────────────────────────────
        TRBrand(name: "Mercedes-Benz", colorHex: "1E2A32", models: [
            m("A-Serisi", "2018–", .hatchback, 1796, 1440, 1375,
              [Premium.mbA180, Premium.mbA200, Premium.mbA180d]),
            m("A-Serisi", "2015–2018", .hatchback, 1780, 1433, 1350,
              [Premium.mbA180, Premium.mbA180d]),
            m("CLA", "2019–", .sedan, 1830, 1439, 1420,
              [Premium.mbCLA180, Premium.mbA200]),
            m("C-Serisi", "2015–", .sedan, 1820, 1438, 1575,
              [Premium.mbC180, Premium.mbC200, Premium.mbC220d]),
            m("E-Serisi", "2016–", .sedan, 1852, 1468, 1680,
              [Premium.mbE200, Premium.mbE220d]),
            m("GLA", "2015–", .crossover, 1804, 1494, 1450,
              [Premium.mbGLA200, Premium.mbA180d]),
            m("Vito", "2015–", .vanLoaded, 1928, 1910, 2000,
              [Premium.mb110cdi, Premium.mb116cdi]),
            m("Sprinter", "2018–", .vanLoaded, 1993, 2355, 2100,
              [Premium.mb116cdi]),
            m("B-Serisi", "2015–", .van, 1786, 1557, 1420,
              [Premium.mbB180, Premium.mbB200d]),
            m("GLC", "2015–", .suv, 1890, 1644, 1735,
              [Premium.mbGLC200, Premium.mbGLC220d]),
            m("V-Serisi", "2015–", .vanLoaded, 1928, 1880, 2100,
              [Premium.mbV220d])
        ]),

        // ── BMW ──────────────────────────────────────────────────────────────
        TRBrand(name: "BMW", colorHex: "0B4B8F", models: [
            m("1 Serisi", "2019–", .hatchback, 1799, 1434, 1395,
              [Premium.bmw116i, Premium.bmw118i, Premium.bmw116d]),
            m("1 Serisi", "2015–2019", .hatchback, 1765, 1440, 1370,
              [Premium.bmw116i, Premium.bmw116d]),
            m("2 Serisi", "2015–", .sedan, 1774, 1418, 1420,
              [Premium.bmw118i, Premium.bmw116d]),
            m("3 Serisi", "2019–", .sedan, 1827, 1440, 1545,
              [Premium.bmw318i, Premium.bmw320i, Premium.bmw320d]),
            m("3 Serisi", "2015–2018", .sedan, 1811, 1429, 1500,
              [Premium.bmw318i, Premium.bmw320i, Premium.bmw320d]),
            m("5 Serisi", "2017–", .sedan, 1868, 1479, 1710,
              [Premium.bmw520i, Premium.bmw520d]),
            m("X1", "2015–", .crossover, 1845, 1616, 1530,
              [Premium.bmwX1_18i, Premium.bmwX1_18d]),
            m("X3", "2017–", .suv, 1891, 1676, 1750,
              [Premium.bmwX3_20i, Premium.bmw320d]),
            m("4 Serisi", "2015–", .sports, 1825, 1377, 1520,
              [Premium.bmw420i, Premium.bmw420d]),
            m("X5", "2018–", .suv, 2004, 1745, 2100,
              [Premium.bmwX5_30d])
        ]),

        // ── Volvo ────────────────────────────────────────────────────────────
        TRBrand(name: "Volvo", colorHex: "1B3A5C", models: [
            m("XC40", "2018–", .crossover, 1863, 1652, 1690,
              [Premium.volvoB3, Premium.volvoB4, Premium.volvoD3]),
            m("XC60", "2017–", .suv, 1902, 1658, 1850,
              [Premium.volvoB4, Premium.volvoB5, Premium.volvoD4]),
            m("S60", "2018–", .sedan, 1850, 1431, 1650,
              [Premium.volvoB4, Premium.volvoD4]),
            m("S90", "2016–", .sedan, 1879, 1443, 1780,
              [Premium.volvoB4, Premium.volvoD4]),
            m("V40", "2015–2019", .hatchback, 1802, 1445, 1400,
              [Premium.volvoT2, Premium.volvoD3]),
            m("XC90", "2015–", .suv, 1958, 1776, 2050,
              [Premium.volvoB5, Premium.volvoD4])
        ]),

        // ── Suzuki ───────────────────────────────────────────────────────────
        TRBrand(name: "Suzuki", colorHex: "0B4C97", models: [
            m("Vitara", "2015–", .crossover, 1775, 1610, 1180,
              [Misc.szBoost14_129, Misc.szVvt16_120, Misc.szDdis16_120]),
            m("S-Cross", "2015–", .crossover, 1785, 1585, 1215,
              [Misc.szBoost14_129, Misc.szVvt16_120]),
            m("Swift", "2017–", .hatchback, 1735, 1495, 950,
              [Misc.szVvt12_90]),
            m("Jimny", "2019–", .suv, 1645, 1720, 1090,
              [Misc.szVvt15_102]),
            m("Baleno", "2016–2020", .hatchback, 1745, 1470, 935,
              [Misc.szBoost10_111, Misc.szVvt12_90])
        ]),

        // ── Togg ─────────────────────────────────────────────────────────────
        TRBrand(name: "Togg", colorHex: "13445E", models: [
            mEV("T10X", "2023–", .crossover, 1878, 1621, 1900, [
                evEngine("Uzun Menzil V1 (RWD)", 218, city: 16.5, highway: 19.5),
                evEngine("Uzun Menzil V2 (RWD)", 218, city: 16.8, highway: 19.8)
            ]),
            mEV("T10F", "2025–", .sedan, 1885, 1492, 1950, [
                evEngine("Uzun Menzil (RWD)", 218, city: 15.8, highway: 18.4)
            ])
        ]),

        // ── Tesla ────────────────────────────────────────────────────────────
        TRBrand(name: "Tesla", colorHex: "9B1616", models: [
            mEV("Model Y", "2021–", .suv, 1921, 1624, 1909, [
                evEngine("Standart Menzil (RWD)", 299, city: 14.8, highway: 17.6),
                evEngine("Long Range (AWD)", 378, city: 15.6, highway: 18.4)
            ]),
            mEV("Model 3", "2019–", .sedan, 1849, 1443, 1760, [
                evEngine("Standart Menzil (RWD)", 283, city: 13.2, highway: 15.4),
                evEngine("Long Range (AWD)", 366, city: 14.0, highway: 16.2)
            ])
        ]),

        // ── MG ───────────────────────────────────────────────────────────────
        TRBrand(name: "MG", colorHex: "8E1B2E", models: [
            mEV("MG4", "2023–", .hatchback, 1836, 1504, 1685, [
                evEngine("51 kWh (RWD)", 170, city: 15.4, highway: 18.2),
                evEngine("64 kWh (RWD)", 204, city: 16.0, highway: 18.8)
            ]),
            m("ZS", "2021–", .crossover, 1809, 1620, 1320,
              [Misc.mgVti15_106, Misc.mgTgdi10_111]),
            m("HS", "2022–", .suv, 1876, 1664, 1520,
              [Misc.mgTgdi15_162])
        ]),

        // ── Chery ────────────────────────────────────────────────────────────
        TRBrand(name: "Chery", colorHex: "1F4C7A", models: [
            m("Tiggo 7 Pro", "2022–", .suv, 1862, 1670, 1490,
              [Misc.cheryTci16_186]),
            m("Tiggo 8 Pro", "2022–", .suv, 1930, 1705, 1660,
              [Misc.cheryTci16_186]),
            m("Tiggo 5X", "2023–", .crossover, 1831, 1662, 1340,
              [Misc.cheryTci15_147])
        ]),


        // ── Mitsubishi ───────────────────────────────────────────────────────
        TRBrand(name: "Mitsubishi", colorHex: "9E1B24", models: [
            m("ASX", "2015–2023", .crossover, 1770, 1640, 1360,
              [Misc.miMivec16_117, Misc.miDid16_115]),
            m("Outlander", "2015–2021", .suv, 1810, 1710, 1560,
              [Misc.miDid24_181, Misc.miPhev24_224]),
            m("Eclipse Cross", "2018–", .crossover, 1805, 1685, 1490,
              [Misc.miMivec16_117]),
            m("L200", "2015–", .pickup, 1815, 1780, 1900,
              [Misc.miDid24_181]),
            m("Space Star", "2016–", .hatchback, 1665, 1505, 900,
              [Misc.miMivec12_80])
        ]),

        // ── Jeep ─────────────────────────────────────────────────────────────
        TRBrand(name: "Jeep", colorHex: "2C4A2E", models: [
            m("Renegade", "2015–", .crossover, 1805, 1667, 1400,
              [Misc.jeepMair14_140, Misc.jeepMjet16_120, Misc.jeepGse13_150]),
            m("Compass", "2017–", .suv, 1819, 1629, 1500,
              [Misc.jeepMjet16_120, Misc.jeepMjet20_170, Misc.jeepGse13_150]),
            m("Cherokee", "2015–2022", .suv, 1859, 1669, 1750,
              [Misc.jeepMjet20_170])
        ]),

        // ── Alfa Romeo ───────────────────────────────────────────────────────
        TRBrand(name: "Alfa Romeo", colorHex: "8E1B2B", models: [
            m("Giulietta", "2015–2020", .hatchback, 1798, 1465, 1355,
              [Misc.alfaJtdm16_120, Misc.alfaMair14_170]),
            m("Giulia", "2016–", .sedan, 1860, 1436, 1500,
              [Misc.alfaJtdm22_190, Misc.alfaTb20_200]),
            m("Stelvio", "2017–", .suv, 1903, 1671, 1700,
              [Misc.alfaJtdm22_190, Misc.alfaTb20_200])
        ]),

        // ── MINI ─────────────────────────────────────────────────────────────
        TRBrand(name: "MINI", colorHex: "1E2A32", models: [
            m("Cooper", "2015–", .hatchback, 1727, 1414, 1160,
              [Misc.miniOne10_102, Misc.miniCooper15_136, Misc.miniCooperS_192, Misc.miniD_150]),
            m("Countryman", "2017–", .crossover, 1822, 1557, 1440,
              [Misc.miniCooper15_136, Misc.miniCooperS_192, Misc.miniD_150])
        ]),

        // ── Land Rover ───────────────────────────────────────────────────────
        TRBrand(name: "Land Rover", colorHex: "1F4A34", models: [
            m("Discovery Sport", "2015–", .suv, 1894, 1724, 1850,
              [Misc.lrTd4_180, Misc.lrSi4_200]),
            m("Range Rover Evoque", "2015–", .suv, 1904, 1649, 1800,
              [Misc.lrTd4_180, Misc.lrSi4_200])
        ]),

        // ── Isuzu ────────────────────────────────────────────────────────────
        TRBrand(name: "Isuzu", colorHex: "9E2020", models: [
            m("D-Max", "2015–", .pickup, 1860, 1785, 1900,
              [Misc.isuzuDmax19_164])
        ]),

        // ── BYD ──────────────────────────────────────────────────────────────
        TRBrand(name: "BYD", colorHex: "13457A", models: [
            mEV("Seal U", "2024–", .suv, 1890, 1670, 1950, [
                evEngine("Comfort (FWD)", 218, city: 16.2, highway: 19.4)
            ]),
            mEV("Atto 3", "2023–", .crossover, 1875, 1615, 1750, [
                evEngine("Comfort (FWD)", 204, city: 15.8, highway: 19.0)
            ])
        ])
    ]

    // MARK: Sorgular

    static func brand(named name: String) -> TRBrand? {
        brands.first { $0.name == name }
    }

    static func models(brand: String) -> [TRModel] {
        self.brand(named: brand)?.models ?? []
    }

    static var modelCount: Int { brands.reduce(0) { $0 + $1.models.count } }
    static var engineCount: Int {
        brands.reduce(0) { $0 + $1.models.reduce(0) { $0 + $1.engines.count } }
    }
}

// ============================================================================
// MARK: - Marka Rozeti
// ============================================================================
//
// Gerçek marka logoları paketlenmiyor — ticari marka hakları nedeniyle bir
// uygulamaya gömülemezler. Yerine markanın karakteristik renginde bir monogram
// rozet çiziliyor: tanınabilir, hoş duruyor ve hukuken temiz.
// ============================================================================

struct BrandBadge: View {
    let brand: TRBrand
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(brand.color.gradient)
            Text(brand.initials)
                .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, size * 0.1)
        }
        .frame(width: size, height: size)
        .shadow(color: brand.color.opacity(0.3), radius: size * 0.08, y: size * 0.04)
        .accessibilityLabel(brand.name)
    }
}
