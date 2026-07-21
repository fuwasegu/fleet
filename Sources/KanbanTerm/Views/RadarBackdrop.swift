import SwiftUI

/// 盤面の背景に敷く、ごく薄いレーダースコープ。アイコン(レーダー)と世界観を繋ぐ。
/// 同心円 + 十字 + かすかなスイープ。低コントラストで主張しすぎない。
struct RadarBackdrop: View {
    private let green = Color(hex: "7FD962")!

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.44)
            let maxR = min(geo.size.width, geo.size.height) * 0.85

            ZStack {
                // 同心円(4本)
                ForEach(1..<5) { i in
                    let d = maxR * CGFloat(i) / 4 * 2
                    Circle()
                        .stroke(green.opacity(0.05), lineWidth: 1)
                        .frame(width: d, height: d)
                        .position(center)
                }
                // 十字ヘアライン
                Path { p in
                    p.move(to: CGPoint(x: center.x - maxR, y: center.y))
                    p.addLine(to: CGPoint(x: center.x + maxR, y: center.y))
                    p.move(to: CGPoint(x: center.x, y: center.y - maxR))
                    p.addLine(to: CGPoint(x: center.x, y: center.y + maxR))
                }
                .stroke(.white.opacity(0.028), lineWidth: 1)

                // かすかなスイープ(静的なくさび形グラデーション)
                AngularGradient(
                    gradient: Gradient(colors: [green.opacity(0.06), .clear, .clear, .clear]),
                    center: .center,
                    angle: .degrees(-35)
                )
                .frame(width: maxR * 2, height: maxR * 2)
                .clipShape(Circle())
                .position(center)
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}
