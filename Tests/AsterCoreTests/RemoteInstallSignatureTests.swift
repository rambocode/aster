import CryptoKit
import Foundation
import Testing

@testable import AsterCore

/// P8.2：Ed25519 测试签名链的签名/验签循环、篡改拒绝、产物类型策略。
///
/// 测试密钥对仅用于验收，不是生产签名基础设施。

// MARK: - 测试密钥对

/// 测试私钥 raw bytes（base64 编码）。仅存在于测试 fixture 中，不编译进 release 产物。
private let testPrivateKeyBase64 = "dp8JPNFseHLLQpTy3YsH1qic5bWNNSQ0ePJwpn7AGMM="

/// 与 `RemoteInstallSignature.testPublicKeyBase64` 对应的公钥。
/// 验证测试密钥对匹配：私钥派生出的公钥必须等于代码常量。
private let expectedPublicKeyBase64 = RemoteInstallSignature.testPublicKeyBase64

// MARK: - 样例

private let sampleDigest = String(repeating: "ab", count: 32)

private func signedManifest(
  digest: String = sampleDigest,
  kind: RemoteArtifactKind = .managedRelease
) throws -> RemoteReleaseManifest {
  let signature = try RemoteInstallSignature.sign(
    sha256Hex: digest,
    privateKeyRaw: Data(base64Encoded: testPrivateKeyBase64)!)
  return RemoteReleaseManifest(
    version: "1.0.0",
    platform: "linux",
    architecture: "x86_64",
    sha256: digest,
    sizeBytes: 2048,
    signature: signature,
    artifactKind: kind,
    protocolMajor: 1,
    protocolMinor: 0)
}

// MARK: - 用例

@Test func testKeyPairMatches() throws {
  // 验证代码常量里的测试公钥确实与测试私钥配对。
  let derived = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: testPrivateKeyBase64)!).publicKey.rawRepresentation.base64EncodedString()
  #expect(derived == expectedPublicKeyBase64)
}

@Test func signAndVerifyRoundTrip() throws {
  let manifest = try signedManifest()
  let result = RemoteInstallSignature.verify(
    manifest: manifest, publicKeyBase64: expectedPublicKeyBase64)
  #expect(result == true)
}

@Test func tamperedDigestIsRejected() throws {
  var manifest = try signedManifest()
  // 篡改摘要的最后两位
  manifest.sha256 = String(repeating: "ab", count: 31) + "ff"
  let result = RemoteInstallSignature.verify(
    manifest: manifest, publicKeyBase64: expectedPublicKeyBase64)
  #expect(result == false)
}

@Test func tamperedSignatureIsRejected() throws {
  var manifest = try signedManifest()
  // 替换成垃圾签名
  manifest.signature = Data(repeating: 0xDE, count: 64).base64EncodedString()
  let result = RemoteInstallSignature.verify(
    manifest: manifest, publicKeyBase64: expectedPublicKeyBase64)
  #expect(result == false)
}

@Test func wrongPublicKeyIsRejected() throws {
  let manifest = try signedManifest()
  // 用另一把密钥的公钥验证
  let otherKey = Curve25519.Signing.PrivateKey()
  let otherPub = otherKey.publicKey.rawRepresentation.base64EncodedString()
  let result = RemoteInstallSignature.verify(manifest: manifest, publicKeyBase64: otherPub)
  #expect(result == false)
}

@Test func missingSignatureReturnsFalse() {
  let manifest = RemoteReleaseManifest(
    version: "1.0.0", platform: "linux", architecture: "x86_64",
    sha256: sampleDigest, sizeBytes: 2048, signature: nil,
    artifactKind: .managedRelease)
  let result = RemoteInstallSignature.verify(
    manifest: manifest, publicKeyBase64: expectedPublicKeyBase64)
  #expect(result == false)
}

@Test func testArtifactBypassesSignature() throws {
  // testArtifact 不需要签名，验证逻辑在 validateProvenance 里跳过。
  let manifest = RemoteReleaseManifest(
    version: "1.0.0", platform: "linux", architecture: "x86_64",
    sha256: sampleDigest, sizeBytes: 2048, signature: nil,
    artifactKind: .testArtifact)
  // validateProvenance 对 testArtifact 直接 return，不调用 signatureVerifier。
  #expect(throws: Never.self) {
    try RemoteInstallValidation.validate(
      manifest: manifest,
      localDigest: sampleDigest,
      localSize: 2048,
      remotePlatform: "linux",
      remoteArchitecture: "x86_64",
      acceptDevelopmentArtifact: false,
      signatureVerifier: { _ in false })  // 即使返回 false 也不影响 testArtifact
  }
}

@Test func managedReleaseWithoutSignatureFails() {
  let manifest = RemoteReleaseManifest(
    version: "1.0.0", platform: "linux", architecture: "x86_64",
    sha256: sampleDigest, sizeBytes: 2048, signature: nil,
    artifactKind: .managedRelease)
  do {
    try RemoteInstallValidation.validate(
      manifest: manifest,
      localDigest: sampleDigest,
      localSize: 2048,
      remotePlatform: "linux",
      remoteArchitecture: "x86_64",
      acceptDevelopmentArtifact: false,
      signatureVerifier: RemoteInstallSignature.testVerifier())
    Issue.record("expected missingSignature error")
  } catch let error as RemoteInstallValidationError {
    #expect(error == .missingSignature)
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}

@Test func managedReleaseWithInvalidSignatureFails() throws {
  var manifest = try signedManifest()
  manifest.signature = "AAAA"  // 格式对但签名不对
  do {
    try RemoteInstallValidation.validate(
      manifest: manifest,
      localDigest: sampleDigest,
      localSize: 2048,
      remotePlatform: "linux",
      remoteArchitecture: "x86_64",
      acceptDevelopmentArtifact: false,
      signatureVerifier: RemoteInstallSignature.testVerifier())
    Issue.record("expected signatureInvalid error")
  } catch let error as RemoteInstallValidationError {
    #expect(error == .signatureInvalid)
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}

@Test func managedReleaseWithValidSignaturePasses() throws {
  let manifest = try signedManifest()
  #expect(throws: Never.self) {
    try RemoteInstallValidation.validate(
      manifest: manifest,
      localDigest: sampleDigest,
      localSize: 2048,
      remotePlatform: "linux",
      remoteArchitecture: "x86_64",
      acceptDevelopmentArtifact: false,
      signatureVerifier: RemoteInstallSignature.testVerifier())
  }
}

@Test func protocolVersionFieldsRoundTrip() throws {
  let manifest = try signedManifest()
  #expect(manifest.protocolMajor == 1)
  #expect(manifest.protocolMinor == 0)
  let data = try JSONEncoder().encode(manifest)
  let decoded = try JSONDecoder().decode(RemoteReleaseManifest.self, from: data)
  #expect(decoded.protocolMajor == 1)
  #expect(decoded.protocolMinor == 0)
  #expect(decoded == manifest)
}

@Test func protocolVersionFieldsDefaultToNil() {
  let manifest = RemoteReleaseManifest(
    version: "0.9.0", platform: "linux", architecture: "x86_64",
    sha256: sampleDigest, sizeBytes: 1024, artifactKind: .testArtifact)
  #expect(manifest.protocolMajor == nil)
  #expect(manifest.protocolMinor == nil)
}
