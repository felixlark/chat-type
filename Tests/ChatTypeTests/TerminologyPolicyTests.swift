import Foundation
import Testing
@testable import ChatType

// All names and organizations below are fictional test fixtures.

@Test
func terminologyPolicyRemovesBulkSegmentationAndGenericDomainSources() {
    let entries = [
        policyTerm("ChatType", source: "user"),
        policyTerm("分词", source: "jieba: https://example.com/dict.txt.big"),
        policyTerm("发展", source: "THUOCL: https://example.com/THUOCL_caijing.txt"),
        policyTerm("患者", source: "THUOCL: https://example.com/THUOCL_medical.txt"),
    ]

    let sanitized = TerminologyPolicy.sanitizedEntries(entries)

    #expect(sanitized.map(\.original) == ["ChatType"])
}

@Test
func terminologyPolicySeparatesNamesUnitsAndTrailingPositions() {
    let entries = [
        policyTerm("周明轩 云城示例组织部 部长", source: "smart-shadow-weixin-remark"),
        policyTerm("吴语桐-示例车队总经理", source: "macos-contacts"),
        policyTerm("示例甲科技总经理、示例乙集团副总裁", source: "macos-contacts"),
        policyTerm("沈初夏老师", source: "macos-contacts"),
        policyTerm("博士，教授", source: "macos-contacts"),
        policyTerm("云城大学校长、海城控制系教授", source: "smart-shadow-weixin-remark"),
        policyTerm("云城示例投资有限合伙企业", source: "smart-shadow-weixin-remark"),
        policyTerm("Alice Smith", source: "apple-contacts-nickname"),
    ]

    let sanitized = TerminologyPolicy.sanitizedEntries(entries)

    #expect(sanitized.map(\.original) == [
        "周明轩",
        "云城示例组织部",
        "吴语桐",
        "示例车队",
        "示例甲科技",
        "示例乙集团",
        "沈初夏",
        "云城大学",
        "海城控制系",
        "云城示例投资有限合伙企业",
        "Alice Smith",
    ])
}

@Test
func terminologyPolicyLeavesUserTermsUntouched() {
    let entries = [
        policyTerm("刘老师", source: "user"),
        policyTerm("产品总监", source: "dictionary-import"),
    ]

    #expect(TerminologyPolicy.sanitizedEntries(entries) == entries)
}

@Test
func terminologyPolicyKeepsUserEntryWhenAnImportedDuplicateComesFirst() {
    let entries = [
        policyTerm("ChatType", source: "macos-contacts"),
        policyTerm("ChatType", source: "user"),
    ]

    let sanitized = TerminologyPolicy.sanitizedEntries(entries)

    #expect(sanitized.count == 1)
    #expect(sanitized[0].source == "user")
}

private func policyTerm(_ value: String, source: String) -> TerminologyEntry {
    TerminologyEntry(
        type: .term,
        original: value,
        replacement: nil,
        aliases: [],
        source: source,
        usageCount: 0,
        createdAt: "2026-08-27T00:00:00Z"
    )
}
