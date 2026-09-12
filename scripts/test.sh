#!/bin/zsh
set -euo pipefail

# 同步 AppKit 宿主避免 SwiftPM async-main 提前结束；全量默认串行分批释放窗口和 PTY。
# 每批完成必须通过 Swift Testing 事件清单审计，不以退出码 0 单独判定成功。
# 定向过滤和显式报告选项由宿主脚本路由为单进程；空 ASTER_TEST_BATCH_SIZE 可关闭分批。
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
python3 -m unittest discover -s Tests/Support -p 'test_batches.py'
export ASTER_TEST_BATCH_SIZE="${ASTER_TEST_BATCH_SIZE-2}"
exec "$PROJECT_DIR/scripts/test-appkit-host.sh" "$@"
