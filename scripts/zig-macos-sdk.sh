# 由需要用 Zig 0.15.2 编 macOS 原生目标的脚本 source（bash）。
#
# Zig 0.15.2 自带的 clang float.h 早于 macOS 27 SDK。27 SDK 的 math.h 在启用 modules 时改由
# <float.h> 的 __need_infinity_nan 提供 INFINITY，而 Zig 的 float.h 在 -std=c++17 下不定义它，
# libc++ 子编译随即报 "use of undeclared identifier 'INFINITY'"。遇到这种 SDK 时改用命令行
# 工具里的 macOS 26 SDK：只拦截 Zig 探测 SDK 的那一条 `xcrun --sdk macosx --show-sdk-path`，
# metal 等其余调用仍然交给 Xcode。SDKROOT 对 `xcrun --sdk macosx` 无效，DEVELOPER_DIR 指到
# 命令行工具又会丢掉 metal，所以只能用垫片。升级到修好此问题的 Zig 后删除本文件。

# 用法：prefix="$(aster_zig_sdk_path_prefix <临时目录>)"; PATH="$prefix$PATH" zig build ...
# 输出需要加在 PATH 最前面的目录（带结尾冒号）；不需要回退时输出空串。
# 垫片写在调用方给的临时目录里，由调用方负责清理。没有可用的 macOS 26 SDK 时返回非 0。
aster_zig_sdk_path_prefix() {
  local shim_parent="$1"
  [[ "$(uname -s)" == Darwin ]] || return 0
  command -v xcrun >/dev/null 2>&1 || return 0
  local default_sdk
  default_sdk="$(xcrun --sdk macosx --show-sdk-path)"
  /usr/bin/grep -q '__need_infinity_nan' "$default_sdk/usr/include/math.h" || return 0

  local fallback_sdk="" candidate
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    [[ -d "$candidate" ]] || continue
    /usr/bin/grep -q '__need_infinity_nan' "$candidate/usr/include/math.h" && continue
    fallback_sdk="$candidate"
  done
  if [[ -z "$fallback_sdk" ]]; then
    echo "error: Zig 0.15.2 cannot build libc++ against $(basename "$default_sdk"); install Command Line Tools with a macOS 26 SDK" >&2
    return 1
  fi
  echo "Using $(basename "$fallback_sdk") for Zig (Zig 0.15.2 is incompatible with $(basename "$default_sdk"))" >&2

  mkdir -p "$shim_parent/xcrun-shim"
  cat > "$shim_parent/xcrun-shim/xcrun" <<SHIM
#!/bin/sh
if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ]; then
  echo "$fallback_sdk"
  exit 0
fi
exec /usr/bin/xcrun "\$@"
SHIM
  chmod +x "$shim_parent/xcrun-shim/xcrun"
  printf '%s:' "$shim_parent/xcrun-shim"
}
