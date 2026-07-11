import SwiftUI
import SwiftData
import SSHConfigCore

enum PaletteAction: CaseIterable, Identifiable {
    case newHost, syncFromFile, syncToFile, syncBoth, rawConfig, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .newHost: "New Host"
        case .syncFromFile: "Sync From File"
        case .syncToFile: "Sync To File"
        case .syncBoth: "Sync Both"
        case .rawConfig: "Raw Config"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .newHost: "plus"
        case .syncFromFile: "arrow.down.doc"
        case .syncToFile: "arrow.up.doc"
        case .syncBoth: "arrow.triangle.2.circlepath"
        case .rawConfig: "doc.plaintext"
        case .settings: "gearshape"
        }
    }
}

enum PaletteHostAction { case connect, copy, reveal }

/// One selectable row in the palette's flattened host list — a single-profile
/// host renders as itself; a multi-profile host expands into one row per
/// member, each independently searchable and independently actionable.
private struct PaletteHostRow: Identifiable {
    var id: String { alias }
    let alias: String
    let title: String
    let subtitle: String
    let isConnectable: Bool
}

private enum PaletteItem: Identifiable {
    case host(PaletteHostRow)
    case action(PaletteAction)

    var id: String {
        switch self {
        case .host(let row): "host-\(row.alias)"
        case .action(let action): "action-\(action.title)"
        }
    }
}

struct CommandPalette: View {
    let groups: [HostGroupView]
    let resolve: (String) -> HostEntry?
    let onHost: (HostEntry, PaletteHostAction) -> Void
    let onAction: (PaletteAction) -> Void
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private static let maxRows = 12

    /// Expands each group into one row per profile, so a fuzzy match on a
    /// member's label/alias/hostname surfaces that specific profile.
    private var hostRows: [PaletteHostRow] {
        groups.flatMap { group in
            group.members.map { member in
                let entry = resolve(member.alias)
                let title = group.isMultiProfile ? "\(group.title) · \(member.label)" : group.title
                let hostName = entry?.properties.first("HostName") ?? "—"
                let subtitle = member.user.map { "\($0)@\(hostName)" } ?? hostName
                return PaletteHostRow(alias: member.alias, title: title,
                                       subtitle: subtitle, isConnectable: member.isConnectable)
            }
        }
    }

    private var results: [PaletteItem] {
        let ranked: [(PaletteItem, Int, Int)] = // (item, score, kindRank: hosts first)
            hostRows.compactMap { row in
                let target = row.title + " " + row.subtitle
                guard let s = FuzzyMatcher.score(query, in: target) else { return nil }
                return (.host(row), s, 0)
            }
            + PaletteAction.allCases.compactMap { action in
                guard let s = FuzzyMatcher.score(query, in: action.title) else { return nil }
                return (.action(action), s, 1)
            }
        return ranked
            .sorted { ($0.1, $1.2) > ($1.1, $0.2) } // score desc, hosts before actions on ties
            .prefix(Self.maxRows)
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                TextField("Search hosts and commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(12)
                    .focused($fieldFocused)
                    .onSubmit { execute(at: selectedIndex, commandModifier: false) }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selectedIndex)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { execute(at: index, commandModifier: false) }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24)
            .padding(.top, 80)
            .onKeyPress(.downArrow) {
                selectedIndex = min(selectedIndex + 1, max(0, results.count - 1)); return .handled
            }
            .onKeyPress(.upArrow) {
                selectedIndex = max(selectedIndex - 1, 0); return .handled
            }
            .onKeyPress(.escape) {
                isPresented = false; return .handled
            }
            .onKeyPress(.return, phases: .down) { press in
                execute(at: selectedIndex, commandModifier: press.modifiers.contains(.command))
                return .handled
            }
        }
        .onAppear {
            query = ""
            selectedIndex = 0
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .host(let row):
                Image(systemName: row.isConnectable ? "server.rack" : "rectangle.stack")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.isConnectable ? "↩ connect · ⌘↩ copy" : "↩ reveal")
                    .font(.caption2).foregroundStyle(.tertiary)
            case .action(let action):
                Image(systemName: action.icon).frame(width: 20)
                Text(action.title)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
    }

    private func execute(at index: Int, commandModifier: Bool) {
        // Return can arrive via both the TextField's onSubmit and the
        // container's onKeyPress; dismiss-first makes any second call a no-op.
        guard isPresented, results.indices.contains(index) else { return }
        isPresented = false
        switch results[index] {
        case .host(let row):
            guard let entry = resolve(row.alias) else { return }
            if commandModifier {
                onHost(entry, .copy)
            } else if row.isConnectable {
                onHost(entry, .connect)
            } else {
                onHost(entry, .reveal)
            }
        case .action(let action):
            onAction(action)
        }
    }
}
