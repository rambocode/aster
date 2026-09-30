// 设置侧栏图标与滚动面包屑的静态资源检查。
import Foundation
import Testing

/// 每个设置分区都要有图标和点击动画，页面要加载图标脚本并带面包屑容器。
@Test("设置侧栏每个分区都有图标与点击动画，页面带滚动面包屑")
func settingsNavIconsCoverEverySection() throws {
  let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/settings-ui", isDirectory: true)
  let html = try String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8)
  let icons = try String(contentsOf: directory.appendingPathComponent("nav-icons.js"), encoding: .utf8)
  let style = try String(contentsOf: directory.appendingPathComponent("nav-icons.css"), encoding: .utf8)

  #expect(html.contains("<script src=\"nav-icons.js\" defer></script>"))
  #expect(html.contains("<link rel=\"stylesheet\" href=\"nav-icons.css\">"))
  #expect(html.contains("id=\"content-topbar\"") && html.contains("id=\"topbar-page\""))
  let motions = ["general": "spin", "shell": "type", "controls": "nudge", "editor": "scroll", "agents": "rock",
                 "hosts": "wave", "view": "cluster", "appearance": "draw", "recipes": "page", "shortcuts": "tilt",
                 "advanced": "rock"]
  for (section, motion) in motions {
    #expect(icons.contains("    \(section): \"<svg"), "缺少 \(section) 图标")
    #expect(icons.contains("    \(section): \"\(motion)\","), "缺少 \(section) 动画")
    #expect(style.contains(".nav-icon-\(motion)"), "缺少 .nav-icon-\(motion) 样式")
  }
}
