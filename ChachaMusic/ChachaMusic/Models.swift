import Foundation

struct Track: Identifiable, Codable, Hashable {
  var id: String
  var title: String
  var artist: String
  var fileName: String
  var isDemo: Bool
  var duration: Double
}
