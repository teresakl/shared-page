import SwiftUI
import UIKit

// ============================================================
// EmojiSticker.swift — 直接贴一个 emoji。
//
// 不烤、不落盘、不进抽屉：emoji 本身就是现成图形，存一个字符串就够了。
// 但摆放这件事要跟贴纸完全一样，所以这里把它渲染成一张高分位图，
// 交给 PlacedArt 走同一条渲染/拖动/缩放的路 —— 直接拿 Text 画的话，
// scaleEffect 放大 3 倍会糊（那是位图变换，不会按新字号重排）。
// ============================================================

enum EmojiRenderer {
    /// 画布够大，缩放到上限 3 倍仍然清楚
    static let canvas: CGFloat = 240

    private static var cache: [String: UIImage] = [:]

    static func image(_ emoji: String) -> UIImage? {
        let key = emoji
        if let hit = cache[key] { return hit }
        guard !emoji.isEmpty else { return nil }

        let font = UIFont.systemFont(ofSize: canvas * 0.82)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let text = emoji as NSString
        let measured = text.size(withAttributes: attrs)
        guard measured.width > 0, measured.height > 0 else { return nil }

        // 摆成正方形，缩放和旋转的锚点才在图形正中
        let side = max(measured.width, measured.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                          format: format).image { _ in
            text.draw(at: CGPoint(x: (side - measured.width) / 2,
                                  y: (side - measured.height) / 2),
                      withAttributes: attrs)
        }
        cache[key] = img
        return img
    }
}

// —— 拉起系统 emoji 键盘 ————————————————————————
// iOS 没有「只给我 emoji 键盘」的公开开关，但可以在 textInputMode 里
// 指定 primaryLanguage == "emoji" 的那个输入模式，系统就会直接弹 emoji 面板。
// 输入框本身是透明的零尺寸，只是个拿焦点的壳子。
final class EmojiOnlyTextField: UITextField {
    override var textInputContextIdentifier: String? { "" }
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
    }
}

struct EmojiCatcher: UIViewRepresentable {
    @Binding var active: Bool
    /// 选中一个就立刻交出去并收键盘，不用二次确认
    var onPick: (String) -> Void

    func makeUIView(context: Context) -> EmojiOnlyTextField {
        let tf = EmojiOnlyTextField()
        tf.delegate = context.coordinator
        tf.tintColor = .clear
        tf.textColor = .clear
        tf.backgroundColor = .clear
        tf.autocorrectionType = .no
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ tf: EmojiOnlyTextField, context: Context) {
        if active, !tf.isFirstResponder {
            DispatchQueue.main.async { tf.becomeFirstResponder() }
        } else if !active, tf.isFirstResponder {
            DispatchQueue.main.async { tf.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let parent: EmojiCatcher
        init(_ parent: EmojiCatcher) { self.parent = parent }

        @objc func changed(_ tf: UITextField) {
            guard let raw = tf.text, !raw.isEmpty else { return }
            // 手快打了好几个也只取第一个字素簇（一个 emoji 可能由多个 scalar 拼成）
            let one = String(raw.prefix(1))
            tf.text = ""
            // 当场交出焦点，不绕 SwiftUI 状态回环——绕一圈键盘常常还赖在屏幕下半截，
            // 挡住刚贴上去的那个 emoji，长按按到的是键盘不是贴纸
            tf.resignFirstResponder()
            parent.active = false
            parent.onPick(one)
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            parent.active = false
        }
    }
}
