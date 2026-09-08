// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import SwiftUI

// ============================================================================
// MARK: - Aracım Ekranı
// ============================================================================
//
// ÖNCEKİ HÂLİN SORUNU
// -------------------
// Ekran "L/100 km kaç?" diye soruyordu. Çoğu sürücü bunu bilmez. Üstelik ekran
// yan menünün 300 puntoluk penceresi içinde açıldığı için alanlar kullanılamaz
// haldeydi ve sayısal klavye kapanmıyordu — pratikte araç EKLENEMİYORDU.
//
// YENİ AKIŞ — İLAN SİTESİ MANTIĞI
// -------------------------------
//        YIL  →  MARKA  →  MODEL  →  MOTOR
//
// Her adım internetten gelir, kullanıcı sadece kendi arabasını tanır. Seçim
// biter bitmez şunlar OTOMATİK dolar:
//        • şehir içi ve otoban tüketimi (EPA gerçek test verisi)
//        • yakıt tipi
//        • gövde sınıfı → viraj stabilite katsayısı
//        • motor hacmi, silindir, şanzıman
// Ardından fiziksel ölçüler (iz genişliği, yükseklik, boş ağırlık) ikinci bir
// kaynaktan çekilip viraj hızı hesabına bağlanır.
//
// Katalogda bulunmayan araçlar için elle giriş her zaman açık — Dacia gibi
// ABD'de satılmayan markalar katalogda yok, ama uygulama yine tam çalışır.
// ============================================================================

struct VehicleView: View {
    @ObservedObject private var vehicle = VehicleManager.shared
    @ObservedObject private var tolls = TollTariffStore.shared
    @ObservedObject private var display = DisplayPreferences.shared

    @State private var showPicker = false
    @State private var showTariffSheet = false

    private var fuel: VehicleProfile.FuelType { vehicle.profile.fuelType }
    private var stability: StabilityCalculator.Result { vehicle.stability }

    var body: some View {
        Form {
            // ────────────────────────────────────────────────────────────────
            Section {
                if vehicle.hasVehicle {
                    HStack(spacing: 14) {
                        if let b = TurkeyVehicleCatalog.brand(named: vehicle.profile.make) {
                            BrandBadge(brand: b, size: 52)
                        } else {
                            Image(systemName: vehicle.profile.bodyClass.icon)
                                .font(.system(size: 34))
                                .foregroundStyle(.tint)
                                .frame(width: 52)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vehicle.profile.name)
                                .font(.title3.bold())
                            if !vehicle.profile.engineText.isEmpty {
                                Text(vehicle.profile.engineText)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Label(vehicle.profile.bodyClass.rawValue, systemImage: "car.side")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)

                    Button {
                        showPicker = true
                    } label: {
                        Label("Aracı Değiştir", systemImage: "arrow.triangle.2.circlepath")
                            .frame(minHeight: 44)
                    }
                } else {
                    // Araç yoksa ekranın en görünür yeri bu olsun — kullanıcı
                    // ne yapması gerektiğini aramak zorunda kalmasın.
                    VStack(spacing: 12) {
                        Image(systemName: "car.badge.gearshape")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Aracını ekle")
                            .font(.title3.bold())
                        Text("Yakıt maliyeti ve virajlarda önerilen hız, aracına göre hesaplanır.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            showPicker = true
                        } label: {
                            Label("Listeden Seç", systemImage: "list.bullet.rectangle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                TextField("Araç adı (ör. Egea 1.4 Fire)", text: $vehicle.profile.name)
                    .font(.body)
                    .frame(minHeight: 44)

                Picker("Yakıt Tipi", selection: $vehicle.profile.fuelType) {
                    ForEach(VehicleProfile.FuelType.allCases, id: \.self) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }

                Picker("Gövde Sınıfı", selection: $vehicle.profile.bodyClass) {
                    ForEach(VehicleBodyClass.allCases) { b in
                        Label(b.rawValue, systemImage: b.icon).tag(b)
                    }
                }

                Picker("Ücret Sınıfı", selection: $tolls.vehicleClass) {
                    ForEach(TollVehicleClass.allCases) { c in
                        Label(c.rawValue, systemImage: c.icon).tag(c)
                    }
                }
            } header: {
                Text("Temel Bilgiler")
            } footer: {
                Text("Katalogdan seçtiysen bunlar otomatik doldu. İstersen elle düzeltebilirsin.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                BigNumberField(label: "Şehir içi",
                               unit: fuel.consumptionUnit,
                               placeholder: String(format: "%.1f", fuel.defaultCity),
                               value: $vehicle.profile.cityConsumption)
                BigNumberField(label: "Otoban",
                               unit: fuel.consumptionUnit,
                               placeholder: String(format: "%.1f", fuel.defaultHighway),
                               value: $vehicle.profile.highwayConsumption)
                NavigationLink {
                    FuelLogView()
                } label: {
                    HStack {
                        Label("Depo Kaydı", systemImage: "fuelpump.circle.fill")
                        Spacer()
                        if let m = FuelLogStore.shared.measuredConsumption {
                            Text(String(format: "%.1f ölçülen", m))
                                .font(.footnote).foregroundStyle(.green)
                        } else {
                            Text("gerçek tüketimini ölç")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("Tüketim")
            } footer: {
                Text(vehicle.profile.consumptionSource.isEmpty
                     ? "Değerleri aracın yol bilgisayarındaki uzun dönem ortalamasından girebilirsin."
                     : "Kaynak: \(vehicle.profile.consumptionSource)")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                BigNumberField(label: "Birim fiyat",
                               unit: fuel.priceUnit,
                               placeholder: String(format: "%.1f", fuel.defaultPrice),
                               value: $vehicle.profile.unitPrice)

                if let live = FuelPriceService.shared.currentPrice(for: fuel) {
                    HStack {
                        Label(String(format: "Kullanılan: %.2f ₺", live),
                              systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                        Spacer()
                        Text(FuelPriceService.shared.currentPriceSource(for: fuel))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Yakıt Fiyatı")
            } footer: {
                Text("Bu alanı doldurmak zorunda değilsin. Uygulama sırasıyla şunları kullanır: depo kaydında ödediğin gerçek fiyat → varsa güncel liste → ulusal ortalama. Depo kaydı tuttukça fiyat da tüketim de senin gerçeğine oturur.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                Picker("Yük Durumu", selection: $vehicle.profile.load) {
                    ForEach(LoadState.allCases) { l in
                        Label(l.rawValue, systemImage: l.icon).tag(l)
                    }
                }

                HStack {
                    Label(stability.isMeasured ? "Ölçülmüş boyutlar" : "Sınıf ortalaması",
                          systemImage: stability.isMeasured ? "ruler.fill" : "questionmark.circle")
                        .font(.footnote)
                        .foregroundStyle(stability.isMeasured ? .green : .secondary)
                    Spacer()
                }
                LabeledContent("Kararlılık (SSF)", value: String(format: "%.2f", stability.ssf))
                LabeledContent("Viraj hızı çarpanı", value: String(format: "×%.2f", stability.speedFactor))

                DisclosureGroup("Ölçüleri elle gir") {
                    BigNumberField(label: "Genişlik", unit: "mm", placeholder: "1780",
                                   value: $vehicle.profile.dimensions.widthMM)
                    BigNumberField(label: "Yükseklik", unit: "mm", placeholder: "1490",
                                   value: $vehicle.profile.dimensions.heightMM)
                    BigNumberField(label: "İz genişliği", unit: "mm", placeholder: "1530",
                                   value: $vehicle.profile.dimensions.trackFrontMM)
                    BigNumberField(label: "Boş ağırlık", unit: "kg", placeholder: "1300",
                                   value: $vehicle.profile.dimensions.kerbWeightKg)
                    Text("Genişlik ve yükseklik ruhsatta yazar. İz genişliğini bilmiyorsan boş bırak — genişliğin %86'sı olarak tahmin edilir.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Viraj Davranışı")
            } footer: {
                Text("""
                Ağırlık tek başına viraj hızını etkilemez — merkezcik denkleminde kütle sadeleşir. \
                Belirleyici olan geometri: SSF = iz genişliği ÷ (2 × ağırlık merkezi yüksekliği).

                Ağırlık yalnızca yük eklendiğinde devreye girer; eklenen kütlenin ağırlık merkezini \
                nereye kaydırdığı boş ağırlıkla hesaplanır. Bu yüzden 75 kg tavan yükü, 300 kg \
                yolcudan daha çok kararlılık düşürür.
                """)
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                Button {
                    showTariffSheet = true
                } label: {
                    HStack {
                        Label("Geçiş Ücreti Tarifesi", systemImage: "road.lanes")
                        Spacer()
                        Text(tolls.tariff.version).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                if tolls.tariff.isStale {
                    Label("Tarife eskimiş olabilir (\(tolls.tariff.validFromText))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Paralı Yollar")
            }
        }
        .navigationTitle("Aracım")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            VehiclePickerView { brand, model, engine in
                vehicle.apply(brand: brand, model: model, engine: engine)
            }
        }
        .sheet(isPresented: $showTariffSheet) {
            NavigationStack { TollTariffView() }
        }
    }
}

// ============================================================================
// MARK: - Kademeli Araç Seçici (Türkiye kataloğu)
// ============================================================================
//
// Akış: MARKA → MODEL → MOTOR
//
// Yıl adımı kaldırıldı. ABD kataloğunda yıl zorunluydu çünkü veri yıl bazlıydı;
// Türkiye kataloğunda motor seçenekleri model ömrü boyunca büyük ölçüde aynı
// kalıyor ve kullanıcıya fazladan bir adım yüklemenin karşılığı yok. Sürücü
// arabasını "Škoda Octavia 1.6 TDI" diye bilir, "2019 Škoda Octavia" diye değil.
// ============================================================================

struct VehiclePickerView: View {
    var onSelect: (TRBrand, TRModel, TREngine) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var brand: TRBrand?
    @State private var model: TRModel?
    @State private var searchText = ""

    private enum Stage { case brand, model, engine }
    private var stage: Stage {
        if brand == nil { return .brand }
        if model == nil { return .model }
        return .engine
    }

    var body: some View {
        NavigationStack {
            List {
                if brand != nil || model != nil {
                    Section {
                        if let brand {
                            crumb("Marka", brand.name) {
                                self.brand = nil; self.model = nil; searchText = ""
                            }
                        }
                        if let model {
                            crumb("Model", model.name) {
                                self.model = nil; searchText = ""
                            }
                        }
                    }
                }

                switch stage {
                case .brand:
                    Section {
                        if filteredBrands.isEmpty {
                            emptyState("\"\(searchText)\" markası listede yok",
                                       "Türkiye'de satılan markalar listeleniyor. Aracın yoksa İptal'e basıp bilgileri elle girebilirsin.")
                        }
                        ForEach(filteredBrands) { b in
                            Button {
                                brand = b; searchText = ""
                            } label: {
                                HStack(spacing: 12) {
                                    BrandBadge(brand: b, size: 38)
                                    Text(b.name).font(.body).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(b.models.count) model")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote).foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 54)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Marka")
                    } footer: {
                        Text("Türkiye'de satılan markalar. Aracın listede yoksa bu ekranı kapatıp bilgileri elle girebilirsin — uygulama aynı doğrulukla çalışır.")
                    }

                case .model:
                    Section("Model") {
                        if filteredModels.isEmpty {
                            emptyState("Bu markada \"\(searchText)\" bulunamadı",
                                       "Aramayı temizle ya da yukarıdan başka bir marka seç.")
                        }
                        ForEach(filteredModels) { m in
                            Button {
                                model = m; searchText = ""
                            } label: {
                                HStack(spacing: 12) {
                                    if let b = brand { BrandBadge(brand: b, size: 32) }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(m.name).font(.body).foregroundStyle(.primary)
                                        Text(m.years).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(m.engines.count) motor")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote).foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 54)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                case .engine:
                    Section {
                        if filteredEngines.isEmpty {
                            emptyState("\"\(searchText)\" motoru bulunamadı",
                                       "Aramayı temizleyip listedeki motorlara bakabilirsin.")
                        }
                        ForEach(filteredEngines) { en in
                            Button {
                                if let b = brand, let m = model { onSelect(b, m, en) }
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: en.fuel.icon)
                                        .foregroundStyle(.tint)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(en.displayName)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(String(format: "şehir %.1f · otoban %.1f %@",
                                                    en.city, en.highway,
                                                    en.fuel == .elektrik ? "kWh/100km" : "L/100km"))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote).foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Motor")
                    } footer: {
                        Text("Tüketim değerleri motor sınıfı tipiğidir — fabrika değerlerinden gerçekçi, ama yine de tahmindir. Aracını ekledikten sonra depo kaydı tutarsan uygulama SENİN gerçek tüketimini öğrenir ve bu rakamı bırakır.")
                    }
                }
            }
            .searchable(text: $searchText, prompt: searchPrompt)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal") { dismiss() }
                }
            }
        }
    }

    /// Boş sonuç durumu.
    ///
    /// Filtre hiçbir şey döndürmediğinde ekran bomboş kalıyordu ve kullanıcı
    /// uygulamanın donduğunu sanabiliyordu. Boş bir liste her zaman
    /// AÇIKLANMALIDIR — özellikle çıkış yolunu da göstererek.
    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "magnifyingglass")
                .font(.body.weight(.medium))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Aramayı temizle") { searchText = "" }
                .font(.footnote.bold())
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
    }

    private func row(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.body).foregroundStyle(.primary)
                Spacer()
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func crumb(_ label: String, _ value: String, onClear: @escaping () -> Void) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.weight(.medium))
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 44)
    }

    private var filteredBrands: [TRBrand] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let all = TurkeyVehicleCatalog.brands.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var filteredModels: [TRModel] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let all = brand?.models ?? []
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var filteredEngines: [TREngine] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let all = model?.engines ?? []
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var title: String {
        switch stage {
        case .brand: return "Marka Seç"
        case .model: return brand?.name ?? "Model Seç"
        case .engine: return model?.name ?? "Motor Seç"
        }
    }

    private var searchPrompt: String {
        switch stage {
        case .brand: return "Marka ara"
        case .model: return "Model ara"
        case .engine: return "Motor ara"
        }
    }
}
