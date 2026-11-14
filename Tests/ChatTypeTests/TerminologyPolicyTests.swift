import Foundation
import Testing
@testable import ChatType

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
        policyTerm("刘鑫财 漳州龙轴组织部 部长", source: "smart-shadow-weixin-remark"),
        policyTerm("郑计阮-厦大车队总经理", source: "macos-contacts"),
        policyTerm("易惠科技总经理、易联众集团副总裁", source: "macos-contacts"),
        policyTerm("刘伟榕老师", source: "macos-contacts"),
        policyTerm("博士，教授", source: "macos-contacts"),
        policyTerm("杭电校长、浙大控制系教授", source: "smart-shadow-weixin-remark"),
        policyTerm("厦门金联云投资有限合伙企业", source: "smart-shadow-weixin-remark"),
        policyTerm("Alice Smith", source: "apple-contacts-nickname"),
    ]

    let sanitized = TerminologyPolicy.sanitizedEntries(entries)

    #expect(sanitized.map(\.original) == [
        "刘鑫财",
        "漳州龙轴组织部",
        "郑计阮",
        "厦大车队",
        "易惠科技",
        "易联众集团",
        "刘伟榕",
        "杭电",
        "浙大控制系",
        "厦门金联云投资有限合伙企业",
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
