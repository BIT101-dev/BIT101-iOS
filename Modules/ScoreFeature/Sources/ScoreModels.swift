/// 此枚举表示成绩页加载状态。
///
/// 成绩页根视图根据此枚举区分空闲、加载、已加载和失败状态。
nonisolated enum ScoreLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}
