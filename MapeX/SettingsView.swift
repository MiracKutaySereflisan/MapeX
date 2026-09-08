import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject private var speech = SpeechManager.shared
    @ObservedObject private var tones = ToneManager.shared
    @ObservedObject private var fuel = FuelPriceService.shared
    @ObservedObject private var tollLearning = TollLearningStore.shared
    @ObservedObject private var display = DisplayPreferences.shared
    @ObservedObject private var startup = StartupRefresh.shared
    @ObservedObject private var weather = RoadWeatherService.shared
    @State private var showClearHistory = false

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let gender: String
        switch v.gender {
        case .female: gender = "Kadın"
        case .male: gender = "Erkek"
        default: gender = ""
        }
        return gender.isEmpty ? v.name : "\(v.name) (\(gender))"
    }

    var body: some View {
        Form {
            // ────────────────────────────────────────────────────────────────
            Section {
                Toggle("Yüksek kontrast", isOn: $display.highContrast)
                Toggle("Sürüşte büyük rakamlar", isOn: $display.largeDrivingText)
                Toggle("Sürüşte ekran açık kalsın", isOn: $display.keepScreenOn)
                Toggle("Sonraki virajlar şeridi", isOn: $display.showCurvePreview)
            } header: {
                Text("Görünürlük")
            } footer: {
                Text("""
                Yazı boyutunu iOS Ayarlar > Ekran ve Parlaklık > Metin Boyutu'ndan \
                büyütürsen uygulama da büyür. Yüksek kontrast, güneş altında okunurluk \
                için ikincil yazıları koyulaştırır ve cam zeminleri opaklaştırır.

                "Sonraki virajlar şeridi" sürüş ekranının altında sıradaki üç virajı \
                ralli notasyonuyla gösterir (yön, derece, mesafe, tavsiye hız). \
                Ekranı kalabalık buluyorsan kapatabilirsin — sesli uyarılar, gösterge \
                rengi ve kenar uyarısı bundan etkilenmez, hiçbir uyarı susmaz.
                """)
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                HStack {
                    Label("Otomatik güncelleme", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if startup.isRunning { ProgressView() }
                }
                if let r = startup.lastRun {
                    LabeledContent("Son kontrol",
                                   value: r.formatted(date: .abbreviated, time: .shortened))
                }
                if !startup.lastSummary.isEmpty {
                    Text(startup.lastSummary).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Veri Tazeleme")
            } footer: {
                Text("Uygulama her açılışta geçiş tarifesini (7 günde bir) ve yakıt fiyatını (12 saatte bir) kontrol eder. İnternet yoksa mevcut veriyle tam çalışmaya devam eder.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                if let s = weather.snapshot {
                    LabeledContent("Hava", value: "\(s.temperatureText) · \(s.summary)")
                    LabeledContent("Zemin", value: s.roadCondition.rawValue)
                    HStack {
                        Text(s.observedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if s.isStale {
                            Text("veri eski").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    // Apple'ın ŞART koştuğu atıf.
                    if let url = weather.attributionURL {
                        Link(" Weather — yasal bilgi", destination: url)
                            .font(.caption)
                    }
                } else {
                    Text("Hava verisi yok. WeatherKit yetkisi açılmadıysa zemin kuru varsayılır ve uygulama tam işlevli çalışmaya devam eder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Hava ve Zemin")
            } footer: {
                Text("""
                Zemin durumu otomatik belirlenir; ana ekrandaki hava çipine dokunarak \
                elle geçersiz kılabilirsin. Hava, zemin tutuşuyla aynı şey değildir: \
                yağmur dinse de yol ıslak kalır (son iki saatin yağışına bakılır) ve \
                sıcaklık 3 °C altındayken ıslaklık varsa buzlu kabul edilir — köprüler \
                altlarından hava geçtiği için yoldan önce buzlanır.

                İnternet yoksa son bilinen hava korunur; o da yoksa kuru varsayılır.
                """)
            }

            // ────────────────────────────────────────────────────────────────
            Section("Sesli Anons") {
                Toggle("Konuşma", isOn: $speech.voiceEnabled)
                if speech.voiceEnabled {
                    Picker("Ses", selection: $speech.voiceIdentifier) {
                        Text("Varsayılan").tag("")
                        ForEach(speech.availableTurkishVoices, id: \.identifier) { v in
                            Text(voiceLabel(v)).tag(v.identifier)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Konuşma hızı").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $speech.rate, in: 0.35...0.65)
                    }
                    Button("Sesi Dene") {
                        speech.speak("Üç yüz metre sonra keskin sol viraj. Tavsiye edilen hız altmış.")
                    }
                }
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                Toggle("Uyarı Sesleri", isOn: $tones.enabled)

                if tones.enabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Yön belirginliği").font(.caption)
                            Spacer()
                            Text(tones.directionalStrength == 0 ? "kapalı"
                                 : String(format: "%.0f%%", tones.directionalStrength * 100))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Slider(value: $tones.directionalStrength, in: 0...1)
                    }

                    Button("🌀 Sol viraj yaklaşıyor") {
                        tones.play(.curveHeadsUp, direction: -1)
                    }
                    Button("🌀 Sağ viraj yaklaşıyor") {
                        tones.play(.curveHeadsUp, direction: 1)
                    }
                    Button("⚠️ Hızını düşür (sol)") {
                        tones.play(.curvePrepare, direction: -1)
                    }
                    Button("🛑 Kritik — yavaşla (sağ)") {
                        tones.play(.curveCritical, direction: 1)
                    }
                    Button("➡️ Sapak — sağa") {
                        tones.play(.turn, direction: 1)
                    }
                    Button("🏁 Varış") { tones.play(.arrive) }
                }
            } header: {
                Text("Nota Uyarıları")
            } footer: {
                Text("Her uyarının motifi sabittir; zamanla sesinden ne olduğunu tanırsın. Motif merkezde başlar, SON NOTASI virajın/sapağın yönüne kayarak biter — sola dönecekseniz ses sol kulakta biter. Tek kulaklık kullanıyorsanız yön belirginliğini kısabilirsiniz.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                Toggle("Konuma göre otomatik", isOn: $fuel.autoUpdate)

                if let r = fuel.region {
                    LabeledContent("Bölge", value: r.displayName)
                }
                if let p = fuel.prices {
                    LabeledContent("Benzin", value: String(format: "%.2f ₺", p.benzin))
                    LabeledContent("Motorin", value: String(format: "%.2f ₺", p.motorin))
                    LabeledContent("LPG", value: String(format: "%.2f ₺", p.lpg))
                    HStack {
                        Text(p.source).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(p.ageText)
                            .font(.caption)
                            .foregroundStyle(p.isStale ? .orange : .secondary)
                    }
                }

                TextField("Fiyat listesi adresi (JSON)", text: $fuel.feedURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                SecureField("CollectAPI anahtarı (opsiyonel)", text: $fuel.collectAPIKey)

                Button {
                    Task { await fuel.fetch() }
                } label: {
                    HStack {
                        Label("Şimdi Güncelle", systemImage: "arrow.clockwise")
                        if fuel.isFetching { Spacer(); ProgressView() }
                    }
                }
                .disabled(fuel.isFetching)

                if let e = fuel.lastError {
                    Text(e).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Yakıt Fiyatları")
            } footer: {
                Text("""
                Türkiye'de dağıtıcıların açık bir fiyat API'si yok; fiyatlar yalnızca web \
                sayfalarında yayımlanıyor. İki yol var: (1) bir sayfayı okuyup JSON üreten \
                kendi adresini gir, (2) CollectAPI'nin ücretsiz anahtarını al — il ve ilçe \
                bazlı fiyat verir. Hiçbiri yoksa Aracım ekranındaki elle girilen fiyat kullanılır.

                İstanbul'da Avrupa ve Anadolu yakası ayrı fiyatlanır; yaka, ilçe adından \
                kesin olarak belirlenir (boylam tahmini yalnızca ilçe çözülemezse kullanılır).
                """)
                .font(.caption2)
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                if !tollLearning.corrections.isEmpty {
                    LabeledContent("Kayıtlı düzeltme", value: "\(tollLearning.corrections.count)")
                    ForEach(tollLearning.corrections.suffix(5).reversed()) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.routeDescription).font(.caption)
                                Text(c.recordedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(Int(c.actualAmount)) ₺").font(.caption.bold())
                                Text("tahmin \(Int(c.estimatedAmount))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Düzeltmeleri Sil", role: .destructive) { tollLearning.clear() }
                } else {
                    Text("Henüz düzeltme yok. Yolculuk sonunda ödediğin geçiş ücretini girersen tahminler kendini düzeltir.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Öğrenilmiş Geçiş Ücretleri")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                NavigationLink("Yolculuk Geçmişi") { TripHistoryView() }
                NavigationLink("Rozetler") { BadgesView() }
                Button("Tüm Geçmişi Sil", role: .destructive) { showClearHistory = true }
            } header: {
                Text("Veriler")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                LabeledContent("Viraj hızı modeli", value: "AASHTO f(V)")
                LabeledContent("Örnekleme", value: "10 m sabit yay")
                LabeledContent("Uyarı mesafesi", value: "hıza bağlı")
            } header: {
                Text("Hesaplama Yöntemi")
            } footer: {
                Text("""
                Viraj tavsiye hızı V = √(127 · R · (e + f)) denkleminden bulunur. \
                f (yanal sürtünme) sabit değil, hıza göre AASHTO Green Book Tablo 3-7'den \
                alınır — yüksek hızda sürücünün katlanabildiği yanal ivme düşer. \
                Dever (e) bilinmediği için 0 varsayılır; bu daima güvenli taraftır. \
                Karlı/buzlu zeminde sınırı konfor değil fiziksel tutuş belirler ve \
                sürtünme çemberi gereği tutuşun yalnızca %60'ı yanal kuvvete ayrılır.

                Uyarı mesafesi d = v·t + (v² − v_güvenli²)/(2a) ile hesaplanır; \
                bu yüzden 120 km/s'te ~830 m, 50 km/s'te ~140 m önceden uyarır.

                Tüm değerler tahmindir; nihai karar sürücüye aittir.
                """)
                .font(.caption2)
            }
        }
        .navigationTitle("Ayarlar")
        .alert("Emin misiniz?", isPresented: $showClearHistory) {
            Button("Sil", role: .destructive) {
                UserDefaults.standard.removeObject(forKey: "tripHistory")
                UserDefaults.standard.removeObject(forKey: "semtSayaclari")
            }
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Tüm yolculuk kayıtları ve rozetler silinecek.")
        }
    }
}

// MARK: - Yolculuk Geçmişi

struct TripHistoryView: View {
    @State private var trips: [TripResult] = []

    var body: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView("Henüz yolculuk yok",
                                       systemImage: "clock.badge.xmark",
                                       description: Text("Tamamlanan sürüşler burada listelenir."))
            } else {
                List {
                    ForEach(trips.sorted { $0.timestamp > $1.timestamp }) { trip in
                        TripHistoryRow(trip: trip)
                    }
                }
            }
        }
        .navigationTitle("Yolculuk Geçmişi")
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: "tripHistory"),
               let history = try? JSONDecoder().decode([TripResult].self, from: data) {
                trips = history
            }
        }
    }
}

struct TripHistoryRow: View {
    let trip: TripResult

    private var scoreColor: Color {
        trip.score >= 85 ? .green : (trip.score >= 60 ? .yellow : .red)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(trip.startSemt) → \(trip.endSemt)").font(.headline)
                    Text(trip.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(trip.score)")
                        .font(.title3.bold())
                        .foregroundStyle(scoreColor)
                    Text(trip.drivingMode.rawValue)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Label(trip.formattedDistance, systemImage: "arrow.left.and.right")
                Label(trip.formattedDuration, systemImage: "clock")
                if trip.tollPaid > 0 {
                    Label("\(Int(trip.tollPaid)) ₺", systemImage: "turkishlirasign.circle")
                }
                let ev = trip.eventSummary
                if ev.braking + ev.accel + ev.cornering > 0 {
                    Label("\(ev.braking + ev.accel + ev.cornering)",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rozetler

struct BadgesView: View {
    @State private var badges: [String: Int] = [:]

    var body: some View {
        Group {
            if badges.isEmpty {
                ContentUnavailableView("Henüz rozet yok",
                                       systemImage: "medal",
                                       description: Text("Güvenli ve düzgün sürerek rozet kazanın."))
            } else {
                List {
                    ForEach(Array(badges.sorted { $0.value > $1.value }), id: \.key) { key, count in
                        HStack {
                            Image(systemName: "medal.fill").foregroundStyle(.yellow)
                            Text(key.replacingOccurrences(of: "cikis-", with: "Çıkış • ")
                                    .replacingOccurrences(of: "varis-", with: "Varış • "))
                            Spacer()
                            Text("\(count) kez").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Rozetler")
        .onAppear {
            badges = UserDefaults.standard.dictionary(forKey: "semtSayaclari") as? [String: Int] ?? [:]
        }
    }
}
