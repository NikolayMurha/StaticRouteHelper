//
//  PersistenceController.swift
//  StaticRouteHelper
//

import CoreData
import Foundation
import SwiftData

/// Creates the SwiftData container at an application-specific URL.
///
/// SwiftData's default URL for an unsandboxed app is
/// `~/Library/Application Support/default.store`. That filename is not scoped
/// to the bundle and can therefore be opened by unrelated unsandboxed apps.
@available(macOS 14, *)
enum PersistenceController {
    static let storeFileName = "StaticRouter.store"
    private static let legacyDefaultStoreFileName = "default.store"

    static func makeModelContainer(storeURL explicitStoreURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema([RouteRule.self, RouteGroup.self])
        let storeURL: URL

        if let explicitStoreURL {
            storeURL = explicitStoreURL
        } else {
            storeURL = try applicationStoreURL()
            try recoverLegacyDefaultStoreIfNeeded(destinationURL: storeURL)
        }

        let configuration = ModelConfiguration(
            "StaticRouter",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func applicationStoreURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "cn.magicdian.staticrouter"
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PersistenceError.applicationSupportUnavailable
        }

        let directory = applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(storeFileName)
    }

    /// Copies the old generic SwiftData store once, but only when Core Data
    /// metadata proves that it contains this application's two model entities.
    private static func recoverLegacyDefaultStoreIfNeeded(
        destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !fileManager.fileExists(atPath: destinationURL.path) else { return }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PersistenceError.applicationSupportUnavailable
        }

        let sourceURL = applicationSupport.appendingPathComponent(legacyDefaultStoreFileName)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        guard isStaticRouterStore(at: sourceURL) else {
            print("[Persistence] Existing default.store does not belong to Static Router; leaving it untouched.")
            return
        }

        // The shared-memory sidecar is process-local and is rebuilt by SQLite.
        // Copy the main file last so an interrupted import is retried next launch.
        var copiedURLs: [URL] = []
        do {
            for suffix in ["-wal", ""] {
                let source = URL(fileURLWithPath: sourceURL.path + suffix)
                let destination = URL(fileURLWithPath: destinationURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: destination)
                copiedURLs.append(destination)
            }
        } catch {
            for copiedURL in copiedURLs {
                try? fileManager.removeItem(at: copiedURL)
            }
            throw error
        }
        print("[Persistence] Recovered the previous SwiftData store at \(destinationURL.path).")
    }

    private static func isStaticRouterStore(at url: URL) -> Bool {
        guard
            let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite,
                at: url
            ),
            let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data]
        else {
            return false
        }

        let entityNames = Set(hashes.keys)
        return entityNames.contains("RouteRule") && entityNames.contains("RouteGroup")
    }
}

enum PersistenceError: LocalizedError {
    case applicationSupportUnavailable
    case invalidLegacyRecord
    case objectNoLongerExists

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Application Support directory is unavailable."
        case .invalidLegacyRecord:
            return "A legacy route record is incomplete."
        case .objectNoLongerExists:
            return "The item no longer exists in the persistent store. Reopen the window and try again."
        }
    }
}
