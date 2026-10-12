// icloud-secret — read/write a secret in the iCloud-SYNCED Keychain.
//
// The built-in `security` CLI cannot do this: the synced (data-protection)
// keychain requires a keychain-access-group, which comes from a code-signing
// entitlement. So this tool only works once compiled, signed, and provisioned
// with a matching Team ID / access group (see scripts/build-sign.sh + README).
//
// The literal token "TEAMID" below is substituted with the real Apple Team ID
// at build time; it must match the entitlement + provisioning profile.
//
//   icloud-secret set <name>   # secret read from stdin
//   icloud-secret get <name>   # secret written to stdout
//   icloud-secret delete <name>
//
import Foundation
import Security
import LocalAuthentication

enum Config {
    static let service = "com.carterscode.icloudsecret"
    static let accountPrefix = "secret:"
    static let accessGroup = "TEAMID.com.carterscode.icloudsecret"
}

struct StdErr: TextOutputStream { func write(_ s: String) { fputs(s, stderr) } }
var errStream = StdErr()

func baseQuery(_ name: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Config.service,
        kSecAttrAccount as String: Config.accountPrefix + name,
        kSecAttrAccessGroup as String: Config.accessGroup,
        kSecAttrSynchronizable as String: kCFBooleanTrue!,   // the whole point: iCloud sync
    ]
}

func fail(_ msg: String, _ status: OSStatus? = nil) -> Never {
    if let st = status {
        let desc = (SecCopyErrorMessageString(st, nil) as String?) ?? "unknown"
        fputs("icloud-secret: \(msg): \(desc) (\(st))\n", stderr)
    } else {
        fputs("icloud-secret: \(msg)\n", stderr)
    }
    exit(1)
}

func setSecret(_ name: String) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { fail("expected secret on stdin") }
    let query = baseQuery(name)
    var add = query
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock   // must not be *ThisDeviceOnly
    add[kSecValueData as String] = data
    let st = SecItemAdd(add as CFDictionary, nil)
    if st == errSecDuplicateItem {
        let us = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard us == errSecSuccess else { fail("update failed", us) }
    } else if st != errSecSuccess {
        fail("add failed", st)
    }
    print("stored", to: &errStream)
}

func getSecret(_ name: String) {
    var q = baseQuery(name)
    q[kSecReturnData as String] = kCFBooleanTrue!
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    let ctx = LAContext()
    ctx.interactionNotAllowed = true          // never prompt; fail instead
    q[kSecUseAuthenticationContext as String] = ctx
    var out: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    guard st == errSecSuccess else { fail("retrieve failed", st) }   // -25300 = not found
    guard let data = out as? Data else { fail("invalid data from keychain") }
    FileHandle.standardOutput.write(data)
}

func deleteSecret(_ name: String) {
    var del = baseQuery(name)
    del[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    let st = SecItemDelete(del as CFDictionary)
    guard st == errSecSuccess || st == errSecItemNotFound else { fail("delete failed", st) }
}

let args = CommandLine.arguments
guard args.count == 3, !args[2].isEmpty else {
    fail("usage: icloud-secret <set|get|delete> <name>")
}
switch args[1] {
case "set":    setSecret(args[2])
case "get":    getSecret(args[2])
case "delete": deleteSecret(args[2])
default:       fail("unknown command '\(args[1])'")
}
