// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import SwiftUI
import MapKit
import CoreLocation
import QuartzCore

// ============================================================================
// MARK: - Akıcı Takip Kamerası
// ============================================================================
//
// PROBLEM — "TIK TIK TIK" HAREKET
// -------------------------------
// GPS saniyede bir fix verir. Kamerayı doğrudan fix'e taşırsan harita saniyede
// bir sıçrar. Eski kod bunu `withAnimation(.linear(duration: 1))` ile
// yumuşatmaya çalışıyordu, ama bu yaklaşımın iki kusuru var:
//
//   1) SÜREKLİ 1 SANİYE GERİDE. Animasyon, aracın BİR SANİYE ÖNCEKİ konumundan
//      ŞİMDİKİ konumuna gidiyor. Yani ekranda gördüğün nokta, gerçekte olduğun
//      yerin bir saniye gerisi. 120 km/s'te bu 33 metre — sapağı geçtikten
//      sonra "sağa dönün" görürsün.
//   2) FIX ARALIĞI DEĞİŞİNCE BOZULUR. GPS bazen 0.8 sn, bazen 1.4 sn'de gelir.
//      Sabit 1 sn'lik animasyon bir öncekini yarıda keser veya bitip bekler →
//      duraklama, sonra sıçrama.
//
// ÇÖZÜM — ÖLÜ HESAP (DEAD RECKONING) + ÜSTEL DÜZELTME
// ---------------------------------------------------
// Gerçek navigasyon uygulamalarının yaptığı şey: GPS'i beklemek yerine ARAYI
// TAHMİN ETMEK.
//
//   ① TAHMİN. Son fix'in konumu, hızı ve yönü biliniyor. O hâlde şu anki konum:
//
//          hedef(t) = son_konum + hız_vektörü × (t − son_fix_zamanı)
//
//      Bu her karede yeniden hesaplanır (60 Hz). Araç sabit hızla giderken
//      tahmin neredeyse kusursuzdur; GPS'i beklemeye gerek kalmaz, GECİKME SIFIR.
//
//   ② DÜZELTME. Yeni fix geldiğinde tahminle arasında küçük bir fark olur.
//      Bu farkı ANINDA uygulamak sıçrama yaratır. Bunun yerine her karede
//      farkın bir kısmı kapatılır:
//
//          görünen ← görünen + (hedef − görünen) × (1 − e^(−Δt/τ))
//
//      Bu, kritik sönümlü bir alçak geçiren filtredir. τ (zaman sabiti) 0.35 sn:
//      düzeltme gözle görülmeyecek kadar yumuşak, ama takip edilemeyecek kadar
//      da yavaş değil. τ büyürse süzülme hissi artar ama araç geride kalır.
//
// Sonuç: 1 Hz'lik GPS'ten 60 Hz'lik, gecikmesiz, sıçramasız hareket.
//
// ---------------------------------------------------------------------------
// SERBEST GEZİNME
// ---------------------------------------------------------------------------
// Sürüş sırasında kullanıcı haritayı kaydırıp uzaklaştırıp tüm rotayı
// inceleyebilmeli. Kamera "takip" modundayken her karede konumu yazdığı için
// kullanıcının kaydırması anında geri alınır — bu yüzden bir DURUM MAKİNESİ
// gerekiyor:
//
//        .following  ── kullanıcı dokunur ──▶  .free
//             ▲                                  │
//             └────── "Ortala" düğmesi ──────────┘
//
// `.free` modunda kamera hiç yazılmaz; harita tamamen kullanıcınındır.
// Dokunma tespiti `simultaneousGesture` ile yapılır — haritanın kendi
// hareketini engellemez, sadece haber verir. (`onMapCameraChange` kullanılamaz:
// bizim yazdığımız kamera değişikliklerini de tetikler, ayırt edilemez.)
// ============================================================================

enum CameraMode: Equatable {
    case idle          // sürüş yok
    case following     // GPS takibi
    case free          // kullanıcı haritayı kurcalıyor
    case overview      // tüm rota görünümü
}

@MainActor
final class NavigationCamera: ObservableObject {

    // MARK: Yayınlanan durum

    @Published var mode: CameraMode = .idle
    @Published var position: MapCameraPosition = .userLocation(fallback: .automatic)

    /// Ekranda gösterilen (yumuşatılmış) konum — araç işareti bunu kullanır ki
    /// işaret ile kamera birbirinden ayrılmasın.
    @Published private(set) var smoothedCoordinate: CLLocationCoordinate2D?
    @Published private(set) var smoothedHeading: Double = 0

    /// Takip modunda mı — arayüz "Ortala" düğmesini buna göre gösterir.
    var isFollowing: Bool { mode == .following }

    // MARK: Ayarlar

    /// Düzeltme zaman sabiti (sn). Küçük → çevik ama sert; büyük → yumuşak ama geride.
    private let tau: Double = 0.35
    /// Yön düzeltmesi için ayrı, biraz daha uzun sabit — kamera dönüşü en çok
    /// göze batan hareket olduğu için fazladan yumuşatılır.
    private let headingTau: Double = 0.50

    /// Kamera yüksekliği/eğimi
    private var targetDistance: Double = 900
    private var targetPitch: Double = 50

    // MARK: İç durum

    private var displayLink: CADisplayLink?

    private var lastFixPoint: MKMapPoint?
    private var lastFixTime: CFTimeInterval = 0
    private var velocityX: Double = 0        // MKMapPoint birimi / sn
    private var velocityY: Double = 0
    private var fixHeading: Double = 0

    private var displayedPoint: MKMapPoint?
    private var displayedHeading: Double = 0
    private var lastFrameTime: CFTimeInterval = 0

    // MARK: - Yaşam döngüsü

    func startFollowing() {
        mode = .following
        startDisplayLink()
    }

    func stop() {
        mode = .idle
        stopDisplayLink()
        lastFixPoint = nil
        displayedPoint = nil
    }

    /// Kullanıcı haritaya dokundu → serbest mod.
    func userDidInteract() {
        guard mode == .following || mode == .overview else { return }
        mode = .free
        // Display link çalışmaya devam eder ama kamerayı yazmaz; böylece
        // "Ortala"ya basıldığında tahmin zinciri kopmamış olur.
    }

    /// "Ortala" düğmesi → takibe dön.
    func recenter(animated: Bool = true) {
        mode = .following
        guard let p = displayedPoint ?? lastFixPoint else { return }
        let camera = MapCamera(centerCoordinate: p.coordinate,
                               distance: targetDistance,
                               heading: displayedHeading,
                               pitch: targetPitch)
        if animated {
            withAnimation(.easeOut(duration: 0.45)) { position = .camera(camera) }
        } else {
            position = .camera(camera)
        }
        startDisplayLink()
    }

    /// Tüm rotayı göster.
    func showOverview(_ rect: MKMapRect, animated: Bool = true) {
        mode = .overview
        let padded = rect.insetBy(dx: -rect.size.width * 0.12, dy: -rect.size.height * 0.12)
        if animated {
            withAnimation(.easeInOut(duration: 0.5)) { position = .rect(padded) }
        } else {
            position = .rect(padded)
        }
    }

    // MARK: - GPS girişi

    /// Her yeni fix'te çağrılır. Kamera bunu doğrudan kullanmaz; hız vektörünü
    /// günceller ve tahmin buradan yürür.
    func ingest(location: CLLocation, course: Double) {
        let p = MKMapPoint(location.coordinate)
        let now = CACurrentMediaTime()

        // Hız vektörünü MKMapPoint biriminde kur.
        // MKMapPoint birim başına metre, enleme bağlıdır.
        let metersPerPoint = MKMetersPerMapPointAtLatitude(location.coordinate.latitude)
        let speedMps = max(0, location.speed)
        let headingRad = course * .pi / 180

        if speedMps > 0.5, metersPerPoint > 0 {
            let pointsPerSecond = speedMps / metersPerPoint
            velocityX = pointsPerSecond * sin(headingRad)
            velocityY = -pointsPerSecond * cos(headingRad)   // y ekseni güneye artar
        } else {
            velocityX = 0; velocityY = 0
        }

        lastFixPoint = p
        lastFixTime = now
        fixHeading = course

        if displayedPoint == nil {
            displayedPoint = p
            displayedHeading = course
            smoothedCoordinate = p.coordinate
            smoothedHeading = course
        }
    }

    /// Viraja/sapağa yaklaşırken kamerayı yakınlaştır ve eğ.
    ///
    /// Zoom sabit değil, MANEVRAYA KALAN SÜREYE bağlı: 120 km/s'te 250 m,
    /// 40 km/s'te 250 m'den çok farklı şeylerdir. 8 saniyeden yakınsa yakınlaş.
    func updateFraming(distanceToEvent: Double?, speedKmh: Double) {
        let secondsAway: Double
        if let d = distanceToEvent, speedKmh > 5 {
            secondsAway = d / (speedKmh / 3.6)
        } else {
            secondsAway = .infinity
        }

        let close = secondsAway < 8
        targetDistance = close ? 420 : (speedKmh > 90 ? 1200 : 900)
        targetPitch = close ? 58 : 48
    }

    // MARK: - Kare döngüsü

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() },
                                 selector: #selector(DisplayLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTime = CACurrentMediaTime()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrameTime, 0), 0.1)   // sekme koruması
        lastFrameTime = now

        guard let fix = lastFixPoint else { return }

        // ① Ölü hesap: son fix'ten bu yana geçen sürede nereye gitmiş olmalıyız
        let elapsed = min(now - lastFixTime, 3.0)        // 3 sn'den fazla tahmin etme
        let target = MKMapPoint(x: fix.x + velocityX * elapsed,
                                y: fix.y + velocityY * elapsed)

        // ② Üstel düzeltme
        var shown = displayedPoint ?? target
        let alpha = 1 - exp(-dt / tau)
        shown = MKMapPoint(x: shown.x + (target.x - shown.x) * alpha,
                           y: shown.y + (target.y - shown.y) * alpha)
        displayedPoint = shown

        // Yön — en kısa yoldan yumuşat (359° → 1° geçişi +2° olmalı, −358° değil)
        let hAlpha = 1 - exp(-dt / headingTau)
        let delta = GeoMath.normalizeAngle(fixHeading - displayedHeading)
        displayedHeading = (displayedHeading + delta * hAlpha)
            .truncatingRemainder(dividingBy: 360)

        smoothedCoordinate = shown.coordinate
        smoothedHeading = displayedHeading

        // ③ Kamerayı yalnızca TAKİP modunda yaz — serbest modda harita kullanıcınındır
        guard mode == .following else { return }
        position = .camera(MapCamera(centerCoordinate: shown.coordinate,
                                     distance: targetDistance,
                                     heading: displayedHeading,
                                     pitch: targetPitch))
    }
}

/// CADisplayLink Objective-C selector istediği için küçük bir köprü.
private final class DisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

// ============================================================================
// MARK: - Harita etkileşim algılayıcı
// ============================================================================

extension View {
    /// Kullanıcının haritayı kaydırma/yakınlaştırma/döndürme hareketini yakalar.
    ///
    /// `simultaneousGesture` kullanılıyor: haritanın kendi hareketini
    /// ENGELLEMEZ, sadece haber verir. `onMapCameraChange` bu iş için
    /// kullanılamaz çünkü bizim programatik kamera yazmalarımızda da tetiklenir
    /// ve ikisi ayırt edilemez.
    func onMapUserInteraction(_ action: @escaping () -> Void) -> some View {
        self
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in action() }
            )
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .onChanged { _ in action() }
            )
            .simultaneousGesture(
                RotateGesture(minimumAngleDelta: .degrees(2))
                    .onChanged { _ in action() }
            )
    }
}
