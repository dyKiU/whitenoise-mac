import Foundation

nonisolated struct OpenverseImageSearchResponse: Decodable {
    let results: [OpenverseImageRecord]
}
