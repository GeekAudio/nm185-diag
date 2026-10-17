# Issue #185 测试手册（RTX 4060 Laptop / R9000P 2023）

> 网页版（手机上更好读）：<https://geekaudio.github.io/nm185-diag/>
>
> 目标机型：Lenovo Legion R9000P 2023 / Ryzen 9 7945HX / RTX 4060 Laptop（`10de:28e0`，8 GB BAR1）/ 内屏 2560×1600
> 驱动：NullMoth **2.3.5**（issue 里的实测停在 2.1.0，2.2.0 之后无人复测过）
> 前提：**能 SSH 进黑屏的系统**。这条已确认可行（issue 里 @iussch 就是这么做的）。

## 一键取证

```bash
curl -fsSL https://raw.githubusercontent.com/GeekAudio/nm185-diag/main/nm185-diag.sh -o /tmp/nm185-diag.sh
bash /tmp/nm185-diag.sh --guide      # ① 先读手册（整份打到终端里）
sudo bash /tmp/nm185-diag.sh         # ② 再取证
```

`--guide` 会把整份手册打印到终端 —— 屏幕不亮也能读，不用开浏览器。

### curl 被重置（Connection reset by peer）

`ping github.com` 通、`curl` 却被 `Recv failure: Connection reset by peer` 掐断
—— 网络是通的，**只是终端没走代理**。

`curl` **不读 macOS 的系统代理设置**（系统设置里勾了也没用），只认环境变量。
代理软件开着 ≠ 终端走代理。

先查出系统里配的端口：

```bash
scutil --proxy          # 看 HTTPSProxy / HTTPSPort 两行
```

或者直接整段粘贴（自动读端口 → 下载 → 打印手册）：

```bash
P=$(scutil --proxy | awk '/HTTPSProxy/{h=$3}/HTTPSPort/{p=$3}END{if(h&&p)print h":"p}')
[ -n "$P" ] && export https_proxy=http://$P http_proxy=http://$P; echo "proxy=${P:-none}"
curl -fsSL https://raw.githubusercontent.com/GeekAudio/nm185-diag/main/nm185-diag.sh -o /tmp/nm185-diag.sh || \
curl -fsSL https://cdn.jsdelivr.net/gh/GeekAudio/nm185-diag@main/nm185-diag.sh -o /tmp/nm185-diag.sh
bash /tmp/nm185-diag.sh --guide
```

`proxy=none` 说明系统里没配代理，得先开代理软件的「系统代理」。
Clash Verge 常见 `7897`、ClashX `7890`、V2Ray `10809`（http），
菜单里一般也有「复制终端代理命令」可以直接粘。

> **实在搞不定就别下载了**：让群友把 `nm185-diag.sh` 直接发给你，存到 `/tmp`，
> 再 `sudo bash /tmp/nm185-diag.sh`。脚本就一个文件，不依赖任何东西。

### command not found / permission denied

文件明明在，但 `sudo ./nm185-diag.sh` 报 `command not found`，直接 `./nm185-diag.sh`
报 `permission denied` —— 因为下载下来的脚本**没有执行位**（默认 644）。
`./xxx.sh` 要求 +x，`bash xxx.sh` 不要求。

```bash
cd ~/Desktop
sudo bash nm185-diag.sh
```

看手册不用 sudo，也不用执行位：`bash nm185-diag.sh --guide`

---

## 必读：boot-args 必须加这 6 项

**这是硬性要求，不是可选优化。** 光把 kext 装进 `/Library/Extensions` 不够 ——
`install.sh` 只拷文件，**不改 OpenCore**。缺了就是黑屏。

boot-args 里必须有这 6 项，一项都不能少：

```
nvfb=1  nvaccel=1  nvfbheads=4  -nvkmsnosmooth
amfi_get_out_of_my_way=0x1  amfi=0x80
```

> ⚠️ `ipc_control_port_options=0` **不是必需的，先别加** —— README 把它列进了推荐串，
> 但已实测有机器加上去**直接 panic**。它只跟 Firefox 启动崩溃有关，跟显示链路无关。
> 要试也放到最后单独试。

并且不能有 `nv_disable=1` 或 `-wegnoegpu`。

| 参数 | 作用 | 缺了会怎样 |
|---|---|---|
| `nvfb=1` | NVRMFB 的启动开关（`nvrm-fb.cpp:2145`，源码注释叫 *boot-loop guard*） | NVRMFB 直接 `NOT starting` → 没有任何 framebuffer → **黑屏** |
| `nvaccel=1` | NVAccel 加速器的启动开关（`nvrm-accel.cpp:593`） | 没有 2D/3D 加速、没有 Metal 合成 → 桌面卡顿或起不来 |
| `nvfbheads=4` | 发布几个显示 nub（`NVRM.cpp:70`，默认 1，上限 4） | 只发 1 个 → 多显示器 / 多 head 的面板点不亮 |
| `-nvkmsnosmooth` | 关掉「平滑接管」：不再复刻固件当前的显示时序，让 NVKMS 自己重新设模式（`NVRM.cpp:583`） | 走 smooth takeover 路径，部分机器上花屏 / 黑屏 |
| `amfi_get_out_of_my_way=0x1` | 关掉 AMFI 的代码签名校验（Apple 参数，不是驱动的） | WindowServer 加载不了未签名的 `NVMTLDriver.bundle` → **没有 Metal** |
| `amfi=0x80` | 同上，放宽库校验（Apple 参数） | 同上 |
| `ipc_control_port_options=0` | 放宽 Mach IPC 控制端口限制（Apple 参数）。**只为修 Firefox 启动崩溃，与显示无关** | 缺了不影响驱动；**但已实测有机器加了直接 panic**，所以默认不加 |

不能有的两个：`nv_disable=1`（旧 web driver 的禁用开关，会隐藏显卡）、
`-wegnoegpu` / `-wegonogpu`（WhateverGreen 的参数，会把独显藏起来）。

**缺 `nvfb=1` 的症状**：四个 kext 全都加载、NVRM 也打印 `PASS 2 REACHED`，
但 NVRMFB 直接 `boot-arg nvfb=1 absent: NOT starting` —— 屏幕全黑，看起来像驱动坏了。

要改的地方：`EFI/OC/config.plist` → `NVRAM` → `Add` → `7C436110-AB2A-4BBB-A880-FE41995C9F82`
→ `boot-args`，**并且把 `boot-args` 同时加进 `NVRAM` → `Delete`**
（只加 Add 不加 Delete 无效，变量已存在时 OpenCore 不会覆盖）。

---

## 〇、先看两行，就知道走到了哪一步

跑完取证脚本后，看这两个值就够了：

| 检查项 | 健康机器（本机 RTX 3080 实测） | #185 机器的现状 |
|---|---|---|
| `ioreg` 里的 `nvrm-bars` | `bar0@0x10:0x81000000+0x1000000` **`bar1@0x14:0x7c00000000+0x200000000`** `bar2@0x1c:0x7e00000000+0x2000000` | 只有 `bar0@0x10` 和 `bar2@0x1c`，**没有 `bar1@0x14`** |
| `sysctl debug.nvrmfb_vram_budget_bytes` | `4294967296`（4 GB） | `25165824`（24 MB） |

**`bar1@0x14` 有没有，就是"真 BAR1 aperture 在不在"的唯一判据。**
预算 24 MB 装不下 2560×1600 的 16 MB surface，所以 WindowServer 崩 —— 这是后半段阻塞的因果链。

---

## 一、安全网（改配置之前必须先做）

这台机器改 `ResizeGpuBars` 有**开不了机**的风险。改之前确认至少有一条后路：

- [ ] **1401 的 `Remove NVIDIA driver` 启动项可用**（OpenCore 选择器里能看到，选它就卸载驱动并还原 config）
- [ ] 或者：U 盘里有一份能启动的 EFI 副本
- [ ] 或者：能把这台机器的硬盘拆到别的机器上挂 ESP

只要有一条，就可以往下走。都没有就先别改 `ResizeGpuBars`，只做 E0。

**随时能回到能用的状态**（黑屏但 SSH 通的情况下，直接在 SSH 里执行）：

```bash
sudo nvram boot-args="nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0 -nvoff"
sudo reboot
```

`-nvoff` 是驱动总开关（`kexts/NVRM/nvrm_off.h`），加上它 NVRM 和 NVRMFB 都不会 start，系统回到普通黑苹果状态。

---

## 二、E0：用 2.3.5 复测一次（5 分钟，零风险）

不改任何配置，只确认后半段阻塞还在。跑一次取证：

```bash
sudo bash nm185-diag.sh ~/Desktop
```

跑完看输出末尾的「驱动:」和「nvrm-bars」两行。

**判读**：

- `nvrm-bars` 里仍然没有 `bar1@0x14` → 后半段阻塞原样还在，继续 E1
- 预算不再是 24 MB → 说明 2.2.0~2.3.5 之间动过 BAR1 预算路径，**先告诉我**，计划要改
- 桌面居然起来了 → 2.3.x 已经修好了，只需更新 issue

---

## 三、E1：BAR 放置矩阵（这是关键一步）

### 为什么做这个

`kexts/NVRM/NVRM.cpp:1031-1053` 有一段专门为 #185 写的跳过逻辑：

```cpp
// Moving such a BAR1 to the top of the host window broke RTX 4060/4070 laptops (GH #185, #205)
if (!newSize) {                                  // BAR1 已经是 >= 4 GB，不需要 resize
    if (cur1 >= (4ULL<<30) && inNub && !conInside) {
        LOG("bar1: BAR1 already %llu MB at 0x%llx ... - left in place, as NVIDIA's driver does");
        return true;                             // ← 不搬，保住 aperture
    }
}
```

三个条件 `cur1 >= 4GB` / `inNub` / `!conInside` 缺一不可。iussch 的日志显示它**没有触发**，
但我们不知道是哪个条件为假。**这一组实验就是把这三种可能拆开。**

### 怎么改

> ★ **更正（2026-10-18 03:20 实测）**：两个键**不在同一节**，此前这份手册写错了。
> - `ResizeGpuBars` 在 **`UEFI → Quirks`**（固件层，决定固件给 GPU 多大的 BAR）
> - `ResizeAppleGpuBars` 在 **`Booter → Quirks`**（macOS 引导层）
> 按旧写法 `Booter.Quirks.ResizeGpuBars` 会因键不存在而失败。
>
> ★★ **本机组 C（`ResizeGpuBars=13`）已实测 = 黑屏起不来**，见 §五。别再重复。

改哪里：OpenCore 的 `EFI/OC/config.plist`，用 ProperTree 或 OCAuxiliaryTools 打开，
只改这两个整数，其它别动。

- `ResizeGpuBars` → **`UEFI → Quirks`**
- `ResizeAppleGpuBars` → **`Booter → Quirks`**

> `ResizeAppleGpuBars` 是**整数**，`-1` 表示"不动"，不是"缩到最小"。
> 改完正常保存、让 EFI 分区正常卸载，再重启。

### 矩阵

| 组 | `ResizeGpuBars` | `ResizeAppleGpuBars` | 想验证什么 |
|---|---|---|---|
| **A** | `-1` | `0` | 基线：Apple 小 BAR 路径（issue 里的现状） |
| **B** | `-1` | `-1` | 保留固件自己的放置 |
| **C** | `13` | `-1` | **重点**：固件直接给 8 GB 且不被 macOS 缩回去 |
| **D** | `12` | `-1` | `>= 4 GB` 这个阈值的边界（4 GB 刚好卡在条件上） |
| **E** | `8` | `-1` | 对照组：固件给 256 MB，走 resize 路径 |

每组跑完都 `sudo bash nm185-diag.sh ~/Desktop`，把 `kernlog-bar1-only.txt` 和 `nvrm-props.txt` 留着。

### 每组要抓的那几行

```
bar1: Resizable BAR capability @0x... says BAR1 = N MB        ← 固件实际给了多大
bar1: BAR1 is N MB; will resize it to M MB                    ← 有没有走 resize
bar1: BAR1 already N MB at 0x... (above 4 GB, in the nub, console 0x... outside it) - left in place   ← ★ 跳过逻辑生效
bar1: placing BAR1 N MB @0x...                                ← 走了搬动（会坏）
bar1: placed in hardware but the aperture list could not be built (no memory)   ← 搬了但建不出 aperture
BAR1 (the VRAM window) has no address from macOS               ← 最终状态
```

---

## 四、判读表

| 现象 | 含义 | 下一步 |
|---|---|---|
| C 组出现 `left in place`，`nvrm-bars` 有 `bar1@0x14`，预算 4 GB，**桌面起来** | 修好了，不用改代码，只需在 OpenCore 里固定这组值 | 更新 issue，写清配置 |
| C 组出现 `left in place`，但**仍然黑屏**，`nvAllocVram` 还是 REFUSED | 不是 BAR1 放置的问题，是别的东西（NVKMS 的 VRAM 布局 / scanout 分配） | 转去看 `kernlog` 里 `nvAllocVram` 的完整上下文 |
| C 组**没有** `left in place`，仍然是 `placing BAR1 ... @0x3ffa...` | 跳过逻辑没触发 → 说明 `inNub` 或 `conInside` 为假 | 需要 E2（二进制补丁）来分开这两个 |
| 所有组都不出现 `left in place`，且 `nvrm-bars` 恒缺 `bar1@0x14` | IOPCIFamily 从不给这个 BAR 建 aperture | 这是 NVRM 侧的活，得重建 aperture |
| E 组能起来 / A 组能起来 | 说明 8 GB BAR1 本身是问题（VRAM 窗口太大） | 换方向：验证 `-nvrmsmallbar`（已知会让这台机器中途重启） |

---

## 五、汇报模板（贴到 issue 或发给我）

```
机型：R9000P 2023 / 7945HX / RTX 4060 Laptop (10de:28e0) / 8 GB BAR1
macOS：15.8.1
驱动：NullMoth 2.3.5（官方 tarball，未修改）
OpenCore：ResizeGpuBars=<X> ResizeAppleGpuBars=<Y> ResizeUsePciRbIo=False
其它 boot-args：<原样>

结果：<桌面起来了 / 黑屏但 SSH 通 / 中途重启>

关键日志：
<贴 kernlog-bar1-only.txt 全文>

nvrm-bars：
<贴那一行>

VRAM 预算：<数字> 字节
```

---

## 六、附：脚本在哪、怎么用

`nm185-diag.sh` —— 只读取证，不改任何系统设置。

```bash
bash nm185-diag.sh --guide           # 把本手册打印到终端
sudo bash nm185-diag.sh              # 输出到 /tmp
sudo bash nm185-diag.sh ~/Desktop    # 输出到桌面
```

产出 `nm185-<主机名>-<时间戳>.tar.gz`，里面最重要的是：

| 文件 | 内容 |
|---|---|
| `nvrm-props.txt` | **`nvrm-bars` 那一行**（判决书） |
| `kernlog-bar1-only.txt` | 只留 bar1 / aperture / RmInitAdapter 相关行，可以直接贴 |
| `sysctl.txt` | VRAM 预算、flip 计数 |
| `gpu-pci.txt` | 显卡 PCI 节点 + `assigned-addresses` |
| `pci-bridges.txt` | 根端口窗口（`placeLargeBar1` 改的就是这里） |
| `crashes.txt` | WindowServer 崩溃循环状态 |
| `ioreg-full.txt` | 完整 ioreg，兜底用（3~4 MB） |

脚本末尾会自动打一句判读结论，先看那句。
