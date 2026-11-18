# ESP32（经典）台架移植结论

> 对应 OpenSpec 变更: `esp32-wroom-32d-bench-bringup`
> 目标硬件: ESP32-WROOM-32D（ESP32-D0WD，4MB Flash，无 PSRAM），飞线台架
> 范围: **只跑运动**（舵机 + 步态 + IMU）
> 状态: 代码与构建链已就位；**构建 / 烧录 / 实机验收尚未执行**（见文末「未完成项」）

本文回答一个问题：**bPuppy 这套栈，哪些能原样搬到经典 ESP32，哪些必须改造，哪些不值得搬。**
判定依据是芯片能力 + 启动路径的硬依赖，不是"试了能不能跑"。

---

## 1. 总表

| 子系统 | 判决 | 依据 |
|---|---|---|
| 步态循环 `motion_task.cpp` | ✅ **可移植，零改动** | 50Hz FreeRTOS 任务 + 纯浮点运算；不依赖 PSRAM / 不依赖 S3 外设 |
| 逆运动学 `ik.c` | ✅ 可移植，零改动 | 纯数学 |
| 姿态脚本 `frozen/poses.py` | ✅ 可移植，零改动 | 只调 `bpuppy_servo` 与 `bpuppy_motion` |
| 舵机 PWM `servo_driver.c` | ⚠ **需改造**（只改引脚表） | LEDC 在 ESP32 上同样有 8 通道 / LS mode；只有 GPIO 号是板级差异 |
| IMU `imu_driver.c` | ✅ 可移植，零改动 | I2C0 走 14/21，与 S3 板相同；MPU6050/9250 与 SoC 无关 |
| BLE `ble_driver.c` / `ble_stream.c` | ✅ 可移植（待实机确认） | NimBLE 两代都有；`CONFIG_BT_NIMBLE_MSYS_1_BLOCK_COUNT=24` 在 esp32 sdkconfig 里同值设置 |
| 电池检测 `adc_driver.c` | ⚠ **需改造 → 本轮直接关闭** | 见 §2.1 |
| WS2812 指示灯 `led_driver.c` | ❌ **不可移植 → 本轮关闭** | 见 §2.2 |
| 语音 UART2 `frozen/voice.py` | ⚠ **需改造**（换脚 16/17） | GPIO20 在经典 ESP32 上不存在 |
| 摄像头 `camera_driver.c` | ❌ **不可移植** | 芯片无 LCD_CAM；且无 PSRAM，帧缓冲无处放 |
| WiFi 图传 `camera_stream.py` | ❌ **不可移植**（依赖摄像头） | 同上；本轮不上电 |
| PWM_EXT `pwm_ext_driver.c` | ⚠ 可移植但**本轮不启用** | MCPWM 两代都有；默认 `PWM_EXT1=3` 与 UART0 RX 冲突 |
| KittenBlock 积木定义 | ✅ 无需改动 | 全部通过通道号与模块名说话，不涉及引脚 |

一句话结论：**运动栈（舵机 + 步态 + IK + IMU）不依赖 S3 的任何独有特性**，
唯二的真实障碍是"引脚编号对不上"和"WS2812 用了不存在的脚"。

---

## 2. 三个被判"关掉"的子系统的理由

### 2.1 电池 ADC —— 关闭而不是改通道

表面看只差一行（`ADC1_CHANNEL_2` → `ADC1_CHANNEL_6`），实际有两条硬理由：

1. **S3 的电池脚 GPIO3 在这颗芯片上是 UART0 RX** —— 那是烧录与 REPL 的唯一通道。
2. **标定系数必须重测**。现有 `a=1.0379 / b=0.4660` 是 S3 上 4 点实测拟合出来的；
   ADC 的衰减曲线、参考电压、分压电阻公差在两颗芯片之间都不同。直接把系数搬过来，
   会得到"看着像正常电压、其实偏了 5~10%"的读数 —— 比没有读数更危险。

关闭后接口行为（已按 spec 约定）：`bpuppy_adc.read_mv()` → `-1`；
`voltage.read_v()` → `-1.0`；`voltage.read_pct()` → `0`。不抛异常。

### 2.2 WS2812 指示灯 —— 不可移植

原引脚 **GPIO48 超出 0~39 范围**。`led_init()` 里是
`ESP_ERROR_CHECK(rmt_config(&config))` —— 一个**编译期合法、运行期中止**的调用。
而 `frozen/main.py` 里 `import voltage` 是裸 import，`voltage.start()` →
`bpuppy_adc.init()` → `led_batt_start()` → `led_init()` → abort。

结果不是"灯不亮"，是**上电 panic 复位循环**，且 REPL 起不来、看不到任何线索。
所以 `BPUPPY_LED_ENABLE=0` 必须在 `led_init()` 最前面返回，而不是靠"不会有人调用它"。

> 这条也是整个变更里唯一一个"不处理就一定开不了机"的点。

### 2.3 摄像头 / 图传 —— 不可移植

芯片没有 LCD_CAM 外设（DVP 并行接口），也没有 PSRAM 放帧缓冲。
本轮不改 `camera_driver.c`、不动 `micropython.cmake` 的 include、不动
`idf_component.yml` 的 `espressif/esp32-camera` —— 保持"**编译进去但从不初始化**"。
代价是几十 KB Flash，收益是不碰组件依赖链与 KittenBlock 扩展重打包。

---

## 3. 改造清单（实际改了哪些文件）

| 文件 | 改动 | 为什么必须改 |
|---|---|---|
| `drivers/board_config.h` | **新增**。按目标声明舵机引脚 / ADC 开关 / LED 开关 / 语音 UART | 让"板级差异"只有一个落点 |
| `drivers/servo_driver.c` | 8 个 `servo_init` 换成遍历 `BPUPPY_SERVO_PINS` | 引脚集中到 board_config |
| `drivers/adc_driver.c` | `BPUPPY_ADC_ENABLE` 由 board_config 提供 | esp32 上必须为 0 |
| `drivers/led_driver.c` | `LED_GPIO` 由 board_config 提供；`led_init` / `led_batt_start` 前置 `#if !BPUPPY_LED_ENABLE` 返回 | 否则 rmt_config 中止 = 上电 panic |
| `drivers/bpuppy_version.c` | 新增 `bpuppy.board()` → `"esp32s3"` / `"esp32"` | frozen `.py` 看不到 Kconfig，需要一条运行时板型通道 |
| `frozen/voice.py` | UART2 引脚按 `bpuppy.board()` 选 | 语音在 esp32 上必须换到 16/17，S3 保持 19/20 |
| `frozen/main.py` | 横幅打印目标与 Flash 容量 | 两个目标产物同名，需要一眼分辨 |
| `CMakeLists.txt` | `BPUPPY_TARGET` 选择板型 / 变体 / sdkconfig | 双目标并存 |
| `sdkconfig.bpuppy.esp32` | **新增**。4MB DIO 40MHz + 4MB 分区表 + NimBLE 24 块 | 目标参数 |
| `partitions_esp32_4m.csv` | **新增**。nvs 同位同尺寸 | 4MB 装不下 S3 的 8MB/8MB 布局 |
| `build.sh` | `--target` 参数、bootloader 偏移、旧 build 目录目标校验 | 经典 ESP32 引导在 `0x1000` |

**没有改**：`motion_task.cpp`、`ik.c`、`motion_task_mpy.c`、`imu_driver.c`、
`ble_*.c`、`pwm_ext_driver.c`、`camera_driver.c`、`frozen/poses.py`、
`frozen/heading_*.py`、`kext-bpuppy/`（积木）、`partitions.csv`（S3 版）。

---

## 4. 关键数字

| 项 | 值 |
|---|---|
| 固件基准大小（S3 版） | 1,750,720 字节 (1.67MB) |
| esp32 `factory` 分区 | 2MB ⇒ 余量约 330KB |
| esp32 `vfs` 分区 | `0x210000` / `0x1F0000` (~1.94MB) |
| `nvs`（两版相同） | `0x9000` / `0x6000` (24KB) |
| 舵机 PWM | 50Hz，500–2500μs，LEDC `TIMER_0` |
| 步态周期 | 50Hz（20ms/帧） |

---

## 5. 剩余风险（按"会不会让验证白做"排序）

1. **移植层是否支持 esp32 目标** — `components/mr9you__micropython-helper` 的 `mpy.cmake`
   若写死 esp32s3，整个方案卡在第一步。**这是必须先验证的一条**，所以任务顺序把它排在最前。
2. **Python GC 堆可能从 MB 级掉到 ~100KB** — S3 的 `SPIRAM_OCT` 很可能把 GC 堆放在 PSRAM。
   运动路径不受影响，但 KittenBlock 用户程序和任何大缓冲会受限。
   判据：开机 `micropython.mem_info()` 的 `GC: total`。**台架结论 ≠ 产品结论**，记下来。
3. **内部 RAM 更紧** — 无 PSRAM 兜底，NimBLE 缓冲池 + 线程栈竞争更明显。
   链接期若报 DRAM 不足，先把 `CONFIG_BT_NIMBLE_MSYS_1_BLOCK_COUNT` 降到 16。
4. **扩展板 3 针口与丝印不一定一一对应** — 接舵机前必须用万用表通断 + `Pin.value()` 空跑确认，
   验证前不插舵机。
5. **8 舵机电流远超板载 buck** — 5A 级峰值会让降压掉压、ESP32 复位。舵机电源从 2S 电池取，共地。

---

## 6. 未完成项（需要在有 Docker + 硬件的机器上做）

以下任务**代码已就位，但没有执行过**，因为当前环境无 Docker、无 ESP-IDF、无网络、无硬件：

- 两个目标各构建一次；确认 S3 产物大小仍为 1,750,720 字节（`board-support` spec 要求 S3 不受影响）
- 烧录 esp32 固件，确认能进 REPL、不复位循环、横幅显示 `ESP32` / `Flash 4MB`
- 记录 esp32 上 `micropython.mem_info()` 的 `GC: total`
- 万用表验证扩展板 3 针口 ↔ 丝印 GPIO 一致性（抽查 19 / 32 / 34）
- 单路舵机方向与中位 → 8 路 + 三点标定迁移 → `poses.stand()` → `set_gait('go')` 连续 10 秒 → IMU 姿态方向

验收阶梯与判据见 `openspec/changes/esp32-wroom-32d-bench-bringup/tasks.md` 的第 3、4 组。
