import SwiftUI

/// 播放设备状态协调器：保证同一个列表里同一时刻只有一个播放器在响。
///
/// ## 身份边界（与 SegmentLibraryViewModel.playingSegmentID 的区别）
/// 两者的真实区别是**生命周期/归属层**不同，不是抽象粒度不同：
/// - 本类型绑定**导入页**：`InlineVideoPlayer` 的消费者是导入视频——该阶段视频
///   尚不是分镜，没有也不应有分镜 VM 归属。
/// - `SegmentLibraryViewModel.playingSegmentID` 绑定**分镜 VM**：驱动分镜播放器互斥
///   与 onChange 抢占、frozen 定格时保留，并由 ContentView 级单实例跨
///   「素材库 ↔ 混剪方案」共享。
/// - 不合并的真实理由：若让导入页复用分镜 VM 的播放状态，会迫使导入流程跨层依赖
///   分镜 VM（设备态与领域态生命周期不同），耦合更高。因此两者各归其位，不是重复抽象。
@Observable
@MainActor
final class PlaybackCoordinator {
    /// 当前唯一允许播放的播放器身份；nil = 无播放。
    private(set) var activePlaybackID: String?

    /// 请求成为唯一播放器（会抢占其它播放器）。
    func activate(_ id: String) {
        activePlaybackID = id
    }

    /// 释放播放占位（仅当占位属于自己时生效）。
    /// 用于：视频自然播完、视图销毁等——不影响画面定格等表现，只释放「唯一播放」身份。
    func deactivate(_ id: String) {
        if activePlaybackID == id {
            activePlaybackID = nil
        }
    }
}
