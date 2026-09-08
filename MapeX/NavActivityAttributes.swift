// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import ActivityKit

// MARK: - Dinamik Ada Canlı Aktivite Modeli
// DİKKAT: Bu dosyanın birebir kopyası MapeXWidget klasöründe de vardır.
// İki hedef (app + widget) aynı tip tanımını kullanmalıdır; değişiklik
// yaparsan İKİSİNİ DE aynı şekilde güncelle.
struct NavActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var speedKmh: Int              // anlık hız
        var suggestedSpeed: Int?       // virajdaysa tavsiye edilen hız
        var speedLevel: Int            // 0 yeşil, 1 sarı, 2 turuncu, 3 kırmızı
        var remainingMinutes: Int      // varışa kalan dk
        var distanceToTurn: Int        // sapağa kalan metre
        var turnAngle: Double          // dönüş açısı (derece): + sağ, − sol
        var instruction: String        // "D-100 yönünde sağa dönün"

        // Viraj uyarısı
        var curveDistance: Int?        // viraja kalan metre
        var curveIsLeft: Bool?         // viraj yönü
        var curveWarning: Int          // 0 yok, 1 bilgi, 2 hazırlan, 3 kritik
        var curveGrade: Int?           // ralli derecesi 1 (dar) – 6 (geniş)
        var riskLevel: Int             // 0 nötr, 1 güvenli, 2 uyarı, 3 kritik
    }

    var destinationName: String
}
