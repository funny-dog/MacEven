import Foundation
import MacEvenCore

final class UpdateIntegrityTests {

    func testParseChecksum() throws {
        let hash = String(repeating: "ab", count: 32)
        // 64 位小写 hex + 文件名（shasum 格式）
        XCTAssertEqual(UpdateIntegrity.parseChecksum("\(hash)  MacEven-v1.0.0.zip\n"), hash)
        // 过滤首尾空白与制表符
        XCTAssertEqual(UpdateIntegrity.parseChecksum(" \t\(hash)  archive.tar.gz \r\n"), hash)
        // 64 位大写 hex 应归一化为小写
        XCTAssertEqual(UpdateIntegrity.parseChecksum(hash.uppercased()), hash)
        XCTAssertEqual(UpdateIntegrity.parseChecksum("  \(hash.uppercased())  "), hash)

        // 拒绝空或空白内容
        XCTAssertNil(UpdateIntegrity.parseChecksum(""))
        XCTAssertNil(UpdateIntegrity.parseChecksum("   \t\r\n"))

        // 拒绝 HTML 错误页
        XCTAssertNil(UpdateIntegrity.parseChecksum("<!DOCTYPE html><html>Not Found</html>"))

        // 拒绝长度不符（63 位、65 位）
        XCTAssertNil(UpdateIntegrity.parseChecksum(String(repeating: "a", count: 63)))
        XCTAssertNil(UpdateIntegrity.parseChecksum(String(repeating: "a", count: 65)))

        // 拒绝包含非十六进制字符
        XCTAssertNil(UpdateIntegrity.parseChecksum(String(repeating: "g", count: 64)))
        XCTAssertNil(UpdateIntegrity.parseChecksum(String(repeating: "ab", count: 31) + "xy"))

        // 拒绝非 ASCII 字符（即使是全角十六进制或中文）
        let fullWidthHex = String(repeating: "ａ", count: 64)
        XCTAssertNil(UpdateIntegrity.parseChecksum(fullWidthHex))
        let nonAscii = String(repeating: "a", count: 63) + "哈"
        XCTAssertNil(UpdateIntegrity.parseChecksum(nonAscii))
    }

    func testParseAssetDigest() throws {
        let hash = String(repeating: "cd", count: 32)
        // 正确解析 sha256:...
        XCTAssertEqual(UpdateIntegrity.parseAssetDigest("sha256:\(hash)"), hash)
        // 前缀与哈希大小写容忍，统一归一化为小写
        XCTAssertEqual(UpdateIntegrity.parseAssetDigest("SHA256:\(hash.uppercased())"), hash)
        XCTAssertEqual(UpdateIntegrity.parseAssetDigest("Sha256:\(hash)"), hash)
        // 过滤前后空白
        XCTAssertEqual(UpdateIntegrity.parseAssetDigest("  sha256:\(hash)\n"), hash)

        // 缺失 digest 或为空
        XCTAssertNil(UpdateIntegrity.parseAssetDigest(nil))
        XCTAssertNil(UpdateIntegrity.parseAssetDigest(""))
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("   \n\t"))

        // 缺少算法前缀
        XCTAssertNil(UpdateIntegrity.parseAssetDigest(hash))

        // 拒绝非 sha256 算法
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("sha512:\(hash)"))
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("sha1:\(hash)"))
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("md5:\(hash)"))

        // 拒绝畸形、长度不足或超长
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("sha256:"))
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("sha256:\(hash.dropLast())"))
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("sha256:\(hash)ff"))

        // 拒绝非十六进制或非 ASCII
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("sha256:\(String(repeating: "z", count: 64))"))
        XCTAssertNil(UpdateIntegrity.parseAssetDigest("sha256:\(String(repeating: "ｃ", count: 64))"))
    }

    func testSigningRequirements() throws {
        let req = UpdateIntegrity.signingRequirements(
            bundleIdentifier: "com.maceven.app",
            leafCertificateSHA1: "A1B2C3D4E5F60718293A4B5C6D7E8F9012345678"
        )
        XCTAssertEqual(
            req,
            "identifier \"com.maceven.app\" and certificate leaf = H\"A1B2C3D4E5F60718293A4B5C6D7E8F9012345678\""
        )
    }

    func testCodeSignatureCheck() throws {
        // 1. 测试当前编译可执行文件
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        guard let requirement = CodeSignatureCheck.designatedRequirement(ofCodeAt: execURL) else {
            throw TestFailure(message: "无法读取当前可执行文件的 designated requirement: \(execURL.path)")
        }
        XCTAssertTrue(!requirement.isEmpty, "designated requirement 不应为空")
        XCTAssertTrue(CodeSignatureCheck.codeAt(execURL, satisfies: requirement), "当前可执行文件必须满足自身的 designated requirement")

        // 传入不匹配的 requirement 规则应返回 false
        XCTAssertFalse(CodeSignatureCheck.codeAt(execURL, satisfies: "identifier \"com.maceven.nonexistent.fake\""))

        // 传入非法语法 requirement 应安全返回 false 而非崩溃
        XCTAssertFalse(CodeSignatureCheck.codeAt(execURL, satisfies: "invalid syntax requirement !!!@@#"))

        // 当前编译出来的可执行文件通常是 ad-hoc 签名，无证书指纹
        let selfLeaf = CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: execURL)
        if let selfLeaf {
            XCTAssertEqual(selfLeaf.count, 40)
        }

        // 2. 测试系统自带证书签名的二进制（/bin/ls）
        let lsURL = URL(fileURLWithPath: "/bin/ls")
        if FileManager.default.fileExists(atPath: lsURL.path) {
            guard let lsReq = CodeSignatureCheck.designatedRequirement(ofCodeAt: lsURL) else {
                throw TestFailure(message: "无法读取 /bin/ls 的 designated requirement")
            }
            XCTAssertTrue(CodeSignatureCheck.codeAt(lsURL, satisfies: lsReq))

            guard let lsLeaf = CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: lsURL) else {
                throw TestFailure(message: "无法读取 /bin/ls 的叶子证书 SHA-1")
            }
            XCTAssertEqual(lsLeaf.count, 40)
            XCTAssertTrue(lsLeaf.allSatisfy { $0.isASCII && $0.isHexDigit }, "证书指纹应全为 ASCII 十六进制")

            // 配合 UpdateIntegrity.signingRequirements 校验
            let validReq = UpdateIntegrity.signingRequirements(bundleIdentifier: "com.apple.ls", leafCertificateSHA1: lsLeaf)
            XCTAssertTrue(CodeSignatureCheck.codeAt(lsURL, satisfies: validReq), "/bin/ls 应满足正确 bundle id 与自身证书的签名规则")

            let invalidIdReq = UpdateIntegrity.signingRequirements(bundleIdentifier: "com.apple.notls", leafCertificateSHA1: lsLeaf)
            XCTAssertFalse(CodeSignatureCheck.codeAt(lsURL, satisfies: invalidIdReq), "bundle id 不匹配时必须被拒绝")
        }

        // 3. 测试不存在的文件
        let nonexistent = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)")
        XCTAssertNil(CodeSignatureCheck.designatedRequirement(ofCodeAt: nonexistent))
        XCTAssertFalse(CodeSignatureCheck.codeAt(nonexistent, satisfies: "identifier \"com.apple.ls\""))
        XCTAssertNil(CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: nonexistent))
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
