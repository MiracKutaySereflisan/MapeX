import Foundation
import CoreLocation
import AVFoundation
import UIKit

// ============================================================================
// MARK: - Konum Yöneticisi
// ============================================================================
//
// ARKA PLAN — ESKİ KODUN EN BÜYÜK EKSİĞİ
// --------------------------------------
// Önceki hâlde yalnızca `requestWhenInUseAuthorization()` çağrılıyordu ve
// `allowsBackgroundLocationUpdates` hiç set edilmemişti. Sonuç: kullanıcı
// telefonu cebine koyduğu veya ekranı kilitlediği anda konum akışı DURUYOR,
// viraj uyarıları susuyor, Dinamik Ada donuyordu. Bir navigasyon uygulaması
// için bu, uygulamanın çalışmaması demektir.
//
// Şimdi:
//   • `.authorizedAlways` isteniyor (kademeli: önce WhenInUse, sürüş başlayınca
//     Always — Apple'ın önerdiği sıralama; ilk açılışta Always istemek kabul
//     oranını düşürür)
//   • `allowsBackgroundLocationUpdates = true` (Info.plist'te `location`
//     background mode ile birlikte, ikisi olmadan çalışmaz)
//   • `pausesLocationUpdatesAutomatically = false` — iOS "araç durdu" sanıp
//     akışı kesmesin; kırmızı ışıkta navigasyonun ölmesi kabul edilemez
//   • `showsBackgroundLocationIndicator = true` — kullanıcı arka planda konum
//     alındığını görsün (şeffaflık; Apple da bunu bekler)
//
// FİLTRELEME
// ----------
// Ham CLLocation gürültülüdür. Doğruluğu kötü fix'ler (horizontalAccuracy > 50 m,
// veya negatif = geçersiz) ve eski fix'ler (timestamp > 5 sn) atılır; bunlar
// haritada aracı zıplatır ve sahte sapma tetikler.
// ============================================================================

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// TEK ÖRNEK.
    ///
    /// Eskiden `ContentView` kendi `LocationManager`ını `@StateObject` olarak
    /// yaratıyordu. CarPlay AYRI BİR SAHNEDİR ve o örneğe erişemez; iki ayrı
    /// `CLLocationManager` açmak ise aynı GPS'i iki kez dinlemek, iki farklı
    /// filtrelenmiş konum akışı ve iki farklı "neredeyiz" cevabı demektir.
    /// Konum tek yerden akar.
    static let shared = LocationManager()

    private let manager = CLLocationManager()

    @Published var location: CLLocation?
    @Published var speedKmh: Double = 0
    @Published var course: Double = 0            // derece, 0 = kuzey
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var isBackgroundCapable = false

    /// Kurs (yön) yalnızca araç hareket hâlindeyken güvenilirdir. Durunca GPS
    /// kursu rastgele savrulur ve harita fır döner; bu yüzden son geçerli kurs
    /// saklanır.
    private var lastValidCourse: Double = 0

    var authorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// Uygulamanın Info.plist'i `location` arka plan modunu ilan ediyor mu?
    ///
    /// NEDEN KONTROL EDİYORUZ — ÇÖKME HİKÂYESİ
    /// `allowsBackgroundLocationUpdates = true` ataması, Info.plist'te
    /// UIBackgroundModes içinde "location" YOKSA yakalanamayan bir istisna
    /// fırlatır ve uygulamayı anında düşürür. `try` ile sarılamaz, `if let` ile
    /// korunamaz — tek çare önceden kontrol etmektir.
    ///
    /// Bu tam olarak yaşandı: build ayarı `INFOPLIST_KEY_UIBackgroundModes`
    /// yazılmıştı ama Xcode dizi tipli bu anahtarı üretilen plist'e KOYMUYOR.
    /// Ayar dosyada görünüyordu, üretilen plist'te yoktu, ve uygulama "Başlat"a
    /// basıldığı anda çöküyordu.
    ///
    /// Artık yapılandırma eksikse uygulama çökmez: arka plan takibi olmadan,
    /// ekran açıkken tam işlevli çalışmaya devam eder.
    private static let hasLocationBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }()

    /// Sürüş başlarken çağrılır: arka plan güncellemelerini açar ve gerekiyorsa
    /// Always iznini ister.
    func beginNavigationSession() {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }

        let authorized = manager.authorizationStatus == .authorizedAlways
                      || manager.authorizationStatus == .authorizedWhenInUse

        if authorized, Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            isBackgroundCapable = true
        } else {
            isBackgroundCapable = false
        }

        if DisplayPreferences.shared.keepScreenOn {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func endNavigationSession() {
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
        }
        isBackgroundCapable = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Delege

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.ingest(loc) }
    }

    private func ingest(_ loc: CLLocation) {
        // Geçersiz / kötü doğruluk / bayat fix ele
        guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 60 else { return }
        guard abs(loc.timestamp.timeIntervalSinceNow) < 5 else { return }

        // SIRALAMA ÖNEMLİ — `location` EN SONA yazılır.
        //
        // `@Published` değişimi `willSet`te yayınlar: abone, o özelliğin YENİ
        // değerini görür ama nesnenin diğer özellikleri HENÜZ ESKİDİR. Sürüş
        // beyni `$location` akışına abone olduğu için, `location` önce
        // yazılsaydı abone yeni konumu BİR ÖNCEKİ hız ve kursla eşleştirirdi —
        // 1 sn'lik gecikme, hızlanma/yavaşlama anında en çok yanıldığı yerde.
        speedKmh = loc.speed >= 0 ? loc.speed * 3.6 : speedKmh

        // Kurs: yalnızca ~2 m/s üstünde güven
        if loc.course >= 0, loc.speed > 2 {
            lastValidCourse = loc.course
        }
        course = lastValidCourse

        location = loc
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Geçici hatalar (kCLErrorLocationUnknown) normaldir; akış devam eder.
    }
}

// ============================================================================
// MARK: - Sesli Anons
// ============================================================================
//
// Konuşma ve nota uyarıları AYRI AYRI açılıp kapatılabilir. Bazı sürücüler
// yalnız notaları ister (konuşma dikkat dağıtıyor), bazıları tersini.
//
// YÖNLÜ KONUŞMA
// -------------
// Konuşma da hafifçe panlanabilir: "sağa dönün" anonsu sağ taraftan gelirse
// kelimeyi işlemeden önce yön bilgisi ulaşır. AVSpeechUtterance doğrudan pan
// vermez; `AVAudioSession` üstünden global pan mümkün değildir. Bu yüzden
// konuşmadan HEMEN ÖNCE yön çanını ilgili taraftan çalıyoruz — kulak, çanın
// geldiği yönü konuşmanın içeriğiyle eşleştiriyor.
// ============================================================================

@MainActor
final class SpeechManager: ObservableObject {
    static let shared = SpeechManager()
    private let synth = AVSpeechSynthesizer()

    @Published var voiceEnabled: Bool = UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled") }
    }

    @Published var voiceIdentifier: String = UserDefaults.standard.string(forKey: "voiceIdentifier") ?? "" {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }

    /// Konuşma hızı. AVSpeechUtterance ölçeğinde 0.5 varsayılan.
    @Published var rate: Double = UserDefaults.standard.object(forKey: "voiceRate") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(rate, forKey: "voiceRate") }
    }

    var availableTurkishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("tr") }
    }

    private init() {}

    /// Anons.
    /// - Parameter interrupting: kritik uyarılarda devam eden konuşmayı keser.
    func speak(_ text: String, interrupting: Bool = false) {
        guard voiceEnabled, !text.isEmpty else { return }
        AudioSessionManager.shared.activateIfNeeded()

        if interrupting, synth.isSpeaking {
            synth.stopSpeaking(at: .word)
        } else if synth.isSpeaking {
            // Sıraya girsin — üst üste bindirmek anlaşılmaz kılar
        }

        let u = AVSpeechUtterance(string: text)
        u.voice = (!voiceIdentifier.isEmpty ? AVSpeechSynthesisVoice(identifier: voiceIdentifier) : nil)
            ?? AVSpeechSynthesisVoice(language: "tr-TR")
        u.rate = Float(rate)
        u.preUtteranceDelay = 0.05
        synth.speak(u)
    }

    /// Yönlü anons: önce yön çanı ilgili taraftan, hemen ardından konuşma.
    func speakDirectional(_ text: String, direction: Float, tone: ToneManager.Signal = .turn) {
        ToneManager.shared.play(tone, direction: direction)
        // Çan bitmeden konuşma başlamasın
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            speak(text)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}
