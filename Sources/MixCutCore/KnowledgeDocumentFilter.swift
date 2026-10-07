import Foundation

/// 知识库文档的检索准入过滤（纯值、纯函数，零 SwiftData 依赖）。
///
/// 存在原因：脚本写作检索原本用 #Predicate
/// `chunk.document?.product?.id == productID && chunk.document?.isEnabled`，
/// 跨两层 to-one 可选链且重复起链，CoreData SQL 生成器无法翻译，
/// 在生成 SELECT 阶段抛 Objective-C 异常——Swift 的 try?/catch 无法捕获，进程 abort。
/// 改为：无 #Predicate 全量 fetch，经解边索引得到本结构后在 Swift 侧过滤。
public enum KnowledgeDocumentFilter {

    /// 一份文档的过滤输入（解边后的纯值）。
    public struct Input: Equatable, Sendable {
        public let id: UUID
        public let isEnabled: Bool
        /// 文档所属产品 id；nil = product 边悬空（目标行已不在 store）。
        public let productID: UUID?

        public init(id: UUID, isEnabled: Bool, productID: UUID?) {
            self.id = id
            self.isEnabled = isEnabled
            self.productID = productID
        }
    }

    /// 筛出「属于目标产品且启用」的文档 id 集合。
    ///
    /// 口径与原 SQL 谓词一致；以下三类一律排除：
    /// - 禁用文档（isEnabled == false）；
    /// - 跨产品文档（productID 为其他产品）；
    /// - product 边悬空（productID == nil）。
    public static func enabledIDs(
        _ inputs: [Input],
        targetProductID: UUID
    ) -> Set<UUID> {
        var out = Set<UUID>()
        for input in inputs {
            guard input.isEnabled, input.productID == targetProductID else { continue }
            out.insert(input.id)
        }
        return out
    }
}
