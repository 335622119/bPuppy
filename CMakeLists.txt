cmake_minimum_required(VERSION 3.16)

# =============================================================
# bPuppy 机器狗 — MicroPython + C 混合开发
# 遵循 micropython-helper 官方文档
#
# 1. include mpy.cmake 设置 MicroPython 构建变量
# 2. include project.cmake + project() 标准 IDF 流程
#
# ★ 两个目标共用同一份业务代码, 只切板级配置:
#     esp32s3 (默认) — ESP32-S3 WROOM-1 N16R8  16MB Flash + 8MB Octal PSRAM
#     esp32          — ESP32-WROOM-32D          4MB Flash, 无 PSRAM (台架验证)
#
#   切换: bash build.sh --target esp32
#         (或 idf.py -DBPUPPY_TARGET=esp32 build; 换目标必须先 rm -rf build)
#
#   引脚/外设开关在 drivers/board_config.h, 分区表按目标分文件。
# =============================================================

# 目标 SoC (缓存变量: 同一 build/ 目录里不会因为重新 configure 而漂)
set(BPUPPY_TARGET "esp32s3" CACHE STRING "目标 SoC: esp32s3 | esp32")
set_property(CACHE BPUPPY_TARGET PROPERTY STRINGS esp32s3 esp32)

if(BPUPPY_TARGET STREQUAL "esp32s3")
    set(ENV{IDF_TARGET} esp32s3)
    set(MICROPY_BOARD ESP32_GENERIC_S3)
    set(MICROPY_BOARD_VARIANT SPIRAM_OCT)   # Octal PSRAM + 240MHz
    set(BPUPPY_SDKCONFIG sdkconfig.bpuppy)
elseif(BPUPPY_TARGET STREQUAL "esp32")
    set(ENV{IDF_TARGET} esp32)
    set(MICROPY_BOARD ESP32_GENERIC)        # 经典 ESP32, 无变体
    unset(MICROPY_BOARD_VARIANT)
    set(BPUPPY_SDKCONFIG sdkconfig.bpuppy.esp32)
else()
    message(FATAL_ERROR "BPUPPY_TARGET 只支持 esp32s3 / esp32, 收到: ${BPUPPY_TARGET}")
endif()

# 定位 micropython-helper
# 原在 managed_components/, 因改了 mphalport.c (dupterm 输入) 移到 components/ 保留修改
if(NOT MICROPY_HELPER_DIR)
    set(MICROPY_HELPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/components/mr9you__micropython-helper)
endif()

if(EXISTS ${MICROPY_HELPER_DIR})
    # 模式 A: micropython-helper 已就绪

    # 注册用户自定义 C 模块（MicroPython 要求变量名 USER_C_MODULES）
    set(USER_C_MODULES ${CMAKE_CURRENT_SOURCE_DIR}/drivers/micropython.cmake)

    # Frozen Python 模块
    set(MICROPY_FROZEN_MANIFEST ${CMAKE_CURRENT_SOURCE_DIR}/frozen/manifest.py)

    # 确保 QSTR 预处理能找到板级头文件 mpconfigboard.h
    set(MICROPY_CPP_INC_EXTRA ${MICROPY_HELPER_DIR}/micropython/ports/esp32/boards/${MICROPY_BOARD})

    # mpy.cmake 设置 MicroPython 构建变量
    include(${MICROPY_HELPER_DIR}/mpy.cmake)

    # bPuppy Flash/PSRAM 覆盖 — 必须在 board sdkconfig 之后加载
    list(APPEND SDKCONFIG_DEFAULTS ${CMAKE_CURRENT_SOURCE_DIR}/${BPUPPY_SDKCONFIG})

    # 标准 ESP-IDF 项目初始化
    include($ENV{IDF_PATH}/tools/cmake/project.cmake)
    project(micropython_bpuppy)

    # esp_tinyusb v1.0.3 缺少 CFG_TUD_CDC_EP_BUFSIZE 定义
    # 仅 S3 有意义: 经典 ESP32 没有 USB-OTG, 不编译 esp_tinyusb
    if(BPUPPY_TARGET STREQUAL "esp32s3")
        idf_build_set_property(COMPILE_OPTIONS "-DCFG_TUD_CDC_EP_BUFSIZE=256" APPEND)
    endif()

else()
    # 模式 B: 首次 set-target（组件尚未下载）
    include($ENV{IDF_PATH}/tools/cmake/project.cmake)
    project(bPuppy_${BPUPPY_TARGET})
endif()
