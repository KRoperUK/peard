import XCTest
@testable import PeardCore

/// What survives of a rejected write.
///
/// PocketBase puts a generic sentence at the top level and the actual reason
/// underneath it. Only the generic one used to reach the app, so every
/// validation failure anywhere in Pear'd read "Failed to create record." — the
/// same sentence whether an address was taken or a password too short.
final class ErrorDetailTests: XCTestCase {
    private func message(_ json: String) -> String? {
        APIClient.errorMessage(in: Data(json.utf8))
    }

    func testFieldDetailWinsOverTheGenericMessage() {
        let json = """
        {"code":400,"message":"Failed to create record.",
         "data":{"email":{"code":"validation_not_unique","message":"Value must be unique."}}}
        """

        XCTAssertEqual(message(json), "email: Value must be unique.")
    }

    /// The field name is kept because "Value must be unique." on its own does
    /// not say which value.
    func testTheFieldNameIsIncluded() {
        let json = #"{"message":"x","data":{"password":{"message":"The length must be at least 8."}}}"#

        XCTAssertEqual(message(json), "password: The length must be at least 8.")
    }

    func testTheTopLevelMessageIsUsedWhenThereIsNoFieldDetail() {
        XCTAssertEqual(message(#"{"code":404,"message":"Missing record."}"#), "Missing record.")
    }

    func testAnEmptyDataObjectFallsBackToTheMessage() {
        XCTAssertEqual(message(#"{"message":"Nope.","data":{}}"#), "Nope.")
    }

    /// Several fields can fail at once. Sorting means the same rejection always
    /// produces the same sentence, rather than one that changes between runs
    /// with dictionary ordering.
    func testMultipleFieldErrorsAreReportedDeterministically() {
        let json = """
        {"message":"Failed.","data":{"password":{"message":"Too short."},"email":{"message":"Taken."}}}
        """

        XCTAssertEqual(message(json), "email: Taken.")
    }

    func testAFieldEntryWithNoMessageIsSkipped() {
        let json = #"{"message":"Failed.","data":{"email":{"code":"x"},"password":{"message":"Too short."}}}"#

        XCTAssertEqual(message(json), "password: Too short.")
    }

    func testNonJSONYieldsNothing() {
        XCTAssertNil(message("<html>502 Bad Gateway</html>"))
    }

    func testAnEmptyMessageIsNotReported() {
        XCTAssertNil(message(#"{"message":""}"#))
    }
}
