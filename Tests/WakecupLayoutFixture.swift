import SwiftUI

struct WakecupLayoutFixture: View {
    @ObservedObject var model: SessionModel
    private let header: WakecupHeaderView
    private let options: WakecupOptionsView

    init(model: SessionModel, updates: UpdateChecker, showAbout: @escaping () -> Void,
         configureDisplayShortcut: @escaping (Bool, @escaping (Bool) -> Void) -> Void = { _, complete in complete(false) },
         showMCPSetup: @escaping () -> Void = {}, helperInteraction: HelperInteraction = .init(),
         isMCPEnabled: @escaping () -> Bool = { false }, setMCPEnabled: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        header = WakecupHeaderView(model: model, updates: updates, showAbout: showAbout, showMCPSetup: showMCPSetup,
            helperInteraction: helperInteraction, isMCPEnabled: isMCPEnabled, setMCPEnabled: setMCPEnabled)
        options = WakecupOptionsView(model: model, configureDisplayShortcut: configureDisplayShortcut,
                                    helperInteraction: helperInteraction)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SessionFeedbackView(feedback: SessionFeedback.current(for: model, placement: .primaryAction))
            options
            SessionFeedbackView(feedback: SessionFeedback.current(for: model, placement: .footer))
        }
        .frame(width: MenuLayout.width)
    }
}
