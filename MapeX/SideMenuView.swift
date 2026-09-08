import SwiftUI

// ============================================================================
// MARK: - Yan Menü
// ============================================================================
//
// DÜZELTİLEN CİDDİ HATA
// ---------------------
// Menü önceden şöyleydi:
//
//      NavigationStack { List { NavigationLink { VehicleView() } … } }
//          .frame(width: 300)          ← ÖLÜMCÜL SATIR
//
// `NavigationStack` 300 puntoya sabitlendiği için, içinden AÇILAN HER EKRAN da
// 300 punto genişliğinde çiziliyordu. "Aracım" ekranı bir `Form`dur: solda
// etiket, sağda metin alanı. 300 puntoda etiketler alanları eziyor, "Araç adı"
// kutusu birkaç punto kalıyor, sayı alanları hiç görünmüyordu.
//
// Sonuç: kullanıcı aracını EKLEYEMİYORDU. Ekran açılıyordu, "çalışmıyor" gibi
// görünmüyordu, sadece kullanılamaz haldeydi — bu yüzden hata olarak da fark
// edilmesi zordu.
//
// ÇÖZÜM
// -----
// Menü artık yalnızca bir SEÇİM BİLDİRİR. Ekranlar ana görünümde tam sayfa
// `sheet` olarak açılır, kendi `NavigationStack`leriyle ve tam genişlikte.
// Menünün 300 punto olması artık yalnızca menüyü ilgilendirir.
//
// ERİŞİLEBİLİRLİK
// ---------------
// Satır yükseklikleri 56 puntoya çıkarıldı ve etiketler `.title3` boyutunda.
// Hedef kitle günlük kullanan yaşlı sürücüler; 44 punto masaüstü tabanıdır,
// araçta ve yaşlı elde yetmez.
// ============================================================================

enum MenuDestination: String, Identifiable {
    case vehicle, settings, favorites, history, badges, help
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vehicle:   return "Aracım"
        case .settings:  return "Ayarlar"
        case .favorites: return "Favori Rotalar"
        case .history:   return "Geçmiş Sürüşler"
        case .badges:    return "Rozetler"
        case .help:      return "Nasıl Çalışır?"
        }
    }

    var icon: String {
        switch self {
        case .vehicle:   return "car.fill"
        case .settings:  return "gearshape.fill"
        case .favorites: return "star.fill"
        case .history:   return "clock.arrow.circlepath"
        case .badges:    return "medal.fill"
        case .help:      return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .vehicle:   return .blue
        case .settings:  return .gray
        case .favorites: return .orange
        case .history:   return .purple
        case .badges:    return .yellow
        case .help:      return .green
        }
    }
}

struct SideMenuView: View {
    @Binding var isOpen: Bool
    var onSelect: (MenuDestination) -> Void

    @ObservedObject private var vehicle = VehicleManager.shared

    private let groups: [[MenuDestination]] = [
        [.vehicle, .favorites],
        [.history, .badges],
        [.settings, .help]
    ]

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 0) {
                    header

                    ScrollView {
                        VStack(spacing: 18) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                                VStack(spacing: 2) {
                                    ForEach(group) { dest in
                                        menuRow(dest)
                                    }
                                }
                                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
                            }
                        }
                        .padding(14)
                    }
                }
                .frame(width: 300)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .padding(.vertical, 8)
                .padding(.leading, 4)
                .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy, value: isOpen)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MapeX").font(.largeTitle.bold())
            // Araç eklenmemişse bunu MENÜDE söyle — kullanıcı yakıt ve viraj
            // tahminlerinin neden eksik olduğunu ekranın derinliğinde aramasın.
            if vehicle.hasVehicle {
                Label(vehicle.profile.name, systemImage: "car.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("Araç eklenmedi", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private func menuRow(_ dest: MenuDestination) -> some View {
        Button {
            close()
            // Menü kapanma animasyonu bitmeden sheet açmak titremeye yol açar
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                onSelect(dest)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: dest.icon)
                    .font(.title3)
                    .foregroundStyle(dest.tint)
                    .frame(width: 30)
                Text(dest.title)
                    .font(.title3)
                    .foregroundStyle(.primary)
                Spacer()
                if dest == .vehicle && !vehicle.hasVehicle {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)          // yaşlı el + araç titreşimi için geniş hedef
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func close() {
        withAnimation(.snappy) { isOpen = false }
    }
}
