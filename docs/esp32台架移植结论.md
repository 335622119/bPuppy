# ESP32（经典）台架移植结论

> 对应 OpenSpec 变更: `esp32-wroom-32d-bench-bringup`
> 目标硬件: ESP32-WROOM-32D（ESP32-D0WD，4MB Flash，无 PSRAM），飞线台架
> 范围: **只跑运动**（舵机 + 步态 + IMU）
> 状态: 构建链已**在 GitHub Actions 上真编通**（S3 全绿；esp32 链接期 IRAM 溢出已修，见 §7）；
> **烧录 / 实机验收尚未执行**（见文末「未完成项」）

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
| **S3 产物（CI 实测）** | **1,759,632 字节** = 基准 +8,912 B（`bpuppy.board()` + 板级常量表） |
| **esp32 首次链接** | `iram0_0_seg` **溢出 1872 字节**（关 WiFi IRAM 优化后解决，见 §7） |

---

## 5. 剩余风险（按"会不会让验证白做"排序）

1. ~~**移植层是否支持 esp32 目标**~~ — **已由 CI 实测排除**：`mpy_startup.c`、`mpy.cmake` 在
   `IDF_TARGET=esp32` 下正常编译、正常链接（链接只卡 IRAM，与移植层无关）。见 §7。
2. **Python GC 堆可能从 MB 级掉到 ~100KB** — S3 的 `SPIRAM_OCT` 很可能把 GC 堆放在 PSRAM。
   运动路径不受影响，但 KittenBlock 用户程序和任何大缓冲会受限。
   判据：开机 `micropython.mem_info()` 的 `GC: total`。**台架结论 ≠ 产品结论**，记下来。
3. **内部 RAM 更紧 —— 已兑现，且比预想更早发作**：不是 DRAM 而是 **IRAM**，
   首次链接就溢出 1872 字节。处理见 §7.2。堆是否还够，要等实机 `mem_info()`。
4. **扩展板 3 针口与丝印不一定一一对应** — 接舵机前必须用万用表通断 + `Pin.value()` 空跑确认，
   验证前不插舵机。
5. **8 舵机电流远超板载 buck** — 5A 级峰值会让降压掉压、ESP32 复位。舵机电源从 2S 电池取，共地。

---

## 6. 未完成项

### 6.1 已在 CI 上完成（不再是"待做"）

- 两个目标各构建一次 —— 见 §7。S3 产物 **1,759,632 字节**（基准 1,750,720，+8,912 B，
  来源是新增的 `bpuppy.board()` 与板级常量表）；S3 侧引脚/ADC/LED/UART 常量与变更前逐一相同。
  ⚠ 不要用"字节数完全相等"当门禁：`bpuppy_version.c` 把 `__DATE__`/`__TIME__` 编进固件，
  每次构建内容都不同，体积也会随代码小幅变化。

### 6.2 仍必须在真板子上做

- 烧录 esp32 固件，确认能进 REPL、不复位循环、横幅显示 `ESP32` / `Flash 4MB`
- 记录 esp32 上 `micropython.mem_info()` 的 `GC: total`（§5 第 2 条）
- 万用表验证扩展板 3 针口 ↔ 丝印 GPIO 一致性（抽查 19 / 32 / 34）
- 单路舵机方向与中位 → 8 路 + 三点标定迁移 → `poses.stand()` → `set_gait('go')` 连续 10 秒 → IMU 姿态方向

验收阶梯与判据见 `openspec/changes/esp32-wroom-32d-bench-bringup/tasks.md` 的第 3、4 组。

---

## 7. CI 远程编译，以及它挖出的两个真问题

`.github/workflows/firmware.yml`：两个目标矩阵并行、`espressif/idf:v5.1.2` 容器、ccache 缓存、
三件产物（`micropython_bpuppy.bin` + `bootloader.bin` + `partition-table.bin`）上传。

> 公开仓库 ⇒ 标准 runner 免费不限分钟。首次冷缓存约 3 分钟（含拉依赖），之后靠 ccache 更快。

### 7.1 「干净 clone 编不出正式固件」—— 一直存在，只是没人从零开始过

`CMakeLists.txt:41` 只认 `components/mr9you__micropython-helper`，而：

- `components/` 被 `.gitignore` 忽略 —— `git clone` 下来没有这个目录；
- 组件管理器下载的是 `managed_components/`，**仓库里没有任何一步把它搬过去**；
- 找不到就走 `CMakeLists.txt:72` 的「模式 B」：`project(bPuppy_<target>)`，
  编出来是个**没有自定义模块、没有 frozen 清单的空壳**，根本不是 `micropython_bpuppy.bin`；
- `build.sh` 的补丁步骤在 `docker run` **之前**执行，补丁目标却在 `components/` 里 ⇒ 目录不存在直接 `exit 1`。

以前一直在同一台机器上增量编，`components/` 是历史遗留目录顶着，所以从没暴露。
CI 固定按这个顺序补上：`idf.py reconfigure`（拉依赖）→ `cp -r managed_components/<helper> components/`
→ `rm -rf build`（清掉模式 B 缓存）→ 打补丁 → `idf.py build`。

**代价**：这条流程目前写在 workflow 里，`build.sh` 本身仍有同样的缺口。
换新电脑用 `build.sh` 时若 `components/` 不存在，会以"补丁应用失败"的形式报错退出（不是静默错误，尚可接受）。

### 7.2 经典 ESP32 的 IRAM 装不下：`iram0_0_seg` 溢出 1872 字节

首次 esp32 构建：所有 `.c/.cpp` 都编过了（含 `motion_task.cpp`、`camera_driver.c`、
`mpy_startup.c`），只在最后链接 `micropython_bpuppy.elf` 时失败：

```
ld: section `.iram0.text' will not fit in region `iram0_0_seg'
ld: region `iram0_0_seg' overflowed by 1872 bytes
```

**为什么 S3 不会遇到**：S3 的 IRAM 段大得多；经典 ESP32 的 `iram0_0_seg` 只有 ~128KB，
而 WiFi 热路径默认被放进 IRAM（`CONFIG_ESP_WIFI_IRAM_OPT` / `CONFIG_ESP_WIFI_RX_IRAM_OPT` 默认 `=y`）。

**处理**（`sdkconfig.bpuppy.esp32`）：把这两个优化关掉，WiFi 代码回到 flash 执行（略慢）。

```ini
CONFIG_ESP_WIFI_IRAM_OPT=n
CONFIG_ESP_WIFI_RX_IRAM_OPT=n
```

台架本轮不用 WiFi 图传，性能代价无感。⚠ 若将来真要在 esp32 上开图传，
**先看链接期还剩多少 IRAM** 再决定要不要改回 `y`；别直接调 `CONFIG_BT_NIMBLE_MSYS_1_BLOCK_COUNT`
（那是 DRAM 侧，治不了 IRAM 溢出）。
