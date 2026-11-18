# ============================================================
# bPuppy 用户自定义 C 模块构建文件
# 该文件由 USER_C_MODULES 变量指向
# micropython-helper 会在构建过程中 include 这个文件
# 用户模块应添加到 "usermod" 目标（MicroPython 标准）
# ============================================================

# 添加模块源文件到 usermod 目标（usermod 是 INTERFACE 库）
target_sources(usermod INTERFACE
    ${CMAKE_CURRENT_LIST_DIR}/bpuppy_version.c
    ${CMAKE_CURRENT_LIST_DIR}/servo_driver.c
    ${CMAKE_CURRENT_LIST_DIR}/imu_driver.c
    ${CMAKE_CURRENT_LIST_DIR}/uart_driver.c
    ${CMAKE_CURRENT_LIST_DIR}/adc_driver.c
    ${CMAKE_CURRENT_LIST_DIR}/ik.c
    ${CMAKE_CURRENT_LIST_DIR}/motion_task.cpp
    ${CMAKE_CURRENT_LIST_DIR}/motion_task_mpy.c
    ${CMAKE_CURRENT_LIST_DIR}/camera_driver.c
    ${CMAKE_CURRENT_LIST_DIR}/led_driver.c
    ${CMAKE_CURRENT_LIST_DIR}/pwm_ext_driver.c
)

# 蓝牙源文件: 仅在目标带 BLE 时编译 (drivers/board_config.h 的 BPUPPY_BLE_ENABLE)
#
# 经典 ESP32 台架关 BLE 是为了换 IRAM —— iram0_0_seg 只有 128KB, 而蓝牙控制器是
# 预编译库, 关不掉它内部占的 IRAM, 只能整块不链。详见 board_config.h 注释。
# ⚠ 不能只靠"不定义 BPUPPY_BLE_KEBLOCK": ble_driver.c 的函数体在宏外,
#   且 NimBLE 头文件在 CONFIG_BT_ENABLED=n 时不存在 ⇒ 必须连源文件一起排除。
if(NOT BPUPPY_TARGET STREQUAL "esp32")
    target_sources(usermod INTERFACE
        ${CMAKE_CURRENT_LIST_DIR}/ble_driver.c
        ${CMAKE_CURRENT_LIST_DIR}/ble_driver_mpy.c
        ${CMAKE_CURRENT_LIST_DIR}/ble_stream.c
    )
endif()

# 添加模块头文件搜索路径
target_include_directories(usermod INTERFACE
    ${CMAKE_CURRENT_LIST_DIR}
    # esp32-camera 组件 (managed_component 头文件不会自动传播到 usermod)
    ${CMAKE_CURRENT_LIST_DIR}/../managed_components/espressif__esp32-camera/driver/include
    ${CMAKE_CURRENT_LIST_DIR}/../managed_components/espressif__esp32-camera/conversions/include
    # esp_jpeg (esp32-camera 的私有依赖, jpeg_decoder.h 被 img_converters.h 引用)
    ${CMAKE_CURRENT_LIST_DIR}/../managed_components/espressif__esp_jpeg/include
)

# ============================================================
# ★ BLE 模式编译开关 (二选一, 编译互斥)
#   两个蓝牙功能不要同时编译! 同一固件只能启用其一。
#
#   BPUPPY_BLE_KEBLOCK   — KittenBlock 蓝牙 (Nordic UART + dupterm REPL)
#   BPUPPY_BLE_HIWONDER  — Hiwonder Wonderbot App (FFE0 MechDog 协议)
#
# 切换: 注释/取消注释下面两行之一, 重新编译
# ============================================================
if(NOT BPUPPY_TARGET STREQUAL "esp32")
    target_compile_definitions(usermod INTERFACE BPUPPY_BLE_KEBLOCK)
    # target_compile_definitions(usermod INTERFACE BPUPPY_BLE_HIWONDER)
endif()
