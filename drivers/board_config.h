/*
 * bPuppy 板级配置 — 按 SoC 目标集中声明引脚与外设开关
 *
 * ★ 换板只改这一个文件。业务代码 (步态 motion_task.cpp / IK / poses.py / BLE)
 *   里**不含任何**目标条件编译 —— 见 openspec 变更 esp32-wroom-32d-bench-bringup。
 *
 * 目标由 CMake 的 BPUPPY_TARGET 选择, 编译期靠 sdkconfig.h 里的
 * CONFIG_IDF_TARGET_* 宏区分。
 *
 * 新增板型 = 加一个 #elif 分支 + 在 CMakeLists.txt 里加一个 BPUPPY_TARGET 取值。
 *
 * ⚠ 通道号 (0..7 = LF_HIP / LF_KNEE / LH_HIP / LH_KNEE / RF_HIP / RF_KNEE /
 *   RH_HIP / RH_KNEE) 是步态、姿态、KittenBlock 积木共同依赖的约定。
 *   换板只能改 BPUPPY_SERVO_PINS 里的 GPIO **数值**, 不能改顺序。
 */
#pragma once

#include "sdkconfig.h"

/* ================================================================
 * ESP32-S3 WROOM-1 N16R8 — 现网板 V3.0
 * ================================================================ */
#if defined(CONFIG_IDF_TARGET_ESP32S3)

#define BPUPPY_TARGET_NAME    "esp32s3"

/* 舵机 GPIO, 下标 = 通道号 */
#define BPUPPY_SERVO_PINS     { 1, 42, 2, 41, 40, 38, 39, 45 }

/* 电池检测 (ADC1) + WS2812 指示灯 */
#define BPUPPY_ADC_ENABLE     1
#define BPUPPY_ADC_CHANNEL    2      /* ADC1_CH2 = GPIO3 */
#define BPUPPY_LED_ENABLE     1
#define BPUPPY_LED_GPIO       48

/* 语音模块 UART2 (CI-33T) */
#define BPUPPY_VOICE_UART_TX  19
#define BPUPPY_VOICE_UART_RX  20

/* 蓝牙: 现网板必备 (KittenBlock 无线连接 + 无线上传) */
#define BPUPPY_BLE_ENABLE     1

/* ================================================================
 * ESP32-WROOM-32D (经典 ESP32-D0WD) — 台架验证
 *
 * 约束 (决定了下面每一个数):
 *   0/2/5/12/15       strapping, 上电电平决定启动模式 → 不用
 *   1/3               UART0 (烧录 + REPL)              → 不用
 *   6..11             Flash 内部占用                   → 不可用
 *   34..39            只输入, 无输出能力               → 不能接舵机
 *   20                该芯片不存在 (S3 才有)           → 语音必须换脚
 *   40..48            该芯片不存在                     → WS2812 原 GPIO48 不可用
 *   16/17             WROVER 上是 PSRAM, -32D 无 PSRAM → 可用 (语音)
 *   14/21             IMU 保持与既有 frozen 模块一致
 * ================================================================ */
#elif defined(CONFIG_IDF_TARGET_ESP32)

#define BPUPPY_TARGET_NAME    "esp32"

/* 舵机 GPIO: ch0=19 ch1=18 ch2=32 ch3=4 ch4=13 ch5=25 ch6=26 ch7=27 */
#define BPUPPY_SERVO_PINS     { 19, 18, 32, 4, 13, 25, 26, 27 }

/* 电池检测: 台架关闭。
 * 原因: S3 的电池脚 GPIO3 在本芯片上是 UART0 RX; ADC1 只在 32~39。
 *       要恢复必须同时改通道 + **重测标定系数** (现系数是 S3 上 4 点拟合的),
 *       否则读出来的数是"看着正常但是错的"。见 bench bring-up 的 D3。 */
#define BPUPPY_ADC_ENABLE     0
#define BPUPPY_ADC_CHANNEL    6      /* 预留: ADC1_CH6 = GPIO34, 仅作记录 */

/* WS2812 指示灯: 台架无此灯, 且原 GPIO48 在本芯片上不存在。
 * 置 0 后 led_init() 直接返回 —— 不会触发 rmt_config 中止。
 * 若要启用: 先确认灯实际接在哪个脚, 再把 ENABLE 改 1 并填 GPIO。 */
#define BPUPPY_LED_ENABLE     0
#define BPUPPY_LED_GPIO       33

/* 语音 UART2: GPIO20 在本芯片上不存在, 改为 16/17。
 * 本轮不验证语音功能, 但引脚必须换 —— 指向不存在的 pad 行为未定义。 */
#define BPUPPY_VOICE_UART_TX  16
#define BPUPPY_VOICE_UART_RX  17

/* 蓝牙: 台架**关闭** —— 这是用功能换 IRAM 的取舍, 不是"暂时没调通"。
 *
 * 原因: 经典 ESP32 的 iram0_0_seg 只有 128KB, 而 WiFi / BT 控制器都是**预编译库**
 *       (libbtdm_app / lib/esp32/libcore.a), 关 WiFi 的 IRAM 优化选项对它们无效
 *       (实测溢出字节一字不差, 见 docs/esp32台架移植结论.md §7.2)。
 *       开启 BLE 时链接期报 `iram0_0_seg` 溢出 1872 字节; 关掉后余量充足,
 *       以后加功能也不会立刻再爆。
 *
 * 代价: 台架只能用 USB 串口 (COM, 115200) 控制, KittenBlock 蓝牙连不上。
 *       走 `BPUPPY_TARGET=esp32s3` 编出来的现网固件**完全不受影响**。
 *
 * 实现 (四处联动, 缺一处就编不过):
 *   drivers/micropython.cmake —— 不编 ble_driver.c / ble_driver_mpy.c / ble_stream.c
 *   sdkconfig.bpuppy.esp32   —— CONFIG_BT_ENABLED=n (连预编译蓝牙控制器一起不链)
 *   CMakeLists.txt           —— -DMICROPY_PY_BLUETOOTH=0
 *                               ⚠ 端口 mpconfigport.h 是 `#ifndef ... #define 1`, 硬开蓝牙;
 *                                 只关 IDF 的 BT 会让 mpnimbleport.c 去 include 已消失的头
 *   frozen/main.py           —— 按 bpuppy.ble_enabled() 跳过 bpuppy_ble.start()
 */
#define BPUPPY_BLE_ENABLE     0

#else
#error "board_config.h: 未支持的 SoC 目标 (只支持 CONFIG_IDF_TARGET_ESP32S3 / CONFIG_IDF_TARGET_ESP32)"
#endif
