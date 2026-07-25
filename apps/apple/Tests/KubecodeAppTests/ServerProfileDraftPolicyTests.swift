import Foundation
import Testing
import KubecodeKit
@testable import KubecodeApp

@Suite
struct ServerProfileDraftPolicyTests {
    @Test func https_profiles_require_name_tls_host_and_bearer() {
        #expect(!ServerProfileDraftPolicy.canAdd(
            name: "Runtime",
            mode: .httpsAttached,
            endpoint: "http://runtime.example",
            bearerToken: "secret",
            sshHost: ""
        ))
        #expect(!ServerProfileDraftPolicy.canAdd(
            name: "Runtime",
            mode: .httpsAttached,
            endpoint: "https://runtime.example",
            bearerToken: "   ",
            sshHost: ""
        ))
        #expect(ServerProfileDraftPolicy.canAdd(
            name: "Runtime",
            mode: .httpsAttached,
            endpoint: "https://runtime.example",
            bearerToken: "secret",
            sshHost: ""
        ))
    }

    @Test func ssh_profiles_require_name_and_ssh_config_host() {
        #expect(!ServerProfileDraftPolicy.canAdd(
            name: "GPU",
            mode: .sshManaged,
            endpoint: "",
            bearerToken: "",
            sshHost: "   "
        ))
        #expect(!ServerProfileDraftPolicy.canAdd(
            name: "   ",
            mode: .sshManaged,
            endpoint: "",
            bearerToken: "",
            sshHost: "gpu-host"
        ))
        #expect(ServerProfileDraftPolicy.canAdd(
            name: "GPU",
            mode: .sshManaged,
            endpoint: "",
            bearerToken: "",
            sshHost: "gpu-host"
        ))
    }
}
