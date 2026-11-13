// SPDX-FileCopyrightText: 2026 Vitalik Makhnev
// SPDX-License-Identifier: MIT AND LicenseRef-Commons-Clause-1.0

import Foundation
import Security

func fail(_ message: String, status: OSStatus? = nil) -> Never {
    let detail: String
    if let status {
        let description = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security framework error"
        detail = "\(message): \(description) (\(status))"
    } else {
        detail = message
    }

    FileHandle.standardError.write(Data("\(detail)\n".utf8))
    exit(EXIT_FAILURE)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: trust-certificate <DER certificate>")
}

let certificateURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let certificateData = try? Data(contentsOf: certificateURL),
    let certificate = SecCertificateCreateWithData(nil, certificateData as CFData)
else {
    fail("Could not read the DER certificate")
}

let preferenceStatus = SecKeychainSetPreferenceDomain(.system)
guard preferenceStatus == errSecSuccess else {
    fail("Could not select the system Keychain domain", status: preferenceStatus)
}

let certificateQuery: [CFString: Any] = [
    kSecClass: kSecClassCertificate,
    kSecValueRef: certificate,
]

let addStatus = SecItemAdd(certificateQuery as CFDictionary, nil)
guard addStatus == errSecSuccess else {
    fail("Could not add the release certificate to the system Keychain", status: addStatus)
}

let trustStatus = SecTrustSettingsSetTrustSettings(certificate, .admin, nil)
guard trustStatus == errSecSuccess else {
    fail("Could not trust the release certificate", status: trustStatus)
}

print("Release certificate trusted for this runner")
