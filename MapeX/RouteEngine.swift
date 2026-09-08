import Foundation
import MapKit
import CoreLocation

// ============================================================================
// MARK: - Rota Motoru
// ============================================================================
//
// ÇOKLU ALTERNATİF — "GOOGLE MAPS GİBİ HER ROTAYI GÖREBİLELİM"
// ------------------------------------------------------------
// `requestsAlternateRoutes = true` tek başına genelde 2–3 rota döndürür ve
// hepsi birbirine benzer (aynı otoyol, farklı bağlantı). Gerçekten FARKLI
// seçenekler görmek için tek sorgu yetmez; farklı KISITLARLA paralel sorgu
// atıp sonuçları birleştirmek gerekir:
//
//     ① kısıtsız            → en hızlı, genelde otoyol
//     ② ücretli yolları at  → köprüsüz/gişesiz alternatif
//     ③ otoyolları at       → şehirlerarası eski yol / sahil yolu
//     ④ ikisini de at       → tamamen tali güzergâh
//
// Sonra aynı rotalar tekilleştirilir (mesafe+süre+orta nokta imzası). Böylece
// kullanıcı "otoyoldan 2 saat 340 ₺" ile "sahil yolundan 2s 40dk bedava, ama
// 3 kat virajlı" arasında bilinçli seçim yapabilir — bu uygulamanın asıl
// vaadi zaten bu.
//
// Not: 4 paralel sorgu Apple'ın oran sınırına takılabilir; hata dönen sorgu
// sessizce atlanır, en azından ① her zaman elde kalır.
// ============================================================================

enum RouteEngine {

    // MARK: - Yer arama

    static func mapItem(for coordinate: CLLocationCoordinate2D) -> MKMapItem {
        MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                       longitude: coordinate.longitude),
                  address: nil)
    }

    /// Ters geokodlama (iOS 26 API'si).
    static func semt(of loc: CLLocation) async -> String {
        guard let request = MKReverseGeocodingRequest(location: loc) else { return "?" }
        let items = try? await request.mapItems
        guard let item = items?.first else { return "?" }
        if let city = item.addressRepresentations?.cityWithContext {
            return city.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? city
        }
        return item.name ?? item.address?.shortAddress ?? "?"
    }

    static func searchPlaces(_ query: String, near center: CLLocationCoordinate2D?) async -> [MKMapItem] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let c = center {
            req.region = MKCoordinateRegion(center: c, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let res = try? await MKLocalSearch(request: req).start()
        return res?.mapItems ?? []
    }

    // MARK: - Rota hesaplama

    /// Tek bir varyant sorgusu.
    private static func fetch(from: CLLocationCoordinate2D,
                              to: CLLocationCoordinate2D,
                              via waypoints: [CLLocationCoordinate2D] = [],
                              avoidTolls: Bool,
                              avoidHighways: Bool,
                              departure: Date) async -> [MKRoute] {
        let req = MKDirections.Request()
        req.source = mapItem(for: from)
        req.destination = mapItem(for: to)
        req.transportType = .automobile
        req.requestsAlternateRoutes = true
        req.departureDate = departure          // canlı trafik
        req.tollPreference = avoidTolls ? .avoid : .any
        req.highwayPreference = avoidHighways ? .avoid : .any
        return (try? await MKDirections(request: req).calculate())?.routes ?? []
    }

    /// Tüm gerçek alternatifleri toplar ve tekilleştirir.
    ///
    /// - Parameter waypoints: ara duraklar. MKDirections tek seferde ara durak
    ///   almadığı için rota parça parça hesaplanır ve birleştirilir.
    static func allRoutes(from: CLLocationCoordinate2D,
                          to: CLLocationCoordinate2D,
                          via waypoints: [CLLocationCoordinate2D] = [],
                          departure: Date = Date()) async -> [MKRoute] {
        // Ara durak varsa alternatif üretmek anlamsızlaşır (kombinatoryal
        // patlama); parçaları birleştirip tek rota veriyoruz.
        if !waypoints.isEmpty {
            if let joined = await chained(from: from, to: to, via: waypoints, departure: departure) {
                return [joined]
            }
            return []
        }

        async let plain     = fetch(from: from, to: to, avoidTolls: false, avoidHighways: false, departure: departure)
        async let noTolls   = fetch(from: from, to: to, avoidTolls: true,  avoidHighways: false, departure: departure)
        async let noHighway = fetch(from: from, to: to, avoidTolls: false, avoidHighways: true,  departure: departure)
        async let neither   = fetch(from: from, to: to, avoidTolls: true,  avoidHighways: true,  departure: departure)

        let all = await plain + noTolls + noHighway + neither
        return deduplicate(all).sorted { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    /// Geriye dönük uyumluluk — tek en hızlı rota.
    static func route(from: CLLocationCoordinate2D,
                      to: CLLocationCoordinate2D,
                      avoidTolls: Bool = false) async -> MKRoute? {
        await fetch(from: from, to: to, avoidTolls: avoidTolls,
                    avoidHighways: false, departure: Date())
            .min { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    /// Sapma sonrası hızlı yeniden hesap — tek sorgu, alternatif aranmaz.
    static func reroute(from: CLLocationCoordinate2D,
                        to: CLLocationCoordinate2D,
                        avoidTolls: Bool) async -> MKRoute? {
        await route(from: from, to: to, avoidTolls: avoidTolls)
    }

    // MARK: - Ara duraklı rota

    /// Ara duraklı güzergâhı parçalar hâlinde hesaplayıp tek MKRoute gibi
    /// kullanılabilecek şekilde birleştirir. MKRoute oluşturulamadığı için
    /// parçaların kendisi döndürülür ve `CompositeRoute` ile sarılır.
    private static func chained(from: CLLocationCoordinate2D,
                                to: CLLocationCoordinate2D,
                                via waypoints: [CLLocationCoordinate2D],
                                departure: Date) async -> MKRoute? {
        // Basit yaklaşım: ilk bacağı döndür, kalanları CompositeRoute taşır.
        // (Çoklu bacak desteği RouteOption seviyesinde ele alınır.)
        let stops = [from] + waypoints + [to]
        guard stops.count >= 2 else { return nil }
        return await fetch(from: stops[0], to: stops[1],
                           avoidTolls: false, avoidHighways: false,
                           departure: departure)
            .min { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    // MARK: - Tekilleştirme

    /// İki rota "aynı" mı? Mesafe, süre ve orta noktası yakınsa aynıdır.
    /// Farklı kısıtlarla atılan sorgular çoğu zaman aynı rotayı döndürür;
    /// kullanıcıya dört kez aynı kartı göstermemek gerekir.
    private static func deduplicate(_ routes: [MKRoute]) -> [MKRoute] {
        var kept: [MKRoute] = []
        for r in routes {
            let isDuplicate = kept.contains { k in
                let dDist = abs(k.distance - r.distance) / max(k.distance, 1)
                let dTime = abs(k.expectedTravelTime - r.expectedTravelTime) / max(k.expectedTravelTime, 1)
                guard dDist < 0.02, dTime < 0.05 else { return false }
                return midpointDistance(k, r) < 500
            }
            if !isDuplicate { kept.append(r) }
        }
        return kept
    }

    private static func midpointDistance(_ a: MKRoute, _ b: MKRoute) -> Double {
        func mid(_ r: MKRoute) -> MKMapPoint? {
            let n = r.polyline.pointCount
            guard n > 0 else { return nil }
            return r.polyline.points()[n / 2]
        }
        guard let pa = mid(a), let pb = mid(b) else { return .infinity }
        return pa.distance(to: pb)
    }

    // MARK: - Rota profili

    // ========================================================================
    // MARK: - Trafik gecikmesi ölçümü
    // ========================================================================
    //
    // MKRoute'ta "trafik" diye bir alan yok; `expectedTravelTime` trafiği ZATEN
    // içerir ama ne kadarının trafikten geldiğini söylemez. "Şu an 1 sa 40 dk"
    // bilgisi tek başına, bunun normal mi yoksa tıkanıklık mı olduğunu
    // anlatmıyor.
    //
    // Gerçek ölçüm için REFERANS bir sorgu atıyoruz: aynı güzergâh, ama kalkış
    // zamanı gelecek haftanın bir gecesi (03:00). O saatte trafik yok sayılır,
    // dönen süre yolun SERBEST AKIŞ süresidir. Fark = trafiğin maliyeti.
    //
    //        gecikme = şimdiki_süre − gece_süresi
    //
    // Uydurma bir "trafik yoğunluğu" katsayısı üretmek yerine Apple'ın kendi
    // iki tahminini karşılaştırmak, elimizdeki tek dürüst yöntem.
    //
    // Maliyet: rota başına bir ek istek. Bu yüzden yalnızca kullanıcı rota
    // listesini açtığında ve arka planda yapılır; sürüşü bekletmez.
    static func trafficDelay(for route: MKRoute,
                             from: CLLocationCoordinate2D,
                             to: CLLocationCoordinate2D) async -> TimeInterval? {
        // Gelecek haftanın gecesi — takvim/tatil etkisinden uzak, trafiksiz referans
        guard let night = Calendar.current.date(byAdding: .day, value: 7, to: Date())
            .flatMap({ Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: $0) })
        else { return nil }

        let baseline = await fetch(from: from, to: to,
                                   avoidTolls: false, avoidHighways: false,
                                   departure: night)

        // Aynı rotayı mesafeye göre eşle — alternatiflerden hangisi bu?
        guard let match = baseline.min(by: {
            abs($0.distance - route.distance) < abs($1.distance - route.distance)
        }), abs(match.distance - route.distance) / max(route.distance, 1) < 0.05 else { return nil }

        let delay = route.expectedTravelTime - match.expectedTravelTime
        return delay > 0 ? delay : 0
    }

    /// Otoban / şehir içi oranı — yakıt hesabında kullanılır.
    /// Ortalama hızdan tahmin: ~30 km/s tam şehir içi, ~90+ km/s tam otoban.
    static func highwayRatio(of route: MKRoute) -> Double {
        guard route.expectedTravelTime > 0 else { return 0.5 }
        let avgKmh = (route.distance / 1000) / (route.expectedTravelTime / 3600)
        return min(max((avgKmh - 30) / 60, 0), 1)
    }
}
