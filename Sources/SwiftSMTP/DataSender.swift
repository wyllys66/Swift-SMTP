/**
 * Copyright IBM Corporation 2017
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

import Foundation
import LoggerAPI

// Used to send the content of an email--headers, text, and attachments.
// Should only be invoked after sending the `DATA` command to the server.
// The email is not actually sent until we have indicated that we are done sending its contents with a `CRLF CRLF`.
// This is handled by `Sender`.
struct DataSender {
    // Socket we use to read and write data to
    private let socket: SMTPSocket?
    private let stream: OutputStream?
    
    // Init a new instance of `DataSender`
    init(socket: SMTPSocket) {
        self.socket = socket
        self.stream = nil;
    }
    
    // Init an instance that write to an output stream instead of a socket
    init(stream: OutputStream) {
        self.stream = stream;
        self.socket = nil;
    }

    // Send the text and attachments of the `mail`
    func send(_ mail: Mail, includeHeaders: Bool = true) throws {
        if includeHeaders {
            try sendHeaders(mail.headersString)
        }
        if mail.pgp {
            // Route PGP first — even with no attachments — so the
            // missingPGPAttachment guard fires instead of silently emitting a
            // plaintext body.
            try sendPGPMIME(mail)
        } else if mail.hasAttachment {
            try sendMixed(mail)
        } else {
            try sendText(mail.text)
        }
    }
}

extension DataSender {
    // Send the headers of a `Mail`
    func sendHeaders(_ headers: String) throws {
        try send(headers)
    }

    // Add custom/default headers to a `Mail`'s text and write it to the socket.
    func sendText(_ text: String) throws {
        try send(text.embedded)
    }

    // Send `mail`'s content that is more than just plain text. Callers should
    // route `mail.pgp == true` to `sendPGPMIME` directly — this path is for
    // non-encrypted multipart/mixed only.
    func sendMixed(_ mail: Mail) throws {
        let boundary = String.makeBoundary()
        try send(String.makeMixedHeader(boundary: boundary))
        try send(boundary.startLine)
        try sendAlternative(for: mail)
        try sendAttachments(mail.attachments, boundary: boundary)
    }

    // If `mail` has an attachment that is an alternative to plain text, sends that attachment and the plain text.
    // Else just sends the plain text.
    func sendAlternative(for mail: Mail) throws {
        if let alternative = mail.alternative {
            let boundary = String.makeBoundary()
            let alternativeHeader = String.makeAlternativeHeader(boundary: boundary)
            try send(alternativeHeader)

            try send(boundary.startLine)
            try sendText(mail.text)

            try send(boundary.startLine)
            try sendAttachment(alternative)

            try send(boundary.endLine)
            return
        }

        try sendText(mail.text)
    }

    // Sends the attachments of a `Mail`.
    func sendAttachments(_ attachments: [Attachment], boundary: String) throws {
        for attachment in attachments {
            try send(boundary.startLine)
            try sendAttachment(attachment)
        }
        try send(boundary.endLine)
    }

    // Frame the caller's attachments as an RFC 3156 §4 `multipart/encrypted`
    // body. The caller is responsible for supplying both required parts (the
    // `application/pgp-encrypted` Version part and the ciphertext) as
    // attachments in order; the library only frames them and refuses to emit
    // `mail.text` so no plaintext leaks alongside the encrypted body.
    func sendPGPMIME(_ mail: Mail) throws {
        guard !mail.attachments.isEmpty else {
            throw SMTPError.missingPGPAttachment
        }
        let boundary = String.makeBoundary()
        try send(String.makeMixedEncryptedHeader(boundary: boundary))
        try sendAttachments(mail.attachments, boundary: boundary)
    }

    // Send the `attachment`.
    func sendAttachment(_ attachment: Attachment) throws {
        var relatedBoundary = ""

        if attachment.hasRelated {
            relatedBoundary = String.makeBoundary()
            let relatedHeader = String.makeRelatedHeader(boundary: relatedBoundary)
            try send(relatedHeader)
            try send(relatedBoundary.startLine)
        }

        let attachmentHeader = attachment.headersString + CRLF
        try send(attachmentHeader)

        switch attachment.type {
        case .data(let data, _, _, _): try sendData(data)
        case .pgp(let pgp, _, _, _): try sendPGPAttachment(pgp)
        case .file(let path, _, _, _): try sendFile(at: path)
        case .html(let content, _, _): try sendHTML(content)
        }

        try send("")

        if attachment.hasRelated {
            try sendAttachments(attachment.relatedAttachments, boundary: relatedBoundary)
        }
    }

    // Send a PGP attachment. The body is already ASCII-armored, so no encoding
    // step is needed and there is nothing worth caching.
    func sendPGPAttachment(_ pgp: String) throws {
        try send(pgp)
    }

    // Send a data attachment, base64-encoded.
    func sendData(_ data: Data) throws {
        try send(data.base64EncodedData(options: .lineLength76Characters))
    }

    // Send a local file, base64-encoded.
    func sendFile(at path: String) throws {
        guard let file = FileHandle(forReadingAtPath: path) else {
            throw SMTPError.fileNotFound(path: path)
        }
        defer { file.closeFile() }
        try send(file.readDataToEndOfFile().base64EncodedData(options: .lineLength76Characters))
    }

    // Send an HTML attachment, base64-encoded.
    func sendHTML(_ html: String) throws {
        let encoded = html.data(using: .utf8)?.base64EncodedData(options: .lineLength76Characters) ?? Data()
        try send(encoded)
    }
}

private extension DataSender {
    // Write `text` to the socket.
    func send(_ text: String) throws {
        if (socket != nil) {
            Log.debug("SEND: \(text)")
            try socket?.write(text)
        } else if (stream != nil) {
            Log.debug("STREAM: \(text)")
            let final = text + CRLF
            try self.stream?.write(final.data(using: .utf8)!)
        }
    }

    // Write `data` to the socket or stream.
    func send(_ data: Data) throws {
        if (socket != nil) {
            Log.debug("SEND: data \(data.count) bytes")
            try socket?.write(data)
        } else if (stream != nil) {
            Log.debug("STREAM: data \(data.count) bytes")
            try self.stream?.write(data)
        }
    }
}

private extension String {
    // Embed plain text content of emails with the proper headers so that it is entered correctly.
    var embedded: String {
        var embeddedText = ""
        embeddedText += "Content-Type: text/plain; charset=utf-8\(CRLF)"
        embeddedText += "Content-Transfer-Encoding: 7bit\(CRLF)"
        embeddedText += "Content-Disposition: inline\(CRLF)"
        embeddedText += "\(CRLF)\(self)\(CRLF)"
        return embeddedText
    }

    // The SMTP protocol requires unique boundaries between sections of an email.
    static func makeBoundary() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func makeMixedEncryptedHeader(boundary: String) -> String {
        return "Content-Type: multipart/encrypted; boundary=\"\(boundary)\"; protocol=\"application/pgp-encrypted\"\(CRLF)"
    }

    // Header for a mixed type email.
    static func makeMixedHeader(boundary: String) -> String {
        return "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Header for an alternative email.
    static func makeAlternativeHeader(boundary: String) -> String {
        return "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Header for an attachment that is related to another attachment. (Such as an image attachment that can be
    // referenced by a related HTML attachment)
    static func makeRelatedHeader(boundary: String) -> String {
        return "Content-Type: multipart/related; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Added to a boundary to indicate the beginning of the corresponding section.
    var startLine: String {
        return "--\(self)"
    }

    // Added to a boundary to indicate the end of the corresponding section.
    var endLine: String {
        return "--\(self)--"
    }
}

extension OutputStream {

    func write(_ data: Data) throws {
        var remaining = data[...]
        while !remaining.isEmpty {
            let bytesWritten = remaining.withUnsafeBytes { buf -> Int in
                // baseAddress is non-nil because `remaining` is non-empty.
                // assumingMemoryBound is there because Foundation declares the
                // pointer as `UnsafePointer<UInt8>` rather than `void *`.
                return self.write(
                    buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    maxLength: buf.count
                )
            }
            if bytesWritten > 0 {
                remaining = remaining.dropFirst(bytesWritten)
            } else {
                // 0 means no space without blocking; <0 means error. Either
                // way we can't make progress — surface to the caller instead
                // of spinning or aborting the process.
                throw self.streamError ?? SMTPError.streamWriteFailed
            }
        }
    }
}
