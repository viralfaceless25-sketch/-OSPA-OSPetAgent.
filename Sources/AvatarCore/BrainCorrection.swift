import Foundation

public struct BrainCorrection: Codable, Equatable, Sendable {
    public let requestShape: String
    public let rejectedApplicationName: String
    public let declinedAt: Date

    public init(
        requestShape: String,
        rejectedApplicationName: String,
        declinedAt: Date
    ) {
        self.requestShape = requestShape
        self.rejectedApplicationName = rejectedApplicationName
        self.declinedAt = declinedAt
    }
}

/// A bounded, inspectable approximation of a request used only to retrieve
/// negative preference hints. It never carries execution authority.
public enum BrainRequestShape {
    public static let maximumScalarCount = 160

    public static func canonical(_ request: String) -> String? {
        let source = request.precomposedStringWithCanonicalMapping.lowercased()
        var result = ""
        var scalarCount = 0
        var needsSeparator = false

        for scalar in source.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !result.isEmpty, scalarCount < maximumScalarCount {
                    result.append(" ")
                    scalarCount += 1
                }
                needsSeparator = false
                guard scalarCount < maximumScalarCount else { break }
                result.append(String(scalar))
                scalarCount += 1
            } else if !result.isEmpty {
                needsSeparator = true
            }
        }

        let shape = result.trimmingCharacters(in: .whitespaces)
        return shape.isEmpty ? nil : shape
    }
}
