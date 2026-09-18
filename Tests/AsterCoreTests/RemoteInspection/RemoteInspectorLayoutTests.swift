// 远端面板分页与宽度档位的规则测试。

import Foundation
import Testing

@testable import AsterCore

@Test func remoteMonitorTabsCoverEveryExpectedSection() {
  let covered = Set(RemoteMonitorTab.allCases.flatMap(\.sections))
  #expect(covered == Set(RemoteHostMonitorSection.expected))
}

@Test func remoteMonitorTabsDoNotOverlap() {
  var seen: Set<String> = []
  for tab in RemoteMonitorTab.allCases {
    for section in tab.sections {
      #expect(seen.insert(section).inserted, "分段 \(section) 出现在多个分页")
    }
  }
}

@Test func remoteInspectorLayoutSwitchesAtThreshold() {
  #expect(RemoteInspectorLayout.mode(forWidth: 240) == .compact)
  #expect(RemoteInspectorLayout.mode(forWidth: 299.9) == .compact)
  #expect(RemoteInspectorLayout.mode(forWidth: 300) == .regular)
  #expect(RemoteInspectorLayout.mode(forWidth: 480) == .regular)
  // 布局还没跑过时宽度是 0 或 NaN，必须落到信息最少但一定放得下的窄栏。
  #expect(RemoteInspectorLayout.mode(forWidth: 0) == .compact)
  #expect(RemoteInspectorLayout.mode(forWidth: .nan) == .compact)
}
