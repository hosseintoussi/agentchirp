import Foundation
import CryptoKit

let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
let signature = Data(base64Encoded: args[2])!
let bytes = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: bytes) else {
    fputs("Update signature does not match the app's public key\n", stderr)
    exit(1)
}
print("Update signature matches the app's embedded public key")
