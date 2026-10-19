//
//  CoreDataMigrator.swift
//  StaticRouteHelper
//
//  迁移逻辑：检测旧 Core Data 存储，将 JSON blob 路由数据导入 SwiftData，然后删除旧存储。

import Foundation
import CoreData
import SwiftData

/// 旧版 routeData 结构体（用于解码 Core Data JSON blob）
private struct LegacyRouteData: Codable {
    var network: String
    var mask: String
    var gateway: String
    var interface: String
    var isOn: Bool
}

/// Core Data → SwiftData 数据迁移工具
@available(macOS 14, *)
enum CoreDataMigrator {

    /// 执行迁移：若旧 Core Data 存储存在，则读取并导入，然后删除旧存储。
    /// 应在 ModelContainer 初始化完成后、视图加载前调用。
    static func migrateIfNeeded(into context: ModelContext) {
        guard let storeURL = legacyStoreURL() else { return }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        print("[Migration] Found legacy Core Data store; starting migration.")

        do {
            let legacyRoutes = try readLegacyRoutes(storeURL: storeURL)
            if !legacyRoutes.isEmpty {
                let importedCount = try importRoutes(legacyRoutes, into: context)
                print("[Migration] Imported \(importedCount) new routes.")
            } else {
                print("[Migration] Legacy store is empty.")
            }
        } catch {
            context.rollback()
            // Never destroy the source store when loading, decoding, or saving failed.
            print("[Migration] Migration failed; legacy store was preserved: \(error)")
            return
        }

        do {
            try deleteLegacyStore(storeURL: storeURL)
            print("[Migration] Removed legacy store after successful migration.")
        } catch {
            // Imported routes are retained; the idempotent import makes a later
            // retry safe if the source files could not be removed this time.
            print("[Migration] Routes were imported, but the legacy store could not be removed: \(error)")
        }
    }

    // MARK: - Private

    /// 旧 Core Data 存储文件 URL（默认位置：Application Support/DataModel.sqlite）
    private static func legacyStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        // NSPersistentContainer 默认将数据库放在 Application Support/<BundleID>/DataModel.sqlite
        // 但实际路径取决于应用 bundle ID；先尝试带 bundle ID 的路径，再尝试直接路径
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let withID = appSupport.appendingPathComponent(bundleID).appendingPathComponent("DataModel.sqlite")
        if FileManager.default.fileExists(atPath: withID.path) { return withID }
        let direct = appSupport.appendingPathComponent("DataModel.sqlite")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return nil
    }

    /// 读取旧 Core Data 中的路由数据（JSON blob）
    private static func readLegacyRoutes(storeURL: URL) throws -> [LegacyRouteData] {
        // 临时构建一个不持久化到现有路径的 NSPersistentContainer 读取旧数据
        guard let modelURL = Bundle.main.url(forResource: "DataModel", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw MigrationError.legacyModelUnavailable
        }

        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.isReadOnly = true
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            defer { semaphore.signal() }
            loadError = error
        }
        semaphore.wait()
        if let loadError { throw loadError }

        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "RouteData")
        let objects = try container.viewContext.fetch(fetchRequest)
        let decoder = JSONDecoder()
        var routes: [LegacyRouteData] = []
        for object in objects {
            guard let data = object.value(forKey: "values") as? Data else {
                throw MigrationError.invalidLegacyRecord
            }
            routes.append(contentsOf: try decoder.decode([LegacyRouteData].self, from: data))
        }

        return routes
    }

    /// 将旧路由数据导入 SwiftData（isActive = false，groups = 空）
    private static func importRoutes(_ routes: [LegacyRouteData], into context: ModelContext) throws -> Int {
        let existingRoutes = try context.fetch(FetchDescriptor<RouteRule>())
        var identities = Set(existingRoutes.map {
            RouteIdentity(
                network: $0.network,
                prefixLength: $0.prefixLength,
                gatewayType: $0.gatewayType.rawValue,
                gateway: $0.gateway
            )
        })
        var importedCount = 0

        for legacy in routes {
            // 将子网掩码转换为前缀长度
            let prefixLength = prefixLengthFromMask(legacy.mask)
            // 判断是 IP 网关还是接口路由（旧版本用 interface 字段区分）
            let gatewayType: GatewayType
            let gateway: String
            if !legacy.interface.trimmingCharacters(in: .whitespaces).isEmpty {
                gatewayType = .interface
                gateway = legacy.interface
            } else {
                gatewayType = .ipAddress
                gateway = legacy.gateway
            }

            let identity = RouteIdentity(
                network: legacy.network,
                prefixLength: prefixLength,
                gatewayType: gatewayType.rawValue,
                gateway: gateway
            )
            guard identities.insert(identity).inserted else { continue }

            let rule = RouteRule(
                network: legacy.network,
                prefixLength: prefixLength,
                gatewayType: gatewayType,
                gateway: gateway,
                isActive: false
            )
            context.insert(rule)
            importedCount += 1
        }
        try context.save()
        return importedCount
    }

    /// 删除旧 Core Data 存储及相关文件（.sqlite, -wal, -shm）
    private static func deleteLegacyStore(storeURL: URL) throws {
        let fm = FileManager.default
        let extensions = ["", "-wal", "-shm"]
        for ext in extensions {
            let url = URL(fileURLWithPath: storeURL.path + ext)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
    }

    /// 将子网掩码字符串（如 "255.255.255.0"）转换为前缀长度（如 24）
    private static func prefixLengthFromMask(_ mask: String) -> Int {
        let parts = mask.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 24 } // 默认值
        let combined: UInt32 = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        return combined.nonzeroBitCount
    }
}

private enum MigrationError: LocalizedError {
    case legacyModelUnavailable
    case invalidLegacyRecord

    var errorDescription: String? {
        switch self {
        case .legacyModelUnavailable:
            return "DataModel.momd is missing from the application bundle."
        case .invalidLegacyRecord:
            return "A legacy RouteData record has no decodable values payload."
        }
    }
}

private struct RouteIdentity: Hashable {
    let network: String
    let prefixLength: Int
    let gatewayType: String
    let gateway: String
}
