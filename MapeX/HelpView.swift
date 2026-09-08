// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import SwiftUI

// ============================================================================
// MARK: - Nasıl Çalışır?
// ============================================================================
//
// Uygulamanın ürettiği renkler, sesler ve rakamlar öğrenilebilir bir dildir —
// ama kimse bir navigasyon uygulamasının kılavuzunu okumaz. Bu yüzden dil,
// KULLANIM SIRASINDA kendini açıklamalı; bu ekran da o dili tek yerde toplayan
// başvuru olmalı.
//
// Uyarı seslerini burada ÇALARAK öğretiyoruz. Bir sesi tarif etmek yerine
// dinletmek, sürüşte tanınmasını çok daha olası kılıyor.
// ============================================================================

struct HelpView: View {
    @ObservedObject private var tones = ToneManager.shared

    var body: some View {
        List {
            Section {
                Text("MapeX, gideceğin yolu önceden okur. Virajın ne kadar keskin olduğunu hesaplar, o virajın hangi hızı taşıdığını söyler ve **yavaşlamaya yetecek kadar önceden** uyarır.")
                Text("Ayrıca yolun gerçek maliyetini gösterir: geçiş ücretleri ve yakıt, tek bir rakamda.")
            } header: {
                Text("Ne yapar?")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                explain(color: .white, title: "Beyaz — Serbest",
                        text: "Viraj kısıtı yok ya da hız 20 km/s altında. Uygulama sessiz.")
                explain(color: .green, title: "Yeşil — Güvenli",
                        text: "Hızın virajın taşıdığı sınırın içinde.")
                explain(color: .yellow, title: "Sarı — Yavaşla",
                        text: "Sınırı %5–25 aşıyorsun. Ayağını gazdan çekmen yeterli.")
                explain(color: .red, title: "Kırmızı — Tehlike",
                        text: "Sınırı %25'ten fazla aşıyorsun. Ekranın kenarı da kırmızı yanıp söner.")
            } header: {
                Text("Renkler ne anlatıyor?")
            } footer: {
                Text("Renk, hızının o virajın taşıdığı hıza oranından gelir — mutlak hızdan değil. 40 km/s dar bir virajda kırmızı, 110 km/s otoyolda yeşil olabilir.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                soundRow("Viraj yaklaşıyor", "Yükselen üç nota. İlk haber.",
                         signal: .curveHeadsUp)
                soundRow("Hızını düşür", "İnen ikili. Artık yavaşlamaya başla.",
                         signal: .curvePrepare)
                soundRow("Yavaşla — kritik", "Hızlı üçleme. Sert fren gerekiyor.",
                         signal: .curveCritical)
                soundRow("Sapak", "Yön çanı. Dönüş yaklaşıyor.",
                         signal: .turn)
            } header: {
                Text("Sesler — dokunup dinle")
            } footer: {
                Text("Her sesin son notası, virajın veya sapağın YÖNÜNE doğru kayar. Sola dönecekseniz ses sol kulakta biter. Böylece kelimeyi beklemeden yönü duyarsınız. Yukarıdaki örnekler sol yöne çalar.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                row("Sakin", "Erken ve bol uyarı. Acemi veya temkinli sürücü için; önerilen hızlar mühendislik değerinin %12 altında.")
                row("Normal", "Dengeli. Karayolu tasarım standardının önerdiği hız.")
                row("Agresif", "Geç ve az uyarı. Deneyimli sürücü için; önerilen hızlar %8 yukarıda.")
            } header: {
                Text("Sürüş modları")
            } footer: {
                Text("Mod, hem önerilen hızı hem uyarının NE KADAR ÖNCEDEN geleceğini değiştirir. Sakin modda 2.5 saniyelik tepki payı, Agresif modda 1.5 saniye kullanılır.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                row("Kuru", "Normal koşul.")
                row("Islak / Yağmurlu", "Önerilen hızlar bir miktar düşer.")
                row("Karlı / Buzlu", "Sınırı artık konfor değil FİZİK belirler; hızlar belirgin düşer.")
            } header: {
                Text("Zemin durumu")
            } footer: {
                Text("Zemini üst bardaki araç simgesinden değiştirebilirsin. Buzlu seçildiğinde model, lastiğin fiilen bulabildiği tutuşa göre hesap yapar — o koşulda konfor sınırı zaten aşılmıştır.")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                row("Sürüşte haritayı gezebilirim", "Parmağınla kaydır, yakınlaştır, tüm rotayı incele. Takip durur, sağ altta ORTALA düğmesi çıkar; ona basınca GPS takibine döner.")
                row("Rotalar arası geçiş", "Alt paneli yukarı veya aşağı sürükle. Her rota haritada kendi renginde çizilidir.")
                row("Ücret yanlış çıktı", "Yolculuk sonunda ödediğin tutarı gir. Uygulama o güzergâhı ve o otoyolun km fiyatını kalıcı olarak düzeltir.")
            } header: {
                Text("İpuçları")
            }

            // ────────────────────────────────────────────────────────────────
            Section {
                Text("Viraj hız önerileri, karayolu mühendisliğinin viraj tasarım denklemine dayanır ve bir TAHMİNDİR. Yolun gerçek eğimi, zemin durumu, lastiklerin ve aracın hâli bilinemez.")
                Text("Hız limitlerine ve trafik kurallarına uymak sürücünün sorumluluğundadır. Nihai karar her zaman sürücünündür.")
                    .fontWeight(.semibold)
            } header: {
                Text("Önemli uyarı")
            }
        }
        .navigationTitle("Nasıl Çalışır?")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Satırlar

    private func explain(color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func soundRow(_ title: String, _ text: String, signal: ToneManager.Signal) -> some View {
        Button {
            tones.play(signal, direction: -1)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "speaker.wave.2.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// ============================================================================
// MARK: - İlk Açılış Tanıtımı
// ============================================================================
//
// Feragatname ekranı hukuken gerekli ama pedagojik olarak yetersiz: kullanıcı
// "Kabul Ediyorum"a basar ve uygulamanın dilini hiç öğrenmeden sürüşe başlar.
// İlk açılışta üç ekranlık kısa bir tanıtım, uyarıların ANLAŞILMA olasılığını
// belirgin biçimde yükseltir — anlaşılmayan uyarı, olmayan uyarıdır.
// ============================================================================

struct OnboardingView: View {
    @Binding var completed: Bool
    @State private var page = 0
    @ObservedObject private var tones = ToneManager.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                pageView(
                    icon: "arrow.triangle.turn.up.right.diamond.fill",
                    tint: .orange,
                    title: "Virajı önceden söyler",
                    body: "MapeX rotandaki her virajın keskinliğini hesaplar ve o virajın hangi hızı taşıdığını bulur. Uyarı, yavaşlamaya yetecek kadar önceden gelir — hızlıysan daha erken, yavaşsan daha geç."
                ).tag(0)

                pageView(
                    icon: "speaker.wave.2.fill",
                    tint: .blue,
                    title: "Ses yönü gösterir",
                    body: "Uyarı sesinin son notası, virajın yönüne doğru kayar. Sola dönecekseniz ses sol tarafta biter. Aşağıdaki düğmelere dokunup dinleyebilirsin.",
                    extra: AnyView(
                        HStack(spacing: 14) {
                            Button {
                                tones.play(.curveHeadsUp, direction: -1)
                            } label: {
                                Label("Sol viraj", systemImage: "arrow.turn.up.left")
                                    .frame(minHeight: 48)
                                    .padding(.horizontal, 14)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                tones.play(.curveHeadsUp, direction: 1)
                            } label: {
                                Label("Sağ viraj", systemImage: "arrow.turn.up.right")
                                    .frame(minHeight: 48)
                                    .padding(.horizontal, 14)
                            }
                            .buttonStyle(.bordered)
                        }
                    )
                ).tag(1)

                pageView(
                    icon: "turkishlirasign.circle.fill",
                    tint: .green,
                    title: "Yolun gerçek maliyeti",
                    body: "Her rota için geçiş ücreti ve yakıt tek rakamda gösterilir. Aracını eklersen tüketim ona göre hesaplanır. Ödediğin ücret farklı çıkarsa girebilirsin — uygulama kendini düzeltir."
                ).tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    completed = true
                }
            } label: {
                Text(page < 2 ? "Devam" : "Başla")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Button("Atla") { completed = true }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
    }

    private func pageView(icon: String, tint: Color, title: String,
                          body text: String, extra: AnyView? = nil) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 66))
                .foregroundStyle(tint)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if let extra { extra }
            Spacer()
            Spacer()
        }
    }
}
