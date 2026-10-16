import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AgentOneWidgets: WidgetBundle {
    var body: some Widget { RunActivityWidget() }
}

/// What the person sees of a run while the app is in the background or the phone is locked.
struct RunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Agent One", systemImage: "hand.tap.fill").font(.caption.bold())
                    Spacer()
                    if !context.state.finished { Link("Stop", destination: RunLinks.stop).font(.caption.bold()) }
                }
                Text(context.attributes.task).font(.subheadline).lineLimit(1)
                Text(context.state.finished ? context.state.detail : "Step \(context.state.step): \(context.state.detail)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "hand.tap.fill") }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.step)").monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.task).font(.caption.bold()).lineLimit(1)
                        Text(context.state.detail).font(.caption2).lineLimit(2)
                    }
                }
            } compactLeading: {
                Image(systemName: "hand.tap.fill")
            } compactTrailing: {
                Text("\(context.state.step)").monospacedDigit()
            } minimal: {
                Image(systemName: "hand.tap.fill")
            }
            .widgetURL(RunLinks.stop)
        }
    }
}
