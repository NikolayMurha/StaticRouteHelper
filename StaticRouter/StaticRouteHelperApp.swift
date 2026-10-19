//
//  StaticRouteHelperApp.swift
//  StaticRouteHelper
//

import SwiftUI
import CoreData
import SwiftData

@main
struct StaticRouteHelperApp: App {

    static let mainWindowID = "main-window"

    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self)
    private var applicationDelegate

    // RouterService uses ObservableObject so @StateObject works on macOS 12+
    @StateObject private var routerService = RouterService()

    // Legacy Core Data stack (macOS 12–13). Always initialized, only used on older OS.
    @StateObject private var legacyStack = LegacyPersistenceStack()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            appRootView
        }
        .commands { MenuBarCommand() }

        Settings {
            SettingsView()
                .environmentObject(routerService)
                .environmentObject(legacyStack)
                .environment(\.managedObjectContext, legacyStack.viewContext)
        }

        if #available(macOS 13, *) {
            MenuBarExtra {
                RouterMenuBarContent()
                    .environmentObject(routerService)
                    .environmentObject(legacyStack)
                    .environment(\.managedObjectContext, legacyStack.viewContext)
            } label: {
                Label("Static Router", systemImage: "network")
                    .accessibilityLabel("Static Router")
            }
            .menuBarExtraStyle(.menu)
        }
    }

    private var appRootView: some View {
        AppRootView()
            .environmentObject(routerService)
            .environmentObject(legacyStack)
            .environment(\.managedObjectContext, legacyStack.viewContext)
            .onAppear {
                applicationDelegate.configure(
                    routerService: routerService,
                    legacyStack: legacyStack
                )
            }
            .task { await onStartup() }
            .onReceive(NotificationCenter.default.publisher(for: .routeDidChange)) { note in
                handleRouteChange(note)
            }
    }

    // MARK: - Startup

    private func onStartup() async {
        if #available(macOS 14, *) {
            await startupCalibration14()
        } else {
            await routerService.refreshSystemRoutes()
        }
    }

    @available(macOS 14, *)
    private func startupCalibration14() async {
        let context = Self.sharedModelContainer.mainContext

        // Migrate old Core Data (CoreDataMigrator – pre-existing v1.3 → v1.4)
        CoreDataMigrator.migrateIfNeeded(into: context)

        // Migrate legacy Core Data (macOS 12–13 store) if user upgraded OS
        migrateLegacyStoreIfNeeded14(into: context)

        await routerService.refreshSystemRoutes()

        let descriptor = FetchDescriptor<RouteRule>()
        do {
            let rules = try context.fetch(descriptor)
            RouteStateCalibrator.calibrate(rules: rules, systemRoutes: routerService.systemRoutes)
            try context.save()
        } catch {
            context.rollback()
            print("[Persistence] Startup route calibration could not be saved: \(error)")
        }
    }

    // MARK: - Legacy → SwiftData Migration

    @available(macOS 14, *)
    private func migrateLegacyStoreIfNeeded14(into context: ModelContext) {
        guard legacyStack.storeFileExists else { return }

        let routeData: [[String: Any]]
        do {
            routeData = try legacyStack.fetchAllRouteData()
        } catch {
            print("[Migration] Could not read macOS 12–13 store; preserving it: \(error)")
            return
        }
        guard !routeData.isEmpty else {
            legacyStack.deleteLegacyStoreFiles()
            return
        }

        do {
            let existingRules = try context.fetch(FetchDescriptor<RouteRule>())
            var existingIDs = Set(existingRules.map(\.id))

            for data in routeData {
                guard
                    let id = data["id"] as? UUID,
                    let network = data["network"] as? String,
                    let prefixLength = data["prefixLength"] as? Int,
                    let gatewayTypeRaw = data["gatewayType"] as? String,
                    let gateway = data["gateway"] as? String
                else {
                    throw PersistenceError.invalidLegacyRecord
                }
                guard existingIDs.insert(id).inserted else { continue }

                let gatewayType: GatewayType = gatewayTypeRaw == "ipAddress" ? .ipAddress : .interface
                let isActive = data["isActive"] as? Bool ?? false
                let createdAt = data["createdAt"] as? Date ?? Date()

                let rule = RouteRule(
                    id: id,
                    network: network,
                    prefixLength: prefixLength,
                    gatewayType: gatewayType,
                    gateway: gateway,
                    isActive: isActive,
                    groups: [],
                    createdAt: createdAt
                )
                context.insert(rule)
            }

            try context.save()
            legacyStack.deleteLegacyStoreFiles()
        } catch {
            context.rollback()
            print("[Migration] Could not save macOS 12–13 routes; preserving the source store: \(error)")
        }
    }

    // MARK: - Route Change Notification Handler

    @MainActor
    private func handleRouteChange(_ notification: Notification) {
        guard #available(macOS 14, *) else { return }
        guard
            let destination = notification.userInfo?["destination"] as? String,
            let gateway = notification.userInfo?["gateway"] as? String,
            let isAdd = notification.userInfo?["isAdd"] as? Bool
        else { return }

        let context = Self.sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<RouteRule>()
        let rules: [RouteRule]
        do {
            rules = try context.fetch(descriptor)
        } catch {
            print("[Persistence] Could not fetch routes after a system route change: \(error)")
            return
        }

        var changed = false
        for rule in rules {
            guard rule.network == destination && rule.gateway == gateway else { continue }
            if rule.isActive != isAdd {
                rule.isActive = isAdd
                changed = true
            }
        }
        if changed {
            do {
                try context.save()
            } catch {
                context.rollback()
                print("[Persistence] Could not save route state update: \(error)")
            }
        }
    }

    // MARK: - SwiftData Container

    @available(macOS 14, *)
    static let sharedModelContainer: ModelContainer = {
        do {
            return try PersistenceController.makeModelContainer()
        } catch {
            fatalError("ModelContainer initialization failed: \(error)")
        }
    }()
}

// MARK: - AppRootView

/// Root view that injects .modelContainer on macOS 14+, passes through on macOS 12–13.
struct AppRootView: View {
    var body: some View {
        if #available(macOS 14, *) {
            MainWindow()
                .modelContainer(StaticRouteHelperApp.sharedModelContainer)
        } else {
            MainWindow()
        }
    }
}
