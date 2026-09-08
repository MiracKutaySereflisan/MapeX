import SwiftUI

@main
struct MapeXApp: App {
    @AppStorage("disclaimerAccepted") private var accepted = false
    @AppStorage("onboardingDone") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if !accepted {
                    DisclaimerView(accepted: $accepted)
                } else if !onboarded {
                    OnboardingView(completed: $onboarded)
                } else {
                    ContentView()
                }
            }
            .task {
                // Uygulama her açılışta tarife ve yakıt fiyatlarını tazeler.
                // Kendi içinde eskime kontrolü yapar; her açılışta ağa çıkmaz.
                await StartupRefresh.shared.run()
            }
            .onChange(of: scenePhase) { _, phase in
                // Uygulamaya geri dönüldüğünde de kontrol et — telefon bütün
                // gün açık kalabilir, fiyatlar gün içinde değişebilir.
                if phase == .active {
                    Task { await StartupRefresh.shared.run() }
                }
            }
        }
    }
}

struct DisclaimerView: View {
    @Binding var accepted: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.yellow)
                Text("Önemli Uyarı")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Bu uygulama bilgilendirme amaçlıdır. Nihai karar her zaman sürücüye aittir.\n\nViraj hız önerileri GPS hassasiyetine bağlı bir tahmindir; kesin veya garantili değildir. Hız limitlerine ve trafik kurallarına uymak sürücünün sorumluluğundadır.\n\nSürüş sırasında ekrana bakmayın, sesli uyarıları dinleyin.")
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                Button {
                    accepted = true
                } label: {
                    Text("Okudum, Anladım ve Kabul Ediyorum")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(24)
        }
    }
}
