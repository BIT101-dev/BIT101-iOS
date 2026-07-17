import SwiftUI

/// 为 segmented 内容区提供一致的横向轻扫判定。
func makeHorizontalSwitchGesture(onStep: @escaping (Int) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 24, coordinateSpace: .local)
        .onEnded { value in
            let horizontal = value.translation.width
            let vertical = value.translation.height

            guard abs(horizontal) > abs(vertical), abs(horizontal) >= 56 else { return }
            onStep(horizontal < 0 ? 1 : -1)
        }
}
