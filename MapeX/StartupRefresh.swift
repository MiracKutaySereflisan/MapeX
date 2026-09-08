import Foundation
import SwiftUI

// ============================================================================
// MARK: - Açılışta Veri Tazeleme
// ============================================================================
//
// SORUN
// -----
// Geçiş tarifesi ve yakıt fiyatı ZAMANLA ESKİYEN verilerdir. Kullanıcıdan
// "Ayarlar'a gir, güncelle düğmesine bas" beklemek gerçekçi değil — kimse
// yapmaz, ve altı ay eski fiyatla hesaplanan maliyet, hesaplanmamasından
// beterdir çünkü doğru sanılır.
//
// ÇÖZÜM
// -----
// Uygulama her açılışta ve her öne gelişte kendi verisini kontrol eder.
// Ama HER SEFERİNDE AĞA ÇIKMAZ — bu pil ve veri israfı olurdu:
//
//      geçiş tarifesi   : 7 günde bir (yılda 1–2 kez değişir)
//      yakıt fiyatı     : 12 saatte bir veya bölge değişince
//
// Ağ hatası sessizce yutulur ve MEVCUT VERİ KORUNUR. Bir navigasyon
// uygulaması, sunucusuna ulaşamadı diye çalışmayı bırakmamalıdır; internetsiz
// de tam işlevli olmalıdır.
//
// Her verinin yanında "ne zaman güncellendi" bilgisi taşınır ve arayüzde
// gösterilir; kullanıcı rakamın tazeliğini kendi değerlendirebilsin.
// ============================================================================

@MainActor
final class StartupRefresh: ObservableObject {
    static let shared = StartupRefresh()

    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?
    /// Son turda ne yapıldığı — Ayarlar'da gösterilir.
    @Published private(set) var lastSummary: String = ""

    /// Aynı oturumda üst üste çalışmayı engeller (öne/arkaya geçişlerde
    /// scenePhase birden çok kez tetiklenebilir).
    private var lastAttempt: Date?

    private let tariffInterval: TimeInterval = 7 * 24 * 3600
    private let minimumGapBetweenRuns: TimeInterval = 60

    private init() {
        lastRun = UserDefaults.standard.object(forKey: "startupRefreshAt") as? Date
    }

    func run() async {
        guard !isRunning else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < minimumGapBetweenRuns { return }
        lastAttempt = Date()

        isRunning = true
        defer { isRunning = false }

        var done: [String] = []

        // ── Geçiş tarifesi ───────────────────────────────────────────────────
        let store = TollTariffStore.shared
        let tariffStale = store.lastRefresh.map { Date().timeIntervalSince($0) > tariffInterval } ?? true
        if tariffStale, !store.tariffURL.trimmingCharacters(in: .whitespaces).isEmpty {
            await store.refresh()
            if store.lastError == nil { done.append("tarife") }
        }

        // ── Yakıt fiyatı ─────────────────────────────────────────────────────
        // Konum servisi henüz hazır olmayabilir; FuelPriceService konum gelince
        // de kendi kendine tetiklenir. Burada yalnızca kayıtlı bölge için
        // tazeleme denenir.
        let fuel = FuelPriceService.shared
        if fuel.autoUpdate,
           !(fuel.feedURL.isEmpty && fuel.collectAPIKey.isEmpty),
           fuel.prices?.isStale ?? true {
            await fuel.fetch()
            if fuel.lastError == nil { done.append("yakıt fiyatı") }
        }

        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: "startupRefreshAt")
        lastSummary = done.isEmpty ? "Güncel — yeni veri gerekmedi"
                                   : "Güncellendi: \(done.joined(separator: ", "))"
    }
}
