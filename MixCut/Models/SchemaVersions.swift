import SwiftData

// ============================================================================
// SwiftData schema 版本化（批 0）
//
// 采纳前：本工程用 `Schema([...10 个模型...])` 裸装配，没有任何版本锚点。schema 不兼容时
// SwiftData 的行为是**静默重建空库**，唯一的兜底是 `MixCutApp.recoverFromDisk()` —— 它只能从磁盘
// 上的视频文件反推项目与分镜结构，台词、混剪方案、配音变体一律拿不回来。
//
// 采纳后：模型集合有了名字与版本号，`SchemaGuard` 能在**开库之前**算出指纹并决定是否留备份，
// 后续真正的 schema 变更也有了声明迁移的地方，而不是靠"这次改动能不能被轻量迁移吃掉"的运气。
// ============================================================================

/// 当前线上形态的快照。**V1 就是"采纳版本化这一刻的 10 个模型"，此后不得就地修改它。**
///
/// 类型名刻意不含品牌字样：`BrandIdentityTests` 会扫 `MixCut/`、`Sources/`、`Tests/` 全部非注释行，
/// 命中 `Brand.displayName`/`Brand.shortName` 即判违规。身份只能住在 `Brand.swift`。
enum AppSchemaV1: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// 顺序无意义（`SchemaGuard` 的指纹按字典序归一化），但**必须与 `MixCutApp` 的模型清单同集合**。
    /// 漏注册一个模型不会编译报错 —— 它只会从 `Schema.entities` 里消失，进而让那张表在开库时被判成
    /// "schema 变了"。所以这条一致性由 `SchemaGuard` 的 0 行/不可信判定 + 批 0 的隔离实测兜住。
    static var models: [any PersistentModel.Type] {
        [
            Project.self,
            Video.self,
            Segment.self,
            MixStrategy.self,
            MixScheme.self,
            SchemeSegment.self,
            ProjectVideo.self,
            SegmentDub.self,
            PhysicalShot.self,
            ShotVariant.self,
            // V1 之后新增（optional 字段 + optional to-one + 新实体，走轻量迁移，
            // 经 .scratch 真实 store 副本 spike 验证；未冻结 V2 副本）：
            Product.self,
            // v3.4 产品脚本成片：知识库 + 脚本四个新实体（新表无存量行，非可选字段无需默认值；
            // SegmentDub/MixScheme 新增字段均带默认值；首次启动新版 SchemaGuard 自动改前备份）。
            KnowledgeDocument.self,
            KnowledgeChunk.self,
            ScriptDocument.self,
            ScriptScene.self,
            // 全局配音音色：Project 新增 optional preferredVoiceChoiceRaw（nil=跟随全局默认，
            // VoiceChoiceCoder 版本化解码，坏串回落 nil）。无新实体，轻量迁移。
            // M1b 音色三级覆盖再补两个带默认值字段（同属轻量迁移，无新实体）：
            //   Video.voiceFollowsGlobal: Bool = false（视频级「跟随全局/项目」开关）；
            //   SchemeSegment.preferredVoiceChoiceRaw: String?（脚本成片段级音色覆盖）。
        ]
    }
}

/// 迁移计划。V1 是采纳点，所以**当前没有任何 stage 是正确状态**，不是待办。
enum AppMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] { [AppSchemaV1.self] }

    static var stages: [MigrationStage] { [] }
}

// ----------------------------------------------------------------------------
// 以后加字段时改哪里（批 3 的「方案批次分组」「AI 产物花费标注」会走到这里）
//
// 1. 先跑 `scripts/backup_store.sh` 之外的一条硬规矩：**手动留一份三件套**再动代码
//    （备份门只在运行时触发，改代码阶段它救不了你）。
// 2. 加**可选**字段（`var x: String?` / 带默认值）：SwiftData 轻量迁移能就地加列，
//    `AppSchemaV1` 与 `stages` 都不用动 —— 但 `SchemaGuard` 会在同事第一次启动新版时
//    自动生成一份改前备份，这是预期行为，不是 bug。
// 3. 加**必需无默认**字段、改字段类型、改关系（如给 `Segment` 挂 project）：轻量迁移过不去，
//    必须新增 `AppSchemaV2` + 一条 `MigrationStage.custom`。注意 V1 里的模型类型此时要
//    冻结成独立副本（Swift 不允许同一个 `@Model` 类同时充当两个版本），这是采纳 VersionedSchema
//    的真实代价，写在这里免得临场发明。
// 4. 无论哪种：`CLAUDE.md` 的「Schema 变更必须先备份数据库」一节要同步，那颗脚本的期望值也要重算。
// ----------------------------------------------------------------------------
