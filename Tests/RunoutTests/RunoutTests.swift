import XCTest
@testable import Runout

final class RunoutTests: XCTestCase {
    func testProjectRoundTripsThroughJSON() throws {
        let now = Date(timeIntervalSince1970: 0)
        let project = Project(name: "Test Album", createdAt: now, modifiedAt: now)

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.schemaVersion, Project.currentSchemaVersion)
    }
}
