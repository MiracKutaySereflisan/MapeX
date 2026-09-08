# MapeX

iOS navigasyon ve sürüş asistanı. SwiftUI ile yazıldı, dış bağımlılık kullanmaz.

Sıradan bir navigasyon uygulamasından iki noktada ayrılır:

1. **Virajı önceden söyler.** Rotadaki her virajın yarıçapını hesaplar, o yarıçapın
   taşıyabileceği hızı karayolu mühendisliği denklemiyle bulur ve sürücünün
   yavaşlamaya yetecek mesafede uyarır — 120 km/s'te yaklaşık 830 m, 50 km/s'te
   yaklaşık 140 m önceden.
2. **Yolun gerçek maliyetini gösterir.** Her alternatif rota için geçiş ücreti ve
   yakıt tüketimi tek bir rakamda birleşir.

## Viraj modeli üzerine

Model konfor eşiğini hedefler, kayma sınırını değil. Kuru zeminde ve Normal modda
ürettiği değerler: R = 100 m → 49 km/s, R = 400 m → 93 km/s, R = 25 m → 29 km/s.

Sürtünme katsayısını µ = 0.8 alan modeller aynı 100 metrelik viraja 101 km/s der.
Bu rakam aracın kaymaya başladığı sınırdır, tavsiye edilebilecek bir hız değildir.
MapeX bilinçli olarak daha düşük bir eşik kullanır.

## Öne çıkan özellikler

- Viraj hız uyarısı: yarıçap çıkarımı, araç dinamiği (SSF), zemin durumu
- Alternatif rota karşılaştırması: süre, geçiş ücreti ve yakıt tek tabloda
- Türkiye geçiş ücreti ağı: gantry tabanlı ücret hesabı, gömülü tarife verisi
- Dynamic Island üzerinde Live Activity ile sürüş sırasında canlı bilgi
- CarPlay sahnesi (kayıtlı hedefler)
- Yakıt kaydı ve tüketim takibi, araç kataloğu
- Sürüş puanı, favoriler, gezi özeti

## Yapı

| Klasör | İçinde ne var |
|---|---|
| `MapeX/` | Uygulama: rota motoru, viraj geometrisi, hız modeli, ücret ağı, arayüz |
| `MapeXWidget/` | Live Activity ve widget uzantısı |
| `Tools/` | KGM geçiş tarifesi verisini çeken yardımcı betik |

Okumaya başlanacak yerler: `CurveGeometry.swift` (viraj yarıçapı çıkarımı) →
`SpeedModel.swift` (yarıçaptan tavsiye hıza) → `RouteEngine.swift` (rota ve
alternatifler) → `TollNetwork.swift` (geçiş ücreti hesabı).

## Çalıştırma

- Xcode 16 veya üzeri, iOS 17.0+
- Şemalar: `MapeX` ve `MapeXWidgetExtension`

```
MapeX3.xcodeproj → aç → şema: MapeX → ⌘R
```

## Sınırlar

- **Hız limiti verisi yok.** MapKit bu veriyi vermiyor; uygulama "bu yolda limit 50"
  diyemez, yalnızca virajın taşıdığı hızı söyler.
- **Şerit bilgisi yok** (aynı sebeple).
- **Viraj motoru sahada doğrulanmadı.** Değerler modelin ürettiği değerlerdir,
  gerçek yol testiyle karşılaştırılmamıştır.
- WeatherKit yetkisi açık değilken zemin kuru varsayılır.
- Ara duraklar ve çok bacaklı rota desteklenmiyor.

## Telif

Tüm hakları saklıdır. Kod incelenmek üzere paylaşılmıştır.
