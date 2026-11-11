import Foundation
import CryptoKit

/// Licencia premium verificada sin internet (ECDSA P-256 / SHA-256). Lógica pura, sin AppKit.
/// Formato: `APP.<payload base64url>.<firma base64url>`; la firma (r‖s, 64 bytes) cubre los bytes del payload.
struct LicenseInfo: Equatable {
    let app: String
    let name: String
    let issued: String
}

enum LicenseError: Error, Equatable {
    case invalid        // clave mal formada o firma incorrecta
    case wrongApp       // firma válida pero de otra app
    case alreadyActive  // esta misma clave ya está activada
}

enum LicenseConfig {
    /// Identificador de esta app dentro de la licencia.
    static let appID = "ferry"
    /// Clave pública (SPKI DER en base64). La privada NO está en este repositorio.
    static let publicKeyBase64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAErtZHvwOjaMNN6Wv5ts90ulpylP9W1Y9Q7ChUIEvUlSZs7Tjvf+ZvGKoVDkE6Xl/LRx5k67YzxqilIIAE/c2GXQ=="

    static var publicKey: P256.Signing.PublicKey? {
        guard let der = Data(base64Encoded: publicKeyBase64) else { return nil }
        return try? P256.Signing.PublicKey(derRepresentation: der)
    }
}

enum LicenseVerifier {
    /// Decodifica base64url con o sin relleno.
    static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t = t.replacingOccurrences(of: "=", with: "")
        guard t.count % 4 != 1 else { return nil }
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }

    private struct Payload: Decodable { let app: String; let name: String; let issued: String? }

    static func verify(_ rawKey: String,
                       app: String = LicenseConfig.appID,
                       publicKey: P256.Signing.PublicKey? = LicenseConfig.publicKey) -> Result<LicenseInfo, LicenseError> {
        guard let publicKey else { return .failure(.invalid) }
        let key = rawKey.filter { !$0.isWhitespace }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty,
              let payloadData = base64URLDecode(parts[1]), !payloadData.isEmpty,
              let sigData = base64URLDecode(parts[2]), sigData.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sigData),
              publicKey.isValidSignature(signature, for: payloadData),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else { return .failure(.invalid) }
        let appID = payload.app.lowercased()
        guard parts[0].lowercased() == appID else { return .failure(.invalid) } // prefijo ≠ payload
        guard appID == app.lowercased() || appID == "all" else { return .failure(.wrongApp) }
        return .success(LicenseInfo(app: appID, name: payload.name, issued: payload.issued ?? ""))
    }
}
