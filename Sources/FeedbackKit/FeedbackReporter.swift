#if canImport(UIKit)
import SwiftUI
import UIKit

public extension Notification.Name {
    /// Posted on every device shake. Post it yourself (e.g. from a "Report a bug" button)
    /// to open the reporter the same way.
    static let feedbackKitDeviceShaken = Notification.Name("FeedbackKit.deviceShaken")
}

extension UIWindow {
    /// A shake anywhere in the app opens the report sheet. An app adopting FeedbackKit
    /// must not override `UIWindow.motionEnded` itself (remove any old one).
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .feedbackKitDeviceShaken, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

public extension View {
    /// Opens ``FeedbackSheet`` on a device shake, above whatever is presented, and retries
    /// reports queued while offline when this view appears. Attach once, at the root.
    func feedbackReporter(config: FeedbackConfig) -> some View {
        modifier(FeedbackReporterModifier(config: config))
    }
}

struct FeedbackReporterModifier: ViewModifier {
    let config: FeedbackConfig

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .feedbackKitDeviceShaken)) { _ in
                FeedbackReporter.shared.present(config: config)
            }
            .task { await FeedbackReporter.shared.retryQueued(config: config) }
    }
}

/// Screenshots the window as it was, builds the context, then presents ``FeedbackSheet``
/// over the topmost view controller.
@MainActor public final class FeedbackReporter {
    public static let shared = FeedbackReporter()

    private var open = false
    private let dismissWatcher = DismissWatcher()

    /// The URL session and queue reports use (tests and previews swap them).
    public var session: URLSession = .shared
    public var queue: FeedbackQueue = .standard

    public init() {}

    public func client(for config: FeedbackConfig) -> FeedbackClient {
        FeedbackClient(config: config, session: session, queue: queue)
    }

    /// Sends what was queued while offline.
    public func retryQueued(config: FeedbackConfig) async {
        await client(for: config).retryQueued()
    }

    public func present(config: FeedbackConfig) {
        guard !open,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let shot = FeedbackScreenshot.capture(window)
        let context = FeedbackContext.build(appID: config.appID, buildSHAInfoKey: config.buildSHAInfoKey,
                                            screen: config.screen(), reporter: config.reporter())
        let diagnostics = config.diagnostics?().map { FeedbackLimits.truncateDiagnostics($0) }
        let client = client(for: config)
        Task { await client.retryQueued() }

        open = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let sheet = FeedbackSheet(screenshot: shot, context: context, diagnostics: diagnostics,
                                  client: client) { [weak self, weak top] in
            top?.presentedViewController?.dismiss(animated: true)
            self?.open = false
        }
        let host = UIHostingController(rootView: sheet)
        dismissWatcher.onDismiss = { [weak self] in self?.open = false }
        host.presentationController?.delegate = dismissWatcher
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
    }

    /// Swiping the sheet away also frees the reporter for the next shake.
    private final class DismissWatcher: NSObject, UIAdaptivePresentationControllerDelegate {
        var onDismiss: () -> Void = {}
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss()
        }
    }
}

public enum FeedbackScreenshot {
    /// The window as it looks now, at 1.5× (readable, small to upload).
    @MainActor public static func capture(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(FeedbackLimits.screenshotScale, window.screen.scale)
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// JPEG at quality 0.6, the encoding the payload carries.
    public static func jpeg(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: FeedbackLimits.jpegQuality)
    }
}
#endif
