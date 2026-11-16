import Testing
@testable import ChatType

struct AppLaunchModeTests {
    @Test
    func overlayDemoModeRequiresExplicitFlag() {
        #expect(AppLaunchMode.resolve(environment: [:]) == .normal)
        #expect(AppLaunchMode.resolve(environment: ["CHATTYPE_OVERLAY_DEMO": "0"]) == .normal)
        #expect(AppLaunchMode.resolve(environment: ["CHATTYPE_OVERLAY_DEMO": "false"]) == .normal)
    }

    @Test
    func overlayDemoModeAcceptsCommonTruthyFlags() {
        #expect(AppLaunchMode.resolve(environment: ["CHATTYPE_OVERLAY_DEMO": "1"]) == .overlayDemo)
        #expect(AppLaunchMode.resolve(environment: ["CHATTYPE_OVERLAY_DEMO": "true"]) == .overlayDemo)
        #expect(AppLaunchMode.resolve(environment: ["CHATTYPE_OVERLAY_DEMO": "demo"]) == .overlayDemo)
    }

    @Test
    func overlayDemoModeAcceptsLaunchServicesArgument() {
        #expect(AppLaunchMode.resolve(environment: [:], arguments: ["ChatType", "--overlay-demo"]) == .overlayDemo)
        #expect(AppLaunchMode.resolve(environment: [:], arguments: ["ChatType", "--chattype-overlay-demo"]) == .overlayDemo)
    }

    @Test
    func settingsModeAcceptsLaunchServicesArgument() {
        #expect(AppLaunchMode.resolve(environment: [:], arguments: ["ChatType", "--settings"]) == .settings)
        #expect(AppLaunchMode.resolve(environment: [:], arguments: ["ChatType", "--open-settings"]) == .settings)
    }

    @Test
    func overlayDemoModeAcceptsSpecificVisualStateArgument() {
        #expect(
            AppLaunchMode.resolve(
                environment: [:],
                arguments: ["ChatType", "--overlay-demo-state", "retryable-error"]
            ) == .overlayDemoState(.retryableError)
        )
        #expect(
            AppLaunchMode.resolve(
                environment: [:],
                arguments: ["ChatType", "--overlay-demo-state=processing"]
            ) == .overlayDemoState(.processing)
        )
        #expect(
            AppLaunchMode.resolve(
                environment: ["CHATTYPE_OVERLAY_DEMO_STATE": "result"],
                arguments: ["ChatType"]
            ) == .overlayDemoState(.result)
        )
    }

    @Test
    func benchmarkModeHasPriorityWhenExplicitlyEnabled() {
        #expect(AppLaunchMode.resolve(environment: ["CHATTYPE_BENCHMARK": "1"]) == .benchmark)
        #expect(
            AppLaunchMode.resolve(
                environment: [
                    "CHATTYPE_BENCHMARK": "true",
                    "CHATTYPE_OVERLAY_DEMO": "1",
                ],
                arguments: ["ChatType", "--overlay-demo"]
            ) == .benchmark
        )
    }
}
