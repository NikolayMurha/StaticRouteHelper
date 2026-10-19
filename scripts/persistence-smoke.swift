import Foundation
import SwiftData

@main
struct PersistenceSmokeTest {
    static func main() throws {
        guard #available(macOS 14, *) else { return }

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaticRoutePersistenceSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let storeURL = testDirectory.appendingPathComponent(PersistenceController.storeFileName)
        try writeInitialData(to: storeURL)
        try verifyAndModifyData(at: storeURL)
        try verifySecondLaunch(at: storeURL)

        print("Persistence smoke test passed")
    }

    @available(macOS 14, *)
    private static func writeInitialData(to storeURL: URL) throws {
        let container = try PersistenceController.makeModelContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let group = RouteGroup(name: "Office VPN", iconName: "building.2")
        let route = RouteRule(
            network: "10.42.0.0",
            prefixLength: 16,
            gatewayType: .ipAddress,
            gateway: "192.168.1.1",
            groups: [group]
        )
        context.insert(group)
        context.insert(route)
        try context.save()

        guard group.routes.count == 1 else {
            throw SmokeTestError.inverseRelationshipMissing
        }
    }

    @available(macOS 14, *)
    private static func verifyAndModifyData(at storeURL: URL) throws {
        let container = try PersistenceController.makeModelContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let groups = try context.fetch(FetchDescriptor<RouteGroup>())
        let routes = try context.fetch(FetchDescriptor<RouteRule>())

        guard groups.count == 1, routes.count == 1 else {
            throw SmokeTestError.recordCountMismatch(groups: groups.count, routes: routes.count)
        }
        guard routes[0].groups.first?.name == "Office VPN", groups[0].routes.count == 1 else {
            throw SmokeTestError.relationshipNotRestored
        }

        groups[0].name = "Corp VPN"
        routes[0].gatewayType = .interface
        routes[0].gateway = "utun7"
        try context.save()
    }

    @available(macOS 14, *)
    private static func verifySecondLaunch(at storeURL: URL) throws {
        let container = try PersistenceController.makeModelContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let groups = try context.fetch(FetchDescriptor<RouteGroup>())
        let routes = try context.fetch(FetchDescriptor<RouteRule>())

        guard
            groups.first?.name == "Corp VPN",
            routes.first?.groups.first?.name == "Corp VPN",
            routes.first?.gatewayType == .interface,
            routes.first?.gateway == "utun7"
        else {
            throw SmokeTestError.updatedGroupNotRestored
        }
    }
}

private enum SmokeTestError: Error {
    case inverseRelationshipMissing
    case recordCountMismatch(groups: Int, routes: Int)
    case relationshipNotRestored
    case updatedGroupNotRestored
}
