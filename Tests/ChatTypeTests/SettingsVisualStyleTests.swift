import Testing
@testable import ChatType

@Test
func settingsTypographyKeepsReadableScale() {
    #expect(SettingsTypography.pageTitleSize > SettingsTypography.sectionTitleSize)
    #expect(SettingsTypography.sectionTitleSize > SettingsTypography.rowTitleSize)
    #expect(SettingsTypography.rowTitleSize > SettingsTypography.bodySize)
    #expect(SettingsTypography.bodySize >= 16)
    #expect(SettingsTypography.detailSize >= 15)
    #expect(SettingsTypography.captionSize >= 13)
    #expect(SettingsTypography.monoValueSize >= 24)
}

@Test
func settingsLayoutKeepsComfortableReadingWidth() {
    #expect(SettingsLayout.contentMaxWidth <= 1_000)
    #expect(SettingsLayout.pagePadding >= 32)
    #expect(SettingsLayout.cardPadding >= 20)
    #expect(SettingsLayout.sectionSpacing >= 24)
    #expect(SettingsLayout.sidebarWidth >= 220)
}
