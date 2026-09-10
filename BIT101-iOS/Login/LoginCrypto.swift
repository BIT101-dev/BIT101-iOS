//
//  LoginCrypto.swift
//  BIT101-iOS
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Android 端登录流程依赖的加密算法。
///
/// iOS 端为了兼容现有后端和学校登录链路，需要严格复刻 Android 端的密码处理逻辑。
enum LoginCrypto {
    static let schoolURLCryptoPublicKey = """
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjVr1zKwohU3xA0afprWLSQvIymaSH/V27MedFc+CecXSnORIFMAp4uEIb4taDq/2X4eMeTI66Mu/rB5GKSFDbExF2Gu4NaO/CNDpf1gHMScUrIFCh4CDqzBnx17kclvezLkIK0T8FVa4cRsINvzjbnA6jUSMaf6Fm1n9wTAtW6QYBjssGOEtCj+c38PTBdFMmJbXp3brt1tEBesz6lb3Fjp76FGvDZ08xtYG8fxYPuiMwKU04eS+mcX/BunwgpU3zwekHYB+PWRIvq0lBry9Wms25sJE5T/RAv5fEuMLbBkfcZK3+7ivSZthTmPpr2Ap/ji70ZZ6u2jvR5VJq+LJHQIDAQAB
    -----END PUBLIC KEY-----
    """

    /// 复刻 Android 端的 AES 加密逻辑，用于学校登录表单和 WebVPN 校验。
    static func encryptPassword(_ password: String, saltBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: saltBase64) else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        let inputData = Data(password.utf8)
        var outputData = Data(count: inputData.count + kCCBlockSizeAES128)
        let outputBufferSize = outputData.count
        var outputLength: size_t = 0

        let status = outputData.withUnsafeMutableBytes { outputBytes in
            inputData.withUnsafeBytes { inputBytes in
                keyData.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        keyData.count,
                        nil,
                        inputBytes.baseAddress,
                        inputData.count,
                        outputBytes.baseAddress,
                        outputBufferSize,
                        &outputLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw LoginServiceError.invalidSchoolLoginPage
        }

        outputData.count = outputLength
        return outputData.base64EncodedString()
    }

    /// 登录模式注册接口要求密码先转成 MD5 十六进制字符串。
    static func md5Hex(_ value: String) -> String {
        Insecure.MD5
            .hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func schoolProtectedHeaders() -> [String: String] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        let key = String((0 ..< 32).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)] })
        let encoded = Data(key.utf8).base64EncodedString()
        let midpoint = encoded.count / 2
        let splitIndex = encoded.index(encoded.startIndex, offsetBy: midpoint)
        let mixed = String(encoded[..<splitIndex]) + encoded + String(encoded[splitIndex...])
        return [
            "Csrf-Key": key,
            "Csrf-Value": md5Hex(String(mixed)),
            "Sid-Language": "zh_CN",
            "User-Agent": BIT101APIClient.browserUserAgent,
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "sec-ch-ua": "\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\", \"Google Chrome\";v=\"150\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"macOS\"",
        ]
    }

    /// 复刻 bit-login 的 URL 加密请求：AES-ECB 加密 JSON，RSA 加密 AES key。
    static func encryptSchoolURLCryptoBody(
        object: [String: String],
        publicKeyPEM: String
    ) throws -> (body: String, encryptedKey: String, aesKey: Data) {
        let plaintext = try JSONSerialization.data(withJSONObject: object)
        var aesKey = Data(count: kCCKeySizeAES128)
        let randomStatus = aesKey.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw LoginServiceError.invalidServerResponse
        }

        let encryptedBody = try aesCrypt(plaintext, key: aesKey, operation: CCOperation(kCCEncrypt))
        let publicKey = try rsaPublicKey(from: publicKeyPEM)
        var error: Unmanaged<CFError>?
        guard let encryptedKey = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionPKCS1,
            Data(aesKey.base64EncodedString().utf8) as CFData,
            &error
        ) as Data? else {
            throw (error?.takeRetainedValue() as Error?) ?? LoginServiceError.invalidServerResponse
        }

        return (
            encryptedBody.base64EncodedString(),
            encryptedKey.base64EncodedString(),
            aesKey
        )
    }

    /// 解密 bit-login URL 加密接口的响应体，兼容 JSON 字符串包裹和多层 Base64。
    static func decryptSchoolURLCryptoResponse(_ data: Data, aesKey: Data) throws -> Data {
        var current = data
        for _ in 0 ..< 4 {
            if let object = try? JSONSerialization.jsonObject(with: current),
               object is [String: Any] || object is [Any]
            {
                return current
            }

            if let string = try? JSONDecoder().decode(String.self, from: current) {
                current = Data(string.utf8)
                continue
            }

            guard let ciphertext = Data(base64Encoded: current) else {
                return current
            }
            current = try aesCrypt(ciphertext, key: aesKey, operation: CCOperation(kCCDecrypt))
        }
        return current
    }

    private static func aesCrypt(_ data: Data, key: Data, operation: CCOperation) throws -> Data {
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else {
            throw LoginServiceError.invalidServerResponse
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw LoginServiceError.invalidServerResponse
        }
        output.count = outputLength
        return output
    }

    private static func rsaPublicKey(from pem: String) throws -> SecKey {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64) else {
            throw LoginServiceError.invalidServerResponse
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw (error?.takeRetainedValue() as Error?) ?? LoginServiceError.invalidServerResponse
        }
        return key
    }
}
