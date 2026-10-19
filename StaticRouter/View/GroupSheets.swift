//
//  GroupSheets.swift
//  StaticRouteHelper
//

import SwiftUI
import SwiftData

// MARK: - AddGroupSheet

@available(macOS 14, *)
struct AddGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RouteGroup.sortOrder) private var groups: [RouteGroup]

    @State private var name = ""
    @State private var iconName = "folder"
    @State private var saveErrorMessage: String? = nil
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private let availableIcons = [
        ("folder", "文件夹"),
        ("network", "网络"),
        ("lock.shield", "安全"),
        ("house", "家"),
        ("building.2", "办公"),
        ("server.rack", "服务器"),
        ("cloud", "云"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "group.add.title"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "group.add.name.label"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("例如：Office VPN", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if isValid { save() } }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "group.add.icon.label"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(availableIcons, id: \.0) { (icon, _) in
                        Button {
                            iconName = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 16))
                                .frame(width: 36, height: 36)
                                .background(iconName == icon ? RouterTheme.accentSoft : RouterTheme.subtleFill)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "group.add.button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "group.add.button.add")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .frame(width: 280)
        .padding(20)
        .persistenceErrorAlert(message: $saveErrorMessage)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let newGroup = RouteGroup(
            name: trimmed,
            iconName: iconName,
            sortOrder: groups.count
        )
        modelContext.insert(newGroup)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - AssignGroupsSheet

@available(macOS 14, *)
struct AssignGroupsSheet: View {
    let rule: RouteRule
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RouteGroup.sortOrder) private var allGroups: [RouteGroup]

    @State private var selectedGroupIDs: Set<PersistentIdentifier> = []
    @State private var saveErrorMessage: String? = nil

    init(rule: RouteRule) {
        self.rule = rule
        // selectedGroupIDs is populated in onAppear / task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "group.assign.title"))
                .font(.headline)

            if allGroups.isEmpty {
                Text(String(localized: "group.assign.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                List(allGroups) { group in
                    Button {
                        if selectedGroupIDs.contains(group.persistentModelID) {
                            selectedGroupIDs.remove(group.persistentModelID)
                        } else {
                            selectedGroupIDs.insert(group.persistentModelID)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedGroupIDs.contains(group.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedGroupIDs.contains(group.persistentModelID) ? RouterTheme.accent : Color.secondary)
                            Image(systemName: group.iconName ?? "folder")
                                .foregroundStyle(.secondary)
                            Text(group.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .frame(minHeight: 120, maxHeight: 260)
            }

            HStack {
                Spacer()
                Button(String(localized: "group.assign.button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "group.assign.button.save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .task {
            // Pre-select current groups
            selectedGroupIDs = Set(rule.groups.map(\.persistentModelID))
        }
        .persistenceErrorAlert(message: $saveErrorMessage)
    }

    private func save() {
        do {
            let ruleID = rule.id
            let descriptor = FetchDescriptor<RouteRule>(
                predicate: #Predicate<RouteRule> { candidate in
                    candidate.id == ruleID
                }
            )
            guard let persistedRule = try modelContext.fetch(descriptor).first else {
                throw PersistenceError.objectNoLongerExists
            }

            persistedRule.groups = allGroups.filter {
                selectedGroupIDs.contains($0.persistentModelID)
            }
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - RenameGroupSheet

@available(macOS 14, *)
struct RenameGroupSheet: View {
    let group: RouteGroup
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name: String
    @State private var saveErrorMessage: String? = nil

    init(group: RouteGroup) {
        self.group = group
        _name = State(initialValue: group.name)
    }

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var hasChanged: Bool { name.trimmingCharacters(in: .whitespaces) != group.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "group.rename.title"))
                .font(.headline)

            TextField(String(localized: "group.rename.field.placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if isValid { save() } }

            HStack {
                Spacer()
                Button(String(localized: "group.rename.button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "group.rename.button.save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || !hasChanged)
            }
        }
        .padding(20)
        .frame(width: 280)
        .persistenceErrorAlert(message: $saveErrorMessage)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let groupID = group.id
            let descriptor = FetchDescriptor<RouteGroup>(
                predicate: #Predicate<RouteGroup> { candidate in
                    candidate.id == groupID
                }
            )
            guard let persistedGroup = try modelContext.fetch(descriptor).first else {
                throw PersistenceError.objectNoLongerExists
            }
            persistedGroup.name = trimmed
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }
}

@available(macOS 14, *)
private extension View {
    func persistenceErrorAlert(message: Binding<String?>) -> some View {
        alert(
            String(localized: "persistence.save_error.title"),
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                message.wrappedValue = nil
            }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
