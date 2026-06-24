import AppKit
import SwiftUI

@main
struct GQuotaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(
                nsImage: MenuBarIconRenderer.image(
                    forSegments: model.menuBarIconSegments,
                    appearance: NSApp.effectiveAppearance
                )
            )
            .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
