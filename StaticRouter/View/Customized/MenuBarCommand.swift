//
//  MenuBarCommand.swift
//  Static Router
//
//  Created by 经典 on 12/1/2023.
//

import Foundation
import SwiftUI
import SwiftData
import CoreData
import AppKit

struct MenuBarCommand: Commands {
    var body: some Commands {
        SidebarCommands()
    }
}

// MARK: - Menu Bar Extra

@available(macOS 13, *)
struct RouterMenuBarContent: View {
    @EnvironmentObject private var routerService: RouterService
    @EnvironmentObject private var legacyStack: LegacyPersistenceStack
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            showMainWindow()
        } label: {
            Label(String(localized: "tray.open"), systemImage: "macwindow")
        }
        .keyboardShortcut("o")

        Divider()

        if #available(macOS 14, *) {
            ModernRouterMenuBarContent()
                .environmentObject(routerService)
                .modelContainer(StaticRouteHelperApp.sharedModelContainer)
        } else {
            LegacyRouterMenuBarContent()
                .environmentObject(routerService)
                .environment(\.managedObjectContext, legacyStack.viewContext)
        }
    }

    private func showMainWindow() {
        let delegate = NSApp.delegate as? AppTerminationDelegate
        guard delegate?.showExistingMainWindow() != true else { return }
        openWindow(id: StaticRouteHelperApp.mainWindowID)
    }
}

@available(macOS 14, *)
private struct ModernRouterMenuBarContent: View {
    @EnvironmentObject private var routerService: RouterService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RouteRule.createdAt) private var routes: [RouteRule]
    @Query(sort: \RouteGroup.sortOrder) private var groups: [RouteGroup]
    @State private var busyRouteIDs: Set<UUID> = []
    @State private var busyGroupIDs: Set<UUID> = []

    var body: some View {
        Menu(String(localized: "tray.routes")) {
            if routes.isEmpty {
                Text(String(localized: "tray.no_routes"))
            } else {
                ForEach(routes) { route in
                    Button {
                        toggle(route)
                    } label: {
                        Label(route.cidrNotation, systemImage: route.isActive ? "checkmark.circle.fill" : "circle")
                    }
                    .disabled(busyRouteIDs.contains(route.id) || routerService.helperStatus != .installed)
                }
            }
        }

        Menu(String(localized: "tray.groups")) {
            if groups.isEmpty {
                Text(String(localized: "tray.no_groups"))
            } else {
                ForEach(groups) { group in
                    Button {
                        toggle(group)
                    } label: {
                        Label(group.name, systemImage: groupState(group).symbolName)
                    }
                    .disabled(
                        group.routes.isEmpty ||
                        busyGroupIDs.contains(group.id) ||
                        routerService.helperStatus != .installed
                    )
                }
            }
        }

        Divider()

        Button(String(localized: "tray.quit"), role: .destructive) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func groupState(_ group: RouteGroup) -> TrayGroupState {
        let activeCount = group.routes.filter(\.isActive).count
        if activeCount == 0 { return .inactive }
        if activeCount == group.routes.count { return .active }
        return .mixed
    }

    private func toggle(_ route: RouteRule) {
        guard !busyRouteIDs.contains(route.id) else { return }
        busyRouteIDs.insert(route.id)

        Task { @MainActor in
            defer { busyRouteIDs.remove(route.id) }
            do {
                let targetState = !route.isActive
                if targetState {
                    try await routerService.activateRoute(route)
                } else {
                    try await routerService.deactivateRoute(route)
                }
                route.isActive = targetState
                try modelContext.save()
            } catch {
                presentMenuBarError(error)
            }
        }
    }

    private func toggle(_ group: RouteGroup) {
        guard !busyGroupIDs.contains(group.id), !group.routes.isEmpty else { return }
        busyGroupIDs.insert(group.id)

        Task { @MainActor in
            defer { busyGroupIDs.remove(group.id) }
            let targetState = groupState(group) != .active

            do {
                for route in group.routes where route.isActive != targetState {
                    if targetState {
                        try await routerService.activateRoute(route)
                    } else {
                        try await routerService.deactivateRoute(route)
                    }
                    route.isActive = targetState
                    // Persist each completed route so a later failure accurately leaves
                    // the menu in a mixed state matching the system route table.
                    try modelContext.save()
                }
            } catch {
                presentMenuBarError(error)
            }
        }
    }
}

@available(macOS 13, *)
private struct LegacyRouterMenuBarContent: View {
    @EnvironmentObject private var routerService: RouterService
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \RouteRuleMO.createdAt, ascending: true)],
        animation: .default
    ) private var routes: FetchedResults<RouteRuleMO>
    @State private var busyRouteIDs: Set<UUID> = []

    var body: some View {
        Menu(String(localized: "tray.routes")) {
            if routes.isEmpty {
                Text(String(localized: "tray.no_routes"))
            } else {
                ForEach(routes) { route in
                    Button {
                        toggle(route)
                    } label: {
                        Label(route.cidrNotation, systemImage: route.isActive ? "checkmark.circle.fill" : "circle")
                    }
                    .disabled(busyRouteIDs.contains(route.id) || routerService.helperStatus != .installed)
                }
            }
        }

        Divider()

        Button(String(localized: "tray.quit"), role: .destructive) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func toggle(_ route: RouteRuleMO) {
        guard !busyRouteIDs.contains(route.id) else { return }
        busyRouteIDs.insert(route.id)

        Task { @MainActor in
            defer { busyRouteIDs.remove(route.id) }
            do {
                if route.isActive {
                    try await routerService.deactivateRouteMO(route, context: context)
                } else {
                    try await routerService.activateRouteMO(route, context: context)
                }
            } catch {
                presentMenuBarError(error)
            }
        }
    }
}

private enum TrayGroupState {
    case inactive
    case mixed
    case active

    var symbolName: String {
        switch self {
        case .inactive: return "circle"
        case .mixed: return "minus.circle"
        case .active: return "checkmark.circle.fill"
        }
    }
}

@MainActor
private func presentMenuBarError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(localized: "tray.error.title")
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
}

// MARK: - Quit Coordination

/// Intercepts both the tray Quit button and the standard Command-Q action.
/// Active routes are removed before the process is allowed to terminate.
@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private weak var routerService: RouterService?
    private weak var legacyStack: LegacyPersistenceStack?
    private weak var mainWindow: NSWindow?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(routerService: RouterService, legacyStack: LegacyPersistenceStack) {
        self.routerService = routerService
        self.legacyStack = legacyStack

        // AppRootView has appeared, so its SwiftUI window is now available for
        // identifying when the main scene closes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: {
                $0.isVisible && $0.canBecomeMain
            }) else { return }

            self.mainWindow = window
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Returns true when an existing scene window was brought forward. A closed
    /// SwiftUI scene must be recreated by `openWindow(id:)` instead.
    func showExistingMainWindow() -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let mainWindow, mainWindow.isVisible else { return false }
        mainWindow.makeKeyAndOrderFront(nil)
        return true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard #available(macOS 13, *) else { return }
        guard let closingWindow = notification.object as? NSWindow else { return }
        guard closingWindow === mainWindow else { return }

        // willClose fires before the window becomes invisible. Defer the check
        // one run-loop turn, then hide the Dock icon if no app window remains.
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            let hasVisibleWindow = NSApp.windows.contains {
                $0.isVisible && $0.canBecomeMain
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Closing the last window is not the same as quitting. Keep the process,
    /// menu-bar extra, helper connection, and active routes alive until the user
    /// explicitly chooses Quit or presses Command-Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let routerService, let legacyStack else { return .terminateNow }

        let activeCount = activeRouteCount(legacyStack: legacyStack)
        guard activeCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "quit.confirm.title")
        alert.informativeText = String(
            format: String(localized: "quit.confirm.message"),
            activeCount
        )
        alert.addButton(withTitle: String(localized: "quit.confirm.disable_and_quit"))
        alert.addButton(withTitle: String(localized: "quit.confirm.cancel"))
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        terminationInProgress = true
        Task { @MainActor [weak self] in
            do {
                try await self?.deactivateAllRoutes(
                    routerService: routerService,
                    legacyStack: legacyStack
                )
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                self?.terminationInProgress = false
                let forceQuit = self?.presentQuitFailure(error) ?? false
                // This reply completes the already-pending termination request,
                // so Force Quit does not re-enter applicationShouldTerminate.
                sender.reply(toApplicationShouldTerminate: forceQuit)
            }
        }
        return .terminateLater
    }

    private func activeRouteCount(legacyStack: LegacyPersistenceStack) -> Int {
        if #available(macOS 14, *) {
            let context = StaticRouteHelperApp.sharedModelContainer.mainContext
            let descriptor = FetchDescriptor<RouteRule>(
                predicate: #Predicate { $0.isActive }
            )
            return (try? context.fetchCount(descriptor)) ?? 0
        }

        let request = NSFetchRequest<RouteRuleMO>(entityName: "RouteRuleMO")
        request.predicate = NSPredicate(format: "isActive == YES")
        return (try? legacyStack.viewContext.count(for: request)) ?? 0
    }

    private func deactivateAllRoutes(
        routerService: RouterService,
        legacyStack: LegacyPersistenceStack
    ) async throws {
        if #available(macOS 14, *) {
            let context = StaticRouteHelperApp.sharedModelContainer.mainContext
            let descriptor = FetchDescriptor<RouteRule>(
                predicate: #Predicate { $0.isActive }
            )
            let activeRoutes = try context.fetch(descriptor)

            for route in activeRoutes {
                try await routerService.deactivateRoute(route)
                route.isActive = false
                try context.save()
            }
            return
        }

        let context = legacyStack.viewContext
        let request = NSFetchRequest<RouteRuleMO>(entityName: "RouteRuleMO")
        request.predicate = NSPredicate(format: "isActive == YES")
        let activeRoutes = try context.fetch(request)

        for route in activeRoutes {
            try await routerService.deactivateRouteMO(route, context: context)
        }
    }

    /// Returns true only when the user explicitly accepts that routes may remain
    /// active and chooses to terminate the process anyway.
    private func presentQuitFailure(_ error: Error) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "quit.failure.title")
        alert.informativeText = String(
            format: String(localized: "quit.failure.message"),
            error.localizedDescription
        )
        alert.addButton(withTitle: String(localized: "quit.failure.keep_running"))
        alert.addButton(withTitle: String(localized: "quit.failure.force_quit"))
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
