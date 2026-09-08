import SwiftUI
import MapKit
import CoreLocation

// ============================================================================
// MARK: - Ev / İş Kısayolları
// ============================================================================
//
// Günlük kullanan bir sürücünün gittiği yerlerin büyük çoğunluğu iki tanedir.
// Her seferinde adres yazdırmak — özellikle araç içinde, yaşlı bir kullanıcıya —
// gereksiz bir engeldir ve uygulamayı "zahmetli" kılar.
//
// Kaydetme akışı bilinçli olarak "şu an buradayım" üzerine kurulu: kullanıcı
// evindeyken "Burayı Ev olarak kaydet" der. Adres yazmak, harita üzerinde pin
// sürüklemekten çok daha az hataya açık.
// ============================================================================

struct SavedPlace: Codable, Identifiable {
    var id: String { kind.rawValue }
    let kind: Kind
    let latitude: Double
    let longitude: Double
    var label: String
    var savedAt: Date

    enum Kind: String, Codable, CaseIterable {
        case home = "Ev"
        case work = "İş"

        var icon: String { self == .home ? "house.fill" : "briefcase.fill" }
        var tint: Color { self == .home ? .blue : .purple }
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

@MainActor
final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()

    @Published private(set) var places: [SavedPlace] = []

    private init() { load() }

    func place(_ kind: SavedPlace.Kind) -> SavedPlace? {
        places.first { $0.kind == kind }
    }

    func save(_ kind: SavedPlace.Kind, coordinate: CLLocationCoordinate2D, label: String) {
        places.removeAll { $0.kind == kind }
        places.append(SavedPlace(kind: kind,
                                 latitude: coordinate.latitude,
                                 longitude: coordinate.longitude,
                                 label: label,
                                 savedAt: Date()))
        persist()
    }

    func remove(_ kind: SavedPlace.Kind) {
        places.removeAll { $0.kind == kind }
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(d, forKey: "savedPlaces")
        }
    }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: "savedPlaces"),
           let p = try? JSONDecoder().decode([SavedPlace].self, from: d) {
            places = p
        }
    }
}

// MARK: - Kısayol şeridi

/// Arama alanının altındaki Ev / İş düğmeleri.
struct PlaceShortcutsRow: View {
    @ObservedObject private var store = PlacesStore.shared
    let currentLocation: CLLocation?
    var onNavigate: (CLLocationCoordinate2D) -> Void

    @State private var savingKind: SavedPlace.Kind?
    @State private var draftLabel = ""

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SavedPlace.Kind.allCases, id: \.self) { kind in
                if let p = store.place(kind) {
                    Button {
                        onNavigate(p.coordinate)
                    } label: {
                        shortcutLabel(icon: kind.icon, tint: kind.tint,
                                      title: kind.rawValue, subtitle: p.label)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Sil", role: .destructive) { store.remove(kind) }
                        if currentLocation != nil {
                            Button("Burayı \(kind.rawValue) yap") { beginSave(kind) }
                        }
                    }
                } else if currentLocation != nil {
                    Button { beginSave(kind) } label: {
                        shortcutLabel(icon: "plus.circle", tint: .secondary,
                                      title: kind.rawValue, subtitle: "kaydet")
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .alert("\(savingKind?.rawValue ?? "") olarak kaydet",
               isPresented: Binding(get: { savingKind != nil },
                                    set: { if !$0 { savingKind = nil } })) {
            TextField("Ad (ör. Kadıköy evi)", text: $draftLabel)
            Button("Kaydet") {
                if let kind = savingKind, let loc = currentLocation {
                    store.save(kind, coordinate: loc.coordinate,
                               label: draftLabel.isEmpty ? kind.rawValue : draftLabel)
                }
                savingKind = nil
            }
            Button("İptal", role: .cancel) { savingKind = nil }
        } message: {
            Text("Şu anki konumun kaydedilecek.")
        }
    }

    private func beginSave(_ kind: SavedPlace.Kind) {
        draftLabel = ""
        savingKind = kind
        // Adı otomatik doldur — kullanıcı hiçbir şey yazmasa da anlamlı olsun
        if let loc = currentLocation {
            Task {
                let semt = await RouteEngine.semt(of: loc)
                if semt != "?" { draftLabel = semt }
            }
        }
    }

    private func shortcutLabel(icon: String, tint: Color,
                               title: String, subtitle: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .glassEffect(.regular, in: .capsule)
    }
}

// ============================================================================
// MARK: - Konum İzni Uyarısı
// ============================================================================
//
// İzin reddedildiğinde uygulama önceden SESSİZCE çalışmıyordu: harita boş
// kalıyor, arama sonuç veriyor ama rota çizilmiyordu. Kullanıcı sebebini
// bilemiyor, uygulamayı bozuk sanıyordu. Reddedilen bir izin, kullanıcıya
// AÇIKÇA söylenmeli ve düzeltme yolu tek dokunuş olmalıdır.
// ============================================================================

struct LocationPermissionOverlay: View {
    let status: CLAuthorizationStatus
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)

            Text("Konum izni gerekli")
                .font(.title2.bold())

            Text(status == .denied
                 ? "MapeX, virajları ve sapakları önceden söyleyebilmek için konumunu bilmek zorunda. İzni Ayarlar'dan açabilirsin."
                 : "Konum erişimi kısıtlı görünüyor. Ayarlar'dan MapeX için konumu açman gerekiyor.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Ayarları Aç", systemImage: "gear")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Button("Tekrar dene", action: onRetry)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea()
    }
}
