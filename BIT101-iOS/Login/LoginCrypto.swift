//
//  LoginCrypto.swift
//  BIT101-iOS
//

import CommonCrypto
import CryptoKit
import Foundation

/// Android 端登录流程依赖的加密算法。
///
/// iOS 端为了兼容现有后端和学校登录链路，需要严格复刻 Android 端的密码处理逻辑。
enum LoginCrypto {
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
}
