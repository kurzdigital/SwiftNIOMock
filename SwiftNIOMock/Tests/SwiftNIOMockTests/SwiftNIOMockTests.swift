import XCTest
@testable import SwiftNIOMock
import NIOHTTP1

class SwiftNIOMockTests: XCTestCase {
    func testCanRestartServer() {
        // given server
        let server = Server(port: 8080) { (_, _, next) in next() }

        // when started
        try! server.start()

        // then should beb stopped to restart
        XCTAssertThrowsError(try server.start(), "Should not start server without stopping it first")

        // when stopped
        try! server.stop()

        // then can restart
        XCTAssertNoThrow(try server.start(), "Server should start again after being stopped")
        try! server.stop()
    }

    func testCanRunTwoServersOnDifferentPorts() {
        // given server1
        let server1 = Server(port: 8080) { (_, _, next) in next() }
        // given server2
        let server2 = Server(port: 8081) { (_, _, next) in next() }

        // when started 1
        try! server1.start()

        //then can start another server on another port
        XCTAssertNoThrow(try server2.start(), "Second server should be started on another port")

        try! server1.stop()
        try! server2.stop()
    }

    func testCanReturnDefaultResponse() {
        // given server with empty handler
        let server = Server(port: 8080) { (_, _, next) in next() }
        try! server.start()
        defer { try! server.stop() }

        // when making a request
        let receivedResponse = XCTestExpectation()

        let url = URL(string: "http://localhost:8080")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            // expect to recieve default response
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(data?.count == 0)
            receivedResponse.fulfill()
        }.resume()
        XCTWaiter().wait(for: [receivedResponse], timeout: 5)
    }

    func testCanRedirectRequestAndInterceptResponse() {
        // given server configured with redirect

        let calledRedirect = XCTestExpectation()
        let redirectRequest = { (request: Server.HTTPHandler.Request) -> Server.HTTPHandler.Request in
            calledRedirect.fulfill()
            var head = request.head
            head.headers.add(name: "custom-request-header", value: "custom-request-header-value")

            var components = URLComponents(string: head.uri)!
            components.host = "postman-echo.com"
            components.path = "/\(String(describing: request.head.method).lowercased())"
            components.scheme = "https"
            head.uri = components.url!.absoluteString

            return Server.HTTPHandler.Request(head: head, body: request.body, ctx: request.ctx)
        }

        let calledIntercept = XCTestExpectation()
        var originalResponse: HTTPResponseHead!
        let interceptResponse = { (response: Server.HTTPHandler.Response) in
            calledIntercept.fulfill()

            response.statusCode = .created
            response.headers.add(name: "custom-response-header", value: "custom-response-header-value")

            response.body = response.body
                .flatMap { try? JSONSerialization.jsonObject(with: $0, options: []) }
                .flatMap { try? JSONSerialization.data(withJSONObject: ["response": $0], options: []) }

            originalResponse = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: response.statusCode, headers: response.headers)
        }

        let server = Server(port: 8080, handler: redirect(request: redirectRequest, response: interceptResponse))
        try! server.start()
        defer { try! server.stop() }

        // when making a request
        let receivedResponse = XCTestExpectation()

        let url = URL(string: "http://localhost:8080?query=value")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "Hello world!".data(using: .utf8)
        request.setValue("text/html; charset=utf-8", forHTTPHeaderField: "Content-Type")
//        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        URLSession.shared.dataTask(with: request) { data, response, error in
            // expect to recieve intercepted response
            let expectedData = try? JSONSerialization.data(withJSONObject: [
                "response": [
                    "args": ["query": "value"],
                    "data":"Hello world!",
                    "files": [:],
                    "form": [:],
                    "headers": [
                        "accept": "*/*",
                        "accept-encoding": "gzip, deflate",
                        "accept-language": "en-us",
                        "content-length": "12",
                        "content-type": "text/html; charset=utf-8",
                        "custom-request-header": "custom-request-header-value",
                        "host": "localhost",
                        "user-agent": "xctest (unknown version) CFNetwork/975.0.3 Darwin/17.7.0",
                        "x-forwarded-port": "443",
                        "x-forwarded-proto": "https"
                    ],
                    "json": nil,
                    "url": "https://localhost/post?query=value",
                ]
                ], options: [.sortedKeys])

            let receivedData = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0, options: []) }
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }

            XCTAssertEqual(receivedData, expectedData)

            let httpResponse = response as! HTTPURLResponse
            var responseHead = HTTPResponseHead(
                version: HTTPVersion(major: 1, minor: 1),
                status: HTTPResponseStatus.init(statusCode: httpResponse.statusCode),
                headers: HTTPHeaders(httpResponse.allHeaderFields.map { ("\($0.key)", "\($0.value)") })
            )

            // content lengths and encoding will be different because of compression
            responseHead.headers.remove(name: "Content-Length")
            originalResponse.headers.remove(name: "Content-Length")
            responseHead.headers.remove(name: "Content-Encoding")
            originalResponse.headers.remove(name: "Content-Encoding")

            XCTAssertEqual(responseHead, originalResponse)

            receivedResponse.fulfill()
        }.resume()
        XCTWaiter().wait(for: [calledRedirect, calledIntercept, receivedResponse], timeout: 5, enforceOrder: true)
    }

}