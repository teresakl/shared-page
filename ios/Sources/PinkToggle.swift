import SwiftUI

// ============================================================
// PinkToggle.swift — 从 我另一个 app 的设置组件.SettingsToggle 移植。
// 原件是自己做的「复刻 iOS 26」开关：平时实心白 knob；按住化成会折射
// 背景、带彩虹色散边的液态玻璃，能拖着滑、松手 snap。
// 这里只剥掉 我另一个 app 的 Theme/Palette 依赖，尺寸、手势、弹簧参数一字未改；
// 轨道色取 我另一个 app 草莓可可主题那档粉 #CF98A4。
// ============================================================

struct PinkToggle: View {
    @Binding var on: Bool
    @State private var pressing = false
    @State private var dragProgress: CGFloat? = nil

    private let trackW: CGFloat = 46
    private let trackH: CGFloat = 20
    private let knobD: CGFloat = 22
    private let onColor  = Color(hex: 0xCF98A4)
    private let offColor = Color(hex: 0xDCD3D5)

    var body: some View {
        let travel = trackW - knobD
        let progress = dragProgress ?? (on ? 1 : 0)
        Capsule()
            .fill(on ? onColor : offColor)
            .frame(width: trackW, height: pressing ? 18 : trackH)
            .overlay(alignment: .leading) {
                knobView
                    .frame(width: pressing ? 44 : knobD, height: pressing ? 34 : knobD)
                    .offset(x: pressing ? (progress * travel - 11) : (progress * travel))
                    .animation(dragProgress != nil
                        ? .interactiveSpring(response: 0.24, dampingFraction: 0.42)
                        : .spring(response: 0.3, dampingFraction: 0.78), value: progress)
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    pressing = true
                    on.toggle()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { pressing = false }
                }
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.22)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        if case .second(true, let drag) = value {
                            if !pressing {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pressing = true }
                            }
                            if let drag {
                                dragProgress = min(max((drag.location.x - knobD / 2) / travel, 0), 1)
                            }
                        }
                    }
                    .onEnded { value in
                        if case .second(_, let drag) = value, let drag {
                            let p = min(max((drag.location.x - knobD / 2) / travel, 0), 1)
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
                                on = p > 0.5
                                dragProgress = nil
                                pressing = false
                            }
                        } else {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.66)) {
                                dragProgress = nil
                                pressing = false
                            }
                        }
                    }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: on)
    }

    // 实心白 ↔ 玻璃两层常驻，靠 pressing 控透明度淡入淡出；形状统一 Capsule（22×22 即圆）
    @ViewBuilder private var knobView: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color.white, Color(hex: 0xF6EFF0)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Capsule()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.0)],
                                             startPoint: .top, endPoint: .center))
                        .padding(0.5)
                        .blur(radius: 0.5)
                )
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                .shadow(color: Color(hex: 0x30292B, alpha: 0.13), radius: 3.5, x: 0, y: 1.5)
                .opacity(pressing ? 0 : 1)
            glassKnob
                .opacity(pressing ? 1 : 0)
        }
    }

    // iOS 26 同款：横向拉长的透明胶囊玻璃，透出底下 track 的颜色 + 一圈彩虹色散边 + 白高光
    private var glassKnob: some View {
        ZStack {
            Capsule()
                .fill(Color.clear)
                .glassEffect(.clear.interactive(), in: Capsule())
            Capsule()
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: Color(hex: 0xFF6B6B, alpha: 0.6),  location: 0.00),
                            .init(color: Color(hex: 0xFFD86E, alpha: 0.45), location: 0.18),
                            .init(color: Color(hex: 0x7EE787, alpha: 0.45), location: 0.38),
                            .init(color: Color(hex: 0x5EC8FF, alpha: 0.65), location: 0.58),
                            .init(color: Color(hex: 0xB58CFF, alpha: 0.65), location: 0.80),
                            .init(color: Color(hex: 0xFF6B6B, alpha: 0.6),  location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(-30)
                    ),
                    lineWidth: 1.1
                )
                .blur(radius: 0.5)
            Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.7)
        }
    }
}
