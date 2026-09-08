import ActivityKit
import WidgetKit
import SwiftUI

// ============================================================================
// MARK: - Dinamik Ada: Navigasyon Canlı Aktivitesi
// ============================================================================
//
// DONANIM FARKINDALIĞI
// --------------------
// Dinamik Ada tek bir dikdörtgen değil; ortada fiziksel sensör kesiti olan
// İKİ AYRI ada bölgesidir. Bu yüzden sol ve sağ bölgeye konan bilgi
// birbirinden bağımsız okunabilmeli — bir cümlenin ikiye bölünmüş hâli
// olmamalı.
//
//   ┌────────────┐   ●●   ┌────────────┐
//   │ compact    │ sensör │  compact   │
//   │ LEADING    │        │  TRAILING  │
//   │ ↰ Sol 2    │        │  68 ◯      │
//   └────────────┘        └────────────┘
//     NE geliyor            NEREDEYİM
//     (yön + derece)        (hız + risk halkası)
//
// Bölünme mantığı: SOL "yol bana ne yapacak", SAĞ "ben ne yapıyorum".
// Sürücü hangi tarafa bakarsa baksın tek başına anlamlı bir bilgi alır.
//
// RALLİ DERECESİ
// --------------
// "Sol 2" gösterimi, "Çok Keskin Sol Viraj"ın sığmadığı yere sığar ve birkaç
// yolculukta öğrenilir: 1 en dar, 6 neredeyse düz.
//
// GÜNCELLEME BÜTÇESİ
// ------------------
// ActivityKit sık güncellemeyi cezalandırdığı için uygulama tarafında
// saniyede bir ve yalnızca değişiklik varsa gönderim yapılır; mesafeler
// 10 m'ye yuvarlanır. `staleDate` +12 sn — akış kesilirse sistem içeriği
// soluklaştırır, sürücü bayat mesafeyi güncel sanmaz.
// ============================================================================

struct NavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state

            return DynamicIsland {
                // ── GENİŞLETİLMİŞ ────────────────────────────────────────────
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let d = state.curveDistance, state.curveWarning > 0 {
                            Text("\(formatMeters(d)) sonra")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                Image(systemName: state.curveIsLeft == true
                                      ? "arrow.turn.up.left" : "arrow.turn.up.right")
                                    .font(.system(size: 15, weight: .black))
                                Text(gradeLabel(state))
                                    .font(.system(size: 16, weight: .black, design: .rounded))
                            }
                            .foregroundStyle(riskColor(state.riskLevel))
                            Text(gradeDescription(state.curveGrade))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            TurnArrow(angle: state.turnAngle)
                                .frame(width: 30, height: 30)
                            Text(formatMeters(state.distanceToTurn))
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    // Mevcut vs hedef hız karşılaştırması
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(state.speedKmh)")
                                .font(.system(size: 24, weight: .black, design: .rounded))
                                .foregroundStyle(riskColor(state.riskLevel))
                                .contentTransition(.numericText())
                            Text("km/s").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        if let target = state.suggestedSpeed {
                            Text("hedef \(target)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(state.speedKmh > target ? .orange : .green)
                        } else {
                            Text("\(state.remainingMinutes) dk")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Text(state.instruction)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                            Text("\(state.remainingMinutes) dk")
                            Text("•").foregroundStyle(.tertiary)
                            Text(context.attributes.destinationName).lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    // Risk aurası — kritikte kart kenarı kızarır
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(riskColor(state.riskLevel).opacity(state.riskLevel >= 2 ? 0.14 : 0))
                    )
                }

            } compactLeading: {
                // ── KAPALI ADA · SOL: ne geliyor ─────────────────────────────
                if state.curveWarning > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: state.curveIsLeft == true
                              ? "arrow.turn.up.left" : "arrow.turn.up.right")
                            .font(.system(size: 12, weight: .black))
                        Text("\(state.curveGrade ?? 0)")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                    }
                    .foregroundStyle(riskColor(state.riskLevel))
                } else {
                    TurnArrow(angle: state.turnAngle)
                        .frame(width: 18, height: 18)
                }

            } compactTrailing: {
                // ── KAPALI ADA · SAĞ: neredeyim ─────────────────────────────
                SpeedRing(speed: state.speedKmh, risk: state.riskLevel)

            } minimal: {
                // ── MİNİMAL (iki uygulama aktif) ────────────────────────────
                // Tek bir sembol sığar: risk rengiyle boyanmış viraj ikonu.
                ZStack {
                    Circle()
                        .stroke(riskColor(state.riskLevel), lineWidth: 2)
                    Image(systemName: state.curveWarning > 0
                          ? (state.curveIsLeft == true ? "arrow.turn.up.left" : "arrow.turn.up.right")
                          : "location.north.fill")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(riskColor(state.riskLevel))
                }
            }
        }
    }

    // ========================================================================
    // MARK: Kilit ekranı
    // ========================================================================

    @ViewBuilder
    private func lockScreenView(_ context: ActivityViewContext<NavActivityAttributes>) -> some View {
        let state = context.state
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                SpeedRing(speed: state.speedKmh, risk: state.riskLevel, large: true)

                VStack(alignment: .leading, spacing: 3) {
                    if state.curveWarning > 0, let d = state.curveDistance {
                        HStack(spacing: 5) {
                            Image(systemName: state.curveIsLeft == true
                                  ? "arrow.turn.up.left" : "arrow.turn.up.right")
                                .font(.system(size: 12, weight: .black))
                            Text("\(formatMeters(d)) · \(gradeLabel(state))")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            if let t = state.suggestedSpeed {
                                Text("→ \(t)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                        }
                        .foregroundStyle(riskColor(state.riskLevel))
                    }
                    Text(state.instruction)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(state.remainingMinutes) dk • \(context.attributes.destinationName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(spacing: 2) {
                    TurnArrow(angle: state.turnAngle)
                        .frame(width: 34, height: 34)
                    Text(formatMeters(state.distanceToTurn))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                }
            }
        }
        .padding(14)
        .background(
            riskColor(state.riskLevel)
                .opacity(state.riskLevel >= 3 ? 0.16 : 0)
        )
    }

    // ========================================================================
    // MARK: Yardımcılar
    // ========================================================================

    private func gradeLabel(_ s: NavActivityAttributes.ContentState) -> String {
        let side = s.curveIsLeft == true ? "Sol" : "Sağ"
        return "\(side) \(s.curveGrade ?? 0)"
    }

    private func gradeDescription(_ grade: Int?) -> String {
        switch grade ?? 6 {
        case 1: return "firketa"
        case 2: return "çok keskin"
        case 3: return "keskin"
        case 4: return "orta"
        case 5: return "hafif"
        default: return "geniş"
        }
    }

    private func formatMeters(_ m: Int) -> String {
        m >= 1000 ? String(format: "%.1f km", Double(m) / 1000) : "\(m) m"
    }

    private func riskColor(_ level: Int) -> Color {
        switch level {
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        // 4 = sınır aşıldı. `default` dalına düşseydi EN KÖTÜ durum beyaz
        // görünürdü — göstergenin sessizleştiği tek yer, en çok bağırması
        // gereken yer olurdu.
        case 4: return Color(red: 0.62, green: 0.11, blue: 0.78)
        default: return .white
        }
    }
}

// ============================================================================
// MARK: - Hız Halkası
// ============================================================================
//
// Hızı, risk rengiyle boyanmış dairesel bir halkanın içinde gösterir. Rakamı
// okumadan bile rengin kendisi bilgi taşır — sürüşte tam olarak istenen şey.
// ============================================================================

struct SpeedRing: View {
    let speed: Int
    let risk: Int
    var large: Bool = false

    private var color: Color {
        switch risk {
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        default: return .white
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.28), lineWidth: large ? 5 : 2.5)
            Circle()
                .stroke(color, lineWidth: large ? 3.5 : 2)
                .opacity(risk >= 3 ? 1 : 0.85)
            Text("\(speed)")
                .font(.system(size: large ? 22 : 13, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .padding(large ? 6 : 2)
        }
        .frame(width: large ? 62 : 26, height: large ? 62 : 26)
    }
}

// ============================================================================
// MARK: - Keskinliğe Göre Kıvrılan Ok
// ============================================================================
// angle: dönüş açısı derece cinsinden. + sağ, − sol.
// 0° → dümdüz ok; açı büyüdükçe gövde o yöne doğru kavis alır,
// 150°+ → neredeyse U dönüşü gibi kıvrılır.

struct TurnArrow: View {
    let angle: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let clamped = max(-160.0, min(160.0, angle))
            let toRight = clamped >= 0
            let mag = abs(clamped)
            let bend = mag / 160.0

            let start = CGPoint(x: w * 0.5, y: h * 0.92)
            let midY = h * (0.55 - 0.10 * bend)
            let endX = w * (0.5 + (toRight ? 1 : -1) * 0.38 * bend)
            let endY = h * (0.30 - 0.12 * bend) + h * 0.30 * bend * bend
            let end = CGPoint(x: endX, y: max(h * 0.12, endY))

            let c1 = CGPoint(x: w * 0.5, y: midY)
            let c2 = CGPoint(x: w * (0.5 + (toRight ? 1 : -1) * 0.42 * bend), y: midY)

            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)

            let stroke = StrokeStyle(lineWidth: max(2.5, w * 0.13), lineCap: .round, lineJoin: .round)
            ctx.stroke(path, with: .color(.cyan), style: stroke)

            let tangentAngle: Double
            if bend < 0.05 {
                tangentAngle = -90 * .pi / 180
            } else {
                let dx = end.x - c2.x, dy = end.y - c2.y
                tangentAngle = atan2(dy, dx)
            }
            let headLen = w * 0.26
            let spread = 28.0 * .pi / 180
            let tip = end
            let l = CGPoint(x: tip.x - headLen * cos(tangentAngle - spread),
                            y: tip.y - headLen * sin(tangentAngle - spread))
            let r = CGPoint(x: tip.x - headLen * cos(tangentAngle + spread),
                            y: tip.y - headLen * sin(tangentAngle + spread))
            var head = Path()
            head.move(to: l)
            head.addLine(to: tip)
            head.addLine(to: r)
            ctx.stroke(head, with: .color(.cyan), style: stroke)
        }
    }
}
