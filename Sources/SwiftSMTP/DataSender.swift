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
        if mail.hasAttachment {
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
    // Add custom/default headers to a `Mail`'s text and write it to the socket.
    func sendPGP(_ text: String) throws {
        try send(text);
    }

    // Send `mail`'s content that is more than just plain text
    func sendMixed(_ mail: Mail) throws {
        let boundary = String.makeBoundary()
        
        var mixedHeader: String
        if mail.pgp {
            mixedHeader = String.makeMixedEncryptedHeader(boundary: boundary)
        } else {
            mixedHeader = String.makeMixedHeader(boundary: boundary)
        }

        try send(mixedHeader)
        if !mail.pgp || mail.text.count > 0 {
            try send(boundary.startLine)
        }
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

        if mail.pgp {
            if mail.text.count > 0 {
                let pgpheader = String.makePGPContentHeaders()
                try send(pgpheader)
                try sendPGP(mail.text + CRLF)
            }
        } else {
            try sendText(mail.text)
        }
    }

    // Sends the attachments of a `Mail`.
    func sendAttachments(_ attachments: [Attachment], boundary: String) throws {
        for attachment in attachments {
            try send(boundary.startLine)
            try sendAttachment(attachment)
        }
        try send(boundary.endLine)
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

    // Send a PGP attachment.
    func sendPGPAttachment(_ pgp: String) throws {
        #if os(macOS)
        if let encodedData = cache.object(forKey: pgp as AnyObject) as? Data {
            return try send(encodedData)
        }
        #else
        if let data = cache.object(forKey: NSString(string: pgp) as AnyObject) as? Data {
            return try send(data)
        }
        #endif

        try send(pgp)

        #if os(macOS)
            cache.setObject(encodedData as AnyObject, forKey: data as AnyObject)
        #else
            cache.setObject(NSString(string: pgp) as AnyObject, forKey: NSString(string: pgp) as AnyObject)
        #endif
    }

    // Send a data attachment. Data must be base 64 encoded before sending.
    // Checks if the base 64 encoded version has been cached first.
    func sendData(_ data: Data) throws {
        #if os(macOS)
            if let encodedData = cache.object(forKey: data as AnyObject) as? Data {
                return try send(encodedData)
            }
        #else
        
            if let encodedData = cache.object(forKey: NSData(data: data) as AnyObject) as? Data {
                return try send(encodedData)
            }
        #endif

        let encodedData = data.base64EncodedData(options: .lineLength76Characters)
        try send(encodedData)

        #if os(macOS)
            cache.setObject(encodedData as AnyObject, forKey: data as AnyObject)
        #else
            cache.setObject(NSData(data: encodedData) as AnyObject, forKey: NSData(data: data) as AnyObject)
        #endif
    }

    // Sends a local file at the given path. File must be base 64 encoded before sending. Checks the cache first.
    // Throws an error if file could not be found.
    func sendFile(at path: String) throws {
        #if os(macOS)
            if let data = cache.object(forKey: path as AnyObject) as? Data {
                return try send(data)
            }
        #else
            if let data = cache.object(forKey: NSString(string: path) as AnyObject) as? Data {
                return try send(data)
            }
        #endif

        guard let file = FileHandle(forReadingAtPath: path) else {
            throw SMTPError.fileNotFound(path: path)
        }

        let data = file.readDataToEndOfFile().base64EncodedData(options: .lineLength76Characters)
        try send(data)
        file.closeFile()

        #if os(macOS)
            cache.setObject(data as AnyObject, forKey: path as AnyObject)
        #else
            cache.setObject(NSData(data: data) as AnyObject, forKey: NSString(string: path) as AnyObject)
        #endif
    }

    // Send an HTML attachment. HTML must be base 64 encoded before sending.
    // Checks if the base 64 encoded version is in cache first.
    func sendHTML(_ html: String) throws {
        #if os(macOS)
            if let encodedHTML = cache.object(forKey: html as AnyObject) as? String {
                return try send(encodedHTML)
            }
        #else
            if let encodedHTML = cache.object(forKey: NSString(string: html) as AnyObject) as? String {
                return try send(encodedHTML)
            }
        #endif

        let encodedHTML = html.data(using: .utf8)?.base64EncodedData(options: .lineLength76Characters) ?? Data()
        try send(encodedHTML)

        #if os(macOS)
            cache.setObject(encodedHTML as AnyObject, forKey: html as AnyObject)
        #else
            cache.setObject(NSData(data: encodedHTML) as AnyObject, forKey: NSString(string: html) as AnyObject)
        #endif
    }
}

private extension DataSender {
    // Write `text` to the socket.
    func send(_ text: String) throws {
        if (socket != nil) {
            //print("SEND: \(text)")
            try socket?.write(text)
        } else if (stream != nil) {
            //print("STREAM: \(text)")
            let final = text + CRLF
            try self.stream?.write(final.data(using: .utf8)!)
        }
    }

    // Write `data` to the socket or stream.
    func send(_ data: Data) throws {
        if (socket != nil) {
            //print("SEND: data \(data.count) bytes")
            try socket?.write(data)
        } else if (stream != nil) {
            //print("STREAM: data \(data.count) bytes")
            try self.stream?.write(data)
        }
    }
}

private extension String {
    // Embed plain text content of emails with the proper headers so that it is entered correctly.
    var embedded: String {
        var embeddedText = ""
        embeddedText += "CONTENT-TYPE: text/plain; charset=utf-8\(CRLF)"
        embeddedText += "CONTENT-TRANSFER-ENCODING: 7bit\(CRLF)"
        embeddedText += "CONTENT-DISPOSITION: inline\(CRLF)"
        embeddedText += "\(CRLF)\(self)\(CRLF)"
        return embeddedText
    }

    // The SMTP protocol requires unique boundaries between sections of an email.
    static func makeBoundary() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func makeMixedEncryptedHeader(boundary: String) -> String {
        return "CONTENT-TYPE: multipart/encrypted; boundary=\"\(boundary)\"; protocol=\"application/pgp-encrypted\"\(CRLF)"
    }
    
    static func makePGPContentHeaders() -> String {
        return "CONTENT-TYPE: text/plain; charset=\"utf-8\"\(CRLF)CONTENT-TRANSFER-ENCODING: 7bit\(CRLF)CONTENT-DISPOSITION: inline\(CRLF)"
    }

    // Header for a mixed type email.
    static func makeMixedHeader(boundary: String) -> String {
        return "CONTENT-TYPE: multipart/mixed; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Header for an alternative email.
    static func makeAlternativeHeader(boundary: String) -> String {
        return "CONTENT-TYPE: multipart/alternative; boundary=\"\(boundary)\"\(CRLF)"
    }

    // Header for an attachment that is related to another attachment. (Such as an image attachment that can be
    // referenced by a related HTML attachment)
    static func makeRelatedHeader(boundary: String) -> String {
        return "CONTENT-TYPE: multipart/related; boundary=\"\(boundary)\"\(CRLF)"
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
            let bytesWritten = remaining.withUnsafeBytes { buf in
                // The force unwrap is safe because we know that `remaining` is
                // not empty. The `assumingMemoryBound(to:)` is there just to
                // make Swift’s type checker happy. This would be unnecessary if
                // `write(_:maxLength:)` were (as it should be IMO) declared
                // using `const void *` rather than `const uint8_t *`.
                self.write(
                    buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    maxLength: buf.count
                )
            }
            guard bytesWritten >= 0 else {
                // … if -1, throw `streamError` …
                // … if 0, well, that’s a complex question …
                if let error = self.streamError {
                    print(error.localizedDescription ?? "Unknown error")
                }
                fatalError()
            }
            remaining = remaining.dropFirst(bytesWritten)
        }
    }
}
