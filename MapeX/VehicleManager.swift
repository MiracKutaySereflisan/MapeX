// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import SwiftUI
import MapKit

// ============================================================================
// MARK: - Araç Profili
// ============================================================================
//
// ELEKTRİKLİ ARAÇ — ESKİ KODDAKİ BİRİM HATASI
// -------------------------------------------
// Önceki hâlde yakıt tipi "Elektrik" seçilse bile form "L/100 km" ve "₺/Litre"
// diyordu; hesap da litre üzerinden yapılıyordu. Elektrikli araçta tüketim
// kWh/100 km, fiyat ₺/kWh'tir. Artık birimler yakıt tipine göre değişiyor ve
// hesap doğru birimle yapılıyor.
// ============================================================================

struct VehicleProfile: Codable, Equatable {
    var name: String = ""
    var make: String = ""
    var model: String = ""
    var year: Int = 2020
    /// Gövde sınıfı — viraj tavsiye hızını SSF üzerinden etkiler.
    /// Bkz. VehicleDynamics.swift
    var bodyClass: VehicleBodyClass = .sedan
    /// Ölçülmüş boyutlar (NHTSA'dan veya elle). Boşsa sınıf ortalaması kullanılır.
    var dimensions: VehicleDimensions = VehicleDimensions()
    /// Yük durumu — ağırlık merkezini yükseltir, SSF'i düşürür.
    var load: LoadState = .solo
    /// Katalogdan gelen motor açıklaması ("4 sil., 1.4 L, Automatic (S8)").
    var engineText: String = ""
    /// Tüketim verisinin kaynağı — kullanıcı rakamın nereden geldiğini bilsin.
    var consumptionSource: String = ""
    var fuelType: FuelType = .benzin
    /// Şehir içi tüketim — benzin/dizel/LPG için L/100 km, elektrik için kWh/100 km.
    var cityConsumption: Double = 8.5
    /// Otoban tüketimi, aynı birim.
    var highwayConsumption: Double = 5.8
    /// Birim fiyat — ₺/L veya ₺/kWh.
    ///
    /// Yalnızca hiçbir fiyat kaynağı yokken kullanılan son çare. 47.0 idi ve
    /// gerçeğin çok altında kalmıştı; `FuelPriceService.baselinePrices`in
    /// benzin değeriyle hizalandı (11 Ağu 2026).
    var unitPrice: Double = 68.90

    enum FuelType: String, Codable, CaseIterable {
        case benzin = "Benzin"
        case dizel = "Dizel"
        case lpg = "LPG"
        case elektrik = "Elektrik"

        var icon: String {
            switch self {
            case .benzin: return "fuelpump.fill"
            case .dizel: return "fuelpump"
            case .lpg: return "flame.fill"
            case .elektrik: return "bolt.car.fill"
            }
        }

        /// Tüketim birimi.
        var consumptionUnit: String { self == .elektrik ? "kWh/100 km" : "L/100 km" }
        /// Miktar birimi.
        var amountUnit: String { self == .elektrik ? "kWh" : "L" }
        /// Fiyat birimi.
        var priceUnit: String { self == .elektrik ? "₺ / kWh" : "₺ / Litre" }

        /// Makul varsayılanlar — kullanıcı hiçbir şey girmezse bile mantıklı
        /// bir tahmin çıksın.
        var defaultCity: Double { self == .elektrik ? 18.0 : (self == .lpg ? 11.0 : 8.5) }
        var defaultHighway: Double { self == .elektrik ? 15.5 : (self == .lpg ? 7.5 : 5.8) }
        var defaultPrice: Double {
            switch self {
            case .benzin: return 52.0
            case .dizel: return 54.0
            case .lpg: return 27.0
            case .elektrik: return 7.5
            }
        }
    }
}

// MARK: - Tüketim tahmini

struct FuelEstimate {
    let amount: Double            // litre veya kWh
    let costTL: Double
    let highwayRatio: Double
    let unit: String
    var unitPrice: Double = 0
    var priceSource: String = ""

    var priceText: String {
        String(format: "%.2f ₺/%@ · %@", unitPrice, unit, priceSource)
    }

    var summary: String { String(format: "≈ %.1f %@  •  ≈ %.0f ₺", amount, unit, costTL) }

    var profileText: String {
        let hw = Int(highwayRatio * 100)
        return "%\(hw) otoban • %\(100 - hw) şehir içi"
    }

    /// Rota + araç profilinden tahmin. Ana aktöre bağlı değildir; arka planda
    /// yapılan rota analizinden çağrılabilir.
    ///
    /// Otoban/şehir içi karışımı, rotanın ortalama hızından tahmin edilen
    /// `highwayRatio` ile ağırlıklandırılır. Bu, düz "ortalama tüketim"e göre
    /// belirgin biçimde doğrudur: 400 km otoyol ile 400 km şehir içi aynı aracı
    /// çok farklı tüketir.
    /// - Parameter livePrice: konuma göre çekilmiş güncel birim fiyat. Varsa
    ///   kullanıcının elle girdiği fiyatın yerine geçer — altı ay önce yazılmış
    ///   47 ₺ ile hesap yapmak tahmini anlamsız kılıyordu.
    nonisolated static func make(for route: MKRoute,
                                 profile: VehicleProfile,
                                 livePrice: Double? = nil,
                                 priceSource: String? = nil) -> FuelEstimate? {
        guard !profile.name.isEmpty else { return nil }
        let ratio = RouteEngine.highwayRatio(of: route)
        let blended = profile.highwayConsumption * ratio + profile.cityConsumption * (1 - ratio)
        let km = route.distance / 1000
        let amount = km * blended / 100
        let unitPrice = livePrice ?? profile.unitPrice
        return FuelEstimate(amount: amount,
                            costTL: amount * unitPrice,
                            highwayRatio: ratio,
                            unit: profile.fuelType.amountUnit,
                            unitPrice: unitPrice,
                            priceSource: priceSource ?? "elle girilen")
    }
}

// MARK: - Yönetici

@MainActor
final class VehicleManager: ObservableObject {
    static let shared = VehicleManager()

    @Published var profile: VehicleProfile { didSet { save() } }
    @Published var hasVehicle: Bool

    private init() {
        if let data = UserDefaults.standard.data(forKey: "vehicleProfile"),
           let p = try? JSONDecoder().decode(VehicleProfile.self, from: data) {
            profile = p
            hasVehicle = !p.name.isEmpty
        } else {
            profile = VehicleProfile()
            hasVehicle = false
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: "vehicleProfile")
        }
        hasVehicle = !profile.name.isEmpty
    }

    func estimate(for route: MKRoute) -> FuelEstimate? {
        FuelEstimate.make(for: route, profile: profile)
    }

    /// Aracın güncel stabilite hesabı — viraj hızı bunu kullanır.
    var stability: StabilityCalculator.Result {
        guard hasVehicle else {
            return StabilityCalculator.Result(ssf: 1.40, cogHeightMM: 0, trackMM: 0,
                                              speedFactor: 1.0, isMeasured: false)
        }
        return StabilityCalculator.compute(bodyClass: profile.bodyClass,
                                           dimensions: profile.dimensions,
                                           load: profile.load)
    }


    /// Türkiye kataloğundan seçilen aracı profile uygular.
    ///
    /// Tek seferde: ad, motor adı (sürücünün tanıdığı biçimde), yakıt tipi,
    /// tüketim, gövde sınıfı ve fiziksel ölçüler. Kullanıcı hiçbir sayı girmez.
    func apply(brand: TRBrand, model: TRModel, engine: TREngine) {
        var p = profile
        p.name = "\(brand.name) \(model.name)"
        p.year = Int(model.years.prefix(4)) ?? p.year
        p.make = brand.name
        p.model = model.name
        p.engineText = engine.displayName
        p.fuelType = engine.fuel
        p.cityConsumption = engine.city
        p.highwayConsumption = engine.highway
        p.bodyClass = model.bodyClass
        p.consumptionSource = engine.source.rawValue
        p.dimensions.widthMM = model.widthMM
        p.dimensions.heightMM = model.heightMM
        p.dimensions.kerbWeightKg = model.kerbWeightKg
        p.dimensions.source = "Türkiye kataloğu"
        if p.unitPrice <= 0 { p.unitPrice = engine.fuel.defaultPrice }
        profile = p

        // Ölçüm varsa katalog değerini hemen ölçüme göre kaydır
        FuelLogStore.shared.reapply()
    }

}

// ============================================================================
// MARK: - Tarife Ekranı
// ============================================================================

struct TollTariffView: View {
    @ObservedObject private var store = TollTariffStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editingKey: String?
    @State private var editValue: String = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Sürüm", value: store.tariff.version)
                LabeledContent("Geçerlilik", value: store.tariff.validFromText)
                LabeledContent("Kaynak", value: store.lastRefresh == nil ? "Gömülü" : "Uzaktan")
                if let r = store.lastRefresh {
                    LabeledContent("Son güncelleme", value: r.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("Tarife Bilgisi")
            } footer: {
                Text(store.tariff.sourceNote)
            }

            Section {
                TextField("https://…/kgm-tarife.json", text: $store.tariffURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                Button {
                    Task { await store.refresh() }
                } label: {
                    HStack {
                        Label("Tarifeyi Güncelle", systemImage: "arrow.clockwise")
                        if store.isRefreshing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(store.isRefreshing || store.tariffURL.isEmpty)

                if let err = store.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                Button("Gömülü Tarifeye Dön", role: .destructive) {
                    store.resetToBundled()
                }
            } header: {
                Text("Uzaktan Tarife")
            } footer: {
                Text("KGM tarifesini JSON'a çeviren bir servis adresi gir. Uygulama açılışta değil, yalnızca bu düğmeye basınca indirir. Tarife yılda 1–2 kez değişir.")
            }

            Section("Köprü / Tünel") {
                ForEach(store.tariff.crossings) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.subheadline)
                            if c.oneWayOnly {
                                Text("tek yön ücretli").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(Int(c.fee(for: store.vehicleClass))) ₺")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingKey = c.key
                        editValue = String(Int(c.fee(for: .class1)))
                    }
                }
            }

            Section {
                ForEach(store.tariff.corridors) { c in
                    HStack {
                        Text(c.name).font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f ₺/km", c.ratePerKm))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Otoyol Koridorları")
            } footer: {
                Text("Gerçek tarife giriş–çıkış gişesi çiftine göre kademelidir. Buradaki ₺/km değerleri yayımlanmış tam güzergâh fiyatlarından türetilmiştir; koridor içi kısa mesafelerde sapma olabilir.")
            }
        }
        .navigationTitle("Geçiş Ücretleri")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Bitti") { dismiss() }
            }
        }
        .alert("Ücreti Güncelle", isPresented: Binding(get: { editingKey != nil },
                                                       set: { if !$0 { editingKey = nil } })) {
            TextField("₺", text: $editValue).keyboardType(.numberPad)
            Button("Kaydet") {
                if let key = editingKey, let v = Double(editValue) {
                    store.overrideFee(v, forCrossing: key)
                }
                editingKey = nil
            }
            Button("İptal", role: .cancel) { editingKey = nil }
        } message: {
            Text("1. sınıf otomobil ücreti. Diğer sınıflar bu değerden türetilir.")
        }
    }
}
