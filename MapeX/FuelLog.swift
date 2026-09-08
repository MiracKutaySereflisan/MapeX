// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import SwiftUI

// ============================================================================
// MARK: - Depo Kaydı — Gerçek Tüketimin Tek Dürüst Kaynağı
// ============================================================================
//
// SORUN
// -----
// Hiçbir katalog, senin arabanın SENİN elinde ne yaktığını bilemez. Fabrika
// değeri iyimserdir; "sınıf tipiği" bir tahmindir. Aynı Octavia 1.6 TDI,
// şehirde tıkanıklıkta 7 litre, uzun yolda 4,2 litre yakar — ve sürücüsüne
// göre de değişir.
//
// Katalog rakamını "gerçek" diye sunmak, uydurulmuş bir kesinlik olurdu.
//
// ÇÖZÜM — TAM DEPO YÖNTEMİ
// ------------------------
// Sürücülerin onlarca yıldır kullandığı yöntem, ve tek doğru olanı:
//
//      1. Depoyu AĞZINA KADAR doldur, kilometreyi not et
//      2. Normal kullan
//      3. Tekrar AĞZINA KADAR doldur, aldığın litreyi ve kilometreyi gir
//
//      tüketim = alınan litre / (yeni km − eski km) × 100
//
// İkinci dolumdaki litre, tam olarak iki dolum arasında YAKILAN litredir —
// çünkü depo her iki ölçümde de aynı seviyededir. Bu yüzden "tam depo" şartı
// önemli; yarım dolumda hesap bozulur ve uygulama bunu açıkça söyler.
//
// ŞEHİR İÇİ / OTOBAN AYRIŞTIRMASI
// -------------------------------
// Tek bir ortalama, rota maliyeti için yetmez: 400 km otoyol ile 400 km şehir
// içi aynı aracı çok farklı tüketir. Uygulama sürüş sırasında zaten her
// yolculuğun otoban oranını hesaplıyor (ortalama hızdan). Dolumlar arasındaki
// yolculukların ağırlıklı otoban oranı biliniyorsa, ölçülen ortalama tüketim
// iki bileşene ayrıştırılabilir:
//
//      ölçülen = şehir × (1 − oran) + otoban × oran
//
// Tek denklem, iki bilinmeyen. Bu yüzden katalogdaki ŞEHİR/OTOBAN ORANI
// korunur ve yalnızca genel SEVİYE ölçüme göre kaydırılır:
//
//      ölçek = ölçülen / katalog_karışımı
//      şehir_yeni  = şehir_katalog  × ölçek
//      otoban_yeni = otoban_katalog × ölçek
//
// Böylece tek ölçümle bile doğru yöne gidilir; ölçüm biriktikçe seviye
// gerçeğe oturur. Motor karakteristiğini (şehir/otoban farkı) katalogdan
// almak, onu tek bir dolumdan uydurmaya çalışmaktan çok daha sağlamdır.
// ============================================================================

struct FuelFillUp: Codable, Identifiable {
    var id = UUID()
    /// Kilometre sayacı değeri (km).
    var odometer: Double
    /// Alınan miktar (litre veya kWh).
    var amount: Double
    /// Ödenen tutar (₺) — isteğe bağlı, gerçek ₺/km için.
    var cost: Double?
    /// Tam depo mu — değilse tüketim hesabına katılmaz.
    var isFull: Bool
    var date: Date

    /// Bu dolumla bir önceki arasındaki mesafe hesaplandıktan sonra doldurulur.
    var computedConsumption: Double?
}

@MainActor
final class FuelLogStore: ObservableObject {
    static let shared = FuelLogStore()

    @Published private(set) var fillUps: [FuelFillUp] = []

    private init() { load() }

    // MARK: Kayıt

    func add(odometer: Double, amount: Double, cost: Double?, isFull: Bool) {
        var entry = FuelFillUp(odometer: odometer, amount: amount,
                               cost: cost, isFull: isFull, date: Date())

        // Bir önceki TAM dolumu bul — tüketim ancak iki tam dolum arasında
        // hesaplanabilir.
        if isFull,
           let previous = fillUps.last(where: { $0.isFull && $0.odometer < odometer }) {
            let distance = odometer - previous.odometer
            if distance > 50 {
                entry.computedConsumption = amount / distance * 100
            }
        }

        fillUps.append(entry)
        fillUps.sort { $0.odometer < $1.odometer }
        persist()
        applyToProfile()
    }

    func remove(_ id: UUID) {
        fillUps.removeAll { $0.id == id }
        persist()
        applyToProfile()
    }

    func clear() {
        fillUps = []
        persist()
    }

    // MARK: Sonuçlar

    /// Ölçülen ortalama tüketim (L/100 km veya kWh/100 km).
    ///
    /// Son beş geçerli ölçümün MESAFE AĞIRLIKLI ortalaması. Ağırlıklandırma
    /// önemli: 800 km'lik bir dolum, 120 km'likten daha güvenilir bilgi taşır.
    var measuredConsumption: Double? {
        let valid = fillUps.filter { $0.computedConsumption != nil }
        guard !valid.isEmpty else { return nil }

        let recent = Array(valid.suffix(5))
        var totalAmount = 0.0
        var totalDistance = 0.0

        for (i, f) in recent.enumerated() {
            guard let _ = f.computedConsumption else { continue }
            // Bu dolumun kapsadığı mesafeyi geri hesapla
            let previousOdo: Double
            if i > 0 {
                previousOdo = recent[i - 1].odometer
            } else if let before = fillUps.last(where: { $0.isFull && $0.odometer < f.odometer }) {
                previousOdo = before.odometer
            } else { continue }

            let d = f.odometer - previousOdo
            guard d > 50 else { continue }
            totalAmount += f.amount
            totalDistance += d
        }

        guard totalDistance > 100 else { return recent.last?.computedConsumption }
        return totalAmount / totalDistance * 100
    }

    /// Ölçüme dayalı gerçek birim maliyet (₺/km).
    var measuredCostPerKm: Double? {
        let withCost = fillUps.filter { $0.cost != nil && $0.computedConsumption != nil }
        guard withCost.count >= 1 else { return nil }
        let recent = Array(withCost.suffix(5))
        var money = 0.0, distance = 0.0
        for f in recent {
            guard let c = f.cost, let cons = f.computedConsumption, cons > 0 else { continue }
            let d = f.amount / cons * 100
            money += c; distance += d
        }
        return distance > 50 ? money / distance : nil
    }

    /// Son dolumda fiilen ödenen birim fiyat (₺/L veya ₺/kWh).
    ///
    /// Bu, herhangi bir fiyat servisinden daha doğrudur: kullanıcının kendi
    /// ilinde, kendi istasyonunda, kendi ödediği fiyattır. Ve hiçbir kurulum
    /// gerektirmez — zaten depo kaydı için girilen iki sayıdan çıkar.
    var lastPaidPricePerUnit: Double? {
        guard let last = fillUps.last(where: { $0.cost != nil && $0.amount > 0 }),
              let cost = last.cost, cost > 0 else { return nil }
        let price = cost / last.amount
        // Saçma değerlere karşı koruma (yanlış birim, hatalı giriş)
        return (price > 1 && price < 500) ? price : nil
    }

    /// Fiyat ne kadar taze — akaryakıt fiyatı sık değişir, 20 günden eskisi
    /// artık güncel sayılmaz.
    var lastPaidPriceIsFresh: Bool {
        guard let last = fillUps.last(where: { $0.cost != nil }) else { return false }
        return Date().timeIntervalSince(last.date) < 20 * 24 * 3600
    }

    var validMeasurementCount: Int {
        fillUps.filter { $0.computedConsumption != nil }.count
    }

    /// Kaç ölçüm daha gerekiyor — kullanıcıya ilerleme göstermek için.
    /// İki tam dolum bir ölçüm eder; üç ölçüm sonrasında sonuç oturur.
    var confidenceText: String {
        switch validMeasurementCount {
        case 0: return "Henüz ölçüm yok — iki tam depo gerekiyor"
        case 1: return "1 ölçüm · ilk tahmin"
        case 2: return "2 ölçüm · oturuyor"
        default: return "\(validMeasurementCount) ölçüm · güvenilir"
        }
    }

    // MARK: Profile uygulama

    /// Ölçülen tüketimi araç profiline yansıtır.
    ///
    /// Katalogdaki şehir/otoban ORANI korunur, yalnızca seviye kaydırılır —
    /// gerekçesi dosya başındaki açıklamada.
    /// Dışarıdan tetiklenebilen yeniden uygulama (araç değişince).
    func reapply() { applyToProfile() }

    private func applyToProfile() {
        guard let measured = measuredConsumption, measured > 0 else { return }
        let manager = VehicleManager.shared
        var p = manager.profile
        guard p.cityConsumption > 0, p.highwayConsumption > 0 else { return }

        // Katalog karışımını tipik bir kullanım profiliyle (%45 otoban) hesapla
        let mixRatio = 0.45
        let catalogMix = p.highwayConsumption * mixRatio + p.cityConsumption * (1 - mixRatio)
        guard catalogMix > 0 else { return }

        let scale = measured / catalogMix
        // Aşırı sapmalara karşı koruma: tek hatalı giriş profili mahvetmesin
        guard scale > 0.5, scale < 2.0 else { return }

        p.cityConsumption = ((p.cityConsumption * scale) * 10).rounded() / 10
        p.highwayConsumption = ((p.highwayConsumption * scale) * 10).rounded() / 10
        p.consumptionSource = "senin ölçümün · \(validMeasurementCount) depo"
        manager.profile = p
    }

    // MARK: Saklama

    private func persist() {
        if let d = try? JSONEncoder().encode(fillUps) {
            UserDefaults.standard.set(d, forKey: "fuelFillUps")
        }
    }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: "fuelFillUps"),
           let f = try? JSONDecoder().decode([FuelFillUp].self, from: d) {
            fillUps = f
        }
    }
}

// ============================================================================
// MARK: - Depo Kaydı Ekranı
// ============================================================================

struct FuelLogView: View {
    @ObservedObject private var store = FuelLogStore.shared
    @ObservedObject private var vehicle = VehicleManager.shared

    @State private var odometer: Double = 0
    @State private var amount: Double = 0
    @State private var cost: Double = 0
    @State private var isFull = true
    @State private var showAdd = false

    private var unit: String { vehicle.profile.fuelType.amountUnit }

    var body: some View {
        Form {
            // ── Sonuç ────────────────────────────────────────────────────────
            Section {
                if let m = store.measuredConsumption {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.1f %@/100 km", m, unit))
                                .font(.title2.bold())
                                .foregroundStyle(.green)
                            Text(store.confidenceText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)

                    if let cpk = store.measuredCostPerKm {
                        LabeledContent("Gerçek maliyet",
                                       value: String(format: "%.2f ₺/km", cpk))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Henüz ölçüm yok")
                            .font(.headline)
                        Text("Depoyu ağzına kadar doldurup kilometreyi kaydet. Bir sonraki tam dolumda aldığın litreyi girince gerçek tüketimin hesaplanır.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Ölçülen Tüketim")
            } footer: {
                Text("Bu rakam katalogdaki tahminin yerine geçer ve rota maliyetleri buna göre hesaplanır.")
            }

            // ── Ekleme ───────────────────────────────────────────────────────
            Section {
                Button {
                    odometer = store.fillUps.last?.odometer ?? 0
                    amount = 0; cost = 0; isFull = true
                    showAdd = true
                } label: {
                    Label("Dolum Ekle", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
            }

            // ── Geçmiş ───────────────────────────────────────────────────────
            if !store.fillUps.isEmpty {
                Section("Dolumlar") {
                    ForEach(store.fillUps.reversed()) { f in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(String(format: "%.0f km", f.odometer))
                                    .font(.body.weight(.medium))
                                    .monospacedDigit()
                                if !f.isFull {
                                    Text("yarım")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Spacer()
                                Text(String(format: "%.1f %@", f.amount, unit))
                                    .font(.body).monospacedDigit()
                            }
                            HStack {
                                Text(f.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let c = f.computedConsumption {
                                    Text(String(format: "%.1f %@/100km", c, unit))
                                        .font(.caption.bold())
                                        .foregroundStyle(.green)
                                } else if f.isFull {
                                    Text("önceki tam dolum bekleniyor")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { idx in
                        let reversed = Array(store.fillUps.reversed())
                        for i in idx { store.remove(reversed[i].id) }
                    }
                }
            }
        }
        .navigationTitle("Depo Kaydı")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                Form {
                    Section {
                        BigNumberField(label: "Kilometre", unit: "km",
                                       placeholder: "125000", value: $odometer,
                                       help: "Aracın kilometre sayacındaki değer.")
                        BigNumberField(label: "Alınan", unit: unit,
                                       placeholder: "42", value: $amount)
                        BigNumberField(label: "Ödenen", unit: "₺",
                                       placeholder: "2100", value: $cost,
                                       help: "İsteğe bağlı — girersen gerçek ₺/km de hesaplanır.")
                    }
                    Section {
                        Toggle("Depoyu ağzına kadar doldurdum", isOn: $isFull)
                    } footer: {
                        Text("Tüketim hesabı yalnızca TAM dolumlarla yapılabilir. Depo her iki ölçümde de aynı seviyede olmalı ki alınan miktar, gerçekten yakılan miktara eşit olsun. Yarım dolum kaydedilir ama hesaba katılmaz.")
                    }
                }
                .navigationTitle("Dolum Ekle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("İptal") { showAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Kaydet") {
                            store.add(odometer: odometer, amount: amount,
                                      cost: cost > 0 ? cost : nil, isFull: isFull)
                            showAdd = false
                        }
                        .disabled(odometer <= 0 || amount <= 0)
                    }
                }
            }
        }
    }
}
