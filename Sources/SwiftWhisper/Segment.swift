import Foundation

public struct Segment: Equatable {
    public let startTime: Int
    public let endTime: Int
    public let text: String
    public let speakerTurn: Bool?
    public let probabilities: [SegmentTextRange]?
}

public struct SegmentTextRange: Equatable {
    public let text: String
    public let probability: Float
}
