import Foundation

protocol LoginServicing {
    var savedStudentID: String { get }
    var savedPassword: String { get }
    var hasCachedSession: Bool { get }

    func checkLogin() async throws -> String?
    func login(studentID: String, password: String) async throws -> String
    func logout()
}

extension LoginService: LoginServicing {}
