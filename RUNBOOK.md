# Issue #185 测试手册（RTX 4060 Laptop / R9000P 2023）

> 网页版（手机上更好读）：<https://geekaudio.github.io/nm185-diag/>
>
> 目标机型：Lenovo Legion R9000P 2023 / Ryzen 9 7945HX / RTX 4060 Laptop（`10de:28e0`，8 GB BAR1）/ 内屏 2560×1600
> 驱动：NullMoth **2.3.5**（issue 里的实测停在 2.1.0，2.2.0 之后无人复测过）
> 前提：**能 SSH 进黑屏的系统**。这条已确认可行（issue 里 @iussch 就是这么做的）。

## 一键取证

```bash
curl -fsSL https://raw.githubusercontent.com/GeekAudio/nm185-diag/main/nm185-diag.sh -o /tmp/nm185-diag.sh
sudo bash /tmp/nm185-diag.sh
```

如果报 `curl: (35) Recv failure: Connection reset by peer`，那是网络被重置，不是脚本问题。
注意 **`curl` 不读 macOS 的系统代理设置**，只认环境变量 —— 代理开着也要显式给：

```bash
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
curl -fsSL https://raw.githubusercontent.com/GeekAudio/nm185-diag/main/nm185-diag.sh -o /tmp/nm185-diag.sh
sudo bash /tmp/nm185-diag.sh
```

端口按代理工具改：Clash / ClashX `7890`、Surge `6152`、V2Ray `10809`（http）。

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

不改任何配置，只确认后半段阻塞还在。

```bash
# 1. 确认版本
plutil -p /Library/Extensions/NVRM.kext/Contents/Info.plist | grep CFBundleVersion
# 期望：2.3.5

# 2. 取证
sudo bash nm185-diag.sh ~/Desktop
```

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

SSH 里改（记得先备份）：

```bash
# 找到并挂载 ESP
diskutil list
sudo diskutil mount disk0s1

# 挂载点里可能是 OC/ 也可能是 EFI/OC/，自动找一下
CFG=$(ls /Volumes/EFI/OC/config.plist /Volumes/EFI/EFI/OC/config.plist 2>/dev/null | head -1)
echo "config = $CFG"

# 备份（★ 一定要做）
sudo cp "$CFG" ~/config.plist.bak-$(date +%H%M)

# 改值：13 = 2^13 MB = 8192 MB；12 = 4096 MB；8 = 256 MB；-1 = 不动
# ★ 注意路径不同：ResizeGpuBars 在 UEFI.Quirks，ResizeAppleGpuBars 在 Booter.Quirks
sudo plutil -replace 'UEFI.Quirks.ResizeGpuBars'        -integer 13 "$CFG"
sudo plutil -replace 'Booter.Quirks.ResizeAppleGpuBars' -integer -1 "$CFG"

# 校验 + 落盘（★ FAT 不 sync 会读到旧文件）
plutil -lint "$CFG"
plutil -extract UEFI.Quirks.ResizeGpuBars        raw "$CFG"
plutil -extract Booter.Quirks.ResizeAppleGpuBars raw "$CFG"
sync; sleep 8

sudo reboot
```

> 上面这几条我在本机的 config.plist 副本上跑过，`plutil -replace` 对负数和整数都正常。
> 注意 `ResizeAppleGpuBars` 在 OpenCore 里是**整数**，`-1` 表示"不动"，不是"缩到最小"。

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
