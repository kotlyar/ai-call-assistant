import Foundation

@MainActor
final class ApplicationTerminationCoordinator {
    static let shared = ApplicationTerminationCoordinator()

    weak var model: AppModel?

    private init() {}

    var needsDeferredTermination: Bool {
        // Context persistence is asynchronous, so even an idle app needs the
        // same deferred termination handshake as an active call.
        model != nil
    }

    func prepareForTermination() async -> Bool {
        guard let model else { return true }
        return await model.prepareForTermination()
    }
}
