import Foundation

// ============================================================================
// 概览投影剪枝 —— 纯值判据，不碰 SwiftData
//
// 为什么这颗必须住在 Core：`.video` 剪枝的输入是「概览投影已经取好的值行」，
// 输出是「剩下的 videoCount / segmentCount」。这半件事没有任何 UI 依赖，
// 却决定两张 StatCard 与卡片列表是否还自洽；写进 VM 就只能靠起容器测，
// 写在这里 `swift test` 直接证（计划 2026-10-23 笔 V2/V-4）。
//
// 口径（与 `ProjectViewModel.refreshOverviewSnapshot` 逐字对齐）：
//   · `videoCount` 只数**进概览卡片**的视频（自建分镜视频不进卡片）；
//   · `segmentCount` 数**全量视频**的可显示分镜（含自建分镜视频），
//     因为概览那张「分镜」卡本来就把它算进去，剪枝不许顺手改语义。
//   · `visibleSegmentCount` 是 `Video.displayableSegmentCount`（决议 K9 的唯一出口），
//     不是 `segments.count` —— 混剪补建的内部整片段不计入用户可见分镜。
// ============================================================================

public enum OverviewProjectionPrune {

    /// 一颗视频在概览侧的两颗数：卡片要不要它、它贡献多少可显示分镜。
    public struct VideoCount: Equatable, Sendable {
        public let id: UUID
        public let visibleSegmentCount: Int
        public let showsAsCard: Bool

        public init(id: UUID, visibleSegmentCount: Int, showsAsCard: Bool) {
            self.id = id
            self.visibleSegmentCount = visibleSegmentCount
            self.showsAsCard = showsAsCard
        }
    }

    /// 摘掉指定视频后剩下的两颗计数。
    public struct Counts: Equatable, Sendable {
        public let videoCount: Int
        public let segmentCount: Int

        public init(videoCount: Int, segmentCount: Int) {
            self.videoCount = videoCount
            self.segmentCount = segmentCount
        }
    }

    /// 纯剪 + 重算：只做减法和求和，不做 fetch、不做去重、不改入参。
    ///
    /// ⚠️ 调用方最容易写错的一格：只剪 `rows` 不重算 `segmentCount`。
    /// 概览上方两张卡与下方卡片列表就会各说一套数 —— 本函数存在的唯一理由就是让这两颗数
    /// 从**同一份剩余值行**里出，而不是从"刚剪完的列表长度"和"剪之前的旧总数"里各取一半。
    public static func counts(removing ids: Set<UUID>, from videos: [VideoCount]) -> Counts {
        var videoCount = 0
        var segmentCount = 0
        for video in videos where !ids.contains(video.id) {
            segmentCount += video.visibleSegmentCount
            if video.showsAsCard { videoCount += 1 }
        }
        return Counts(videoCount: videoCount, segmentCount: segmentCount)
    }
}
