import SwiftUI
import MapKit

// ============================================================================
// MARK: - Rota Karşılaştırma
// ============================================================================
//
// Uygulamanın ayırt edici ekranı. Google Maps "3 dakika daha hızlı" der ve
// biter; burada kullanıcı asıl merak ettiğini görür:
//
//     • Ne kadar sürer, ne kadar km
//     • Toplam CEBE MALİYET (geçiş + yakıt)  ← tek rakamda
//     • Kaç keskin viraj, en yavaş nereye ineceğim
//     • Hangi köprüden geçiyorum, ne kadar ödüyorum (kalem kalem)
//
// Böylece "otoyoldan 1170 ₺ Osmangazi verip 40 dk kazanmak" ile "körfezi
// dolanıp bedava ama 60 viraj" arasındaki tercih bilinçli hâle gelir.
// ============================================================================

struct RouteComparisonView: View {
    @ObservedObject var vm: DriveViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var expandedID: UUID?

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.routeOptions) { opt in
                    Section {
                        card(opt)
                    }
                }

                Section {
                    Picker("Sürüş Modu", selection: $vm.drivingMode) {
                        ForEach(DrivingMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Zemin", selection: $vm.roadCondition) {
                        ForEach(RoadCondition.allCases, id: \.self) { c in
                            Label(c.rawValue, systemImage: c.icon).tag(c)
                        }
                    }
                } header: {
                    Text("Hız Önerisi Ayarları")
                } footer: {
                    Text("Zemin durumu, viraj tavsiye hızlarını fiziksel olarak düşürür — karlı/buzlu seçilirse mevcut tutuş sınırı devreye girer. Sürüş modu ise uyarıların ne kadar erken geleceğini belirler.")
                }
            }
            .navigationTitle("Rotalar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
    }

    // MARK: Kart

    @ViewBuilder
    private func card(_ opt: RouteOption) -> some View {
        let selected = opt.id == vm.selectedOptionID
        let expanded = expandedID == opt.id

        VStack(alignment: .leading, spacing: 10) {
            Button {
                vm.select(option: opt)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    // Haritadaki çizgi rengiyle eşleşen şerit
                    Capsule().fill(opt.color).frame(width: 6, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(opt.durationText)
                                .font(.title3.bold())
                                .foregroundStyle(selected ? opt.color : .primary)
                            Text(opt.distanceText).foregroundStyle(.secondary)
                        }
                        if opt.trafficLevel != .unknown {
                            HStack(spacing: 4) {
                                Image(systemName: opt.trafficLevel.icon).font(.caption2)
                                Text(opt.trafficLevel.label).font(.caption2.bold())
                                if let t = opt.trafficText {
                                    Text("· \(t)").font(.caption2)
                                }
                            }
                            .foregroundStyle(opt.trafficLevel.color)
                        }
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(opt.color)
                    }
                }
            }
            .buttonStyle(.plain)

            if !opt.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(opt.tags) { t in
                            Label(t.rawValue, systemImage: t.icon)
                                .font(.caption2.bold())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            // Toplam maliyet — en çok merak edilen tek rakam
            HStack(spacing: 16) {
                metric("Toplam", value: String(format: "%.0f ₺", opt.totalCostTL),
                       tint: .primary, bold: true)
                metric("Geçiş", value: opt.toll.hasAny ? "\(Int(opt.toll.total)) ₺" : "yok",
                       tint: opt.toll.hasAny ? .yellow : .green)
                if let f = opt.fuel {
                    metric("Yakıt", value: "\(Int(f.costTL)) ₺", tint: .orange)
                }
                metric("Ort. hız", value: "\(opt.avgSpeedKmh)", tint: .secondary)
            }

            // Yakıt fiyatının KAYNAĞI ve birim fiyatı.
            //
            // `FuelEstimate.priceText` uzun süre tanımlıydı ama hiçbir görünüm
            // onu okumuyordu: birim fiyat hesaplanıp taşınıyor, sonra atılıyordu.
            // Sonucu, gömülü tabanın gerçeğin %30–50 altına düşmesine rağmen
            // kimsenin fark edememesi oldu. Proje kuralı zaten bunu söylüyor:
            // her sayının kaynağı taşınır VE arayüzde görünür.
            if let f = opt.fuel, f.unitPrice > 0 {
                Text(f.priceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Viraj profili
            HStack(spacing: 16) {
                metric("Keskin viraj", value: "\(opt.sharpCurveCount)",
                       tint: opt.sharpCurveCount > 5 ? .orange : .green)
                if let t = opt.tightestSafeSpeed {
                    metric("En yavaş", value: "\(Int(t)) km/s",
                           tint: t < 50 ? .red : (t < 70 ? .orange : .green))
                }
                metric("Virajlılık", value: String(format: "%.0f", opt.curviness),
                       tint: .secondary)
            }

            CurvatureBar(option: opt)

            // Ücret dökümü
            if opt.toll.hasAny {
                Button {
                    withAnimation(.snappy) { expandedID = expanded ? nil : opt.id }
                } label: {
                    HStack {
                        Text(expanded ? "Ücret dökümünü gizle" : "Ücret dökümü")
                            .font(.caption.bold())
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        // Gişe çiftleri — rakamı doğrulanabilir kılan bilgi
                        ForEach(Array(opt.toll.gantryPairs.values).sorted(), id: \.self) { pair in
                            Label(pair, systemImage: "arrow.left.arrow.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                        ForEach(opt.toll.items) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.caption)
                                    if let d = item.detail {
                                        Text(d).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(Int(item.amount)) ₺")
                                    .font(.caption.bold()).monospacedDigit()
                            }
                        }
                        // Yurt dışı kesimleri
                        if !opt.toll.countryNotes.isEmpty {
                            Divider()
                            ForEach(opt.toll.countryNotes, id: \.country) { n in
                            VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text("\(n.country) — \(n.model)")
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(n.amount > 0 ? "≈\(Int(n.amount)) ₺" : "ücret yok")
                                            .font(.caption.bold())
                                            .foregroundStyle(n.amount > 0 ? Color.primary : Color.green)
                                    }
                                    Text(n.note).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }

                        Divider()
                        HStack {
                            Text(opt.toll.source.rawValue)
                                .font(.caption2).foregroundStyle(.secondary)
                            if opt.toll.isStaleTariff {
                                Label("tarife eski olabilir", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ label: String, value: String, tint: Color, bold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(bold ? .subheadline.bold() : .subheadline)
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label).scaledFont(size: 11, relativeTo: .caption2).foregroundStyle(.secondary)
        }
    }
}

// ============================================================================
// MARK: - Viraj Profili Çubuğu
// ============================================================================
//
// Rotayı soldan sağa bir şerit olarak çizer; her viraj, konumuna ve
// keskinliğine göre renkli bir dilim olur. Kullanıcı tek bakışta "virajlar
// nerede yoğunlaşıyor" görür — sayı listesi bunu asla anlatamaz.
// ============================================================================

struct CurvatureBar: View {
    let option: RouteOption

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                ForEach(option.curves) { c in
                    let total = max(option.route.distance, 1)
                    let x = (c.entryDistance / total) * geo.size.width
                    let w = max(2, (c.length / total) * geo.size.width)
                    Capsule()
                        .fill(color(for: c.severity))
                        .frame(width: w)
                        .offset(x: min(x, geo.size.width - w))
                }
            }
        }
        .frame(height: 7)
        .clipShape(Capsule())
    }

    private func color(for s: Curve.Severity) -> Color {
        switch s {
        case .gentle: return .green
        case .moderate: return .yellow
        case .sharp: return .orange
        case .verySharp, .hairpin: return .red
        }
    }
}
