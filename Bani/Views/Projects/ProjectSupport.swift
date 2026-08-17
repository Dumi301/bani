import SwiftUI

// MARK: - Project color

extension ProjectSnapshot {
    /// Projects reuse the fixed 8-swatch semantic palette (`BaniCustom0…7`),
    /// `colorIndex mod 8` — the same convention as `CustomCategory`, so a project
    /// reads as part of the one warm family and never a raw color.
    var color: Color { CustomCategoryPalette.color(colorIndex) }
}

extension Project {
    var color: Color { CustomCategoryPalette.color(colorIndex) }
}

// MARK: - Status badge

/// Small "Active / Finished" pill for cards + the detail header.
struct ProjectStatusBadge: View {
    let status: ProjectStatus

    private var tint: Color { status == .active ? Palette.accent : Palette.secondaryInk }

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { Capsule().fill(tint.opacity(0.16)) }
            .foregroundStyle(tint)
            .accessibilityIdentifier("project.statusBadge")
    }
}

// MARK: - Chip (voice / manual / share confirmation cards)

/// A compact, tappable project chip. Shows the selected project's color dot +
/// name, or an "assign to project" affordance when none is set. Tapping opens a
/// recent-first menu (the active projects + a "None" option). Used on the Work
/// confirmation cards and the manual-entry sheet.
struct ProjectChipMenu: View {
    /// Active, non-archived projects, recent-first.
    let projects: [ProjectSnapshot]
    @Binding var selectedID: UUID?

    private var selected: ProjectSnapshot? { projects.first { $0.id == selectedID } }
    private var tint: Color { selected?.color ?? Palette.secondaryInk }

    var body: some View {
        Menu {
            ForEach(projects) { project in
                Button {
                    selectedID = project.id
                } label: {
                    Label(project.name, systemImage: selectedID == project.id ? "checkmark" : "folder")
                }
            }
            Divider()
            Button {
                selectedID = nil
            } label: {
                Label(String(localized: "project.none"), systemImage: selectedID == nil ? "checkmark" : "xmark.circle")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                Text(selected?.name ?? String(localized: "project.assign"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
            .font(.system(.caption).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(tint.opacity(0.14))
            }
            .metalSurface(cornerRadius: Radius.chip)
            .foregroundStyle(tint)
        }
        .accessibilityIdentifier("project.chip")
        .accessibilityLabel(Text(selected.map { String(localized: "project.chip.a11y \($0.name)") } ?? String(localized: "project.chip.a11y.none")))
    }
}

// MARK: - Form picker row (edit sheets)

/// A `Form`/`Menu` project picker row for the edit sheets (transaction edit,
/// scheduled-item add/edit). "None" clears the assignment.
struct ProjectPickerRow: View {
    let projects: [ProjectSnapshot]
    @Binding var selectedID: UUID?

    private var selected: ProjectSnapshot? { projects.first { $0.id == selectedID } }

    var body: some View {
        Menu {
            ForEach(projects) { project in
                Button { selectedID = project.id } label: {
                    Label(project.name, systemImage: selectedID == project.id ? "checkmark" : "folder")
                }
            }
            Divider()
            Button { selectedID = nil } label: {
                Label(String(localized: "project.none"), systemImage: selectedID == nil ? "checkmark" : "xmark.circle")
            }
        } label: {
            HStack {
                Text("project.field.label")
                    .foregroundStyle(Palette.ink)
                Spacer()
                HStack(spacing: 6) {
                    if let selected {
                        Circle().fill(selected.color).frame(width: 9, height: 9)
                        Text(selected.name).foregroundStyle(Palette.secondaryInk)
                    } else {
                        Text("project.none").foregroundStyle(Palette.secondaryInk)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
        }
        .accessibilityIdentifier("project.pickerRow")
    }
}
