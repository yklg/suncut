import Testing
import Foundation
@testable import MixCutCore

// MARK: - GroundingChecker

@Test func grounding_extractsNumbersAndLatinNames() {
    let facts = GroundingChecker.extractFacts(from: "通过 ISO9001 认证，抑菌率 99%，型号 FDA-X")
    #expect(facts.contains("99%"))
    #expect(facts.contains("ISO9001"))
    #expect(facts.contains("FDA"))
}

@Test func grounding_factPresentInSourcesIsSupported() {
    let report = GroundingChecker.check(
        text: "实测抑菌率达到 99%",
        sources: ["第三方检测报告显示抑菌率 99%，符合标准"])
    #expect(report.isGrounded)
    #expect(report.unsupportedFacts.isEmpty)
}

@Test func grounding_fabricatedNumberIsUnsupported() {
    let report = GroundingChecker.check(
        text: "全网销量 1000 万台",
        sources: ["产品于 2023 年上市，主打高频拍打功能"])
    #expect(!report.isGrounded)
    #expect(report.unsupportedFacts.contains("1000"))
}

@Test func grounding_noFactsIsGrounded() {
    let report = GroundingChecker.check(
        text: "用起来很方便，清洁得很干净",
        sources: ["用户反馈使用方便"])
    #expect(report.isGrounded)
}

@Test func grounding_factsDeduplicatedInOrder() {
    let facts = GroundingChecker.extractFacts(from: "99% 和 99% 与 ISO ISO")
    #expect(facts.filter { $0 == "99%" }.count == 1)
    #expect(facts.filter { $0 == "ISO" }.count == 1)
}

// MARK: - ComplianceChecker

@Test func compliance_forbiddenSuperlativesDetected() {
    let issues = ComplianceChecker.scan("这是全网最好用的除螨仪，国家级品质，销量第一")
    let words = issues.compactMap { issue -> String? in
        guard case .forbiddenWord(let w) = issue else { return nil }
        return w
    }
    #expect(words.contains("最好"))
    #expect(words.contains("国家级"))
    #expect(words.contains("第一"))
}

@Test func compliance_placeholdersDetectedCaseInsensitive() {
    let issues = ComplianceChecker.scan("效果待补充，todo later，还有 XXX 需要改")
    let words = issues.compactMap { issue -> String? in
        guard case .placeholder(let w) = issue else { return nil }
        return w
    }
    #expect(words.contains("待补充"))
    #expect(words.contains("todo"))
    #expect(words.contains("xxx"))
}

@Test func compliance_cleanTextHasNoIssues() {
    let issues = ComplianceChecker.scan("高频拍打，深层清洁，适合日常使用")
    #expect(issues.isEmpty)
}

@Test func compliance_describeIsReadable() {
    let desc = ComplianceChecker.describe(.forbiddenWord("最佳"))
    #expect(desc.contains("最佳"))
    #expect(desc.contains("广告法"))
}
