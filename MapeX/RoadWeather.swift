// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import CoreLocation
import SwiftUI
import WeatherKit

// ============================================================================
// MARK: - Havadan Zemin Tespiti
// ============================================================================
//
// NEDEN KULLANICI SEÇMESİN
// ------------------------
// Zemin durumu, viraj hızını belirleyen EN GÜÇLÜ değişken: aynı virajda kuru
// asfaltta 49 km/s tavsiye edilirken karda 28'e iniyor. Bu kadar belirleyici
// bir girdiyi "kullanıcı menüden seçsin" diye bırakmak iki şekilde başarısız
// olur:
//
//   • Kullanıcı seçmeyi UNUTUR. Yağmur başlar, uygulama hâlâ kuru zemine göre
//     hesaplar ve gerçeğin üstünde hız tavsiye eder — tam da tehlikenin
//     arttığı anda model iyimserleşir.
//   • Kullanıcı seçmeyi BIRAKIR. Bir kez karlıya alıp yaz gelince geri almazsa
//     uygulama sürekli fazla temkinli olur, uyarılar anlamsızlaşır ve sürücü
//     hepsini yok saymaya başlar.
//
// İkisi de sessiz hatadır: uygulama çalışıyor görünür, rakamlar yanlıştır.
// Bu yüzden zemin artık otomatik belirlenir; kullanıcı yalnızca GEREKİRSE
// devreye girer.
//
// HAVA ≠ ZEMİN
// ------------
// Meteoroloji "yağmur yağıyor mu" der; bizim sorumuz "asfalt tutuyor mu".
// İkisi aynı şey değil ve aradaki farkın tamamı güvenlikle ilgili:
//
//   • Yağmur DURMUŞ olabilir ama yol hâlâ ıslaktır. Bu yüzden son iki saatin
//     yağış kaydına da bakılır.
//   • Yağış YOKKEN de buzlanma olur: sıcaklık sıfıra yakınken önceki ıslaklık
//     donar. En tehlikeli zemin (buz) en sessiz havada oluşabilir.
//   • Sıcaklık tek başına yetmez: -5 °C ve kuru asfalt, +2 °C ve ıslak
//     asfalttan çok daha iyi tutar.
//
// EŞLEME TABLOSU (yukarıdaki sıra ÖNEMLİ — ilk eşleşen kazanır)
//
//   ① Kar / dolu / kar-yağmur karışımı yağıyor           → Karlı
//   ② Sıcaklık ≤ 3 °C  VE  ıslaklık var (yağış ya da
//      son 2 saatte yağmış ya da donan yağış)            → Buzlu
//   ③ Şiddetli yağmur / fırtına                          → Şiddetli Yağmur
//   ④ Yağmur / çiseleme / son 2 saatte yağmış            → Islak
//   ⑤ Diğer her şey                                      → Kuru  (varsayılan)
//
// 3 °C eşiği: hava sıcaklığı yol yüzeyi sıcaklığından yüksek olabilir
// (özellikle köprüde ve gece), bu yüzden 0 °C değil 3 °C alınır. Köprüler ve
// viyadükler altlarından hava geçtiği için yoldan önce buzlanır — bu, güvenli
// taraftaki hatadır.
//
// İNTERNETSİZ
// -----------
// Ağ yoksa son bilinen hava korunur; o da yoksa KURU varsayılır. Kuru varsayım
// burada "iyimser" değil "nötr"dür: kullanıcı gerçekten karda ise elle
// seçebilir, ve uygulamanın internetsiz tam işlevli kalması kuralı korunur.
//
// APPLE ŞARTI
// -----------
// WeatherKit kullanan uygulama, Apple Weather atıfını ve yasal bağlantıyı
// GÖSTERMEK ZORUNDADIR. `attributionURL` bunun içindir; Ayarlar'da gösterilir.
// ============================================================================

@MainActor
final class RoadWeatherService: ObservableObject {
    static let shared = RoadWeatherService()

    struct Snapshot {
        let temperatureC: Double
        /// SF Symbol adı — Apple'ın kendi hava ikonu.
        let symbolName: String
        /// "Parçalı bulutlu" gibi kısa metin.
        let summary: String
        let roadCondition: RoadCondition
        let observedAt: Date
        let coordinate: CLLocationCoordinate2D

        var temperatureText: String { "\(Int(temperatureC.rounded()))°" }

        /// Hava verisi bayatladıysa zemin tahmini de şüphelidir.
        var isStale: Bool { Date().timeIntervalSince(observedAt) > 2 * 3600 }
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isFetching = false
    /// Apple'ın zorunlu kıldığı yasal atıf bağlantısı.
    @Published private(set) var attributionURL: URL?

    private let service = WeatherService.shared
    private var lastFetchAt: Date = .distantPast
    private var lastFetchCoordinate: CLLocationCoordinate2D?

    private init() {}

    /// Hava verisi ne sıklıkla tazelenir.
    ///
    /// 20 dakika: hava bundan hızlı değişmez, ama yağmurun başlaması 20 dakika
    /// içinde yakalanmalı. Ayrıca 25 km'den fazla yol alındıysa beklenmeden
    /// tazelenir — dağ yoluna girerken vadi havasıyla hesap yapmak istemeyiz.
    private static let refreshInterval: TimeInterval = 20 * 60
    private static let refreshDistance: CLLocationDistance = 25_000

    func updateIfNeeded(for location: CLLocation) async {
        guard !isFetching else { return }

        let movedFar = lastFetchCoordinate.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: location) > Self.refreshDistance
        } ?? true
        let aged = Date().timeIntervalSince(lastFetchAt) > Self.refreshInterval
        guard movedFar || aged else { return }

        await fetch(for: location)
    }

    func fetch(for location: CLLocation) async {
        isFetching = true
        defer { isFetching = false }

        do {
            let weather = try await service.weather(for: location)
            let current = weather.currentWeather
            let tempC = current.temperature.converted(to: .celsius).value

            // Son iki saatte yağmış mı? Yol, yağmur durduktan sonra da ıslak
            // kalır. Bu sorgu BEST-EFFORT: başarısız olursa yalnızca "yakın
            // geçmişte yağış" bilgisini kaybederiz, tahmin yine üretilir.
            let recentlyWet = await recentPrecipitation(at: location)

            let condition = Self.roadCondition(from: current.condition,
                                               temperatureC: tempC,
                                               precipitating: current.precipitationIntensity.value > 0,
                                               recentlyWet: recentlyWet)

            snapshot = Snapshot(temperatureC: tempC,
                                symbolName: current.symbolName,
                                summary: Self.summary(for: current.condition),
                                roadCondition: condition,
                                observedAt: current.date,
                                coordinate: location.coordinate)
            lastFetchAt = Date()
            lastFetchCoordinate = location.coordinate

            if attributionURL == nil {
                attributionURL = try? await service.attribution.legalPageURL
            }
        } catch {
            // Ağ hatası SESSİZCE yutulur ve son bilinen hava korunur.
            // Uygulamanın internetsiz tam işlevli kalma kuralı burada da geçerli.
        }
    }

    /// Son iki saatte kayda değer yağış oldu mu?
    private func recentPrecipitation(at location: CLLocation) async -> Bool {
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        guard let hourly = try? await service.weather(
            for: location, including: .hourly(startDate: twoHoursAgo, endDate: now))
        else { return false }

        // 0.2 mm eşiği: ölçüm gürültüsünü ve yolu ıslatmayan çiy benzeri
        // değerleri elemek için. Bunun altındaki yağış asfaltı ıslatmaz.
        return hourly.contains { $0.precipitationAmount.converted(to: .millimeters).value >= 0.2 }
    }

    // MARK: - Eşleme

    /// Hava durumundan zemin tutuşuna. Sıra önemlidir; ilk eşleşen kazanır.
    static func roadCondition(from condition: WeatherCondition,
                              temperatureC: Double,
                              precipitating: Bool,
                              recentlyWet: Bool) -> RoadCondition {

        // ① Katı yağış — yolda kar/buz birikir
        switch condition {
        case .blizzard, .blowingSnow, .flurries, .heavySnow, .snow,
             .sunFlurries, .wintryMix, .sleet, .hail:
            return .snow
        default:
            break
        }

        // Donan yağış doğrudan buz demektir; sıcaklık eşiğini beklemez.
        if condition == .freezingDrizzle || condition == .freezingRain {
            return .ice
        }

        let wet = precipitating || recentlyWet
            || condition == .rain || condition == .drizzle
            || condition == .heavyRain || condition == .sunShowers

        // ② Sıfıra yakın + ıslaklık = buzlanma. Hava sıcaklığı yol yüzeyinden
        //    yüksek olabildiği için eşik 0 değil 3 °C.
        if temperatureC <= 3, wet { return .ice }

        // ③ Şiddetli yağış ve fırtınalar
        switch condition {
        case .heavyRain, .thunderstorms, .strongStorms, .isolatedThunderstorms,
             .scatteredThunderstorms, .tropicalStorm, .hurricane:
            return .heavyRain
        default:
            break
        }

        // ④ Islak
        if wet { return .wet }

        // ⑤ Varsayılan
        return .dry
    }

    /// Kısa Türkçe özet. WeatherKit'in kendi metni yerelleştirilmiş gelmiyor.
    static func summary(for condition: WeatherCondition) -> String {
        switch condition {
        case .clear, .mostlyClear:            return "Açık"
        case .partlyCloudy:                   return "Parçalı bulutlu"
        case .cloudy, .mostlyCloudy:          return "Bulutlu"
        case .drizzle, .sunShowers:           return "Çiseliyor"
        case .rain:                           return "Yağmurlu"
        case .heavyRain:                      return "Şiddetli yağmur"
        case .freezingDrizzle, .freezingRain: return "Donan yağmur"
        case .snow, .heavySnow, .flurries,
             .sunFlurries, .blowingSnow:      return "Kar yağışlı"
        case .blizzard:                       return "Tipi"
        case .sleet, .wintryMix:              return "Karla karışık"
        case .hail:                           return "Dolu"
        case .foggy:                          return "Sisli"
        case .haze, .smoky:                   return "Puslu"
        case .windy, .breezy:                 return "Rüzgârlı"
        case .thunderstorms, .strongStorms,
             .isolatedThunderstorms,
             .scatteredThunderstorms:         return "Gök gürültülü"
        case .hurricane, .tropicalStorm:      return "Fırtına"
        case .frigid:                         return "Dondurucu"
        case .hot:                            return "Çok sıcak"
        case .blowingDust:                    return "Tozlu"
        @unknown default:                     return "—"
        }
    }
}
