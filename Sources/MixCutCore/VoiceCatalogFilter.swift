import Foundation

// ============================================================================
// 音色目录筛选（纯逻辑）—— M1b VoicePickerSheet 的 chips + 搜索唯一判据。
// 视图只收集选中的 Set<VoiceTag> 与搜索串，过滤规则全在此处，可单测、可复用。
// ============================================================================

public enum VoiceCatalogFilter {

    /// 按标签集合 + 搜索串过滤音色目录。
    /// - selectedTags: 空集 = 不按标签过滤；非空 = 音色必须**同时**带齐所选标签
    ///   （交集语义：性别类互斥不会同选，「带货人设」可与任一性别叠加）。
    /// - query: trim 后为空 = 不过滤；否则对 id / displayName / summary 做
    ///   大小写不敏感的子串匹配（命中任一字段即保留；顺序按原目录，不重排）。
    public static func filter(_ voices: [TTSVoice],
                              selectedTags: Set<VoiceTag>,
                              query: String) -> [TTSVoice] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return voices.filter { voice in
            if !selectedTags.isEmpty && !voice.tags.isSuperset(of: selectedTags) {
                return false
            }
            if keyword.isEmpty { return true }
            return voice.id.lowercased().contains(keyword)
                || voice.displayName.lowercased().contains(keyword)
                || voice.summary.lowercased().contains(keyword)
        }
    }

    /// 目录中每条音色是否恰好带一个性别类标签（female/male/child/character）。
    /// 供单测对进选择器的目录全量强制——漏标（筛不到）与多选（chips 交集失效）都不行。
    public static func hasExactlyOneGenderTag(_ voice: TTSVoice) -> Bool {
        voice.tags.intersection(VoiceTag.genderTags).count == 1
    }
}
