import XCTest
@testable import FnMusic

final class KeychainHashTests: XCTestCase {
    /// Known SHA-256 vectors; no Keychain access happens in these tests.
    func testPasswordHashKnownVectors() {
        XCTAssertEqual(
            KeychainStore.passwordHash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            KeychainStore.passwordHash(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testPasswordHashHandlesMultibyteInput() {
        XCTAssertEqual(
            KeychainStore.passwordHash("测试"),
            "6aa8f49cc992dfd75a114269ed26de0ad6d4e7d7a70d9c8afb3d7a57a88a73ed"
        )
    }

    func testPasswordHashIsDeterministicAndLowerCaseHex() {
        let first = KeychainStore.passwordHash("password-密码-🔒")
        let second = KeychainStore.passwordHash("password-密码-🔒")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { $0.isLowercase || $0.isNumber }, "hex output must stay lower-case letters and digits")
    }
}
