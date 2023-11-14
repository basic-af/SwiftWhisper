import Foundation
import whisper_cpp

public struct WhisperContextParams {
    let useGPU: Bool
    public init(useGPU: Bool) {
        self.useGPU = useGPU
    }
}

struct WhisperTokenData {
    var id: Int32   // Assuming whisper_token is an alias for uint32_t
    var tid: Int32  // Adjust as per the actual type of whisper_token

    var p: Float
    var plog: Float
    var pt: Float
    var ptsum: Float

    var t0: Int64
    var t1: Int64

    var vlen: Float
}

// If you have a pointer to whisper_token_data, add an initializer:
extension WhisperTokenData {
    init(cStruct: whisper_token_data) {
        self.id = cStruct.id
        self.tid = cStruct.tid
        self.p = cStruct.p
        self.plog = cStruct.plog
        self.pt = cStruct.pt
        self.ptsum = cStruct.ptsum
        self.t0 = cStruct.t0
        self.t1 = cStruct.t1
        self.vlen = cStruct.vlen
    }
}

public class Whisper {
    private let whisperContext: OpaquePointer
    private var unmanagedSelf: Unmanaged<Whisper>?

    public var delegate: WhisperDelegate?
    public var params: WhisperParams
    public private(set) var inProgress = false

    internal var frameCount: Int? // For progress calculation (value not in `whisper_state` yet)
    internal var cancelCallback: (() -> Void)?

    public init(fromFileURL fileURL: URL, withParams params: WhisperParams = .default, contextParams: WhisperContextParams) {
        var contextParamsInternal = whisper_context_default_params()
        contextParamsInternal.use_gpu = contextParams.useGPU
        self.whisperContext = fileURL.relativePath.withCString { whisper_init_from_file_with_params($0, contextParamsInternal) }
        self.params = params
    }

    public init(fromData data: Data, withParams params: WhisperParams = .default) {
        var copy = data // Need to copy memory so we can gaurentee exclusive ownership over pointer

        self.whisperContext = copy.withUnsafeMutableBytes { whisper_init_from_buffer($0.baseAddress!, data.count) }
        self.params = params
    }

    deinit {
        whisper_free(whisperContext)
    }

    private func prepareCallbacks() {
        /*
         C-style callbacks can't capture any references in swift, so we'll convert `self`
         to a pointer which whisper passes back as the `user_data` argument.

         We can unwrap that and obtain a copy of self inside the callback.
         */
        cleanupCallbacks()
        let unmanagedSelf = Unmanaged.passRetained(self)
        self.unmanagedSelf = unmanagedSelf
        params.new_segment_callback_user_data = unmanagedSelf.toOpaque()
        params.encoder_begin_callback_user_data = unmanagedSelf.toOpaque()
        params.progress_callback_user_data = unmanagedSelf.toOpaque()

        // swiftlint:disable line_length
        params.new_segment_callback = { (ctx: OpaquePointer?, _: OpaquePointer?, newSegmentCount: Int32, userData: UnsafeMutableRawPointer?) in
        // swiftlint:enable line_length
            guard let ctx = ctx,
                  let userData = userData else { return }
            let whisper = Unmanaged<Whisper>.fromOpaque(userData).takeUnretainedValue()
            guard let delegate = whisper.delegate else { return }

            let segmentCount = whisper_full_n_segments(ctx)
            var newSegments: [Segment] = []
            newSegments.reserveCapacity(Int(newSegmentCount))

            let startIndex = segmentCount - newSegmentCount

            for index in startIndex..<segmentCount {
                guard let text = whisper_full_get_segment_text(ctx, index) else { continue }
                let startTime = whisper_full_get_segment_t0(ctx, index)
                let endTime = whisper_full_get_segment_t1(ctx, index)

                newSegments.append(.init(
                    startTime: Int(startTime) * 10, // Time is given in ms/10, so correct for that
                    endTime: Int(endTime) * 10,
                    text: String(Substring(cString: text)),
                    speakerTurn: nil,
                    probabilities: nil
                ))
            }

            DispatchQueue.main.async {
                delegate.whisper(whisper, didProcessNewSegments: newSegments, atIndex: Int(startIndex))
            }
        }

        params.encoder_begin_callback = { (_: OpaquePointer?, _: OpaquePointer?, userData: UnsafeMutableRawPointer?) in
            guard let userData = userData else { return true }
            let whisper = Unmanaged<Whisper>.fromOpaque(userData).takeUnretainedValue()

            if whisper.cancelCallback != nil {
                return false
            }

            return true
        }

        // swiftlint:disable line_length
        params.progress_callback = { (_: OpaquePointer?, _: OpaquePointer?, progress: Int32, userData: UnsafeMutableRawPointer?) in
        // swiftlint:enable line_length
            guard let userData = userData else { return }
            let whisper = Unmanaged<Whisper>.fromOpaque(userData).takeUnretainedValue()

            DispatchQueue.main.async {
                whisper.delegate?.whisper(whisper, didUpdateProgress: Double(progress) / 100)
            }
        }
    }

    private func cleanupCallbacks() {
        guard let unmanagedSelf = unmanagedSelf else { return }

        unmanagedSelf.release()
        self.unmanagedSelf = nil
    }

    public func transcribe(audioFrames: [Float], parallel: Bool, threads: Int32, completionHandler: @escaping (Result<[Segment], Error>) -> Void) {
        prepareCallbacks()

        let wrappedCompletionHandler: (Result<[Segment], Error>) -> Void = { result in
            self.cleanupCallbacks()
            completionHandler(result)
        }

        guard !inProgress else {
            wrappedCompletionHandler(.failure(WhisperError.instanceBusy))
            return
        }
        guard audioFrames.count > 0 else {
            wrappedCompletionHandler(.failure(WhisperError.invalidFrames))
            return
        }

        inProgress = true
        frameCount = audioFrames.count

        DispatchQueue.global(qos: .userInitiated).async {
            if parallel {
                whisper_full_parallel(self.whisperContext, self.params.whisperParams, audioFrames, Int32(audioFrames.count), threads)
            } else {
                whisper_full(self.whisperContext, self.params.whisperParams, audioFrames, Int32(audioFrames.count))
            }
            
            let segmentCount = whisper_full_n_segments(self.whisperContext)

            var segments: [Segment] = []
            segments.reserveCapacity(Int(segmentCount))

            for index in 0..<segmentCount {

                guard let text = whisper_full_get_segment_text(self.whisperContext, index) else { continue }
                let startTime = whisper_full_get_segment_t0(self.whisperContext, index)
                let endTime = whisper_full_get_segment_t1(self.whisperContext, index)
                let speakerTurn: Bool = whisper_full_get_segment_speaker_turn_next(self.whisperContext, index)
                let numberOfTokens = whisper_full_n_tokens(self.whisperContext, index)

                let probabilities: [SegmentTextRange] = (0...numberOfTokens - 1).map { token in
                    let tokenText = whisper_full_get_token_text(self.whisperContext, index, token)
                    let tokenData = whisper_full_get_token_data(self.whisperContext, index, token)

                    if let cString = tokenText {
                        let tokenTextDecoded = String(cString: cString)

                        if self.containsSpecialTokens(in: tokenTextDecoded) {
                            return nil
                        }

                        let tokenDataDecoded = WhisperTokenData(cStruct: tokenData)
                        
                        print("\(tokenTextDecoded) - \(tokenDataDecoded)")

                        return SegmentTextRange(text: tokenTextDecoded, probability: tokenDataDecoded.p)
                    } else {
                        return nil
                    }
                }
                .compactMap({$0})

                segments.append(
                    .init(
                        startTime: Int(startTime) * 10, // Correct for ms/10
                        endTime: Int(endTime) * 10,
                        text: String(Substring(cString: text)),
                        speakerTurn: speakerTurn,
                        probabilities: probabilities
                    )
                )
            }

            if let cancelCallback = self.cancelCallback {
                DispatchQueue.main.async {
                    // Should cancel callback be called after delegate and completionHandler?
                    cancelCallback()

                    let error = WhisperError.cancelled

                    self.delegate?.whisper(self, didErrorWith: error)
                    wrappedCompletionHandler(.failure(error))
                }
            } else {
                DispatchQueue.main.async {
                    self.delegate?.whisper(self, didCompleteWithSegments: segments)
                    wrappedCompletionHandler(.success(segments))
                }
            }

            self.frameCount = nil
            self.cancelCallback = nil
            self.inProgress = false
        }
    }

    func containsSpecialTokens(in text: String) -> Bool {
        let pattern = "\\[_(TT|EOT|SOT|SOLM|PREV|NOSP|NOT|BEG|extra_token)_(\\d+)?\\]"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        
        // Check if there's at least one match
        return regex?.firstMatch(in: text, options: [], range: range) != nil
    }

    public func cancel(completionHandler: @escaping () -> Void) throws {
        guard inProgress else { throw WhisperError.cancellationError(.notInProgress) }
        guard cancelCallback == nil else { throw WhisperError.cancellationError(.pendingCancellation)}

        cancelCallback = completionHandler
    }

    @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
    public func transcribe(audioFrames: [Float], parallel: Bool, threads: Int32 = 2) async throws -> [Segment] {
        return try await withCheckedThrowingContinuation { cont in
            self.transcribe(audioFrames: audioFrames, parallel: parallel, threads: threads) { result in
                switch result {
                case .success(let segments):
                    cont.resume(returning: segments)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    @available(iOS 13, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
    public func cancel() async throws {
        return try await withCheckedThrowingContinuation { cont in
            do {
                try self.cancel {
                    cont.resume()
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
