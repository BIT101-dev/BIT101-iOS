import Combine
import ScoreDomain
import ScorePorts
import ScheduleDomain
import SchedulePorts
@testable import ScoreInfrastructure
import CommunityTransport
import CommunityCore
@testable import GalleryFeature
@testable import CommunityUI
@testable import ScheduleFeature
@testable import MediaKit
@testable import ScoreFeature
import StorageCore
import TransportCore
import ClientCore
import ScheduleContracts
import ScheduleActivityContracts
import Foundation
import Network
import os
import Security
import Testing
import UIKit
import XCTest
@testable import BIT101_iOS

private nonisolated final class DelayedSchoolCookieServer: Sendable {
    private struct State: Sendable {
        var connection: NWConnection?
        var request = ""
        var failure: NWError?
        var port: UInt16?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SchoolCookieIsolationTests")
    private let state = OSAllocatedUnfairLock(initialState: State())
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [listener, state] value in
            state.withLock {
                if case .ready = value { $0.port = listener.port?.rawValue }
                if case let .failed(error) = value { $0.failure = error }
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [self] data, _, complete, error in
            if let error { state.withLock { $0.failure = error }; return }
            var bytes = buffered
            if let data { bytes.append(data) }
            let request = String(decoding: bytes, as: UTF8.self)
            if request.contains("\r\n\r\n") { state.withLock { $0.connection = connection; $0.request = request } }
            else if !complete { receive(connection, buffered: bytes) }
        }
    }
    func url() async throws -> URL {
        try await waitForTestEvent {
            let snapshot = state.withLock { $0 }
            if let failure = snapshot.failure { throw failure }
            return snapshot.port != nil
        }
        let port = try #require(state.withLock { $0.port })
        return AppURL.required("http://127.0.0.1:\(port)/cookie-isolation")
    }
    func waitForRequest() async throws {
        try await waitForTestEvent {
            let snapshot = state.withLock { $0 }
            if let error = snapshot.failure { throw error }
            return snapshot.connection != nil
        }
    }
    func requestHasCookie() -> Bool { state.withLock { $0.request.lowercased().contains("\r\ncookie:") } }
    func finish() {
        let connection = state.withLock { value in let current = value.connection; value.connection = nil; return current }
        let response = Data("HTTP/1.1 200 OK\r\nSet-Cookie: school-test=retired-session; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection?.send(content: response, completion: .contentProcessed { _ in connection?.cancel() })
    }
    func stop() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        state.withLock { $0.connection?.cancel() }
        listener.cancel()
    }
}

@MainActor
struct SchoolCookieIsolationTests {
    @Test func smokeAuthenticationStartsWithIndependentCookieContainers() throws {
        let first = AppSchoolSession.isolatedState()
        let second = AppSchoolSession.isolatedState()
        let cookie = try #require(HTTPCookie(properties: [.domain: "sso.bit.edu.cn", .path: "/",
            .name: "smoke-fixture", .value: "first"] ))
        first.cookieStorage.setCookie(cookie)
        #expect(first.cookieStorage !== second.cookieStorage)
        #expect(second.cookieStorage.cookies?.contains(where: { $0.name == cookie.name }) == false)
        #expect(first.cookieStorage !== AppSchoolSession.teachingCenter.cookieStorage)
    }
    @Test(.timeLimit(.minutes(1)))
    func delayedSessionCookieWritesRemainInTheRetiredAccountContainer() async throws {
        let retiredCookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let currentCookies = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: retiredCookies)
        let server = try DelayedSchoolCookieServer()
        defer { server.stop() }
        var selections: [HTTPCookieStorage] = []
        let transport = SchoolCookieTransport(state: state) { cookies in
            selections.append(cookies)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = cookies
            configuration.httpCookieAcceptPolicy = .always
            return URLSessionTransport.make(configuration: configuration)
        }
        let request = URLRequest(url: try await server.url())
        let oldRequest = Task { try await transport.data(for: request) }
        defer { oldRequest.cancel() }
        try await server.waitForRequest()
        state.clearSchoolAuthenticationCookies()
        state.replaceCookieStorage(with: currentCookies)
        server.finish()
        _ = try await oldRequest.value
        #expect(retiredCookies.cookies?.contains(where: { $0.name == "school-test" }) == true)
        #expect(currentCookies.cookies?.isEmpty == true)
        #expect(state.hasUsableSession(for: "next-account") == false)
        let newRequest = Task { try await transport.data(for: request) }
        defer { newRequest.cancel() }
        try await server.waitForRequest()
        #expect(server.requestHasCookie() == false)
        server.finish()
        _ = try await newRequest.value
        #expect(selections.count == 2 && selections[0] === retiredCookies && selections[1] === currentCookies)
        currentCookies.setCookie(try #require(HTTPCookie(properties: [.domain: "webvpn.bit.edu.cn", .path: "/", .name: "school-owner", .value: "current-session"])))
        #expect(state.hasUsableSession(for: "next-account") == false)
        state.markAuthenticated(for: "next-account")
        #expect(state.hasUsableSession(for: "next-account"))
    }
}
