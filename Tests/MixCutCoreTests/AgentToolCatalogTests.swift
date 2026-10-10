import Foundation
import Testing
@testable import MixCutCore

@Suite("AgentToolCatalog")
struct AgentToolCatalogTests {
    @Test("25 个工具且命名齐全")
    func allTools() {
        let names = AgentToolCatalog.all.map(\.name)
        // 2026-09-29：**有意的契约变更 23→24**（新增只读工具 get_asr_status，计划 §3.5）。
        // 2026-10-10：24→25（新增 split_segment，计划 §AE —— 拆分此前只能手点）。
        // 名单是逐名比对的，不是数个数，所以改名/漏名/多名都会在这里被抓。
        #expect(names == [
            "list_projects", "get_project", "list_segments", "list_schemes", "get_job", "get_asr_status",
            "create_project", "import_videos", "retry_analysis", "retry_asr", "remove_video",
            "generate_schemes", "export_scheme", "delete_project",
            "update_segment_tags", "update_segment_text", "adjust_segment_boundary", "split_segment",
            "set_subtitle_mode",
            "set_voice_keep_original", "set_dub_participation", "generate_voice_variants",
            "delete_segments", "create_custom_scheme", "export_segments",
        ])
    }

    @Test("split_segment 必须声明破坏性（拆完不可恢复），且拆分点两种写法都在 schema 里")
    func splitSegmentIsMarkedDestructive() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "split_segment" })
        let annotations = try #require(tool.annotationsJSON)
        #expect(annotations.contains("\"destructiveHint\":true"), "实际：\(annotations)")
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        for key in ["project_id", "video_no", "segment_no", "segment_id", "cut_frame", "cut_seconds"] {
            #expect(props[key] != nil, "split_segment 缺 \(key)")
        }
        // 必填留空：cut_frame 与 cut_seconds 是「二选一」，写进 required 就变成两个都得给
        #expect((obj["required"] as? [Any] ?? []).isEmpty, "实际：\(obj)")
    }

    @Test("get_asr_status 必须声明为只读且无必填参数（它只报现状，不许改任何东西）")
    func asrStatusIsReadOnly() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "get_asr_status" })
        let annotations = try #require(tool.annotationsJSON)
        #expect(annotations.contains("\"readOnlyHint\":true"), "实际：\(annotations)")
        #expect(!annotations.contains("\"destructiveHint\":true"),
                "只读工具不许声明破坏性；实际：\(annotations)")
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        #expect((obj["required"] as? [Any] ?? []).isEmpty, "只读状态面不该有必填参数")
    }

    @Test("分镜工具的 selector 参数齐全")
    func segmentSelectorSchema() throws {
        for name in ["update_segment_tags", "adjust_segment_boundary", "set_subtitle_mode",
                     "set_voice_keep_original", "set_dub_participation", "generate_voice_variants",
                     "delete_segments", "export_segments"] {
            let tool = try #require(AgentToolCatalog.all.first { $0.name == name })
            let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
            let props = try #require(obj["properties"] as? [String: Any])
            for key in ["project_id", "video_no", "segment_nos", "segment_ids"] {
                #expect(props[key] != nil, "\(name) 缺 \(key)")
            }
        }
    }

    @Test("set_subtitle_mode 只认三档中文枚举")
    func subtitleModeEnum() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "set_subtitle_mode" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        let mode = try #require(props["mode"] as? [String: Any])
        #expect(mode["enum"] as? [String] == ["直接烧录", "模糊虚化", "纯色遮挡"])
    }

    @Test("update_segment_text schema：items 必填且每项必须带 text")
    func updateSegmentTextSchema() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "update_segment_text" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        #expect(obj["required"] as? [String] == ["items"])
        let props = try #require(obj["properties"] as? [String: Any])
        let items = try #require(props["items"] as? [String: Any])
        let itemSchema = try #require(items["items"] as? [String: Any])
        #expect(itemSchema["required"] as? [String] == ["text"])
        let itemProps = try #require(itemSchema["properties"] as? [String: Any])
        for key in ["video_no", "segment_no", "segment_id", "text"] {
            #expect(itemProps[key] != nil, "update_segment_text 缺 \(key)")
        }
    }

    @Test("delete_segments 带 destructiveHint")
    func deleteSegmentsAnnotation() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "delete_segments" })
        let json = try #require(tool.annotationsJSON)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["destructiveHint"] as? Bool == true)
    }

    @Test("破坏性工具带 destructiveHint，只读工具带 readOnlyHint")
    func annotations() throws {
        func hints(_ name: String) throws -> [String: Any] {
            let tool = try #require(AgentToolCatalog.all.first { $0.name == name })
            let json = try #require(tool.annotationsJSON)
            return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        #expect(try hints("delete_project")["destructiveHint"] as? Bool == true)
        #expect(try hints("remove_video")["destructiveHint"] as? Bool == true)
        #expect(try hints("list_projects")["readOnlyHint"] as? Bool == true)
        #expect(try hints("export_scheme")["destructiveHint"] as? Bool == false)
    }

    @Test("delete_project schema 含 confirm 二次确认参数")
    func deleteProjectConfirm() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "delete_project" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        #expect(props["confirm"] != nil)
    }

    @Test("export_scheme schema 声明必填参数")
    func exportSchemeSchema() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "export_scheme" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let required = try #require(obj["required"] as? [String])
        #expect(Set(required) == ["scheme_ids", "output_dir"])
    }

    @Test("每个工具的 inputSchema 都是合法 JSON object")
    func schemasAreValidJSON() throws {
        for tool in AgentToolCatalog.all {
            let obj = try JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any]
            #expect(obj?["type"] as? String == "object", "\(tool.name) schema 非法")
            #expect(!tool.description.isEmpty)
        }
    }

    @Test("import_videos schema 声明必填参数")
    func importVideosSchema() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "import_videos" })
        let obj = try #require(JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8)) as? [String: Any])
        let required = try #require(obj["required"] as? [String])
        #expect(Set(required) == ["project_id", "paths"])
    }

    @Test("AgentJSON.error 输出结构化错误")
    func errorJSON() throws {
        let json = AgentJSON.error(code: .projectNotFound, message: "找不到项目 x")
        let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["code"] as? String == "PROJECT_NOT_FOUND")
        #expect(obj["message"] as? String == "找不到项目 x")
    }

    @Test("AgentJSON.encode 稳定输出（sortedKeys）")
    func encodeSorted() {
        let json = AgentJSON.encode(["b": 1, "a": 2])
        #expect(json == #"{"a":2,"b":1}"#)
    }
}
