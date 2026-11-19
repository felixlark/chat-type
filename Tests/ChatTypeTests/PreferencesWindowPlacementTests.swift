import CoreGraphics
import Testing
@testable import ChatType

@Test
func settingsWindowMaximizesOnBuiltInDisplay() {
    let external = PreferencesScreenGeometry(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055),
        isBuiltIn: false
    )
    let builtIn = PreferencesScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 74, width: 1512, height: 875),
        isBuiltIn: true
    )

    #expect(PreferencesWindowPlacement.maximizedFrame(
        in: [external, builtIn]
    ) == builtIn.visibleFrame)
}

@Test
func settingsWindowFallsBackToFirstAvailableDisplay() {
    let external = PreferencesScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850),
        isBuiltIn: false
    )

    #expect(PreferencesWindowPlacement.maximizedFrame(
        in: [external]
    ) == external.visibleFrame)
    #expect(PreferencesWindowPlacement.maximizedFrame(in: []) == nil)
}
