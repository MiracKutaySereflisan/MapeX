// Copyright (c) 2026 Mirac Kutay Sereflisan. Tum haklari saklidir.
import Foundation
import MapKit

// MARK: - Favori Yolculuk
struct FavoriteRoute: Codable, Identifiable {
    var id = UUID()
    let name: String
    let startName: String
    let endName: String
    let startCoord: CodableCoordinate
    let endCoord: CodableCoordinate
    let distance: Double
    var timestamp: Date
    var usageCount: Int = 1
}

// Codable yapı için wrapper
struct CodableCoordinate: Codable {
    let latitude: Double
    let longitude: Double
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    init(_ coord: CLLocationCoordinate2D) {
        self.latitude = coord.latitude
        self.longitude = coord.longitude
    }
}

// MARK: - Depolama Yöneticisi
enum StorageManager {
    
    // MARK: - Favoriler
    static func saveFavoriteRoute(_ start: String, _ end: String,
                                 from: CLLocationCoordinate2D,
                                 to: CLLocationCoordinate2D,
                                 distance: Double) {
        let favorite = FavoriteRoute(
            name: "\(start) → \(end)",
            startName: start,
            endName: end,
            startCoord: CodableCoordinate(from),
            endCoord: CodableCoordinate(to),
            distance: distance,
            timestamp: Date()
        )
        
        var favorites = loadFavorites()
        if let idx = favorites.firstIndex(where: { $0.startName == start && $0.endName == end }) {
            favorites[idx].usageCount += 1
            favorites[idx].timestamp = Date()
        } else {
            favorites.append(favorite)
        }
        
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "favoriteRoutes")
        }
    }
    
    static func loadFavorites() -> [FavoriteRoute] {
        guard let data = UserDefaults.standard.data(forKey: "favoriteRoutes"),
              let favorites = try? JSONDecoder().decode([FavoriteRoute].self, from: data) else {
            return []
        }
        // En sık kullanılanlar önce
        return favorites.sorted { $0.usageCount > $1.usageCount }
    }
    
    static func deleteFavorite(_ id: UUID) {
        var favorites = loadFavorites()
        favorites.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "favoriteRoutes")
        }
    }
    
    // MARK: - Uygulamada Ayarlar
    static func saveSetting(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
    
    static func loadSetting(_ key: String, defaultValue: Any) -> Any {
        UserDefaults.standard.value(forKey: key) ?? defaultValue
    }
}
