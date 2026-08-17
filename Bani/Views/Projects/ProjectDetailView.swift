import SwiftUI
import SwiftData

/// Inside a project: a segmented switch over three panes — Dashboard (the existing
/// Finances analytics scoped by `projectID`), Money schedule (pending items +
/// mark-done), and Documents (this project's attachments). All three read the
/// same single cash pot through the project lens; nothing here moves money.
struct ProjectDetailView: View {
    @Environment(\.metrics) private var metrics
    let project: Project

    @State private var pane: Pane = .dashboard

    enum Pane: String, CaseIterable, Identifiable {
        case dashboard, schedule, documents
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dashboard: String(localized: "project.pane.dashboard")
            case .schedule:  String(localized: "project.pane.schedule")
            case .documents: String(localized: "project.pane.documents")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("project.pane", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.label).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .tint(Palette.accent)
            .padding(.horizontal, metrics.screenPadding)
            .padding(.vertical, metrics.elementSpacing)
            .accessibilityIdentifier("project.panePicker")

            switch pane {
            case .dashboard:
                ProjectDashboardView(projectID: project.id)
            case .schedule:
                ProjectScheduleView(projectID: project.id)
            case .documents:
                ProjectDocumentsView(projectID: project.id)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
