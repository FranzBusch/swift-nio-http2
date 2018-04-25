//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO
import NIOHTTP1
import NIOHTTP2

/// Have two `EmbeddedChannel` objects send and receive data from each other until
/// they make no forward progress.
func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel) {
    var operated: Bool

    repeat {
        operated = false

        if case .some(.byteBuffer(let data)) = first.readOutbound() {
            operated = true
            XCTAssertNoThrow(try second.writeInbound(data))
        }
        if case .some(.byteBuffer(let data)) = second.readOutbound() {
            operated = true
            XCTAssertNoThrow(try first.writeInbound(data))
        }
    } while operated
}

class SimpleClientServerTests: XCTestCase {
    var clientChannel: EmbeddedChannel!
    var serverChannel: EmbeddedChannel!

    override func setUp() {
        self.clientChannel = EmbeddedChannel()
        self.serverChannel = EmbeddedChannel()
    }

    override func tearDown() {
        self.clientChannel = nil
        self.serverChannel = nil
    }

    func testBasicRequestResponse() throws {
        // Begin by getting the connection up.
        try! self.clientChannel.pipeline.add(handler: HTTP2Parser(mode: .client)).wait()
        try! self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server)).wait()
        interactInMemory(self.clientChannel, self.serverChannel)

        // We're now going to try to send a request from the client to the server.
        let requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/")
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        var reqFrame = HTTP2Frame(streamID: 1, payload: .headers(.request(requestHead)))
        reqFrame.endHeaders = true
        var reqBodyFrame = HTTP2Frame(streamID: 1, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        self.clientChannel.write(reqFrame, promise: nil)
        self.clientChannel.writeAndFlush(reqBodyFrame, promise: nil)
        interactInMemory(self.clientChannel, self.serverChannel)

        XCTAssertNil(self.clientChannel.readInbound())
        guard let firstFrame: HTTP2Frame = self.serverChannel.readInbound() else {
            XCTFail("No frame")
            return
        }
        XCTAssertEqual(firstFrame.streamID, 1)
        XCTAssertFalse(firstFrame.endStream)
        XCTAssertTrue(firstFrame.endHeaders)
        guard case .headers(.request(let receivedRequestHead)) = firstFrame.payload else {
            XCTFail("Payload incorrect")
            return
        }

        XCTAssertEqual(receivedRequestHead, requestHead)

        guard let secondFrame: HTTP2Frame = self.serverChannel.readInbound() else {
            XCTFail("No second frame")
            return
        }
        XCTAssertEqual(secondFrame.streamID, 1)
        XCTAssertTrue(secondFrame.endStream)
        guard case .data(.byteBuffer(let receivedData)) = secondFrame.payload else {
            XCTFail("Payload incorrect")
            return
        }

        XCTAssertEqual(receivedData, requestBody)

        // Let's send a quick response back.
        let responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0),
                                            status: .ok,
                                            headers: HTTPHeaders([("content-length", "0")]))
        var respFrame = HTTP2Frame(streamID: 1, payload: .headers(.response(responseHead)))
        respFrame.endHeaders = true
        respFrame.endStream = true
        XCTAssertNoThrow(try self.serverChannel.writeAndFlush(respFrame).wait())
        interactInMemory(self.clientChannel, self.serverChannel)

        // The client should have seen this.
        guard let receivedResponseFrame: HTTP2Frame = self.clientChannel.readInbound() else {
            XCTFail("No frame")
            return
        }
        XCTAssertEqual(firstFrame.streamID, 1)
        XCTAssertTrue(firstFrame.endStream)
        XCTAssertTrue(firstFrame.endHeaders)
        guard case .headers(.response(let receivedResponseHead)) = receivedResponseFrame.payload else {
            XCTFail("Payload incorrect")
            return
        }

        XCTAssertEqual(receivedResponseHead, responseHead)
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
