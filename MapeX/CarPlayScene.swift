import CarPlay
import Combine
import CoreLocation
import MapKit
import UIKit

// ============================================================================
// MARK: - CarPlay
// ============================================================================
//
// NEDEN CARPLAY
// -------------
// Bu uygulamanın feragatnamesi "sürüş sırasında ekrana bakmayın" diyor. Telefon
// ekranı için doğru olan bu cümle, aracın kendi ekranı için geçerli değildir:
// gösterge panelinin hizasındaki ekran, yola bakışı kesintiye uğratmadan
// okunabilecek TEK yüzeydir. Virajı önceden söylemeyi iddia eden bir uygulama
// için en doğal yer burasıdır.
//
// MİMARİ
// ------
// CarPlay AYRI BİR SAHNEDİR (`CPTemplateApplicationScene`) ve telefon
// arayüzünün `View` ağacına erişemez. Bu yüzden sürüş beyni tek örneğe
// taşındı (`DriveViewModel.shared`, `LocationManager.shared`) ve konum akışı
// arayüzden bağımsız hâle getirildi. Buradaki sınıflar YALNIZCA GÖSTERİR;
// hiçbir hesap yapmazlar — viraj hızı, uyarı mesafesi, ücret hep aynı
// çekirdekten gelir. İki ekran arasında sayı farkı çıkması imkânsız olmalı.
//
// ARAYÜZ İKİ KATMANDIR
//   ① `CPMapTemplate` — Apple'ın çizdiği üst şerit: manevra, mesafe, ETA,
//      düğmeler. Sürücü dikkati için Apple'ın kuralları geçerli.
//   ② `carWindow` — bizim çizdiğimiz harita (`MKMapView`): rota, viraj
//      noktaları ve araç işareti.
//
// APPLE YETKİSİ — DÜRÜST OLMAK GEREKİRSE
// --------------------------------------
// CarPlay navigasyon uygulamaları `com.apple.developer.carplay-maps` yetkisi
// ister. Bu yetki App Store'a yüklemekle GELMEZ; Apple'a ayrıca başvurulur ve
// Apple navigasyon kategorisinde seçicidir. Yetki olmadan bu sahne gerçek
// araçta AÇILMAZ. CarPlay Simulator'da (Simulator > I/O > External Displays >
// CarPlay) test edilebilir. Kod eksiksizdir; eksik olan izindir.
// ============================================================================

// CarPlay'in delege protokolü SDK'da `@MainActor` işaretli DEĞİL; metotları
// nonisolated sayılıyor. Bu sınıf ise `@MainActor` (sürüş beynine, haritaya ve
// şablonlara dokunuyor). Swift 6'da main-actor bir metot nonisolated bir
// gereksinimi karşılayamaz.
//
// Çözüm UYUMLULUĞU main actor'a izole etmek. `@preconcurrency` de uyarıyı
// susturur ama yanlış olur: veri yarışını derleme zamanı hatasından ÇALIŞMA
// ZAMANI çökmesine çevirir, yani sorunu araca taşır. CarPlay bu geri çağrıları
// zaten daima ana iş parçacığında yapar; doğru olan bunu derleyiciye SÖYLEMEK.
@MainActor
final class CarPlaySceneDelegate: UIResponder, @MainActor CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var mapController: CarPlayMapViewController?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?

    private var cancellables = Set<AnyCancellable>()

    /// Aynı manevra için CarPlay'e tekrar tekrar yazmamak adına son gönderilen
    /// metin saklanır — `CPManeuver` her yazışta şeridi yeniden çizer.
    private var lastManeuverText: String?
    /// Aynı viraj için tek uyarı. Uyarıyı her fix'te tekrarlamak, telefon
    /// tarafındaki sesli uyarı disiplininin (bkz. `announceCurve`) CarPlay'de
    /// bozulması demek olurdu.
    private var alertedCurveID: UUID?

    // MARK: Bağlantı

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController

        let controller = CarPlayMapViewController()
        window.rootViewController = controller
        mapController = controller

        let template = CPMapTemplate()
        template.mapDelegate = self
        template.guidanceBackgroundColor = .black
        configureButtons(on: template)
        mapTemplate = template

        interfaceController.setRootTemplate(template, animated: true, completion: nil)

        // Konum izni henüz istenmemişse CarPlay'de harita boş kalırdı.
        LocationManager.shared.start()

        observeDrivingState()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        cancellables.removeAll()
        navigationSession = nil
        mapTemplate = nil
        mapController = nil
        self.interfaceController = nil
    }

    // MARK: Düğmeler

    private func configureButtons(on template: CPMapTemplate) {
        // Haritanın üstünde yüzen düğme: takibe dön.
        let recenter = CPMapButton { [weak self] _ in
            self?.mapController?.recenter()
        }
        recenter.image = UIImage(systemName: "location.fill")
        template.mapButtons = [recenter]

        // Sürüş yokken: hedef seçimi. Sürüşteyken: bitir.
        updateNavigationBar(on: template)
    }

    private func updateNavigationBar(on template: CPMapTemplate) {
        let driving = DriveViewModel.shared.phase == .driving

        if driving {
            let finish = CPBarButton(title: "Bitir") { [weak self] _ in
                self?.finishTrip()
            }
            template.leadingNavigationBarButtons = []
            template.trailingNavigationBarButtons = [finish]
        } else {
            let destinations = CPBarButton(title: "Nereye?") { [weak self] _ in
                self?.presentDestinationList()
            }
            template.leadingNavigationBarButtons = [destinations]
            template.trailingNavigationBarButtons = []
        }
    }

    // MARK: Hedef listesi
    //
    // CarPlay'de klavye yoktur (araç hareket hâlindeyken Apple metin girişini
    // zaten engeller). Bu yüzden hedefler KAYITLI olanlardan seçilir: Ev, İş
    // ve favori rotalar. Yeni bir adres aramak telefonda yapılır — sürüşe
    // başlamadan önce yapılacak iş, sürüş sırasında yapılacak iş değildir.

    private func presentDestinationList() {
        var items: [CPListItem] = []

        for kind in SavedPlace.Kind.allCases {
            guard let place = PlacesStore.shared.place(kind) else { continue }
            let item = CPListItem(text: kind.rawValue, detailText: place.label)
            item.handler = { [weak self] _, completion in
                self?.startNavigation(to: place.coordinate, name: place.label)
                completion()
            }
            items.append(item)
        }

        for fav in StorageManager.loadFavorites().prefix(8) {
            let item = CPListItem(text: fav.name,
                                  detailText: String(format: "%.0f km", fav.distance / 1000))
            item.handler = { [weak self] _, completion in
                self?.startNavigation(to: fav.endCoord.coordinate, name: fav.endName)
                completion()
            }
            items.append(item)
        }

        let section = CPListSection(items: items)
        let list = CPListTemplate(title: "Nereye?", sections: [section])
        // Boş liste sessizce boş bir ekran olurdu; sebebini söyleyelim.
        list.emptyViewSubtitleVariants = [
            "Telefonda Ev/İş kaydet veya bir rotayı favorilere ekle; burada görünür."
        ]
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    // MARK: Sürüş

    private func startNavigation(to coordinate: CLLocationCoordinate2D, name: String) {
        guard let origin = LocationManager.shared.location?.coordinate else { return }
        let vm = DriveViewModel.shared

        Task {
            await vm.loadRoute(to: coordinate, from: origin)
            guard vm.selectedOption != nil else { return }

            interfaceController?.popToRootTemplate(animated: true, completion: nil)
            vm.startDriving(from: LocationManager.shared.location, location: LocationManager.shared)
            beginNavigationSession(destinationName: name)
        }
    }

    /// Telefonda başlatılmış bir sürüş varsa CarPlay ona KATILIR — yeniden
    /// hesaplamaz. Sürücü telefonda rotayı seçip arabaya bindiğinde, CarPlay
    /// aynı yolculuğu devralmalı.
    private func beginNavigationSession(destinationName: String) {
        let vm = DriveViewModel.shared
        guard let template = mapTemplate,
              let option = vm.selectedOption,
              let originCoord = LocationManager.shared.location?.coordinate
        else { return }

        let origin = RouteEngine.mapItem(for: originCoord)
        let destination = vm.destination ?? RouteEngine.mapItem(for: option.route.polyline.coordinate)

        let choice = CPRouteChoice(
            summaryVariants: [option.durationText + " • " + option.distanceText],
            additionalInformationVariants: [routeSummary(option)],
            selectionSummaryVariants: [destinationName])

        let trip = CPTrip(origin: origin, destination: destination, routeChoices: [choice])
        navigationSession = template.startNavigationSession(for: trip)
        lastManeuverText = nil
        alertedCurveID = nil
        updateNavigationBar(on: template)
    }

    /// Rotanın CarPlay'de gösterilecek tek satırlık özeti — uygulamanın ayırt
    /// edici iki sayısı: en keskin viraj ve toplam maliyet.
    private func routeSummary(_ option: RouteOption) -> String {
        var parts: [String] = []
        if let tightest = option.tightestSafeSpeed {
            parts.append("en keskin viraj \(Int(tightest)) km/s")
        }
        if option.toll.hasAny {
            parts.append("geçiş \(Int(option.toll.total)) ₺")
        }
        return parts.isEmpty ? option.distanceText : parts.joined(separator: " • ")
    }

    private func finishTrip() {
        guard let loc = LocationManager.shared.location else { return }
        DriveViewModel.shared.finish(at: loc, location: LocationManager.shared)
        navigationSession?.finishTrip()
        navigationSession = nil
        if let template = mapTemplate { updateNavigationBar(on: template) }
    }

    // MARK: Sürüş beynini dinle

    private func observeDrivingState() {
        let vm = DriveViewModel.shared

        // Manevra ve kalan mesafe/süre
        vm.$guidance
            .compactMap { $0 }
            .sink { [weak self] g in self?.apply(guidance: g) }
            .store(in: &cancellables)

        // Viraj uyarısı — CarPlay'in kendi uyarı şeridi
        vm.$curveAlert
            .sink { [weak self] alert in self?.apply(curveAlert: alert) }
            .store(in: &cancellables)

        // Telefonda sürüş başlatıldıysa CarPlay de oturumu açsın
        vm.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                guard let self, let template = self.mapTemplate else { return }
                self.updateNavigationBar(on: template)
                if phase == .driving, self.navigationSession == nil {
                    self.beginNavigationSession(
                        destinationName: DriveViewModel.shared.destination?.name ?? "Hedef")
                }
                if phase != .driving, self.navigationSession != nil {
                    self.navigationSession?.finishTrip()
                    self.navigationSession = nil
                }
            }
            .store(in: &cancellables)
    }

    private func apply(guidance g: TurnTracker.Guidance) {
        guard let session = navigationSession else { return }

        let estimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: g.distanceToTurn, unit: UnitLength.meters),
            timeRemaining: g.remainingTime)

        // Manevra metni değişmediyse yalnızca tahminleri tazele; `CPManeuver`
        // nesnesini her fix'te yeniden kurmak şeridi titretir.
        if g.instruction != lastManeuverText {
            lastManeuverText = g.instruction

            let maneuver = CPManeuver()
            maneuver.instructionVariants = [g.instruction]
            maneuver.symbolImage = maneuverSymbol(angle: g.turnAngle)
            maneuver.initialTravelEstimates = estimates
            session.upcomingManeuvers = [maneuver]
        } else if let current = session.upcomingManeuvers.first {
            session.updateEstimates(estimates, for: current)
        }
    }

    /// Dönüş açısına göre ok — telefon arayüzündeki `TurnGlyph` ile aynı eşikler.
    private func maneuverSymbol(angle: Double) -> UIImage? {
        let name: String
        switch angle {
        case ..<(-135): name = "arrow.uturn.left"
        case ..<(-35):  name = "arrow.turn.up.left"
        case ..<(-12):  name = "arrow.up.left"
        case ..<12:     name = "arrow.up"
        case ..<35:     name = "arrow.up.right"
        case ..<135:    name = "arrow.turn.up.right"
        default:        name = "arrow.uturn.right"
        }
        return UIImage(systemName: name)
    }

    private func apply(curveAlert alert: CurveTracker.Alert?) {
        mapController?.highlight(curve: alert?.curve)

        guard let alert, let template = mapTemplate else { return }

        // Yalnızca "hazırlan" ve üstü CarPlay uyarısına dönüşür. `headsUp`
        // bilgilendirmedir; araç ekranında her hafif viraj için uyarı açmak
        // Apple'ın dikkat kurallarına da, uygulamanın kendi "uyarı körlüğü
        // yaratma" ilkesine de aykırı olurdu.
        guard alert.level >= .prepare, alert.isNew, alertedCurveID != alert.curve.id else { return }
        alertedCurveID = alert.curve.id

        let title = alert.level == .critical ? "YAVAŞLA" : "Hızını düşür"
        let subtitle = "\(alert.curve.gradeLabel) viraj • \(Int(alert.curve.safeSpeedKmh)) km/s"

        let carAlert = CPNavigationAlert(
            titleVariants: [title],
            subtitleVariants: [subtitle],
            image: UIImage(systemName: alert.curve.direction.icon),
            primaryAction: CPAlertAction(title: "Tamam", style: .default) { _ in },
            secondaryAction: nil,
            duration: alert.level == .critical ? 6 : 4)

        template.present(navigationAlert: carAlert, animated: true)
    }
}

// MARK: - Harita etkileşimi

extension CarPlaySceneDelegate: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     panWith direction: CPMapTemplate.PanDirection) {
        mapController?.pan(direction)
    }

    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        mapController?.setFollowing(false)
    }
}

// ============================================================================
// MARK: - CarPlay Haritası
// ============================================================================
//
// Telefondaki harita SwiftUI `Map`tir ve `MapCameraPosition` ile sürülür;
// CarPlay penceresinde UIKit gerekir. İkisi AYNI yumuşatılmış konumu okur
// (`NavigationCamera.smoothedCoordinate`), böylece iki ekranda araç işareti
// aynı yerde durur — ham GPS okunsaydı biri zıplar, diğeri akardı.
// ============================================================================

@MainActor
final class CarPlayMapViewController: UIViewController, MKMapViewDelegate {

    private let mapView = MKMapView(frame: .zero)
    private var cancellables = Set<AnyCancellable>()

    private var routeOverlay: MKPolyline?
    private var curveAnnotations: [CurveAnnotation] = []
    /// Kimlikten işarete doğrudan erişim — vurgu değişiminde 150 elemanlı
    /// diziyi taramamak için.
    private var annotationsByCurveID: [UUID: CurveAnnotation] = [:]
    private var following = true
    private var highlightedCurveID: UUID?

    /// Viraj noktası görüntüleri. Keskinlik (5) × vurgu (2) = en fazla 10 ayrı
    /// bitmap var; her işaret için yeniden çizmek aynı 10 görüntüyü yüzlerce
    /// kez üretmek demekti.
    private static var dotImageCache: [String: UIImage] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        // Sürüşte ilgi noktaları gürültüdür; yol geometrisi görünsün.
        mapView.pointOfInterestFilter = .excludingAll
        view.addSubview(mapView)

        bind()
    }

    // MARK: Bağlama

    private func bind() {
        let vm = DriveViewModel.shared

        // Rota değişimi (seçim, yeniden hesaplama)
        Publishers.CombineLatest(vm.$routeOptions, vm.$selectedOptionID)
            .sink { [weak self] _, _ in self?.redrawRoute() }
            .store(in: &cancellables)

        // Araç konumu — yumuşatılmış akış 60 Hz yayın yapar. MKMapView kamerasını
        // o hızda yazmak gereksiz ve pahalı; 10 Hz göz için zaten akıcı.
        vm.camera.$smoothedCoordinate
            .compactMap { $0 }
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] coord in self?.follow(to: coord) }
            .store(in: &cancellables)
    }

    // MARK: Çizim

    private func redrawRoute() {
        if let existing = routeOverlay {
            mapView.removeOverlay(existing)
            routeOverlay = nil
        }
        mapView.removeAnnotations(curveAnnotations)
        curveAnnotations = []
        annotationsByCurveID = [:]
        // Yeni rotanın virajları eskisinden farklı; vurgu kimliği taşınmamalı.
        highlightedCurveID = nil

        guard let option = DriveViewModel.shared.selectedOption else { return }

        mapView.addOverlay(option.route.polyline, level: .aboveRoads)
        routeOverlay = option.route.polyline

        // 500 km'lik rotada yüzlerce viraj var; hepsini işaretlemek haritayı
        // okunmaz kılar. Telefon tarafındaki sınırın aynısı geçerli.
        let curves = Array(option.curves.prefix(150))
        curveAnnotations = curves.map { CurveAnnotation(curve: $0) }
        annotationsByCurveID = Dictionary(uniqueKeysWithValues:
            curveAnnotations.map { ($0.curve.id, $0) })
        mapView.addAnnotations(curveAnnotations)
    }

    /// Uyarı verilen virajı haritada belirginleştir.
    ///
    /// YALNIZCA DURUMU DEĞİŞEN İKİ İŞARET yeniden çizilir: vurgusu kalkan ve
    /// vurgusu gelen. Önceki hâli 150 işaretin HEPSİNİ yeniden çiziyordu —
    /// yani her viraj değişiminde 148 gereksiz bitmap üretiliyordu, sürüş
    /// boyunca birkaç saniyede bir. Görünen bir hata vermez, sadece pil ve
    /// bellek yer; tam da fark edilmeden birikecek türden bir israf.
    func highlight(curve: Curve?) {
        let newID = curve?.id
        guard newID != highlightedCurveID else { return }
        let previousID = highlightedCurveID
        highlightedCurveID = newID

        for id in [previousID, newID].compactMap({ $0 }) {
            guard let annotation = annotationsByCurveID[id],
                  let view = mapView.view(for: annotation) else { continue }
            apply(style: annotation, to: view)
        }
    }

    // MARK: Kamera

    private func follow(to coordinate: CLLocationCoordinate2D) {
        guard following else { return }
        let camera = MKMapCamera(lookingAtCenter: coordinate,
                                 fromDistance: 700,
                                 pitch: 45,
                                 heading: DriveViewModel.shared.camera.smoothedHeading)
        mapView.setCamera(camera, animated: true)
    }

    func recenter() {
        following = true
        if let coord = DriveViewModel.shared.camera.smoothedCoordinate
            ?? LocationManager.shared.location?.coordinate {
            follow(to: coord)
        }
    }

    func setFollowing(_ value: Bool) { following = value }

    func pan(_ direction: CPMapTemplate.PanDirection) {
        following = false
        var center = mapView.centerCoordinate
        let span = mapView.region.span
        let stepLat = span.latitudeDelta * 0.3
        let stepLon = span.longitudeDelta * 0.3

        if direction.contains(.up)    { center.latitude  += stepLat }
        if direction.contains(.down)  { center.latitude  -= stepLat }
        if direction.contains(.left)  { center.longitude -= stepLon }
        if direction.contains(.right) { center.longitude += stepLon }

        mapView.setCenter(center, animated: true)
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.strokeColor = UIColor.systemBlue
        renderer.lineWidth = 8
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let curveAnnotation = annotation as? CurveAnnotation else { return nil }

        let id = "curve"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
            ?? MKAnnotationView(annotation: curveAnnotation, reuseIdentifier: id)
        view.annotation = curveAnnotation
        view.canShowCallout = false
        apply(style: curveAnnotation, to: view)
        return view
    }

    /// Viraj noktasının görünümü. Uyarı verilen viraj büyür ve beyaz halka alır —
    /// "şu an konuşulan viraj bu" bilgisi haritada da olsun.
    private func apply(style annotation: CurveAnnotation, to view: MKAnnotationView) {
        let isHighlighted = annotation.curve.id == highlightedCurveID
        view.image = Self.dotImage(severity: annotation.curve.severity,
                                   highlighted: isHighlighted)
    }

    /// Viraj noktası görüntüsü — önbellekli.
    private static func dotImage(severity: Curve.Severity, highlighted: Bool) -> UIImage {
        let key = "\(severity.rawValue)|\(highlighted)"
        if let cached = dotImageCache[key] { return cached }

        let size: CGFloat = highlighted ? 20 : (severity == .gentle ? 9 : 13)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 1.5, dy: 1.5)
            context.cgContext.setFillColor(severity.carPlayColor.cgColor)
            context.cgContext.fillEllipse(in: rect)
            context.cgContext.setStrokeColor(UIColor.white.cgColor)
            context.cgContext.setLineWidth(highlighted ? 3 : 1.5)
            context.cgContext.strokeEllipse(in: rect)
        }
        dotImageCache[key] = image
        return image
    }
}

// MARK: - Viraj işareti

final class CurveAnnotation: NSObject, MKAnnotation {
    let curve: Curve
    var coordinate: CLLocationCoordinate2D { curve.coordinate }

    init(curve: Curve) {
        self.curve = curve
        super.init()
    }
}

extension Curve.Severity {
    /// UIKit karşılığı. Telefon tarafındaki `uiColor` SwiftUI `Color`ıdır;
    /// ikisi aynı eşleşmeyi kullanır.
    var carPlayColor: UIColor {
        switch self {
        case .gentle:              return .systemGreen
        case .moderate:            return .systemYellow
        case .sharp:               return .systemOrange
        case .verySharp, .hairpin: return .systemRed
        }
    }
}
