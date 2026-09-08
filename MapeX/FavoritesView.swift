import SwiftUI
import MapKit

struct FavoritesView: View {
    @State private var favorites: [FavoriteRoute] = []
    @State private var showAddFavorite = false
    var onSelectRoute: (FavoriteRoute) -> Void = { _ in }
    
    var body: some View {
        ZStack {
            
            if favorites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "star")
                        .font(.system(size: 48))
                        .foregroundStyle(.yellow)
                    Text("Henüz favori yoktur")
                        .bold()
                        
                    Text("Sık gidiş gelişlerinizi kaydedin")
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(favorites) { route in
                            Button {
                                onSelectRoute(route)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(route.name)
                                            .bold()
                                            
                                        Label(route.startName, systemImage: "mappin.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Label(route.endName, systemImage: "mappin")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(String(format: "%.1f km", route.distance / 1000))
                                            .font(.caption).bold()
                                            .foregroundStyle(.green)
                                        Text("×\(route.usageCount)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding()
                                .background(.quaternary.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    StorageManager.deleteFavorite(route.id)
                                    loadFavorites()
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Favoriler")
        .onAppear { loadFavorites() }
    }
    
    private func loadFavorites() {
        favorites = StorageManager.loadFavorites()
    }
}

#Preview {
    FavoritesView()
}
