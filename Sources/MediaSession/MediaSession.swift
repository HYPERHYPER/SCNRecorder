//
//  MediaSession.swift
//  SCNRecorder
//
//  Created by Vladislav Grigoryev on 24.05.2020.
//  Copyright © 2020 GORA Studio. https://gora.studio
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import AVFoundation

final class MediaSession {

  typealias Input = MediaSessionInput

  typealias Output = MediaSessionOutput

  enum VideoInput: Input.Video {

    case pixel(_ input: Input.PixelBufferVideo)

    case sample(_ input: Input.SampleBufferVideo)

    var videoInput: Input.Video {
      switch self {
      case .pixel(let input): return input
      case .sample(let input): return input
      }
    }

    var size: CGSize { videoInput.size }

    var videoColorProperties: [String: String]? { videoInput.videoColorProperties }

    func start() { videoInput.start() }

    func stop() { videoInput.stop() }
  }

  let queue: DispatchQueue

  @UnfairAtomic var videoOutputs = [Output.Video]()

  @UnfairAtomic var audioOutputs = [Output.Audio]()

  @Observable var error: Swift.Error?

  let videoInput: VideoInput

  private(set) var audioInput: Input.SampleBufferAudio?

  init(
    queue: DispatchQueue,
    videoInput: VideoInput
  ) {
    self.queue = queue
    self.videoInput = videoInput
  }

  convenience init(
    queue: DispatchQueue,
    videoInput: Input.PixelBufferVideo
  ) {
    self.init(queue: queue, videoInput: .pixel(videoInput))

    videoInput.output = { [weak self] (buffer: CVBuffer, time: CMTime) in
      guard let this = self else { return }
      this.appendVideoBuffer(buffer, at: time)
    }
  }

  convenience init(
    queue: DispatchQueue,
    videoInput: Input.SampleBufferVideo
  ) {
    self.init(queue: queue, videoInput: .sample(videoInput))

    videoInput.output = { [weak self] (sampleBuffer: CMSampleBuffer) in
      guard let this = self else { return }
      this.appendVideoBuffer(sampleBuffer)
    }
  }

  func setAudioInput(_ audioInput: Input.SampleBufferAudio) {
    self.audioInput = audioInput
    audioInput.output = { [weak self] (sampleBuffer) in
      guard let this = self else { return }
      this.appendAudioBuffer(sampleBuffer)
    }
  }
}

extension MediaSession {

  func appendVideoBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
    videoOutputs.forEach { $0.appendVideoPixelBuffer(pixelBuffer, at: time) }
  }

  func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
    videoOutputs.forEach { $0.appendVideoSampleBuffer(sampleBuffer) }
  }

  func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
    audioOutputs.forEach { $0.appendAudioSampleBuffer(sampleBuffer) }
  }
}

@available(iOS 13.0, *)
extension MediaSession {

  func capturePixelBuffers(
    handler: @escaping (CVPixelBuffer, CMTime) -> Void
  ) -> PixelBufferOutput {
    let output = PixelBufferOutput(handler: handler)
    let weakOutput = PixelBufferOutput.Weak(output: output) { [weak self] in
        self?.removeVideoOutput($0)
    }
    addVideoOutput(weakOutput)
    return output
  }

  func makeVideoRecording(
    to url: URL,
    videoSettings: VideoSettings = VideoSettings(),
    audioSettings: AudioSettings? = nil
  ) throws -> VideoRecording {
    var videoSettings = videoSettings
    if videoSettings.size == nil { videoSettings.size = videoInput.size }
    videoSettings.videoColorProperties = videoInput.videoColorProperties

    let audioSettingsDictionary = audioSettings?.outputSettings
      ?? audioInput?.recommendedAudioSettingsForAssetWriter(
        writingTo: videoSettings.fileType.avFileType
      )

    let videoOutput = try VideoOutput(
      url: url,
      videoSettings: videoSettings,
      audioSettings: audioSettingsDictionary,
      queue: queue
    )

    videoOutput.onFinalState = { [weak self] in
      self?.removeVideoOutput($0)
      self?.removeAudioOutput($0)
    }

    addVideoOutput(videoOutput)
    addAudioOutput(videoOutput)
    return videoOutput.startVideoRecording()
  }

  func takePhoto(
    scale: CGFloat,
    orientation: UIImage.Orientation,
    handler: @escaping (Result<UIImage, Swift.Error>) -> Void
  ) {
    takePixelBuffer(
      handler: ImageOutput.takeUIImage(
        scale: scale,
        orientation: orientation,
        handler: handler
      )
    )
  }

  func takeCoreImage(handler: @escaping (Result<CIImage, Swift.Error>) -> Void) {
    takePixelBuffer(handler: ImageOutput.takeCIImage(handler: handler))
  }

  func takePixelBuffer(handler: @escaping (Result<CVPixelBuffer, Swift.Error>) -> Void) {
    var localHandler: ((Result<CVPixelBuffer, Swift.Error>) -> Void)?
    let output = capturePixelBuffers(
      handler: ImageOutput.takePixelBuffer(handler: { localHandler?($0) })
    )

    localHandler = {
      _ = output
      localHandler = nil
      handler($0)
    }
  }
}

extension MediaSession {

  func addVideoOutput(_ videoOutput: MediaSession.Output.Video) {
    if ($videoOutputs.modify {
      $0.append(videoOutput)
      return $0.count == 1
    }) { videoInput.start() }
  }

  func removeVideoOutput(_ videoOutput: MediaSession.Output.Video) {
    if ($videoOutputs.modify {
      $0 = $0.filter { $0 !== videoOutput }
      return $0.count == 0
    }) { videoInput.stop() }
  }

  func addAudioOutput(_ audioOutput: MediaSession.Output.Audio) {
    if ($audioOutputs.modify {
      $0.append(audioOutput)
      return $0.count == 1
    }) { audioInput?.start() }
  }

  func removeAudioOutput(_ audioOutput: MediaSession.Output.Audio) {
    if ($audioOutputs.modify {
      $0 = $0.filter { $0 !== audioOutput }
      return $0.count == 0
    }) { audioInput?.stop() }
  }
}
