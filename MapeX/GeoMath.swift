// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import MapKit
import CoreLocation

// ============================================================================
// MARK: - Geometri Çekirdeği
// ============================================================================
//
// NEDEN BU DOSYA VAR
// ------------------
// Eski kodda rotaya olan uzaklık, rotanın "örnek noktalarına" olan en kısa
// mesafeyle ölçülüyordu. Bu matematiksel olarak yanlıştır: bir doğru parçasının
// ortasında duran araç, uç noktalara çok uzak olabilir.
//
//      A ●──────────────────────────● B      (rota segmenti, 600 m)
//                    ▲
//                  araç             → noktaya mesafe: 300 m  (YANLIŞ)
//                                   → segmente mesafe:  0 m  (DOĞRU)
//
// Bütün konum-rota ilişkileri (sapma tespiti, gişe yakalama, viraja kalan
// mesafe, ilerleme yüzdesi) buradaki "nokta–segment" ve "along-track" ölçüleri
// üzerine kurulur.
//
// KOORDİNAT SİSTEMİ
// -----------------
// MKMapPoint kullanıyoruz: Web Mercator düzlem projeksiyonu. Metrik hesap için
// MKMetersPerMapPointAtLatitude(lat) ile ölçekleniyor. Türkiye enlemlerinde
// (36°–42°) Mercator'ın yerel ölçek hatası, birkaç yüz metrelik bir segment
// üzerinde binde birin altındadır — navigasyon için fazlasıyla yeterli, ve
// haversine'e göre çok daha hızlıdır (viraj tespiti binlerce nokta işliyor).
// ============================================================================

enum GeoMath {

    // MARK: - Nokta ↔ Segment

    /// Bir noktanın A-B doğru parçasına dik (en kısa) mesafesi ve segment
    /// üzerindeki izdüşümü.
    ///
    /// - Returns: `distance` metre, `t` ∈ [0,1] segment üzerindeki oran,
    ///            `projection` izdüşüm noktası.
    ///
    /// Klasik vektör izdüşümü:  t = ((P−A)·(B−A)) / |B−A|²  , [0,1]'e kırpılır.
    static func distanceToSegment(point p: MKMapPoint,
                                  a: MKMapPoint,
                                  b: MKMapPoint) -> (distance: Double, t: Double, projection: MKMapPoint) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy

        // Dejenere segment (A == B) → nokta mesafesi
        guard lenSq > 0 else {
            return (p.distance(to: a), 0, a)
        }

        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
        return (p.distance(to: proj), t, proj)
    }

    // MARK: - Rota üzerinde konumlandırma

    /// Bir noktanın polyline üzerindeki en yakın izdüşümü.
    ///
    /// - Parameter cumulative: `points`'in kümülatif mesafe dizisi
    ///   (`cumulativeDistances(of:)` ile üretilir). Verilirse `alongTrack`
    ///   (rota başından itibaren kat edilen mesafe) da hesaplanır.
    struct Snap {
        let crossTrack: Double     // rota eksenine dik mesafe (m) — sapma ölçüsü
        let alongTrack: Double     // rota başından izdüşüme kadar mesafe (m)
        let segmentIndex: Int      // hangi segmentte
        let projection: MKMapPoint
    }

    /// Tüm segmentleri tarayarak en yakın izdüşümü bulur.
    ///
    /// `searchWindow` verilirse yalnızca o segment aralığına bakar — sürüş
    /// sırasında araç rotada ileri doğru gittiği için her fix'te baştan
    /// taramaya gerek yok (O(n) yerine O(pencere)). Uzun rotalarda 1 Hz'de
    /// binlerce segment taramak pil yakar.
    static func snap(point p: MKMapPoint,
                     to points: [MKMapPoint],
                     cumulative: [Double],
                     searchWindow: Range<Int>? = nil) -> Snap? {
        guard points.count >= 2 else { return nil }

        let lower = max(0, searchWindow?.lowerBound ?? 0)
        let upper = min(points.count - 1, searchWindow?.upperBound ?? (points.count - 1))
        guard lower < upper else { return nil }

        var best = Snap(crossTrack: .infinity, alongTrack: 0, segmentIndex: lower, projection: p)

        for i in lower..<upper {
            let r = distanceToSegment(point: p, a: points[i], b: points[i + 1])
            if r.distance < best.crossTrack {
                let segLen = points[i].distance(to: points[i + 1])
                best = Snap(crossTrack: r.distance,
                            alongTrack: cumulative[i] + r.t * segLen,
                            segmentIndex: i,
                            projection: r.projection)
            }
        }
        return best.crossTrack.isFinite ? best : nil
    }

    /// Polyline'ın kümülatif mesafe dizisi. `cumulative[i]` = başlangıçtan
    /// `points[i]`'ye kadar olan yol uzunluğu (metre).
    static func cumulativeDistances(of points: [MKMapPoint]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var out = [Double](repeating: 0, count: points.count)
        for i in 1..<points.count {
            out[i] = out[i - 1] + points[i - 1].distance(to: points[i])
        }
        return out
    }

    // MARK: - Polyline → nokta dizisi

    static func points(of polyline: MKPolyline) -> [MKMapPoint] {
        let n = polyline.pointCount
        guard n > 0 else { return [] }
        let buf = polyline.points()
        return (0..<n).map { buf[$0] }
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let n = polyline.pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    // MARK: - Yeniden örnekleme

    /// Polyline'ı **sabit yay uzunluğunda** yeniden örnekler.
    ///
    /// NEDEN GEREKLİ: MapKit'in verdiği noktalar düzgün aralıklı değildir —
    /// otoyolda 200 m, şehir içi kavşakta 3 m arayla nokta gelebilir. Eğrilik
    /// (1/R) ardışık noktalardan hesaplandığı için, örnekleme aralığı doğrudan
    /// sonuca karışır: aynı fiziksel viraj, nokta sıklığına göre farklı yarıçap
    /// verir. Sabit aralığa çekmek bu bağımlılığı ortadan kaldırır.
    static func resample(_ points: [MKMapPoint], spacing: Double) -> [MKMapPoint] {
        guard points.count >= 2, spacing > 0 else { return points }

        var out: [MKMapPoint] = [points[0]]
        var carry: Double = 0   // önceki segmentten devreden yol

        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let segLen = a.distance(to: b)
            guard segLen > 0 else { continue }

            var travelled = spacing - carry
            while travelled <= segLen {
                let t = travelled / segLen
                out.append(MKMapPoint(x: a.x + t * (b.x - a.x),
                                      y: a.y + t * (b.y - a.y)))
                travelled += spacing
            }
            carry = segLen - (travelled - spacing)
        }

        if let last = points.last, out.last?.distance(to: last) ?? 0 > spacing * 0.25 {
            out.append(last)
        }
        return out
    }

    // MARK: - Kerteriz

    /// İki koordinat arasındaki başlangıç kerterizi (0° kuzey, saat yönü +).
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi).truncatingRemainder(dividingBy: 360)
    }

    /// Mercator düzleminde kerteriz. Eğrilik hesabı için yeterli ve hızlı.
    static func planarBearing(from a: MKMapPoint, to b: MKMapPoint) -> Double {
        // MKMapPoint'te y ekseni GÜNEYE doğru artar → kuzey referansı için -dy
        atan2(b.x - a.x, a.y - b.y) * 180 / .pi
    }

    /// İki açı arasındaki en kısa farkı (−180, +180] aralığına indirger.
    /// Kerteriz farkı alırken 359° → 1° geçişinin +2° olduğunu görmek için şart.
    static func normalizeAngle(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    // MARK: - Koordinat dönüşümü

    static func coordinate(_ p: MKMapPoint) -> CLLocationCoordinate2D { p.coordinate }
    static func mapPoint(_ c: CLLocationCoordinate2D) -> MKMapPoint { MKMapPoint(c) }
}
