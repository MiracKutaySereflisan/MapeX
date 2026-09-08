import SwiftUI

// ============================================================================
// MARK: - Erişilebilirlik
// ============================================================================
//
// HEDEF KİTLE GERÇEĞİ
// -------------------
// Bu uygulamanın asıl kullanıcısı, teknolojiye hâkim ama YAŞLI bir sürücü.
// Bu iki şey birlikte özel bir tasarım kısıtı yaratır: kişi arayüzü anlar,
// ama gözü küçük puntoyu, eli küçük hedefi, güneş altındaki düşük kontrastı
// affetmez. Ve araçta, titreşim altında kullanılır.
//
// Bu dosya üç somut sorunu çözüyor:
//
//   ① SAYISAL KLAVYE KAPANMIYORDU
//      `.decimalPad` ve `.numberPad` klavyelerinde return tuşu YOKTUR. Araç
//      bilgisi formundaki her sayı alanı bir kez dokunulduğunda klavye ekranı
//      kaplıyor ve KAPANMIYORDU. Kullanıcı formun geri kalanını göremiyor,
//      "çalışmıyor" sanıyordu. Artık her sayısal alanın üstünde "Bitti" var.
//
//   ② SABİT PUNTOLAR DYNAMIC TYPE'I YOK SAYIYORDU
//      `.font(.system(size: 9))` gibi sabit boyutlar, kullanıcı iOS'ta yazıyı
//      büyüttüğünde BÜYÜMEZ. Yaşlı kullanıcı sistem genelinde yazıyı
//      büyütmüştür — uygulamamız bunu görmezden geliyordu. `.scaledFont`
//      sabit puntoyu Dynamic Type'a bağlar.
//
//   ③ GÜNEŞ ALTINDA OKUNMUYORDU
//      Cam efekti (glass) üzerine `.secondary`/`.tertiary` metin, açık havada
//      araç içinde okunmaz. "Yüksek kontrast" seçeneği ikincil renkleri tam
//      opaklığa çeker ve cam efektini opak zemine düşürür.
// ============================================================================

// MARK: - Görünüm tercihleri

@MainActor
final class DisplayPreferences: ObservableObject {
    static let shared = DisplayPreferences()

    /// Yüksek kontrast: ikincil metinler koyulaşır, cam zeminler opaklaşır.
    @Published var highContrast: Bool = UserDefaults.standard.bool(forKey: "highContrast") {
        didSet { UserDefaults.standard.set(highContrast, forKey: "highContrast") }
    }

    /// Sürüş ekranında büyük rakam modu — hız ve mesafe belirgin büyür.
    @Published var largeDrivingText: Bool = UserDefaults.standard.object(forKey: "largeDrivingText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(largeDrivingText, forKey: "largeDrivingText") }
    }

    /// Ekranı sürüş boyunca açık tut.
    @Published var keepScreenOn: Bool = UserDefaults.standard.object(forKey: "keepScreenOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn") }
    }

    /// Sürüş ekranında sonraki virajları gösteren şerit.
    ///
    /// Varsayılan AÇIK — uygulamanın ayırt edici özelliği bu. Ama ekranı
    /// kalabalık bulan sürücü kapatabilmeli: sesli uyarı ve gösterge rengi
    /// zaten şeritten bağımsız çalışır, kapatmak hiçbir uyarıyı susturmaz.
    @Published var showCurvePreview: Bool = UserDefaults.standard.object(forKey: "showCurvePreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCurvePreview, forKey: "showCurvePreview") }
    }

    private init() {}

    /// İkincil metin rengi — yüksek kontrastta okunurluk için koyulaşır.
    var secondaryText: Color { highContrast ? .primary.opacity(0.85) : .secondary }
    var tertiaryText: Color { highContrast ? .primary.opacity(0.70) : Color.secondary.opacity(0.7) }

    /// Sürüş ekranındaki ana rakamların punto çarpanı.
    var drivingScale: CGFloat { largeDrivingText ? 1.18 : 1.0 }
}

// MARK: - Ölçeklenen sabit punto

extension View {
    /// Sabit puntoyu Dynamic Type'a bağlar.
    ///
    /// `.font(.system(size: 9))` kullanıcının yazı boyutu ayarını yok sayar.
    /// Bu değiştirici, verilen puntoyu bir metin stiline göre ölçekler; küçük
    /// bilgi etiketleri de kullanıcı yazıyı büyüttüğünde büyür.
    func scaledFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .footnote,
                    minimum: CGFloat = 11) -> some View {
        modifier(ScaledFont(size: max(size, minimum), weight: weight,
                            design: design, style: style))
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaled, weight: weight, design: design))
    }
}

// MARK: - Sürüş ekranı rakamları

extension View {
    /// Sürüş ekranındaki ANA rakamlar için punto (hız, sapak mesafesi, viraj
    /// mesafesi).
    ///
    /// DÜZELTİLEN HATA — AYARLAR EKRANI SÖZ VERİP TUTMUYORDU
    /// -----------------------------------------------------
    /// Ayarlar'daki "Sürüşte büyük rakamlar" anahtarı ve iOS'un metin boyutu
    /// ayarı, sürüş ekranında HİÇBİR ŞEY yapmıyordu: hız 40 pt, sapak mesafesi
    /// 30 pt, viraj mesafesi 22 pt sabit `.system(size:)` idi. `drivingScale`
    /// tanımlıydı ama uygulamada tek bir tüketicisi yoktu.
    ///
    /// Yani erişilebilirlik ayarları tam da en çok gerektikleri ekranda —
    /// araçta, titreşim altında, tek bakışta okunması gereken yerde — etkisizdi.
    ///
    /// Bu değiştirici ikisini birden uygular: önce Dynamic Type ölçeği
    /// (`@ScaledMetric`), sonra kullanıcının büyük rakam çarpanı.
    func drivingNumber(size: CGFloat,
                       weight: Font.Weight = .black,
                       design: Font.Design = .rounded,
                       relativeTo style: Font.TextStyle = .title) -> some View {
        modifier(DrivingNumberFont(size: size, weight: weight, design: design, style: style))
    }

    /// Cam zemin — yüksek kontrast açıkken opak zemine düşer.
    ///
    /// `.glassEffect` altındaki haritayı geçirir. Güneş altında, hareketli bir
    /// harita üzerinde duran yazı okunmaz hâle gelir. "Yüksek kontrast" açıkken
    /// zemin opaklaşır ve kenarına belirgin bir çerçeve gelir.
    func adaptiveGlass(in shape: some Shape) -> some View {
        modifier(AdaptiveGlass(shape: shape))
    }
}

private struct DrivingNumberFont: ViewModifier {
    @ObservedObject private var display = DisplayPreferences.shared
    @ScaledMetric private var base: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle) {
        _base = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: base * display.drivingScale, weight: weight, design: design))
    }
}

private struct AdaptiveGlass<S: Shape>: ViewModifier {
    @ObservedObject private var display = DisplayPreferences.shared
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if display.highContrast {
            content
                .background(.background, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.30), lineWidth: 1.5))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - Klavye kapatma

/// Sayısal klavyelere "Bitti" çubuğu ekler.
///
/// `.decimalPad` / `.numberPad` klavyelerinde return tuşu bulunmadığı için,
/// bu olmadan kullanıcı klavyeyi kapatamaz. Formun geri kalanı klavyenin
/// altında kalır ve ekran kilitlenmiş gibi hissettirir.
struct NumericKeyboardToolbar: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Bitti") { focused = false }
                        .font(.body.bold())
                }
            }
    }
}

extension View {
    func dismissableNumericKeyboard() -> some View {
        modifier(NumericKeyboardToolbar())
    }

    /// Ekranın herhangi bir yerine dokununca klavyeyi kapatır.
    /// "Bitti" tuşunu bulamayan kullanıcı için ikinci bir çıkış yolu.
    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil)
        }
    }
}

// MARK: - Büyük sayı alanı

/// Yaşlı kullanıcı için tasarlanmış sayı giriş satırı.
///
/// • 52 punto yükseklik (44 punto masaüstü tabanı araçta yetmez)
/// • Birim etiketi alanın İÇİNDE — "8.5 ne?" sorusu kalmasın
/// • Klavye kapatılabilir
/// • Boş bırakılırsa varsayılan gösterilir, sıfır yazılmaz
struct BigNumberField: View {
    let label: String
    let unit: String
    let placeholder: String
    @Binding var value: Double
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.body)
                Spacer()
                HStack(spacing: 4) {
                    TextField(placeholder, value: $value,
                              format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.title3.monospacedDigit())
                        .frame(width: 100)
                        .dismissableNumericKeyboard()
                    Text(unit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 54, alignment: .leading)
                }
            }
            .frame(minHeight: 52)

            if let help {
                Text(help)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
