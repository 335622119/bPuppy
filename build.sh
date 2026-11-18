#!/bin/bash
# ============================================================
# bPuppy 固件编译脚本（在宿主机 Git Bash 中运行）
#
# 用法:
#   bash build.sh                  # 默认目标 esp32s3 (现网板 N16R8)
#   bash build.sh --target esp32   # 目标 esp32 (WROOM-32D 台架, 4MB)
#
# 首次使用:
#   mkdir -p ~/.ccache_bpuppy     # 建 ccache 目录（只需一次）
#   bash build.sh                 # 编译
#
# 日常增量编译:
#   bash build.sh
#
# 改了 CMakeLists.txt / sdkconfig / idf_component.yml:
#   rm -rf build && bash build.sh
#
# ⚠ 换目标 (esp32s3 <-> esp32) 必须 rm -rf build:
#   两个目标的 CMake 缓存 / sdkconfig / 分区表都不同, 混用会编出前言不搭后语的固件。
#   本脚本会在检测到 build/ 属于另一个目标时直接报错退出。
#
# 多台电脑:
#   每台电脑各自有 ~/.ccache_bpuppy，互不影响
#   build/ 目录不提交 git，每台电脑独立
# ============================================================
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CCACHE_DIR="$HOME/.ccache_bpuppy"

# ---- 解析参数 ----
TARGET="esp32s3"
while [ $# -gt 0 ]; do
  case "$1" in
    --target|-t)
      [ -n "$2" ] || { echo "!! --target 后面要跟目标名 (esp32s3 / esp32)" >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --target=*)
      TARGET="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "!! 未知参数: $1  (用法: bash build.sh [--target esp32s3|esp32])" >&2
      exit 2 ;;
  esac
done

# ---- 目标 -> esptool 参数 ----
# 经典 ESP32 的二级引导在 0x1000, S3 在 0x0 —— 全烧命令不能跨目标复用。
case "$TARGET" in
  esp32s3)
    CHIP="esp32s3"
    BOOT_OFFSET="0x0"
    TARGET_DESC="ESP32-S3 WROOM-1 N16R8 (16MB Flash)"
    ;;
  esp32)
    CHIP="esp32"
    BOOT_OFFSET="0x1000"
    TARGET_DESC="ESP32-WROOM-32D (4MB Flash, 台架)"
    ;;
  *)
    echo "!! --target 只支持 esp32s3 / esp32, 收到: $TARGET" >&2
    exit 2 ;;
esac

mkdir -p "$CCACHE_DIR"

echo "=== bPuppy 编译 ==="
echo "项目: $PROJECT_DIR"
echo "目标: $TARGET_DESC   (BPUPPY_TARGET=$TARGET)"
echo "缓存: $CCACHE_DIR"
echo ""

# ---- 旧 build/ 目标一致性检查 ----
# CMake 的缓存变量记录着上次 configure 的目标。目标不同就必须清目录,
# 否则 idf.py 会用旧的 sdkconfig / 分区表 + 新的源文件, 产出无法解释的固件。
if [ -f "$PROJECT_DIR/build/CMakeCache.txt" ]; then
  _cached="$(sed -n 's/^BPUPPY_TARGET:STRING=//p' "$PROJECT_DIR/build/CMakeCache.txt" | head -n 1)"
  if [ -z "$_cached" ]; then
    # 双目标改造之前建的 build/: 缓存里没有这个变量, 它的 sdkconfig 一定是 S3 的。
    # 继续用它编 esp32 会**静默忽略** sdkconfig.bpuppy.esp32 (IDF 只在
    # build/sdkconfig 不存在时才重新生成) —— 正是 AGENTS.md 记的那个坑。
    if [ "$TARGET" != "esp32s3" ]; then
      echo "!! build/ 建立于双目标改造之前, 无法判断它属于哪个目标" >&2
      echo "   换目标必须清目录 (否则 sdkconfig.bpuppy.esp32 会被静默忽略):" >&2
      echo "   rm -rf build && bash build.sh --target $TARGET" >&2
      exit 1
    fi
  elif [ "$_cached" != "$TARGET" ]; then
    echo "!! build/ 是 '$_cached' 的产物, 与本次目标 '$TARGET' 不同" >&2
    echo "   执行: rm -rf build && bash build.sh --target $TARGET" >&2
    exit 1
  fi
fi

# ---- 应用 patches/ 下的本地补丁 ----
# components/ 是组件管理器自动下载的第三方依赖 (见 main/idf_component.yml), 整个目录
# 被 .gitignore 忽略 —— 所以对它做的必要改动**不会进 git**, 换台电脑重下依赖就丢了。
# 这些改动以补丁形式存在 patches/ 里, 每次编译前自动打上。
#
# 必须带 -c core.autocrlf=false: 本仓库 core.autocrlf=true, 直接 git apply 会把
# 打补丁的文件整体转成 CRLF (C 编译不受影响, 但补丁之后就无法反向校验了)。
for p in "$PROJECT_DIR"/patches/*.patch; do
  [ -e "$p" ] || continue
  _name="$(basename "$p")"
  if git -C "$PROJECT_DIR" -c core.autocrlf=false apply --check --reverse "$p" 2>/dev/null; then
    echo "补丁已应用, 跳过: $_name"      # 反向能打 = 已在目标状态, 幂等
  elif git -C "$PROJECT_DIR" -c core.autocrlf=false apply "$p"; then
    echo "已应用补丁: $_name"
  else
    echo "!! 补丁应用失败: $_name" >&2
    echo "   多半是 components/ 里的文件版本变了 (依赖升版), 上下文对不上。" >&2
    echo "   处理: 手动改对应文件, 再按 patches/README.md 重新生成补丁。" >&2
    exit 1
  fi
done
echo ""

# MSYS_NO_PATHCONV=1 阻止 Git Bash 把 /d/xxx 转成 C:/Program Files/Git/xxx
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "${PROJECT_DIR}:/workspace" \
  -v "${CCACHE_DIR}:/root/.ccache" \
  -e CCACHE_DIR=/root/.ccache \
  espressif/idf:v5.1.2 \
  bash -c "source /opt/esp/idf/export.sh && cd /workspace && idf.py -DBPUPPY_TARGET=$TARGET build"

echo ""
echo "=== 编译完成 ==="
echo "目标: $TARGET_DESC"
echo "固件: build/micropython_bpuppy.bin"
echo ""
echo "烧录 (Windows PowerShell):"
echo "  cd $(cygpath -w "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")\\build"
echo "  # 只烧 app (日常, 保留 NVS 标定与 vfs 用户程序):"
echo "  esptool --chip $CHIP --port COM14 --baud 921600 write-flash 0x10000 micropython_bpuppy.bin"
echo "  # 全烧 (首次 / 换过分区表; ⚠ 会要重建 vfs, 见 AGENTS.md):"
echo "  esptool --chip $CHIP --port COM14 --baud 921600 write-flash $BOOT_OFFSET bootloader/bootloader.bin 0x8000 partition_table/partition-table.bin 0x10000 micropython_bpuppy.bin"
