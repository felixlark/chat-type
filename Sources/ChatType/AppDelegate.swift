import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var applicationMenu: ApplicationMenuController?
    private let authManager = ChatGPTAuthManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AcceptanceTranscriptionDeadline.requested(arguments: ProcessInfo.processInfo.arguments) {
            let deadline = AcceptanceTranscriptionDeadline()
            coordinator = AppCoordinator(authManager: authManager, pipelineFactory: { config, auth, policy in
                deadline.pipeline(config, auth, policy)
            })
        } else {
            coordinator = AppCoordinator(authManager: authManager)
        }
        applicationMenu = ApplicationMenuController.install { [weak self] in
            self?.coordinator?.showSettings()
        }
        coordinator?.start(
            launchMode: AppLaunchMode.resolve(
                environment: ProcessInfo.processInfo.environment,
                arguments: ProcessInfo.processInfo.arguments
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.cancelCurrentSession()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        coordinator?.showSettings()
        return true
    }
}
