// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import SwiftUI

struct TripSummaryView: View {
    @ObservedObject var vm: DriveViewModel
    @State private var actualToll: String = ""
    @State private var tollSaved = false

    private var trip: TripResult { vm.trip }

    private func scoreColor(_ s: Int) -> Color {
        switch s {
        case 85...: return .green
        case 60..<85: return .yellow
        default: return .red
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    // Skor halkası
                    ZStack {
                        Circle()
                            .stroke(.quaternary, lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: CGFloat(trip.score) / 100)
                            .stroke(scoreColor(trip.score).gradient,
                                    style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(trip.score)")
                                .font(.system(size: 54, weight: .black, design: .rounded))
                                .foregroundStyle(scoreColor(trip.score))
                            Text("PUAN").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 170, height: 170)
                    .padding(.top, 20)

                    // Skorun bileşenleri — hangi kısımdan kaybettiği görünsün
                    if trip.hasCurveData {
                        HStack(spacing: 14) {
                            scorePart("Viraj disiplini", value: trip.curveScore, weight: "%55")
                            scorePart("Sürüş düzgünlüğü", value: trip.smoothnessScore, weight: "%45")
                        }
                        .padding(.horizontal)
                    } else {
                        Text("Bu rotada değerlendirilecek viraj yoktu; puan tamamen sürüş düzgünlüğünden geldi.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    // Yolculuk gerçekleri
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        statTile("Mesafe", trip.formattedDistance, "arrow.left.and.right")
                        statTile("Süre", trip.formattedDuration, "clock")
                        statTile("Ortalama", "\(trip.averageSpeedKmh) km/s", "speedometer")
                        statTile("Geçiş ücreti", "\(Int(trip.tollPaid)) ₺", "turkishlirasign.circle")
                    }
                    .padding(.horizontal)

                    tollCorrectionCard

                    // Sert olaylar
                    let ev = trip.eventSummary
                    if ev.braking + ev.accel + ev.cornering > 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sert Olaylar").font(.headline)
                            eventRow("Sert fren", ev.braking, "exclamationmark.brakesignal", .red)
                            eventRow("Ani hızlanma", ev.accel, "gauge.with.dots.needle.100percent", .orange)
                            eventRow("Sert viraj", ev.cornering, "arrow.triangle.turn.up.right.diamond.fill", .yellow)
                            Text("Eşikler: fren −0.30 g, hızlanma +0.25 g, viraj 0.30 g yanal. Bunlar telematik literatüründe \"planlı değil tepkisel\" sürüş sınırı olarak kullanılır.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 16))
                        .padding(.horizontal)
                    } else if trip.distance > 5000 {
                        Label("Hiç sert fren, ani hızlanma veya sert viraj yok.",
                              systemImage: "checkmark.seal.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .padding(.horizontal)
                    }

                    // Viraj dağılımı
                    if trip.hasCurveData {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Virajlarda Hız Uyumu").font(.headline)
                            ForEach(trip.dagilim, id: \.0) { renk, adet in
                                HStack {
                                    Circle().fill(renk.color).frame(width: 11, height: 11)
                                    Text(renk.etiket)
                                    Spacer()
                                    Text("\(adet) viraj").foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 16))
                        .padding(.horizontal)
                    }

                    // Rozetler
                    if !vm.badges.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(vm.badges) { b in
                                HStack {
                                    Image(systemName: b.icon).foregroundStyle(.yellow)
                                    Text(b.title)
                                    Spacer()
                                    Text("Sv. \(b.level)").foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                                .padding(12)
                                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal)
                    }

                    Button {
                        vm.reset()
                    } label: {
                        Text("Yeni Yolculuk")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("\(trip.startSemt) → \(trip.endSemt)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // ========================================================================
    // MARK: Ücret düzeltmesi
    // ========================================================================
    //
    // Uygulamanın söylediği ile gişede ödenen tutar tutmayabilir — otoyol
    // tarifeleri gişe çiftine göre kademelidir ve tam matris kamuya açık bir
    // API'de yayımlanmıyor. Tahmini kesinmiş gibi sunmak yerine, kullanıcıya
    // gerçek tutarı girme imkânı veriyoruz.
    //
    // Girilen tutar iki işe yarar:
    //   1) Aynı güzergâh bir daha planlandığında TAHMİN DEĞİL, ölçülmüş rakam
    //      gösterilir.
    //   2) O koridorun ₺/km oranı yeniden türetilir; aynı otoyolu kullanan
    //      FARKLI güzergâhlar da doğrulaşır.
    //
    // Yani uygulama sürüldükçe ücret tahmini kendiliğinden düzelir.
    @ViewBuilder
    private var tollCorrectionCard: some View {
        if let option = vm.selectedOption, option.toll.hasAny {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Geçiş Ücreti", systemImage: "road.lanes")
                        .font(.headline)
                    Spacer()
                    Text(option.toll.confidence)
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                HStack {
                    Text("Uygulamanın tahmini")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(option.toll.estimatedTotal)) ₺").bold().monospacedDigit()
                }
                .font(.subheadline)

                Divider()

                HStack {
                    Text("Gerçekte ödediğin")
                    Spacer()
                    TextField("₺", text: $actualToll)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                }
                .font(.subheadline)

                Button {
                    guard let value = Double(actualToll.replacingOccurrences(of: ",", with: ".")),
                          value >= 0 else { return }
                    TollLearningStore.shared.record(
                        actual: value,
                        for: option.toll,
                        routeDescription: "\(trip.startSemt) → \(trip.endSemt)",
                        vehicleClass: TollTariffStore.shared.vehicleClass)
                    tollSaved = true
                    actualToll = ""
                } label: {
                    Label(tollSaved ? "Kaydedildi — bir dahakine bunu kullanacak"
                                    : "Kaydet ve düzelt",
                          systemImage: tollSaved ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(actualToll.isEmpty || tollSaved)
                .tint(tollSaved ? .green : .accentColor)

                Text("Otoyol tarifeleri giriş–çıkış gişesine göre kademelidir ve tam liste açık bir API'de yayımlanmıyor. Ödediğin tutarı girdikçe hem bu güzergâh hem aynı otoyolu kullanan diğer rotalar doğrulaşır.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    private func scorePart(_ label: String, value: Int, weight: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.bold())
                .foregroundStyle(scoreColor(value))
            Text(label).font(.caption2)
            Text(weight).scaledFont(size: 11, relativeTo: .caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    private func statTile(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    }

    private func eventRow(_ label: String, _ count: Int, _ icon: String, _ tint: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(count > 0 ? tint : .secondary)
            Text(label)
            Spacer()
            Text("\(count)")
                .font(.subheadline.bold())
                .foregroundStyle(count > 0 ? tint : .secondary)
        }
        .font(.subheadline)
    }
}
