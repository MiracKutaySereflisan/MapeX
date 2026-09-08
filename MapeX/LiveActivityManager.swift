// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import ActivityKit

// ============================================================================
// MARK: - Dinamik Ada Yöneticisi
// ============================================================================
//
// STALE DATE — ESKİ KODDAKİ SESSİZ TEHLİKE
// ----------------------------------------
// Önceki hâlde `staleDate: nil` veriliyordu. Anlamı: "bu bilgi hiç eskimez".
// Uygulama arka planda öldürülür veya konum akışı kesilirse Dinamik Ada'da
// DONMUŞ bir mesafe kalır — sürücü "sapağa 300 m" yazısını güncel sanar.
// Navigasyonda bayat veri, veri olmamasından tehlikelidir.
//
// Artık her güncellemeye +12 sn'lik `staleDate` konuyor. Sistem bu süre dolunca
// içeriği soluklaştırıp "güncel değil" görünümüne geçiriyor.
//
// GÜNCELLEME BÜTÇESİ
// ------------------
// ActivityKit sık güncellemeyi cezalandırır. İki kural:
//   • en fazla saniyede bir
//   • içerik gerçekten değişmediyse hiç gönderme
// Ayrıca mesafe 10 m'ye yuvarlanarak gönderilir; 287→286 m değişimi için
// sistem uyandırmaya değmez.
// ============================================================================

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<NavActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: NavActivityAttributes.ContentState?

    /// İçeriğin geçerli sayılacağı süre (sn).
    private let staleAfter: TimeInterval = 12

    private init() {}

    var isActive: Bool { activity != nil }

    func start(destinationName: String, initial: NavActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = NavActivityAttributes(destinationName: destinationName)
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: initial, staleDate: Date().addingTimeInterval(staleAfter))
        )
        lastState = initial
        lastUpdate = Date()
    }

    func update(_ state: NavActivityAttributes.ContentState) {
        guard let activity else { return }

        // Gürültü azaltma: mesafeleri 10 m'ye yuvarla
        var s = state
        s.distanceToTurn = (s.distanceToTurn / 10) * 10
        if let cd = s.curveDistance { s.curveDistance = (cd / 10) * 10 }

        guard Date().timeIntervalSince(lastUpdate) >= 1.0, s != lastState else { return }
        lastUpdate = Date()
        lastState = s

        let stale = Date().addingTimeInterval(staleAfter)
        Task { await activity.update(.init(state: s, staleDate: stale)) }
    }

    func end() {
        guard let activity else { return }
        let final = lastState
        self.activity = nil
        self.lastState = nil
        Task {
            if let final {
                await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .immediate)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
