// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation

// ============================================================================
// MARK: - Motor Ailesi Kütüphanesi
// ============================================================================
//
// NEDEN AYRI BİR KÜTÜPHANE
// ------------------------
// Otomotiv gruplarında motorlar markalar arasında PAYLAŞILIR. VAG'ın 1.4 TDI'ı
// Polo'da da vardır, Fabia'da da, Ibiza'da da, A1'de de — ve üçü de aşağı
// yukarı aynı yakar. PSA'nın 1.5 BlueHDi'si Peugeot, Citroën ve 2017 sonrası
// Opel'de aynıdır. Renault'nun 1.5 dCi'si Dacia ve Nissan'da da çalışır.
//
// Bunları her model için ayrı ayrı yazmak üç sorun doğurur:
//   • aynı motor farklı yerlerde farklı rakam alır (tutarsızlık)
//   • bir motoru düzeltmek onlarca satır düzeltmek demektir
//   • kapsam büyüdükçe hata olasılığı doğrusal artar
//
// Bu yüzden motorlar BİR KEZ tanımlanır, modeller onlara REFERANS verir.
// Bir motorun tüketimini düzeltmek, o motoru kullanan bütün araçları düzeltir.
//
// TÜKETİM NASIL TÜRETİLİYOR
// -------------------------
// Motor tanımı hacim/doldurma/yakıt taşır; gövde ve şanzıman etkisi
// `ConsumptionModel.typical` içinde uygulanır (bkz. TurkeyVehicleCatalog).
// Yani aynı 1.5 TSI, Golf'te ve Tiguan'da farklı rakam verir — çünkü gövde
// farklıdır — ama ikisi de aynı motor tanımından türer.
// ============================================================================

struct EngineSpec {
    let name: String                    // "1.4 TDI" — sürücünün tanıdığı ad
    let power: Int                      // beygir
    let displacement: Double            // litre
    let fuel: VehicleProfile.FuelType
    let turbo: Bool
    /// Türkiye'de hangi şanzımanlarla sunuldu.
    let gearboxes: [Gearbox]

    init(_ name: String, _ power: Int, _ displacement: Double,
         _ fuel: VehicleProfile.FuelType = .benzin,
         turbo: Bool = true,
         _ gearboxes: [Gearbox] = [.manual, .automatic]) {
        self.name = name
        self.power = power
        self.displacement = displacement
        self.fuel = fuel
        self.turbo = turbo
        self.gearboxes = gearboxes
    }
}

/// Motor listesini belirli bir gövde için TREngine'lere açar.
func expand(_ specs: [EngineSpec], body: VehicleBodyClass) -> [TREngine] {
    specs.flatMap { spec in
        spec.gearboxes.map { gb in
            let t = ConsumptionModel.typical(displacement: spec.displacement,
                                             turbo: spec.turbo,
                                             fuel: spec.fuel,
                                             body: body,
                                             gearbox: gb)
            return TREngine(name: spec.name, power: spec.power, fuel: spec.fuel,
                            gearbox: gb, city: t.city, highway: t.highway,
                            source: .classTypical)
        }
    }
}

/// Elektrikli motor — tüketim doğrudan verilir (kWh/100 km).
func evEngine(_ name: String, _ power: Int, city: Double, highway: Double) -> TREngine {
    TREngine(name: name, power: power, fuel: .elektrik, gearbox: .automatic,
             city: city, highway: highway, source: .classTypical)
}

// ============================================================================
// MARK: - VAG · Volkswagen · Škoda · SEAT · Audi
// ============================================================================

enum VAG {
    // Benzin — atmosferik
    static let mpi10_60  = EngineSpec("1.0 MPI", 60, 1.0, turbo: false, [.manual])
    static let mpi10_75  = EngineSpec("1.0 MPI", 75, 1.0, turbo: false, [.manual])
    static let mpi10_80  = EngineSpec("1.0 MPI", 80, 1.0, turbo: false, [.manual])
    static let mpi16_110 = EngineSpec("1.6 MPI", 110, 1.6, turbo: false)

    // Benzin — turbo
    static let tsi10_95  = EngineSpec("1.0 TSI", 95, 1.0)
    static let tsi10_110 = EngineSpec("1.0 TSI", 110, 1.0)
    static let tsi10_115 = EngineSpec("1.0 TSI", 115, 1.0)
    static let tsi12_90  = EngineSpec("1.2 TSI", 90, 1.2)
    static let tsi12_110 = EngineSpec("1.2 TSI", 110, 1.2)
    static let tsi14_125 = EngineSpec("1.4 TSI", 125, 1.4)
    static let tsi14_150 = EngineSpec("1.4 TSI", 150, 1.4)
    static let tsi15_130 = EngineSpec("1.5 TSI", 130, 1.5)
    static let tsi15_150 = EngineSpec("1.5 TSI", 150, 1.5)
    static let etsi15_150 = EngineSpec("1.5 eTSI", 150, 1.5, .benzin, turbo: true, [.automatic])
    static let tsi18_180 = EngineSpec("1.8 TSI", 180, 1.8)
    static let tsi20_190 = EngineSpec("2.0 TSI", 190, 2.0, .benzin, turbo: true, [.automatic])
    static let tsi20_245 = EngineSpec("2.0 TSI", 245, 2.0, .benzin, turbo: true, [.automatic])

    // Dizel — kullanıcının işaret ettiği 1.4 TDI dahil
    static let tdi14_75  = EngineSpec("1.4 TDI", 75, 1.4, .dizel, turbo: true, [.manual])
    static let tdi14_90  = EngineSpec("1.4 TDI", 90, 1.4, .dizel)
    static let tdi16_90  = EngineSpec("1.6 TDI", 90, 1.6, .dizel, turbo: true, [.manual])
    static let tdi16_110 = EngineSpec("1.6 TDI", 110, 1.6, .dizel)
    static let tdi16_115 = EngineSpec("1.6 TDI", 115, 1.6, .dizel)
    static let tdi20_150 = EngineSpec("2.0 TDI", 150, 2.0, .dizel)
    static let tdi20_184 = EngineSpec("2.0 TDI", 184, 2.0, .dizel, turbo: true, [.automatic])
    static let tdi20_190 = EngineSpec("2.0 TDI", 190, 2.0, .dizel, turbo: true, [.automatic])
    static let tdi20_200 = EngineSpec("2.0 TDI", 200, 2.0, .dizel, turbo: true, [.automatic])

    // Audi rozet adları (aynı motorlar, farklı isim)
    static let tfsi30_110 = EngineSpec("30 TFSI", 110, 1.0, .benzin, turbo: true, [.automatic])
    static let tfsi35_150 = EngineSpec("35 TFSI", 150, 1.5, .benzin, turbo: true, [.automatic])
    static let tfsi40_190 = EngineSpec("40 TFSI", 190, 2.0, .benzin, turbo: true, [.automatic])
    static let atdi30_116 = EngineSpec("30 TDI", 116, 2.0, .dizel, turbo: true, [.automatic])
    static let atdi35_150 = EngineSpec("35 TDI", 150, 2.0, .dizel, turbo: true, [.automatic])
    static let atdi40_190 = EngineSpec("40 TDI", 190, 2.0, .dizel, turbo: true, [.automatic])

    /// Küçük sınıf (Polo/Fabia/Ibiza/A1) 2015+ yaygın kombinasyonu
    static let smallCar: [EngineSpec] = [mpi10_60, mpi10_75, mpi10_80, tsi10_95, tsi10_110,
                                         tsi12_90, tsi12_110, tdi14_75, tdi14_90]
    /// Kompakt sınıf (Golf/Octavia/Leon/A3)
    static let compact: [EngineSpec] = [tsi10_110, tsi12_110, tsi14_125, tsi14_150,
                                        tsi15_130, tsi15_150, etsi15_150,
                                        tdi16_110, tdi16_115, tdi20_150, tdi20_184]
    static let tdi16_120 = EngineSpec("1.6 TDI", 120, 1.6, .dizel)
    static let tdi20_180 = EngineSpec("2.0 TDI", 180, 2.0, .dizel, turbo: true, [.automatic])

    /// Orta sınıf (Passat/Superb)
    static let midsize: [EngineSpec] = [tsi14_150, tsi15_150, tsi18_180, tsi20_190,
                                        tdi16_120, tdi20_150, tdi20_190, tdi20_200]
    /// SUV sınıfı (Tiguan/Kodiaq/Ateca/Q3)
    static let suv: [EngineSpec] = [tsi15_150, tsi14_150, tsi20_190,
                                    tdi20_150, tdi20_190, tdi16_115]
}

// ============================================================================
// MARK: - Renault · Dacia · Nissan
// ============================================================================

enum RN {
    static let sce10_65  = EngineSpec("1.0 SCe", 65, 1.0, turbo: false, [.manual])
    static let sce10_72  = EngineSpec("1.0 SCe", 72, 1.0, turbo: false, [.manual])
    static let sce12_75  = EngineSpec("1.2 16V", 75, 1.2, turbo: false, [.manual])
    static let tce09_90  = EngineSpec("0.9 TCe", 90, 0.9, .benzin, turbo: true, [.manual])
    static let tce10_90  = EngineSpec("1.0 TCe", 90, 1.0)
    static let tce10_100 = EngineSpec("1.0 TCe", 100, 1.0)
    static let tce10_110 = EngineSpec("1.0 TCe", 110, 1.0)
    static let tce12_120 = EngineSpec("1.2 TCe", 120, 1.2)
    static let tce13_140 = EngineSpec("1.3 TCe", 140, 1.3)
    static let tce13_150 = EngineSpec("1.3 TCe", 150, 1.3, .benzin, turbo: true, [.automatic])
    static let tce13_160 = EngineSpec("1.3 TCe", 160, 1.3, .benzin, turbo: true, [.automatic])
    static let lpg10_100 = EngineSpec("1.0 ECO-G LPG", 100, 1.0, .lpg, turbo: true, [.manual])

    static let dci15_85  = EngineSpec("1.5 dCi", 85, 1.5, .dizel, turbo: true, [.manual])
    static let dci15_90  = EngineSpec("1.5 dCi", 90, 1.5, .dizel)
    static let dci15_95  = EngineSpec("1.5 Blue dCi", 95, 1.5, .dizel, turbo: true, [.manual])
    static let dci15_110 = EngineSpec("1.5 Blue dCi", 110, 1.5, .dizel)
    static let dci15_115 = EngineSpec("1.5 Blue dCi", 115, 1.5, .dizel)
    static let dci16_130 = EngineSpec("1.6 dCi", 130, 1.6, .dizel, turbo: true, [.manual])

    static let hyb16_145 = EngineSpec("1.6 E-Tech Hybrid", 145, 1.6, .benzin, turbo: false, [.automatic])
    static let hyb16_140 = EngineSpec("1.6 Hybrid", 140, 1.6, .benzin, turbo: false, [.automatic])
    static let hyb12_200 = EngineSpec("1.2 E-Tech Hybrid", 200, 1.2, .benzin, turbo: true, [.automatic])

    // Nissan rozetleri
    static let digt10_114 = EngineSpec("1.0 DIG-T", 114, 1.0)
    static let digt12_115 = EngineSpec("1.2 DIG-T", 115, 1.2)
    static let digt13_140 = EngineSpec("1.3 DIG-T", 140, 1.3)
    static let digt13_158 = EngineSpec("1.3 DIG-T", 158, 1.3, .benzin, turbo: true, [.automatic])
    static let epower_190 = EngineSpec("1.5 e-Power", 190, 1.5, .benzin, turbo: true, [.automatic])
    static let epower_204 = EngineSpec("1.5 e-Power", 204, 1.5, .benzin, turbo: true, [.automatic])
    static let njuke_hyb  = EngineSpec("1.6 Hybrid", 143, 1.6, .benzin, turbo: false, [.automatic])
    static let digt16_190 = EngineSpec("1.6 DIG-T", 190, 1.6, .benzin, turbo: true, [.manual])
    static let sce16_110  = EngineSpec("1.6 16V", 110, 1.6, turbo: false)
    static let dci16_120  = EngineSpec("1.6 dCi", 120, 1.6, .dizel, turbo: true, [.manual])
    static let dci16_145  = EngineSpec("1.6 dCi", 145, 1.6, .dizel, turbo: true, [.manual])
    static let dci23_130  = EngineSpec("2.3 dCi", 130, 2.3, .dizel, turbo: true, [.manual])
    static let dci23_145  = EngineSpec("2.3 dCi", 145, 2.3, .dizel)
}

// ============================================================================
// MARK: - PSA / Stellantis · Peugeot · Citroën · Opel (2017+) · DS
// ============================================================================

enum PSA {
    static let pt12_82   = EngineSpec("1.2 PureTech", 82, 1.2, turbo: false, [.manual])
    static let pt12_100  = EngineSpec("1.2 PureTech", 100, 1.2)
    static let pt12_110  = EngineSpec("1.2 PureTech", 110, 1.2)
    static let pt12_130  = EngineSpec("1.2 PureTech", 130, 1.2)
    static let pt12_155  = EngineSpec("1.2 PureTech", 155, 1.2, .benzin, turbo: true, [.automatic])
    static let thp16_165 = EngineSpec("1.6 THP", 165, 1.6, .benzin, turbo: true, [.automatic])

    static let bh15_100  = EngineSpec("1.5 BlueHDi", 100, 1.5, .dizel, turbo: true, [.manual])
    static let bh15_102  = EngineSpec("1.5 BlueHDi", 102, 1.5, .dizel, turbo: true, [.manual])
    static let bh15_130  = EngineSpec("1.5 BlueHDi", 130, 1.5, .dizel)
    static let bh16_100  = EngineSpec("1.6 BlueHDi", 100, 1.6, .dizel, turbo: true, [.manual])
    static let bh16_120  = EngineSpec("1.6 BlueHDi", 120, 1.6, .dizel)
    static let bh20_150  = EngineSpec("2.0 BlueHDi", 150, 2.0, .dizel)
    static let bh20_177  = EngineSpec("2.0 BlueHDi", 177, 2.0, .dizel, turbo: true, [.automatic])
    static let pt16_180  = EngineSpec("1.6 PureTech", 180, 1.6, .benzin, turbo: true, [.automatic])
    static let vti10_72  = EngineSpec("1.0 VTi", 72, 1.0, turbo: false, [.manual])

    // Opel'in kendi adlandırması (2017 öncesi ve sonrası)
    static let opel12_75  = EngineSpec("1.2", 75, 1.2, turbo: false, [.manual])
    static let opel12_100 = EngineSpec("1.2 Turbo", 100, 1.2)
    static let opel12_130 = EngineSpec("1.2 Turbo", 130, 1.2)
    static let opel14_140 = EngineSpec("1.4 Turbo", 140, 1.4)
    static let opel15_102 = EngineSpec("1.5 Dizel", 102, 1.5, .dizel, turbo: true, [.manual])
    static let opel15_130 = EngineSpec("1.5 Dizel", 130, 1.5, .dizel)
    static let opel16_110 = EngineSpec("1.6 CDTI", 110, 1.6, .dizel, turbo: true, [.manual])
    static let opel16_136 = EngineSpec("1.6 CDTI", 136, 1.6, .dizel)
    static let opel12_110 = EngineSpec("1.2 Turbo", 110, 1.2)
}

// ============================================================================
// MARK: - Ford
// ============================================================================

enum FordEng {
    static let eb10_100  = EngineSpec("1.0 EcoBoost", 100, 1.0, .benzin, turbo: true, [.manual])
    static let eb10_125  = EngineSpec("1.0 EcoBoost", 125, 1.0)
    static let eb10h_125 = EngineSpec("1.0 EcoBoost Hybrid", 125, 1.0)
    static let eb10h_155 = EngineSpec("1.0 EcoBoost Hybrid", 155, 1.0, .benzin, turbo: true, [.automatic])
    static let eb15_150  = EngineSpec("1.5 EcoBoost", 150, 1.5)
    static let eb15_182  = EngineSpec("1.5 EcoBoost", 182, 1.5, .benzin, turbo: true, [.automatic])
    static let tdci15_95 = EngineSpec("1.5 TDCi", 95, 1.5, .dizel, turbo: true, [.manual])
    static let ecb15_120 = EngineSpec("1.5 EcoBlue", 120, 1.5, .dizel)
    static let ecb15_100 = EngineSpec("1.5 EcoBlue", 100, 1.5, .dizel, turbo: true, [.manual])
    static let ecb20_150 = EngineSpec("2.0 EcoBlue", 150, 2.0, .dizel)
    static let ecb20_136 = EngineSpec("2.0 EcoBlue", 136, 2.0, .dizel, turbo: true, [.manual])
    static let ecb20_170 = EngineSpec("2.0 EcoBlue", 170, 2.0, .dizel, turbo: true, [.automatic])
    static let hyb25_190 = EngineSpec("2.5 Hybrid", 190, 2.5, .benzin, turbo: false, [.automatic])
    static let tdci20_150 = EngineSpec("2.0 TDCi", 150, 2.0, .dizel)
    static let tdci20_180 = EngineSpec("2.0 TDCi", 180, 2.0, .dizel, turbo: true, [.automatic])
    static let ecb20_130 = EngineSpec("2.0 EcoBlue", 130, 2.0, .dizel, turbo: true, [.manual])
}

// ============================================================================
// MARK: - Toyota
// ============================================================================

enum ToyotaEng {
    static let vvti133_99  = EngineSpec("1.33 Dual VVT-i", 99, 1.33, turbo: false, [.manual])
    static let vvti16_132  = EngineSpec("1.6 Valvematic", 132, 1.6, turbo: false)
    static let d4d14_90    = EngineSpec("1.4 D-4D", 90, 1.4, .dizel, turbo: true, [.manual])
    static let hyb15_116   = EngineSpec("1.5 Hybrid", 116, 1.5, .benzin, turbo: false, [.automatic])
    static let hyb18_122   = EngineSpec("1.8 Hybrid", 122, 1.8, .benzin, turbo: false, [.automatic])
    static let hyb18_140   = EngineSpec("1.8 Hybrid", 140, 1.8, .benzin, turbo: false, [.automatic])
    static let hyb20_196   = EngineSpec("2.0 Hybrid", 196, 2.0, .benzin, turbo: false, [.automatic])
    static let hyb25_218   = EngineSpec("2.5 Hybrid", 218, 2.5, .benzin, turbo: false, [.automatic])
    static let d4d24_150   = EngineSpec("2.4 D-4D", 150, 2.4, .dizel)
    static let d4d28_204   = EngineSpec("2.8 D-4D", 204, 2.8, .dizel)
    static let d4d16_112   = EngineSpec("1.6 D-4D", 112, 1.6, .dizel, turbo: true, [.manual])
    static let d4d20_143   = EngineSpec("2.0 D-4D", 143, 2.0, .dizel)
    static let vvti18_147   = EngineSpec("1.8 Valvematic", 147, 1.8, turbo: false)
}

// ============================================================================
// MARK: - Hyundai · Kia
// ============================================================================

enum HK {
    static let mpi10_67   = EngineSpec("1.0 MPI", 67, 1.0, turbo: false, [.manual])
    static let mpi12_84   = EngineSpec("1.2 MPI", 84, 1.2, turbo: false)
    static let mpi14_100  = EngineSpec("1.4 MPI", 100, 1.4, turbo: false)
    static let mpi16_123  = EngineSpec("1.6 MPI", 123, 1.6, turbo: false)
    static let mpi16_132  = EngineSpec("1.6 MPI", 132, 1.6, turbo: false)
    static let tgdi10_100 = EngineSpec("1.0 T-GDI", 100, 1.0)
    static let tgdi10_120 = EngineSpec("1.0 T-GDI", 120, 1.0)
    static let tgdi14_140 = EngineSpec("1.4 T-GDI", 140, 1.4)
    static let tgdi15_160 = EngineSpec("1.5 T-GDI", 160, 1.5, .benzin, turbo: true, [.automatic])
    static let tgdi16_150 = EngineSpec("1.6 T-GDI", 150, 1.6, .benzin, turbo: true, [.automatic])
    static let tgdi16_177 = EngineSpec("1.6 T-GDI", 177, 1.6, .benzin, turbo: true, [.automatic])
    static let crdi14_90  = EngineSpec("1.4 CRDi", 90, 1.4, .dizel, turbo: true, [.manual])
    static let crdi16_115 = EngineSpec("1.6 CRDi", 115, 1.6, .dizel)
    static let crdi16_136 = EngineSpec("1.6 CRDi", 136, 1.6, .dizel)
    static let hyb16_141  = EngineSpec("1.6 GDI Hybrid", 141, 1.6, .benzin, turbo: false, [.automatic])
    static let hyb16_230  = EngineSpec("1.6 T-GDI Hybrid", 230, 1.6, .benzin, turbo: true, [.automatic])
    static let crdi20_185 = EngineSpec("2.0 CRDi", 185, 2.0, .dizel, turbo: true, [.automatic])
    static let crdi22_200 = EngineSpec("2.2 CRDi", 200, 2.2, .dizel, turbo: true, [.automatic])
    static let crdi25_170 = EngineSpec("2.5 CRDi", 170, 2.5, .dizel)
    static let mpi20_155  = EngineSpec("2.0 MPI", 155, 2.0, turbo: false, [.automatic])
}

// ============================================================================
// MARK: - Honda
// ============================================================================

enum HondaEng {
    static let vtec15_130 = EngineSpec("1.5 i-VTEC", 130, 1.5, turbo: false)
    static let vtec16_125 = EngineSpec("1.6 i-VTEC", 125, 1.6, turbo: false)
    static let turbo15_182 = EngineSpec("1.5 VTEC Turbo", 182, 1.5, .benzin, turbo: true, [.automatic])
    static let idtec16_120 = EngineSpec("1.6 i-DTEC", 120, 1.6, .dizel)
    static let hev15_131  = EngineSpec("1.5 e:HEV Hybrid", 131, 1.5, .benzin, turbo: false, [.automatic])
    static let hev20_184  = EngineSpec("2.0 e:HEV Hybrid", 184, 2.0, .benzin, turbo: false, [.automatic])
    static let vtec15_120 = EngineSpec("1.5 i-VTEC", 120, 1.5, turbo: false)
    static let vtec13_102 = EngineSpec("1.3 i-VTEC", 102, 1.3, turbo: false)
}

// ============================================================================
// MARK: - Fiat / Tofaş
// ============================================================================

enum FiatEng {
    static let fire14_77  = EngineSpec("1.4 Fire", 77, 1.4, turbo: false, [.manual])
    static let fire14_95  = EngineSpec("1.4 Fire", 95, 1.4, turbo: false)
    static let firefly10_100 = EngineSpec("1.0 FireFly", 100, 1.0)
    static let etorq16_110 = EngineSpec("1.6 E-Torq", 110, 1.6, turbo: false, [.automatic])
    static let mjet13_95  = EngineSpec("1.3 MultiJet", 95, 1.3, .dizel)
    static let mjet16_120 = EngineSpec("1.6 MultiJet", 120, 1.6, .dizel)
    static let mjet16_130 = EngineSpec("1.6 MultiJet", 130, 1.6, .dizel)
    static let hyb15_130  = EngineSpec("1.5 Hybrid", 130, 1.5, .benzin, turbo: true, [.automatic])
    static let fire12_69  = EngineSpec("1.2 Fire", 69, 1.2, turbo: false, [.manual])
    static let twinair09_85 = EngineSpec("0.9 TwinAir", 85, 0.9)
    static let mjet23_130 = EngineSpec("2.3 MultiJet", 130, 2.3, .dizel, turbo: true, [.manual])
    static let mjet23_160 = EngineSpec("2.3 MultiJet", 160, 2.3, .dizel)
}

// ============================================================================
// MARK: - Premium rozet adlandırmaları
// ============================================================================

enum Premium {
    // Mercedes
    static let mbA180  = EngineSpec("A 180", 136, 1.3, .benzin, turbo: true, [.automatic])
    static let mbA200  = EngineSpec("A 200", 163, 1.3, .benzin, turbo: true, [.automatic])
    static let mbA180d = EngineSpec("A 180 d", 116, 2.0, .dizel, turbo: true, [.automatic])
    static let mbC180  = EngineSpec("C 180", 170, 1.5, .benzin, turbo: true, [.automatic])
    static let mbC200  = EngineSpec("C 200", 204, 2.0, .benzin, turbo: true, [.automatic])
    static let mbC220d = EngineSpec("C 220 d", 200, 2.0, .dizel, turbo: true, [.automatic])
    static let mbE200  = EngineSpec("E 200", 204, 2.0, .benzin, turbo: true, [.automatic])
    static let mbE220d = EngineSpec("E 220 d", 197, 2.0, .dizel, turbo: true, [.automatic])
    static let mbCLA180 = EngineSpec("CLA 180", 136, 1.3, .benzin, turbo: true, [.automatic])
    static let mbGLA200 = EngineSpec("GLA 200", 163, 1.3, .benzin, turbo: true, [.automatic])
    static let mb110cdi = EngineSpec("110 CDI", 102, 1.7, .dizel, turbo: true, [.manual])
    static let mb116cdi = EngineSpec("116 CDI", 163, 2.0, .dizel, turbo: true, [.automatic])
    static let mbB180   = EngineSpec("B 180", 136, 1.3, .benzin, turbo: true, [.automatic])
    static let mbB200d  = EngineSpec("B 200 d", 150, 2.0, .dizel, turbo: true, [.automatic])
    static let mbGLC200 = EngineSpec("GLC 200", 197, 2.0, .benzin, turbo: true, [.automatic])
    static let mbGLC220d = EngineSpec("GLC 220 d", 194, 2.0, .dizel, turbo: true, [.automatic])
    static let mbV220d  = EngineSpec("V 220 d", 163, 2.0, .dizel, turbo: true, [.automatic])

    // BMW
    static let bmw116i = EngineSpec("116i", 109, 1.5, .benzin, turbo: true, [.automatic])
    static let bmw118i = EngineSpec("118i", 136, 1.5, .benzin, turbo: true, [.automatic])
    static let bmw116d = EngineSpec("116d", 116, 1.5, .dizel, turbo: true, [.automatic])
    static let bmw318i = EngineSpec("318i", 156, 2.0, .benzin, turbo: true, [.automatic])
    static let bmw320i = EngineSpec("320i", 184, 2.0, .benzin, turbo: true, [.automatic])
    static let bmw320d = EngineSpec("320d", 190, 2.0, .dizel, turbo: true, [.automatic])
    static let bmw520i = EngineSpec("520i", 184, 2.0, .benzin, turbo: true, [.automatic])
    static let bmw520d = EngineSpec("520d", 190, 2.0, .dizel, turbo: true, [.automatic])
    static let bmwX1_18i = EngineSpec("sDrive18i", 136, 1.5, .benzin, turbo: true, [.automatic])
    static let bmwX1_18d = EngineSpec("sDrive18d", 150, 2.0, .dizel, turbo: true, [.automatic])
    static let bmw420i = EngineSpec("420i", 184, 2.0, .benzin, turbo: true, [.automatic])
    static let bmw420d = EngineSpec("420d", 190, 2.0, .dizel, turbo: true, [.automatic])
    static let bmwX3_20i = EngineSpec("xDrive20i", 184, 2.0, .benzin, turbo: true, [.automatic])
    static let bmwX5_30d = EngineSpec("xDrive30d", 286, 3.0, .dizel, turbo: true, [.automatic])

    // Volvo
    static let volvoB3 = EngineSpec("B3", 163, 2.0, .benzin, turbo: true, [.automatic])
    static let volvoB4 = EngineSpec("B4", 197, 2.0, .benzin, turbo: true, [.automatic])
    static let volvoB5 = EngineSpec("B5", 250, 2.0, .benzin, turbo: true, [.automatic])
    static let volvoD3 = EngineSpec("D3", 150, 2.0, .dizel, turbo: true, [.automatic])
    static let volvoD4 = EngineSpec("D4", 190, 2.0, .dizel, turbo: true, [.automatic])
    static let volvoT2 = EngineSpec("T2", 122, 1.5, .benzin, turbo: true, [.automatic])
}

// ============================================================================
// MARK: - Diğer
// ============================================================================

enum Misc {
    // Suzuki
    static let szBoost14_129 = EngineSpec("1.4 Boosterjet Hybrid", 129, 1.4)
    static let szVvt16_120   = EngineSpec("1.6 VVT", 120, 1.6, turbo: false)
    static let szDdis16_120  = EngineSpec("1.6 DDiS", 120, 1.6, .dizel, turbo: true, [.manual])
    static let szVvt15_102   = EngineSpec("1.5 VVT", 102, 1.5, turbo: false)
    static let szBoost10_111 = EngineSpec("1.0 Boosterjet", 111, 1.0)

    // MG / Chery / Çin
    static let mgVti15_106 = EngineSpec("1.5 VTi", 106, 1.5, .benzin, turbo: false, [.automatic])
    static let mgTgdi10_111 = EngineSpec("1.0 T-GDI", 111, 1.0, .benzin, turbo: true, [.automatic])
    static let cheryTci16_186 = EngineSpec("1.6 TCI", 186, 1.6, .benzin, turbo: true, [.automatic])
    static let cheryTci15_147 = EngineSpec("1.5 TCI", 147, 1.5, .benzin, turbo: true, [.automatic])
    static let szVvt12_90     = EngineSpec("1.2 Dualjet", 90, 1.2, turbo: false)
    static let mgTgdi15_162   = EngineSpec("1.5 T-GDI", 162, 1.5, .benzin, turbo: true, [.automatic])

    // Mitsubishi
    static let miDid16_115 = EngineSpec("1.6 DI-D", 115, 1.6, .dizel)
    static let miMivec16_117 = EngineSpec("1.6 MIVEC", 117, 1.6, turbo: false)
    static let miDid24_181 = EngineSpec("2.4 DI-D", 181, 2.4, .dizel)
    static let miMivec12_80 = EngineSpec("1.2 MIVEC", 80, 1.2, turbo: false)
    static let miPhev24_224 = EngineSpec("2.4 PHEV", 224, 2.4, .benzin, turbo: false, [.automatic])

    // Jeep
    static let jeepMair14_140 = EngineSpec("1.4 MultiAir", 140, 1.4)
    static let jeepMjet16_120 = EngineSpec("1.6 MultiJet", 120, 1.6, .dizel)
    static let jeepMjet20_170 = EngineSpec("2.0 MultiJet", 170, 2.0, .dizel, turbo: true, [.automatic])
    static let jeepGse13_150  = EngineSpec("1.3 GSE Turbo", 150, 1.3, .benzin, turbo: true, [.automatic])

    // Alfa Romeo
    static let alfaJtdm16_120 = EngineSpec("1.6 JTDm", 120, 1.6, .dizel)
    static let alfaJtdm22_190 = EngineSpec("2.2 JTDm", 190, 2.2, .dizel, turbo: true, [.automatic])
    static let alfaTb20_200   = EngineSpec("2.0 Turbo Benzin", 200, 2.0, .benzin, turbo: true, [.automatic])
    static let alfaMair14_170 = EngineSpec("1.4 MultiAir", 170, 1.4)

    // Mini
    static let miniOne10_102  = EngineSpec("One 1.5", 102, 1.5)
    static let miniCooper15_136 = EngineSpec("Cooper 1.5", 136, 1.5)
    static let miniCooperS_192 = EngineSpec("Cooper S 2.0", 192, 2.0, .benzin, turbo: true, [.automatic])
    static let miniD_150      = EngineSpec("Cooper D 2.0", 150, 2.0, .dizel, turbo: true, [.automatic])

    // Land Rover
    static let lrTd4_180 = EngineSpec("2.0 TD4", 180, 2.0, .dizel, turbo: true, [.automatic])
    static let lrSi4_200 = EngineSpec("2.0 Si4", 200, 2.0, .benzin, turbo: true, [.automatic])

    // Isuzu
    static let isuzuDmax19_164 = EngineSpec("1.9 Dizel", 164, 1.9, .dizel)
}
