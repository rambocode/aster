import Testing

@testable import AsterCore

/// 稳定通道必须映射成空集合而不是 `["stable"]`：Sparkle 的默认通道不是一个名字，
/// 写错会让所有未标记 channel 的正式版对稳定用户直接消失。
@Test("更新通道映射到 Sparkle 的 channel 集合且预览包含稳定分支")
func updateChannelMapsToSparkleChannelNames() {
  #expect(UpdateChannel.stable.sparkleChannelNames.isEmpty)
  #expect(UpdateChannel.preview.sparkleChannelNames == ["preview"])
  #expect(UpdateChannel.allCases.count == 2)
  #expect(UpdateChannel(rawValue: "nightly") == nil)
  for channel in UpdateChannel.allCases {
    #expect(UpdateChannel(rawValue: channel.rawValue) == channel)
  }
}

/// 状态点颜色键是网页 CSS 的选择器值，拼错不会报错、只会静默变灰，因此逐个锁定。
@Test("更新状态映射为可读文案与状态点颜色键")
func softwareUpdateStatusMapsToWebStatus() {
  #expect(SoftwareUpdateStatus.unavailable.statusState == "unknown")
  #expect(SoftwareUpdateStatus.idle.statusState == "unknown")
  #expect(SoftwareUpdateStatus.checking.statusState == "unknown")
  #expect(SoftwareUpdateStatus.upToDate.statusState == "upToDate")
  #expect(SoftwareUpdateStatus.available(version: "0.5.0").statusState == "updateAvailable")
  #expect(SoftwareUpdateStatus.downloading(version: "0.5.0").statusState == "updateAvailable")
  #expect(SoftwareUpdateStatus.readyToInstall(version: "0.5.0").statusState == "updateAvailable")
  #expect(SoftwareUpdateStatus.failed(reason: "超时").statusState == "failed")

  #expect(SoftwareUpdateStatus.available(version: "0.5.0").statusText.contains("0.5.0"))
  #expect(SoftwareUpdateStatus.downloading(version: "0.5.0").statusText.contains("0.5.0"))
  #expect(SoftwareUpdateStatus.readyToInstall(version: "0.5.0").statusText.contains("0.5.0"))
  #expect(SoftwareUpdateStatus.failed(reason: "超时").statusText.contains("超时"))
  #expect(!SoftwareUpdateStatus.upToDate.statusText.isEmpty)

  // 进行中的两个状态不是结论，设置页据此保留顶部横幅。
  #expect(SoftwareUpdateStatus.checking.isTerminal == false)
  #expect(SoftwareUpdateStatus.downloading(version: "0.5.0").isTerminal == false)
  #expect(SoftwareUpdateStatus.upToDate.isTerminal)
  #expect(SoftwareUpdateStatus.readyToInstall(version: "0.5.0").isTerminal)
  #expect(SoftwareUpdateStatus.failed(reason: "超时").isTerminal)
}
