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
    /// v0.4 — project-first entry: "+ plată" opens manual entry pre-filled
    /// with this project (Work context).
    @State private var addingPayment = false
    @Query private var allProjects: [Project]

    private var units: [Project] {
        let active = allProjects.filter { !$0.archived }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        return ProjectTree.children(of: project.id, in: active.map(\.snapshot)).compactMap { byID[$0.id] }
    }

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

            if !units.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(units, id: \.id) { unit in
                            NavigationLink(value: unit) {
                                HStack(spacing: 6) {
                                    Circle().fill(CustomCategoryPalette.color(unit.colorIndex)).frame(width: 8, height: 8)
                                    Text(unit.name).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .metalSurface(cornerRadius: Radius.button)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, metrics.screenPadding)
                }
                .padding(.bottom, metrics.elementSpacing)
                .accessibilityIdentifier("project.unitsStrip")
            }

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingPayment = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(Palette.accent)
                .accessibilityIdentifier("project.addPayment")
                .accessibilityLabel(Text("project.addPayment"))
            }
        }
        .sheet(isPresented: $addingPayment) {
            ManualEntrySheet(defaultProjectID: project.id)
        }
    }
}
