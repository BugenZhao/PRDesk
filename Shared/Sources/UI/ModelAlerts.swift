import SwiftUI

/// The model's errors as alerts, and the send sheet for Grok Bot requests that wait on the viewer.
struct ModelAlerts: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert(
                "GitHub not updated",
                isPresented: Binding(get: { model.writeError != nil }, set: { if !$0 { model.writeError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(model.writeError ?? "") }
            )
            .alert(
                "Grok Bot not reached",
                isPresented: Binding(get: { model.botError != nil }, set: { if !$0 { model.botError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(model.botError ?? "") }
            )
            .alert(
                "Not opened",
                isPresented: Binding(get: { model.linkError != nil }, set: { if !$0 { model.linkError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(model.linkError ?? "") }
            )
            .alert(
                model.requestTrip?.isPause == true ? "GitHub requests stopped" : "A repeating request stopped",
                isPresented: Binding(get: { model.requestTrip != nil }, set: { if !$0 { model.requestTrip = nil } }),
                presenting: model.requestTrip,
                actions: { trip in
                    if trip.isPause {
                        Button("Resume") { model.resumeRequests() }
                        Button("Keep Stopped", role: .cancel) {}
                    } else {
                        Button("OK") {}
                    }
                },
                message: { trip in Text(trip.message) }
            )
            .sheet(item: Binding(get: { model.pendingBotSend }, set: { model.pendingBotSend = $0 })) { pending in
                BotSendSheet(pending: pending)
            }
    }
}
