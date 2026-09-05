import AVKit
import CoreMedia

/// AVKit 的实时、静音 sample-buffer 播放源。暂停只冻结镜像，不向终端发送控制字符。
@MainActor
final class PictureInPicturePlayback: NSObject,
  @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate
{
  let displayLayer = AVSampleBufferDisplayLayer()
  private(set) var isPaused = false
  private(set) var presentedFrameCount = 0
  var onPlayingChanged: ((Bool) -> Void)?
  var onRenderSizeChanged: ((CGSize) -> Void)?
  private var timebase: CMTimebase?

  override init() {
    super.init()
    displayLayer.videoGravity = .resizeAspect
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
    if let timebase {
      CMTimebaseSetTime(timebase, time: .zero)
      CMTimebaseSetRate(timebase, rate: 1)
      displayLayer.controlTimebase = timebase
    }
  }

  /// 返回错误信息表示帧无法呈现；背压时允许丢帧，下次从邮箱读取最新画面。
  func enqueue(_ pixelBuffer: CVPixelBuffer) -> String? {
    guard !isPaused else { return nil }
    if displayLayer.status == .failed { displayLayer.flush() }
    guard displayLayer.isReadyForMoreMediaData else { return nil }
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr, let format
    else { return "无法描述画中画视频帧" }
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: timebase.map(CMTimebaseGetTime) ?? .zero,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample) == noErr, let sample
    else { return "无法创建画中画视频帧" }
    // 终端帧按到达顺序立即显示，不是带可预测时长的视频；系统 PiP 的播放时钟可能
    // 与源图层不同，不能让实时帧排在另一个时钟的未来或被当作过期帧丢弃。
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,
      createIfNecessary: true) as? [NSMutableDictionary], let attachment = attachments.first
    else { return "无法设置画中画视频帧时序" }
    attachment[kCMSampleAttachmentKey_DisplayImmediately as String] = true
    displayLayer.enqueue(sample)
    if displayLayer.status != .failed { presentedFrameCount += 1 }
    return displayLayer.status == .failed ? "系统无法显示画中画视频帧" : nil
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    isPaused = !playing
    onPlayingChanged?(playing)
    controller.invalidatePlaybackState()
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController)
    -> CMTimeRange
  {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    isPaused
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions)
  {
    // 系统按源宽高比缩放镜像；改变 PiP 尺寸不能 resize 原终端或触发 PTY reflow。
    guard newRenderSize.width > 0, newRenderSize.height > 0 else { return }
    onRenderSizeChanged?(CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height)))
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion: @escaping () -> Void)
  {
    completion() // 实时源没有可 seek 的历史，仍必须完成系统请求。
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ controller: AVPictureInPictureController) -> Bool
  {
    true
  }
}
