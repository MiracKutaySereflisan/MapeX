import Foundation
import AVFoundation

// ============================================================================
// MARK: - Nota Tabanlı Yönlü Uyarı Sesleri
// ============================================================================
//
// TASARIM İLKESİ
// --------------
// Her sinyalin motifi SABİTTİR; sürücü zamanla sesi tanır ve ekrana bakmadan
// ne olduğunu anlar. Motif kısa, müzikal ve zarflıdır — bildirim "biip"i değil,
// bir enstrüman çıtı gibi. Sürüşte dikkat çalmadan bilgi taşıması gerekir.
//
// YÖN BİLGİSİ — SESİN KENDİSİ NEREYE GİDİLECEĞİNİ SÖYLER
// ------------------------------------------------------
// Sürücü "sağa mı sola mı" bilgisini kelimeyi işlemeden, refleks düzeyinde
// almalı. Bunun için stereo panlama kullanıyoruz — ama motifin TAMAMINI tek
// tarafa atmak yanlış: ses "geldiği yer" hissini kaybeder ve mono hoparlörlü
// ortamlarda motif tanınmaz hâle gelir.
//
// Bunun yerine motif MERKEZDE başlar, SON NOTASI hedef yöne KAYARAK biter:
//
//        C5 ────── E5 ────── G5 ⟶⟶⟶ (sola süzülür)
//        merkez    merkez     kayan
//
// Böylece:
//   • Motifin kimliği (hangi uyarı olduğu) merkezde net duyulur
//   • Son nota kulakta bir "yönelme" bırakır — sola dönecekse ses sola akar
//   • Araç hoparlöründe, kulaklıkta, tek AirPods'ta hepsinde tutarlı çalışır
//
// Kayma sabit değil, son notanın süresi boyunca SÜREKLİDİR (her örnekte pan
// güncellenir). Ani sıçrama yerine akış, yönü çok daha güçlü hissettirir.
//
// PANLAMA YASASI
// --------------
// Sabit güçte (equal-power) panlama: gainL = cos(θ), gainR = sin(θ),
// θ = (pan+1)·π/4. Doğrusal panlamada ses ortada güç kaybeder ("delik"
// oluşur); equal-power'da toplam güç sabit kalır.
// ============================================================================

@MainActor
final class ToneManager: ObservableObject {
    static let shared = ToneManager()

    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "tonesEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "tonesEnabled") }
    }

    /// Yön panlamasının şiddeti. 0 = kapalı (mono), 1 = tam kenar.
    /// Bazı sürücüler tek kulaklıkla kullanıyor; kısabilsinler.
    @Published var directionalStrength: Double = UserDefaults.standard.object(forKey: "toneDirectionalStrength") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(directionalStrength, forKey: "toneDirectionalStrength") }
    }

    // MARK: - Notalar

    private enum Note: Double {
        case g4 = 392.00
        case c5 = 523.25, d5 = 587.33, e5 = 659.25, f5 = 698.46, g5 = 783.99
        case a5 = 880.00, b5 = 987.77, c6 = 1046.50, e6 = 1318.51
    }

    // MARK: - Sinyaller

    enum Signal: String {
        case safe          // ✅ tek yumuşak G5 — "hız uygun"
        case curveHeadsUp  // 🌀 C5-E5-G5 yükselen arpej — "ileride viraj var"
        case curvePrepare  // ⚠️ E5→C5 inen ikili — "yavaşlamaya başla"
        case curveCritical // 🛑 A5×3 hızlı üçleme — "şimdi fren"
        case turn          // ➡️ D5→G5 yön çanı — "sapak"
        case turnNow       // ➡️ G5→B5 kısa ve net — "şimdi dön"
        case reroute       // 🔄 G4-C5 — "rota yeniden hesaplanıyor"
        case arrive        // 🏁 C5-E5-G5-C6 varış fanfarı

        /// (frekans, süre, sonraki notaya boşluk)
        var notes: [(freq: Double, dur: Double, gap: Double)] {
            switch self {
            case .safe:
                return [(Note.g5.rawValue, 0.14, 0)]
            case .curveHeadsUp:
                return [(Note.c5.rawValue, 0.13, 0.02), (Note.e5.rawValue, 0.13, 0.02), (Note.g5.rawValue, 0.22, 0)]
            case .curvePrepare:
                return [(Note.e5.rawValue, 0.14, 0.03), (Note.c5.rawValue, 0.24, 0)]
            case .curveCritical:
                return [(Note.a5.rawValue, 0.11, 0.06), (Note.a5.rawValue, 0.11, 0.06), (Note.a5.rawValue, 0.18, 0)]
            case .turn:
                return [(Note.d5.rawValue, 0.12, 0.03), (Note.g5.rawValue, 0.24, 0)]
            case .turnNow:
                return [(Note.g5.rawValue, 0.10, 0.02), (Note.b5.rawValue, 0.20, 0)]
            case .reroute:
                return [(Note.g4.rawValue, 0.13, 0.03), (Note.c5.rawValue, 0.18, 0)]
            case .arrive:
                return [(Note.c5.rawValue, 0.12, 0.02), (Note.e5.rawValue, 0.12, 0.02),
                        (Note.g5.rawValue, 0.12, 0.02), (Note.c6.rawValue, 0.30, 0)]
            }
        }

        /// Aynı sinyalin üst üste binmemesi için asgari aralık (sn).
        var minInterval: TimeInterval {
            switch self {
            case .safe:           return 8
            case .curveHeadsUp:   return 5
            case .curvePrepare:   return 3
            case .curveCritical:  return 1.5
            case .turn:           return 3
            case .turnNow:        return 2
            case .reroute:        return 8
            case .arrive:         return 10
            }
        }

        /// Aciliyete göre ses düzeyi — kritik uyarı diğerlerinden yüksek çalar.
        var gain: Double {
            switch self {
            case .curveCritical: return 0.40
            case .curvePrepare, .turnNow: return 0.32
            case .safe: return 0.18
            default: return 0.28
            }
        }
    }

    // MARK: - Motor

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var lastPlayed: [String: Date] = [:]

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Çalma

    /// Yönsüz (merkez) çalma.
    func play(_ signal: Signal) {
        play(signal, direction: 0)
    }

    /// Yönlü çalma.
    ///
    /// - Parameter direction: −1 tam sol, 0 merkez, +1 tam sağ.
    ///   Motif merkezde başlar; **son notası** bu yöne doğru kayarak biter.
    ///   Sol viraj → ses sol hoparlörde/kulaklıkta sona erer.
    func play(_ signal: Signal, direction: Float) {
        guard enabled else { return }

        // Oran sınırı
        if let last = lastPlayed[signal.rawValue],
           Date().timeIntervalSince(last) < signal.minInterval { return }
        lastPlayed[signal.rawValue] = Date()

        AudioSessionManager.shared.activateIfNeeded()
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }

        let target = Float(max(-1, min(1, Double(direction) * directionalStrength)))
        guard let buffer = makeBuffer(for: signal, targetPan: target) else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// Viraj yönünden çalma kolaylığı.
    func play(_ signal: Signal, curveDirection: Curve.Direction) {
        play(signal, direction: curveDirection == .left ? -1 : 1)
    }

    // MARK: - Sentez

    /// Motifi tek stereo buffer'a çizer.
    ///
    /// Pan davranışı:
    ///   • son notadan öncekiler → merkez (0)
    ///   • son nota → 0'dan `targetPan`'a örnek örnek kayar
    /// Kayma eğrisi `smoothstep` (3t²−2t³): başı ve sonu yumuşak, ortası hızlı.
    /// Doğrusal kaymaya göre daha doğal, "sürüklenen" bir his verir.
    private func makeBuffer(for signal: Signal, targetPan: Float) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let notes = signal.notes
        guard !notes.isEmpty else { return nil }

        let totalDur = notes.reduce(0) { $0 + $1.dur + $1.gap } + 0.06
        let frameCount = AVAudioFrameCount(sr * totalDur)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount
        guard let left = buf.floatChannelData?[0], let right = buf.floatChannelData?[1] else { return nil }

        // Sessizlikle başla
        for i in 0..<Int(frameCount) { left[i] = 0; right[i] = 0 }

        let lastIndex = notes.count - 1
        var cursor = 0

        for (noteIndex, note) in notes.enumerated() {
            let n = Int(sr * note.dur)
            let attack = Int(sr * 0.012)
            let release = Int(Double(n) * 0.45)      // uzun release → yumuşak "nota" hissi
            let isLast = noteIndex == lastIndex

            for i in 0..<n {
                let idx = cursor + i
                guard idx < Int(frameCount) else { break }

                let t = Double(i) / sr

                // Temel + oktav harmoniği → daha sıcak tını
                var s = sin(2 * .pi * note.freq * t)
                s += 0.25 * sin(2 * .pi * note.freq * 2 * t)

                // Zarf
                var env: Double = 1
                if i < attack { env = Double(i) / Double(attack) }
                if i > n - release { env = Double(n - i) / Double(release) }

                let v = Float(s * env * signal.gain)

                // ── Pan ──────────────────────────────────────────────────────
                // Yalnızca SON notada kayar; öncekiler merkezde kalır.
                let pan: Float
                if isLast && targetPan != 0 {
                    let p = Float(i) / Float(max(n - 1, 1))
                    let eased = p * p * (3 - 2 * p)          // smoothstep
                    pan = targetPan * eased
                } else {
                    pan = 0
                }

                let angle = (pan + 1) * .pi / 4               // equal-power
                left[idx]  += v * cos(angle) * 1.414 * 0.5
                right[idx] += v * sin(angle) * 1.414 * 0.5
            }
            cursor += n + Int(sr * note.gap)
        }
        return buf
    }
}

// ============================================================================
// MARK: - Ses Oturumu
// ============================================================================
//
// Eski kodda her `speak()` ve her `play()` çağrısında `setCategory` +
// `setActive` yapılıyordu — sürüşte saniyede bir. Bu:
//   • pahalı bir sistem çağrısı (ses yolu yeniden kuruluyor)
//   • Bluetooth'ta müzik kesilmesine / anonsun başının yutulmasına yol açıyor
//   • `.duckOthers` ile `.mixWithOthers`'ın birlikte verilmesi ducking'i
//     etkisiz bırakıyordu (mixWithOthers, diğer sesi kısma talebini geçersiz kılar)
//
// Doğrusu: oturumu BİR KEZ kur, `.playback` + `.spokenAudio` + `.duckOthers`
// ile. Navigasyon anonsu tam da bunun için tasarlanmış bir kategoridir: araç
// müziğini kısar, anonsu araya sokar, biter bitmez müziği geri açar.
// ============================================================================

@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private var configured = false
    private var active = false
    private var deactivateWork: Task<Void, Never>?

    private init() {}

    func configure() {
        guard !configured else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback,
                                 mode: .spokenAudio,
                                 options: [.duckOthers,
                                           .allowBluetoothHFP,
                                           .allowBluetoothA2DP,
                                           .interruptSpokenAudioAndMixWithOthers])
        configured = true
    }

    /// Anons öncesi oturumu açar. Zaten açıksa hiçbir şey yapmaz — sürüş
    /// boyunca art arda gelen uyarılarda tek bir aktivasyon yeter.
    func activateIfNeeded() {
        configure()
        deactivateWork?.cancel()
        guard !active else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        active = true
    }

    /// Sürüş bitince oturumu bırakır ki araç müziği tam sesine dönsün.
    func release(after delay: TimeInterval = 1.5) {
        deactivateWork?.cancel()
        deactivateWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self?.active = false
        }
    }
}
