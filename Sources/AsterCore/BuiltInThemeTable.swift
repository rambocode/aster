import Foundation

/// Otty 1.3.1 的内置主题真值表。
///
/// 终端前景、背景、ANSI 16 色及显式光标/选区颜色逐项来自 Otty 随应用发布的
/// `.ottytheme`；界面令牌也优先采用主题中独立声明的值。未声明的光标与选区颜色
/// 遵循 Otty 的级联规则；本阶段先把浅色选区回退对齐为终端前景的 30% 透明度。
enum BuiltInThemeTable {
  static let all: [TerminalTheme] = [
    make(
      id: "april", name: "April", mode: .light, foreground: "#17703f", background: "#ffffff",
      ansi: "#1A1F1C #B23B3B #5DA802 #B88A3A #3D87C8 #9B5AAB #3F9B85 #8cbaa5 #3D4B44 #D04A3D #7CB342 #D89B47 #5AA3D6 #A67ABF #5BB8A0 #2A332E",
      interfaceForeground: "#2A332E", secondary: "#6B7A73", tertiary: "#9AA8A1",
      accent: "#5DA802", panel: "#F4F6F4", surface: "#FFFFFF", border: "#E0E6E2",
      interfaceWindow: "#ffffff",
      style: aprilStyle),
    make(
      id: "ayu-light", name: "Ayu Light", mode: .light, foreground: "#5C6166", background: "#FCFCFC",
      ansi: "#010101 #E7666A #80AB24 #EBA54D #4196DF #9870C3 #51B891 #C1C1C1 #343434 #EE9295 #9FD32F #F0BC7B #6DAEE6 #B294D2 #75C7A8 #DBDBDB",
      interfaceForeground: "#1A1A1A", secondary: "#8E8E93", tertiary: "#BBBBBB",
      accent: "#4196DF", surface: "#FFFFFF", border: "#E0E0E0",
      interfaceWindow: "#FCFCFC", style: ayuLightStyle),
    make(
      id: "floating-card", name: "Floating Card", mode: .light, foreground: "#24292E", background: "#FFFFFF",
      ansi: "#24292E #D73A49 #28A745 #DBAB09 #0366D6 #5A32A3 #0598BC #d4d6d7 #959DA5 #CB2431 #22863A #B08800 #005CC5 #5A32A3 #3192AA #D1D5DA",
      cursor: "#18181B", selection: "#E4E4E7", interfaceForeground: "#18181B",
      secondary: "#52525B", tertiary: "#A1A1AA", accent: "#000000", panel: "#FFFFFF",
      surface: "#FAFAFA", container: "#FFFFFF", border: "#E5E5E5",
      interfaceWindow: "none", material: .glass,
      style: floatingCardStyle),
    make(
      id: "glass-light", name: "Glass Light", mode: .light, foreground: "#303030", background: "none",
      ansi: "#303030 #A31700 #0A7F3D #AF551D #006CD8 #583CAC #00798A #e5e5e5 #8c8c8c #A31700 #0A7F3D #AF551D #006CD8 #583CAC #00798A #cdcdcd",
      cursor: "#303030", cursorText: "#565656", selectionForeground: "#FAFAFF",
      selection: "#AD95E9", interfaceForeground: "#25313B", secondary: "#5D6872",
      tertiary: "#93A0A9", accent: "#4B8FB7", panel: "#ffffff", surface: "#F7FBFD",
      border: "#2E3E4A29", interfaceWindow: "none", material: .glass, style: glassLightStyle),
    make(
      id: "newsprint", name: "Newsprint", mode: .light, foreground: "#333638", background: "#f4f4f1",
      ansi: "#262522 #A33A35 #5C7A3E #967927 #2F5F8A #904180 #3E7A78 #BFBAAE #7A766B #C25852 #7A9A52 #d4a945 #4470a0 #be79bb #739797 #dfdbd1",
      interfaceForeground: "#262522", secondary: "#7A766B", tertiary: "#B8B3A6",
      accent: "#2F5F8A", panel: "#f3f2ee", surface: "#F4F1EA", border: "#DBD6C8",
      interfaceWindow: "#F4F4F1", style: newsprintStyle),
    make(
      id: "one-light", name: "One Light", mode: .light, foreground: "#2A2B33", background: "#FFFFFF",
      ansi: "#000000 #DE3D35 #3E953A #D2B67B #2F5AF3 #A00095 #3E953A #BBBBBB #000000 #DE3D35 #3E953A #D2B67B #2F5AF3 #A00095 #3E953A #FFFFFF",
      panel: "#F7F7F7", border: "#E5E5E5",
      interfaceWindow: "#FFFFFF", style: oneLightStyle),
    make(
      id: "paper", name: "Paper", mode: .light, foreground: "#1A1A1A", background: "#FCFBF9",
      ansi: "#1A1A1A #A33A3A #2B5A38 #A85A20 #4A7A8A #4A3A6A #3A7A6A #C1BEB5 #8C8A80 #C36A6A #6B9A78 #C88A50 #7A9AAA #8A7A9A #6ABAAA #EBEBE6",
      interfaceForeground: "#1A1A1A", secondary: "#8C8A80", tertiary: "#C1BEB5",
      accent: "#2B5A38", panel: "#F5F4F0", surface: "#FCFBF9", border: "#E0DFD5",
      interfaceWindow: "#FCFBF9", style: paperStyle),
    make(
      id: "pink", name: "Pink", mode: .light, foreground: "#2A2422", background: "#F5F0F0",
      ansi: "#2A2422 #B85951 #6B8442 #B8862E #4D72A0 #B16078 #4F8587 #9A938E #6B6360 #D87169 #8AA254 #D5A445 #6B8FBE #CC8595 #6FA4A6 #1A1412",
      cursor: "#CC8595", cursorText: "#F5F0F0", selectionForeground: "#2A2422",
      selection: "#EDC4BE", interfaceForeground: "#2A2422", secondary: "#7A6E6A",
      tertiary: "#B8ADA8", accent: "#CC8595", panel: "#F0EAEA", surface: "#FBF7F6",
      border: "#E5DCDA", interfaceWindow: "#F5F0F0", style: pinkStyle),
    make(
      id: "solarized-light", name: "Solarized Light", mode: .light, foreground: "#586E75", background: "#FDF6E3",
      ansi: "#073642 #DC322F #859900 #B58900 #268BD2 #D33682 #2AA198 #EEE8D5 #002B36 #CB4B16 #586E75 #657B83 #839496 #6C71C4 #93A1A1 #FDF6E3",
      interfaceForeground: "#586E75", secondary: "#839496", tertiary: "#93A1A1",
      accent: "#268BD2", panel: "#F3EEDC", surface: "#EEE8D5", border: "#E2DCC7",
      interfaceWindow: "#FDF6E3", style: solarizedLightStyle),

    make(
      id: "april-dark", name: "April Dark", mode: .dark, foreground: "#FFFFFF", background: "#141B18",
      ansi: "#101513 #E06C75 #98C379 #E5C07B #61AFEF #B876B8 #5FB8A0 #8A9992 #5C6B64 #EB8A91 #C5E86C #F0D499 #82C2F3 #D098D0 #85CDB6 #FFFFFF",
      interfaceForeground: "#FFFFFF", secondary: "#8A9992", tertiary: "#5C6B64",
      accent: "#C5E86C", panel: "#141B18", surface: "#1A2420", border: "#25332D",
      style: aprilDarkStyle),
    make(
      id: "ayu-dark", name: "Ayu Dark", mode: .dark, foreground: "#B3B1AD", background: "#0A0E14",
      ansi: "#01060E #EA6C73 #91B362 #F9AF4F #53BDFA #FAE994 #90E1C6 #C7C7C7 #686868 #F07178 #C2D94C #FFB454 #59C2FF #FFEE99 #95E6CB #FFFFFF",
      secondary: "#c0c0c0", tertiary: "#9f9f9f", style: ayuDarkStyle),
    make(
      id: "catppuccin-mocha", name: "Catppuccin Mocha", mode: .dark, foreground: "#CDD6F4", background: "#1E1E2E",
      ansi: "#45475A #F38BA8 #A6E3A1 #F9E2AF #89B4FA #F5C2E7 #94E2D5 #BAC2DE #585B70 #F38BA8 #A6E3A1 #F9E2AF #89B4FA #F5C2E7 #94E2D5 #A6ADC8"),
    make(
      id: "dracula", name: "Dracula", mode: .dark, foreground: "#F8F8F2", background: "#282A36",
      ansi: "#21222C #FF5555 #50FA7B #F1FA8C #BD93F9 #FF79C6 #8BE9FD #F8F8F2 #6272A4 #FF6E6E #69FF94 #FFFFA5 #D6ACFF #FF92DF #A4FFFF #FFFFFF"),
    make(
      id: "glass-dark", name: "Glass Dark", mode: .dark, foreground: "#F7F8FF", background: "none",
      ansi: "#252A35 #FF8A8A #A8D46F #E8C778 #8DB7FF #D1A3FF #7FD6C2 #E3E6F0 #747B8E #FFB0A8 #C8EA90 #F2DA9A #B2CCFF #E0C2FF #A3E6D8 #FFFFFF",
      cursor: "#F7F8FF", selection: "#bbc9ed", interfaceForeground: "#F7F8FF",
      secondary: "#C9CEDB", tertiary: "#8E95A8", accent: "#b4d979", panel: "#444445",
      surface: "#40434b", border: "#6B7286", material: .vibrancyRegular,
      style: glassDarkStyle),
    make(
      id: "gruvbox-dark", name: "Gruvbox Dark", mode: .dark, foreground: "#EBDBB2", background: "#282828",
      ansi: "#282828 #CC241D #98971A #D79921 #458588 #B16286 #689D6A #A89984 #928374 #FB4934 #B8BB26 #FABD2F #83A598 #D3869B #8EC07C #EBDBB2"),
    make(
      id: "monokai-classic", name: "Monokai Classic", mode: .dark, foreground: "#FDFFF1", background: "#272822",
      ansi: "#272822 #F92672 #A6E22E #E6DB74 #FD971F #AE81FF #66D9EF #FDFFF1 #6E7066 #F92672 #A6E22E #E6DB74 #FD971F #AE81FF #66D9EF #FDFFF1",
      cursor: "#C0C1B5", cursorText: "#8D8E82", selectionForeground: "#FDFFF1", selection: "#57584F"),
    make(
      id: "night", name: "Night", mode: .dark, foreground: "#ffffff", background: "#363B40",
      ansi: "#1F2226 #F07178 #C3E88D #FFCB6B #82AAFF #C792EA #89DDFF #BFC7D5 #676E95 #FF8B92 #D2EE9F #FFD68A #9CBEFF #D5A8F0 #A5E5FF #FFFFFF",
      interfaceForeground: "#dce4f3", secondary: "#A5ACBA", tertiary: "#676E95",
      accent: "#82AAFF", panel: "#363B40", surface: "#2E3033", border: "#222426",
      style: nightStyle),
    make(
      id: "nord", name: "Nord", mode: .dark, foreground: "#f1f6ff", background: "#2E3440",
      ansi: "#3B4252 #BF616A #A3BE8C #EBCB8B #81A1C1 #B48EAD #88C0D0 #E5E9F0 #4C566A #BF616A #A3BE8C #EBCB8B #81A1C1 #B48EAD #8FBCBB #ECEFF4",
      cursor: "#E5E9F0", cursorText: "#2E3440", selectionForeground: "#2e3440",
      selection: "#e5e9f0", interfaceForeground: "#E5E9F0", secondary: "#C0C7D3",
      tertiary: "#7B8294", accent: "#88C0D0", panel: "#2E3440", surface: "#3B4252",
      container: "#2E3440", border: "#FFFFFF0F", interfaceWindow: "#2E3440",
      material: TerminalThemeMaterial.none,
      style: nordStyle),
    make(
      id: "one-dark", name: "One Dark", mode: .dark, foreground: "#ABB2BF", background: "#282C34",
      ansi: "#1E2127 #E06C75 #98C379 #D19A66 #61AFEF #C678DD #56B6C2 #ABB2BF #5C6370 #E06C75 #98C379 #D19A66 #61AFEF #C678DD #56B6C2 #FFFFFF"),
    make(
      id: "owl", name: "Owl", mode: .dark, foreground: "#DEDEDE", background: "#2F2B2C",
      ansi: "#302C2C #5A5A5A #989898 #CACACA #656565 #B1B1B1 #7F7F7F #DEDEDE #5D595B #DA5B2C #989898 #CACACA #656565 #B1B1B1 #7F7F7F #FFFFFF",
      cursor: "#DEDEDE", cursorText: "#2F2B2C", selectionForeground: "#2F2B2C", selection: "#DEDEDE"),
    make(
      id: "rose-pine", name: "Rosé Pine", mode: .dark, foreground: "#E0DEF4", background: "#191724",
      ansi: "#26233A #EB6F92 #31748F #F6C177 #9CCFD8 #C4A7E7 #EBBCBA #E0DEF4 #6E6A86 #EB6F92 #31748F #F6C177 #9CCFD8 #C4A7E7 #EBBCBA #E0DEF4"),
    make(
      id: "seafoam-pastel", name: "Seafoam Pastel", mode: .dark, foreground: "#D4E7D4", background: "#243435",
      ansi: "#757575 #825D4D #728C62 #ADA16D #4D7B82 #8A7267 #729494 #E0E0E0 #8A8A8A #CF937A #98D9AA #FAE79D #7AC3CF #D6B2A1 #ADE0E0 #E0E0E0",
      cursor: "#57647A", cursorText: "#323232", selectionForeground: "#9E8B13", selection: "#FFFFFF"),
    make(
      id: "solarized-dark", name: "Solarized Dark", mode: .dark, foreground: "#839496", background: "#002B36",
      ansi: "#073642 #DC322F #859900 #B58900 #268BD2 #D33682 #2AA198 #EEE8D5 #002B36 #CB4B16 #586E75 #657B83 #839496 #6C71C4 #93A1A1 #FDF6E3"),
    make(
      id: "tokyo-night", name: "Tokyo Night", mode: .dark, foreground: "#C0CAF5", background: "#1A1B26",
      ansi: "#15161E #F7768E #9ECE6A #E0AF68 #7AA2F7 #BB9AF7 #7DCFFF #A9B1D6 #414868 #FF899D #9FE044 #FABA4A #8DB0FF #C7A9FF #A4DAFF #C0CAF5"),
  ]

  // 以下结构化令牌逐项抄录自 Otty 1.3.1 原始主题文件，仓库副本在 `Resources/themes`
  // （`ThemeResourceBaselineTests` 比对两侧防漂移）。没有把阴影、
  // 透明度或边框“视觉近似”为统一值，确保主题之间原本的性格差异可以被渲染。
  private static let aprilStyle = TerminalThemeStyle(
    radius: 4,
    sidebarBackground: color("#F4F6F4"),
    sidebarBorderColor: color("#E0E6E2"),
    sidebarBorderWidth: 1,
    titlebarBackground: color("#F4F6F4"),
    titlebarForeground: color("#698678"),
    tab: TerminalTabStyle(
      radius: 0,
      height: 32,
      foreground: color("#6B7A73"),
      hoverBackground: color("#0000000A"),
      activeBackground: color("#14934B2F"),
      activeForeground: color("#2A332E"),
      activeFontWeight: 500,
      activeShadow: shadow(y: 1, blur: 3, color: "#0000000F")
    ),
    horizontalTabBarBackground: color("#F4F6F4"),
    horizontalTabBarHeight: 44,
    container: TerminalContainerStyle(radius: 0)
  )

  private static let aprilDarkStyle = TerminalThemeStyle(
    radius: 4,
    sidebarBackground: color("#1A2420"),
    sidebarBorderColor: color("#25332D"),
    sidebarBorderWidth: 1,
    tab: TerminalTabStyle(
      radius: 4,
      foreground: color("#8A9992"),
      hoverBackground: color("#22302A"),
      activeBackground: color("#22302A"),
      activeForeground: color("#FFFFFF"),
      activeFontWeight: 500
    ),
    container: TerminalContainerStyle(radius: 4)
  )

  private static let ayuLightStyle = TerminalThemeStyle(
    radius: 6,
    sidebarBackground: color("#F4F4F400"),
    sidebarBorderColor: color("#D7D7D7"),
    sidebarBorderWidth: 1,
    sidebarMaterial: .glass,
    titlebarBackground: color("#F4F4F4"),
    titlebarMaterial: .vibrancyThin,
    tab: TerminalTabStyle(
      radius: 0,
      hoverBackground: color("#0000000A"),
      activeBackground: color("#6F869E50"),
      activeForeground: color("#1A1A1A"),
      activeFontWeight: 600,
      activeShadow: shadow(y: 1, blur: 3, color: "#0000000F")
    ),
    horizontalTabBarMaterial: .vibrancyThin,
    container: TerminalContainerStyle()
  )

  private static let ayuDarkStyle = TerminalThemeStyle(
    sidebarMaterial: .vibrancyThin
  )

  private static let floatingCardStyle = TerminalThemeStyle(
    radius: 8,
    sidebarBackground: color("#FFFFFF00"),
    sidebarMaterial: .glass,
    titlebarForeground: color("#52525B"),
    tab: TerminalTabStyle(
      radius: 6,
      foreground: color("#52525B"),
      hoverBackground: color("#0000000A"),
      activeBackground: color("#FFFFFFE6"),
      activeForeground: color("#18181B"),
      activeBorderColor: color("#E5E5E5"),
      activeBorderWidth: 1,
      activeFontWeight: 700,
      activeShadow: shadow(y: 1, blur: 2, color: "#0000000D")
    ),
    container: TerminalContainerStyle(
      background: color("#FFFFFF"),
      radius: 15,
      margin: ThemeInsets(top: 4, leading: 16, bottom: 16, trailing: 16),
      horizontalLayoutMargin: ThemeInsets(all: 12),
      padding: ThemeInsets(top: 8, leading: 16, bottom: 8, trailing: 16),
      borderColor: color("#E5E5E5"),
      borderWidth: 1,
      shadow: shadow(y: 1.5, blur: 6, color: "#0000002E")
    )
  )

  private static let glassLightStyle = TerminalThemeStyle(
    radius: 12,
    sidebarBackground: color("#EAEAEA00"),
    sidebarMaterial: .glass,
    tab: TerminalTabStyle(
      radius: 4,
      foreground: color("#5D6872"),
      hoverBackground: color("#FFFFFF61"),
      activeBackground: color("#AAAAAA3A"),
      activeBorderColor: color("#2E3E4A24"),
      activeBorderWidth: 1,
      activeFontWeight: 500
    ),
    horizontalTab: TerminalTabStyle(
      radius: 4,
      foreground: color("#5D6872"),
      hoverBackground: color("#C0C0C061"),
      activeBackground: color("#8D8D8D43"),
      activeBorderColor: color("#D6D6D6CF"),
      activeBorderWidth: 1,
      activeFontWeight: 500
    ),
    container: TerminalContainerStyle(radius: 0, padding: ThemeInsets(all: 8))
  )

  private static let glassDarkStyle = TerminalThemeStyle(
    radius: 12,
    sidebarBackground: color("#2528325D"),
    titlebarForeground: color("#DCE0EA"),
    tab: TerminalTabStyle(
      radius: 8,
      foreground: color("#C9CEDB"),
      hoverBackground: color("#FFFFFF1A"),
      activeBackground: color("#FFFFFF29"),
      activeForeground: color("#FFFFFF"),
      activeBorderColor: color("#FFFFFF2E"),
      activeBorderWidth: 1,
      activeFontWeight: 500
    ),
    container: TerminalContainerStyle(radius: 0, padding: ThemeInsets(all: 8))
  )

  private static let newsprintStyle = TerminalThemeStyle(
    radius: 4,
    sidebarBackground: color("#F4F4F1"),
    sidebarBorderColor: color("#DBD6C8"),
    sidebarBorderWidth: 1,
    sidebarMaterial: TerminalThemeMaterial.none,
    tab: TerminalTabStyle(
      radius: 4,
      foreground: color("#7A766B"),
      hoverBackground: color("#C4BFB16F"),
      activeBackground: color("#6D7478"),
      activeForeground: color("#FFFFFF"),
      activeFontWeight: 500
    ),
    horizontalTab: TerminalTabStyle(
      radius: 14,
      height: 32,
      foreground: color("#7A766B"),
      hoverBackground: color("#C4BFB16F"),
      activeBackground: color("#6D7478"),
      activeForeground: color("#FFFFFF"),
      activeFontWeight: 500,
      activeShadow: shadow(y: 1, blur: 4, color: "#0000000D")
    ),
    horizontalTabBarHeight: 44,
    container: TerminalContainerStyle()
  )

  /// 当前 Otty 的 One Light 不声明 [tab]/[panel.surface]：标签悬停 / 选中一律走
  /// 原生叠加色（黑 4%/6%），侧栏底为原生 #F7F7F7。只保留主题真的声明过的
  /// 标题栏白底与侧栏分隔线。
  private static let oneLightStyle = TerminalThemeStyle(
    sidebarBackground: color("#F7F7F7"),
    sidebarBorderColor: color("#E5E5E5"),
    sidebarBorderWidth: 1,
    titlebarBackground: color("#FFFFFF"),
    container: TerminalContainerStyle(background: color("#FFFFFF"))
  )

  private static let nightStyle = TerminalThemeStyle(
    radius: 4,
    sidebarBackground: color("#2E3033"),
    sidebarBorderColor: color("#222426"),
    sidebarBorderWidth: 1,
    tab: TerminalTabStyle(
      radius: 4,
      foreground: color("#A5ACBA"),
      hoverBackground: color("#2A2C2F"),
      activeBackground: color("#222222"),
      activeForeground: color("#FFFFFF"),
      activeFontWeight: 500
    ),
    container: TerminalContainerStyle(radius: 4)
  )

  private static let nordStyle = TerminalThemeStyle(
    radius: 6,
    sidebarBackground: color("#2E3440"),
    sidebarBorderColor: color("#434C5E"),
    sidebarBorderWidth: 1,
    sidebarMaterial: TerminalThemeMaterial.none,
    titlebarForeground: color("#C0C7D3"),
    tab: TerminalTabStyle(
      radius: 6,
      foreground: color("#C0C7D3"),
      hoverBackground: color("#FFFFFF0D"),
      activeBackground: color("#3B4252"),
      activeForeground: color("#ECEFF4"),
      activeFontWeight: 500,
      activeShadow: shadow(y: 1, blur: 2, color: "#00000040")
    ),
    horizontalTab: TerminalTabStyle(radius: 8, height: 28),
    horizontalTabBarHeight: 36,
    container: TerminalContainerStyle(
      background: color("#2E3440"), radius: 0, padding: ThemeInsets(all: 8)
    )
  )

  private static let paperStyle = TerminalThemeStyle(
    radius: 4,
    sidebarBackground: color("#F5F4F0"),
    sidebarBorderColor: color("#E0DFD5"),
    sidebarBorderWidth: 1,
    tab: TerminalTabStyle(
      radius: 4,
      foreground: color("#8C8A80"),
      hoverBackground: color("#EBEAE5"),
      activeBackground: color("#FFFFFF"),
      activeForeground: color("#1A1A1A"),
      activeBorderColor: color("#E0DFD5"),
      activeBorderWidth: 1,
      activeFontWeight: 400,
      activeShadow: shadow(y: 1, blur: 2, color: "#00000005")
    ),
    horizontalTab: TerminalTabStyle(
      radius: 14,
      height: 32,
      foreground: color("#8C8A80"),
      hoverBackground: color("#EBEAE5"),
      activeBackground: color("#FFFFFF"),
      activeForeground: color("#1A1A1A"),
      activeBorderColor: color("#E0DFD5"),
      activeBorderWidth: 1,
      activeFontWeight: 400,
      activeShadow: shadow(y: 1, blur: 4, color: "#0000000F")
    ),
    horizontalTabBarHeight: 44,
    container: TerminalContainerStyle(radius: 0)
  )

  private static let pinkStyle = TerminalThemeStyle(
    radius: 6,
    sidebarBackground: color("#F0EAEA"),
    sidebarBorderColor: color("#E5DCDA"),
    sidebarBorderWidth: 1,
    sidebarMaterial: TerminalThemeMaterial.none,
    titlebarBackground: color("#F0EAEA"),
    tab: TerminalTabStyle(
      radius: 6,
      foreground: color("#7A6E6A"),
      hoverBackground: color("#CC85951A"),
      activeBackground: color("#EDC4BE"),
      activeForeground: color("#2A2422"),
      activeFontWeight: 600
    ),
    container: TerminalContainerStyle()
  )

  /// Solarized Light 文件只声明终端色表，Sidebar/Tab 使用 Otty 的默认浅色级联。
  /// 默认层次不是终端背景的简单复用：侧栏更深、活动标签再深一档。
  private static let solarizedLightStyle = TerminalThemeStyle(
    radius: 4,
    sidebarBackground: color("#F3EEDC"),
    sidebarBorderColor: color("#E2DCC7"),
    sidebarBorderWidth: 1,
    tab: TerminalTabStyle(
      radius: 4,
      foreground: color("#839496"),
      hoverBackground: color("#EEE8D580"),
      activeBackground: color("#EEE8D5"),
      activeForeground: color("#586E75"),
      activeFontWeight: 500
    ),
    container: TerminalContainerStyle(background: color("#FDF6E3"))
  )

  private static func shadow(
    x: Double = 0, y: Double, blur: Double, color value: String
  ) -> ThemeShadow {
    ThemeShadow(x: x, y: y, blur: blur, color: color(value))
  }

  /// 将紧凑真值表转换为运行时模型，并集中实现 Otty 对缺省令牌的级联行为。
  private static func make(
    id: String,
    name: String,
    mode: TerminalThemeMode,
    foreground: String,
    background: String,
    ansi: String,
    cursor: String? = nil,
    cursorText: String? = nil,
    selectionForeground: String? = nil,
    selection: String? = nil,
    interfaceForeground: String? = nil,
    secondary: String? = nil,
    tertiary: String? = nil,
    accent: String? = nil,
    panel: String? = nil,
    surface: String? = nil,
    container: String? = nil,
    border: String? = nil,
    interfaceWindow: String? = nil,
    material: TerminalThemeMaterial? = nil,
    style: TerminalThemeStyle? = nil
  ) -> TerminalTheme {
    let terminalForeground = color(foreground)
    let terminalBackground = color(background)
    let ansiColors = ansi.split(separator: " ").map { color(String($0)) }
    // Otty 语义：未声明 panel/surface 的主题（Dracula、One Dark 等终端-only 主题）
    // chrome 用原生 token 色，而不是沿用终端背景；surface 保留 nil，选中标签才能
    // 落到原生叠加色而不是与侧栏同色。
    let resolvedPanel = panel.map(color) ?? mode.nativeChromeBackground
    let resolvedSurface = surface.map(color)
    let resolvedInterfaceWindow = color(interfaceWindow ?? panel ?? normalized(background))
    let resolvedInterfaceForeground = color(interfaceForeground ?? foreground)
    let resolvedSecondary = secondary.map(color) ?? mode.nativeSecondaryForeground
    // Otty 语义：容器默认与终端画布连续（继承终端背景），不借用 panel。
    // 借用 panel 会让 April 等「panel 灰绿 + 终端纯白」的主题在右侧内容区套上
    // 一层 panel 色，与白色终端画布割裂；透明背景（glass）仍保持透明。
    let resolvedContainer = color(container ?? normalized(background))
    // 合成样式不再写死 hover/active 底色：留空让 slot 级联落到原生叠加色
    // （浅色黑 4%/6%、深色白 5%/8%），与当前 Otty 的终端-only 主题渲染一致。
    let resolvedStyle = style ?? TerminalThemeStyle(
      sidebarBackground: resolvedPanel,
      tab: TerminalTabStyle(
        foreground: resolvedSecondary,
        activeForeground: resolvedInterfaceForeground
      ),
      container: TerminalContainerStyle(background: resolvedContainer)
    )

    return TerminalTheme(
      id: id,
      name: name,
      mode: mode,
      palette: TerminalThemePalette(
        windowBackground: terminalBackground,
        containerBackground: resolvedContainer,
        panelBackground: resolvedPanel,
        foreground: terminalForeground,
        secondaryForeground: resolvedSecondary,
        accent: color(accent ?? ansiColors[4].stringValue),
        cursor: color(cursor ?? foreground),
        // Otty 没有显式选区色时使用终端前景的 30% 透明度；不能退化成不透明前景，
        // 否则 April、Ayu Light、Paper 等主题一选中文字就会盖住整块终端内容。
        selection: selection.map(color)
          ?? (mode == .light
            ? HexColor(
              red: terminalForeground.red,
              green: terminalForeground.green,
              blue: terminalForeground.blue,
              alpha: 77
            ) : terminalForeground),
        ansiColors: ansiColors,
        interfaceWindowBackground: resolvedInterfaceWindow,
        interfaceForeground: resolvedInterfaceForeground,
        tertiaryForeground: color(tertiary ?? secondary ?? ansiColors[8].stringValue),
        panelSurface: resolvedSurface,
        interfaceBorder: border.map(color),
        cursorText: color(cursorText ?? normalized(background)),
        selectionForeground: color(selectionForeground ?? normalized(background)),
        material: material
      ),
      style: resolvedStyle,
      isBuiltIn: true
    )
  }

  /// Otty 的 `none` 表示完全透明；在 Aster 的 RGBA 模型中使用透明黑保存相同语义。
  private static func normalized(_ value: String) -> String {
    value.caseInsensitiveCompare("none") == .orderedSame ? "#00000000" : value
  }

  private static func color(_ value: String) -> HexColor {
    guard let result = HexColor(normalized(value)) else {
      preconditionFailure("内置主题包含非法颜色：\(value)")
    }
    return result
  }
}
