/**
 * Copyright IBM Corporation 2024
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import XCTest
@testable import SwiftSMTP

// Verifies the MIME structure produced by `Mail.render(to:)` when `Mail.pgp`
// is set, against RFC 3156 §4 (security multiparts using PGP). These tests
// render to an in-memory `OutputStream` and never touch the network, so they
// don't require the live SMTP server the rest of the suite expects.
class TestPGPMIME: XCTestCase {
    static var allTests = [
        ("testTopLevelHeaderIsMultipartEncrypted", testTopLevelHeaderIsMultipartEncrypted),
        ("testFirstPartIsApplicationPGPEncryptedVersion", testFirstPartIsApplicationPGPEncryptedVersion),
        ("testSecondPartContainsCiphertextAttachment", testSecondPartContainsCiphertextAttachment),
        ("testBodyHasExactlyTwoParts", testBodyHasExactlyTwoParts),
        ("testPlaintextIsDroppedWhenPGPSet", testPlaintextIsDroppedWhenPGPSet),
        ("testMissingPGPAttachmentThrows", testMissingPGPAttachmentThrows),
        ("testPGPAttachmentFilenamePreserved", testPGPAttachmentFilenamePreserved),
    ]

    // Realistic-looking ASCII armor. The content is never decrypted — these
    // tests only verify MIME framing.
    private let armoredCiphertext = """
        -----BEGIN PGP MESSAGE-----
        Version: GnuPG v2

        hQEMA1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz
        0123456789+/SGVsbG8gV29ybGQgdGhpcyBpcyBub3QgYWN0dWFsbHkgY2lwaGVydGV4dA==
        =ABCD
        -----END PGP MESSAGE-----
        """

    private let sender = Mail.User(name: "Alice", email: "alice@example.com")
    private let recipient = Mail.User(name: "Bob", email: "bob@example.com")

    private func makeVersionPart() -> Attachment {
        // RFC 3156 §4 first body part: application/pgp-encrypted; "Version: 1".
        return Attachment(pgp: "Version: 1", mime: "application/pgp-encrypted", name: "")
    }

    private func makeCiphertextPart(name: String = "encrypted.asc") -> Attachment {
        return Attachment(pgp: armoredCiphertext, mime: "application/octet-stream", name: name)
    }

    private func makePGPMail(text: String = "", attachments: [Attachment]? = nil) -> Mail {
        return Mail(
            from: sender,
            to: [recipient],
            subject: "Encrypted message",
            text: text,
            pgp: true,
            attachments: attachments ?? [makeVersionPart(), makeCiphertextPart()]
        )
    }

    private func render(_ mail: Mail) throws -> String {
        let stream = OutputStream(toMemory: ())
        stream.open()
        defer { stream.close() }
        try mail.render(to: stream)
        let data = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data ?? Data()
        guard let rendered = String(data: data, encoding: .utf8) else {
            XCTFail("Rendered body was not valid UTF-8")
            return ""
        }
        return rendered
    }

    private func extractBoundary(from rendered: String) -> String? {
        let pattern = #"multipart/encrypted;\s*boundary="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
        guard let match = regex.firstMatch(in: rendered, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: rendered) else {
            return nil
        }
        return String(rendered[captureRange])
    }

    func testTopLevelHeaderIsMultipartEncrypted() throws {
        let rendered = try render(makePGPMail())
        XCTAssert(rendered.contains("Content-Type: multipart/encrypted"),
                  "Top-level Content-Type must be multipart/encrypted (RFC 3156 §4)")
        XCTAssert(rendered.contains(#"protocol="application/pgp-encrypted""#),
                  "multipart/encrypted must carry the protocol=application/pgp-encrypted parameter")
        XCTAssertNotNil(extractBoundary(from: rendered),
                        "multipart/encrypted Content-Type must declare a quoted boundary")
    }

    func testFirstPartIsApplicationPGPEncryptedVersion() throws {
        let rendered = try render(makePGPMail())
        guard let boundary = extractBoundary(from: rendered) else {
            XCTFail("No boundary; cannot locate first part")
            return
        }
        let parts = rendered.components(separatedBy: "--\(boundary)")
        // [0] preamble, [1] first part, [2] second part, [3] (trailing — contains the "--" close marker)
        guard parts.count >= 3 else {
            XCTFail("Expected at least 2 body parts, found \(parts.count - 1)")
            return
        }
        let firstPart = parts[1]
        XCTAssert(firstPart.contains("Content-Type: application/pgp-encrypted"),
                  "First part must declare Content-Type: application/pgp-encrypted")
        XCTAssert(firstPart.contains("Version: 1"),
                  "First part body must be \"Version: 1\" per RFC 3156 §4")
    }

    func testSecondPartContainsCiphertextAttachment() throws {
        let rendered = try render(makePGPMail())
        guard let boundary = extractBoundary(from: rendered) else {
            XCTFail("No boundary; cannot locate second part")
            return
        }
        let parts = rendered.components(separatedBy: "--\(boundary)")
        guard parts.count >= 3 else {
            XCTFail("Expected at least 2 body parts, found \(parts.count - 1)")
            return
        }
        let secondPart = parts[2]
        XCTAssert(secondPart.contains("Content-Type: application/octet-stream"),
                  "Second part should carry the attachment's declared MIME type")
        XCTAssert(secondPart.contains("-----BEGIN PGP MESSAGE-----"),
                  "Second part body must contain the ASCII-armored ciphertext")
        XCTAssert(secondPart.contains("-----END PGP MESSAGE-----"),
                  "Second part body must contain the ASCII-armor terminator")
    }

    func testBodyHasExactlyTwoParts() throws {
        let rendered = try render(makePGPMail())
        guard let boundary = extractBoundary(from: rendered) else {
            XCTFail("No boundary; cannot count parts")
            return
        }
        // Count delimiter occurrences. A correct two-part body has the
        // boundary appearing 3 times in raw form (2 part openers + 1 closer);
        // the closer is "--BOUNDARY--", so splitting on the bare "--BOUNDARY"
        // delimiter yields preamble + 2 parts + the "--" tail.
        let segments = rendered.components(separatedBy: "--\(boundary)")
        XCTAssertEqual(segments.count, 4,
                       "RFC 3156 multipart/encrypted must contain exactly two body parts (Version + ciphertext), got \(segments.count - 2)")
        XCTAssert(rendered.contains("--\(boundary)--"),
                  "Multipart body must terminate with the closing boundary delimiter")
    }

    func testPlaintextIsDroppedWhenPGPSet() throws {
        let secret = "this plaintext must NOT leak alongside the encrypted body"
        let rendered = try render(makePGPMail(text: secret))
        XCTAssertFalse(rendered.contains(secret),
                       "mail.text must not appear inside a multipart/encrypted envelope — it would defeat the encryption")
    }

    func testMissingPGPAttachmentThrows() {
        let mail = Mail(
            from: sender,
            to: [recipient],
            subject: "Encrypted",
            text: "",
            pgp: true,
            attachments: []
        )
        let stream = OutputStream(toMemory: ())
        stream.open()
        defer { stream.close() }
        XCTAssertThrowsError(try mail.render(to: stream)) { error in
            guard let smtpError = error as? SMTPError, case .missingPGPAttachment = smtpError else {
                XCTFail("Expected SMTPError.missingPGPAttachment, got \(error)")
                return
            }
        }
    }

    func testPGPAttachmentFilenamePreserved() throws {
        let ciphertext = makeCiphertextPart(name: "msg.asc")
        let rendered = try render(makePGPMail(attachments: [makeVersionPart(), ciphertext]))
        XCTAssert(rendered.contains(#"filename="msg.asc""#),
                  "Attachment's filename must surface in Content-Disposition")
    }
}
