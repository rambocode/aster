// 界面字号档位与「加深界面文字」取色规则的领域测试。
import Foundation
import Testing

@testable import AsterCore

@Test("界面字号五档的倍数单调递增，默认档为 1")
func interfaceTextScaleFactorsAreOrdered() {
  let factors = InterfaceTextScale.allCases.map(\.factor)
  #expect(factors == [0.9, 1, 1.15, 1.3, 1.5])
  #expect(InterfaceTextScale.standard.factor == 1)
}

@Test("旧配置没有界面文字字段时按默认档解析，开关关闭")
func legacyConfigurationResolvesInterfaceTextDefaults() throws {
  var appearance = AppearanceConfiguration()
  appearance.interfaceTextScale = nil
  appearance.interfaceHighContrastText = nil
  #expect(appearance.resolvedInterfaceTextScale == .standard)
  #expect(!appearance.resolvedInterfaceHighContrastText)

  var configuration = AsterConfiguration()
  configuration.appearance = appearance
  let normalized = configuration.normalized()
  #expect(normalized.appearance.interfaceTextScale == .standard)
  #expect(normalized.appearance.interfaceHighContrastText == false)
}

@Test("界面字号档位写入配置后编解码往返不丢")
func interfaceTextScaleRoundTripsThroughConfiguration() throws {
  var configuration = AsterConfiguration()
  configuration.appearance.interfaceTextScale = .larger
  configuration.appearance.interfaceHighContrastText = true
  let data = try JSONEncoder().encode(configuration)
  let decoded = try JSONDecoder().decode(AsterConfiguration.self, from: data)
  #expect(decoded.appearance.resolvedInterfaceTextScale == .larger)
  #expect(decoded.appearance.resolvedInterfaceHighContrastText)
}

@Test("未知的字号档位落回默认，而不是让解码失败")
func unknownInterfaceTextScaleFallsBackToStandard() throws {
  let decoded = try JSONDecoder().decode([InterfaceTextScale].self, from: Data(#"["huge"]"#.utf8))
  #expect(decoded == [.standard])
}

@Test("不透明背景上，加深后的次要文字对比度不低于 4.5")
func strengthenedTextMeetsMinimumContrastOnOpaqueBackground() throws {
  // 设置页浅色模式的三级文字 #aaa 在白底上只有约 2.3:1，是反馈里「太淡」的典型。
  let pale = try #require(HexColor("#AAAAAA"))
  let ink = try #require(HexColor("#1A1A1A"))
  let white = try #require(HexColor("#FFFFFF"))
  #expect(InterfaceTextContrast.contrastRatio(pale, white) < 3)

  let result = InterfaceTextContrast.strengthened(pale, toward: ink, against: white)
  #expect(InterfaceTextContrast.contrastRatio(result, white) >= InterfaceTextContrast.minimumRatio)

  // 深色主题同理：朝亮的主文字色推。
  let dim = try #require(HexColor("#5C6066"))
  let light = try #require(HexColor("#E8E8E6"))
  let dark = try #require(HexColor("#171817"))
  let darkResult = InterfaceTextContrast.strengthened(dim, toward: light, against: dark)
  #expect(
    InterfaceTextContrast.contrastRatio(darkResult, dark) >= InterfaceTextContrast.minimumRatio)
}

@Test("半透明或未知背景只做固定幅度的加深，并保留原色透明度")
func strengthenedTextUsesBaseBlendWithoutOpaqueBackground() throws {
  let pale = try #require(HexColor("#AAAAAA80"))
  let ink = try #require(HexColor("#000000"))
  let glass = try #require(HexColor("#FFFFFF00"))

  let unknown = InterfaceTextContrast.strengthened(pale, toward: ink, against: nil)
  let translucent = InterfaceTextContrast.strengthened(pale, toward: ink, against: glass)
  // 0xAA 朝 0 推 40% 得 0x66。
  #expect(unknown == HexColor(red: 0x66, green: 0x66, blue: 0x66, alpha: 0x80))
  #expect(translucent == unknown)
}

@Test("已经足够深的文字只按固定幅度推近，不会越过主文字色")
func strengthenedTextNeverOvershootsForeground() throws {
  let ink = try #require(HexColor("#202124"))
  let white = try #require(HexColor("#FFFFFF"))
  #expect(InterfaceTextContrast.strengthened(ink, toward: ink, against: white) == ink)
}
