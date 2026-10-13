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
//   icloud-secret set <name>            # hidden prompt when run interactively,
//                                       # or read from stdin when piped
//   icloud-secret set <name> <secret>   # value on the command line (see caveat)
//   icloud-secret get <name>            # secret written to stdout
//   icloud-secret delete <name>
//
// CAVEAT on `set <name> <secret>`: anything in argv is visible to `ps` for the
// lifetime of the process and is recorded in shell history. It exists because
// it is convenient in scripts; prefer the prompt or a pipe for a real secret.
// In zsh with HIST_IGNORE_SPACE, prefixing the command with a space keeps it
// out of history.
//
import Foundation
import Darwin
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

/// Prompt on the terminal with echo off, submitted by Enter. Returns nil only
/// if the terminal cannot be put into no-echo mode, so a caller can fall back.
func promptHidden(_ prompt: String) -> String? {
    fputs(prompt, stderr)
    var orig = termios()
    guard tcgetattr(STDIN_FILENO, &orig) == 0 else {
        fputs("\n", stderr)
        return readLine(strippingNewline: true)   // no tty control; input will echo
    }
    var quiet = orig
    quiet.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
    let line = readLine(strippingNewline: true)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
    fputs("\n", stderr)                            // the user's Enter was swallowed
    return line
}

func setSecret(_ name: String, inline: String? = nil) {
    var data: Data

    if let inline = inline {
        data = Data(inline.utf8)
    } else if isatty(STDIN_FILENO) == 1 {
        // Interactive: prompt, hide the input, and let Enter submit it. Reading
        // stdin to EOF here would sit silently waiting for Ctrl-D, which looks
        // indistinguishable from a hung command.
        guard let typed = promptHidden("Secret for '\(name)' (hidden, Enter to submit): "),
              !typed.isEmpty else { fail("no secret entered") }
        data = Data(typed.utf8)
    } else {
        data = FileHandle.standardInput.readDataToEndOfFile()
        // Tolerate the trailing newline that `echo`, a heredoc or a pasted line
        // adds. Storing it silently produces a credential that fails to
        // authenticate for reasons nobody can see.
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
    }

    guard !data.isEmpty else { fail("expected a secret on stdin") }
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
let usage = """
usage: icloud-secret <set|get|delete> <name>
       icloud-secret set <name> <secret>   # value on argv: visible to `ps`, kept in shell history
       icloud-secret set <name>            # hidden prompt, or stdin when piped
"""
guard args.count == 3 || args.count == 4, !args[2].isEmpty else { fail(usage) }
if args.count == 4 && args[1] != "set" { fail(usage) }

switch args[1] {
case "set":    setSecret(args[2], inline: args.count == 4 ? args[3] : nil)
case "get":    getSecret(args[2])
case "delete": deleteSecret(args[2])
default:       fail("unknown command '\(args[1])'")
}
