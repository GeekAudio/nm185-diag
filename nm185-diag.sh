#!/bin/bash
# nm185-diag.sh — NullMoth NVIDIA 驱动现场取证脚本
#
# 为 GitHub issue #185（RTX 4060 Laptop + Ryzen 9 7945HX，BAR1 aperture 缺失导致黑屏）
# 而写，但脚本本身与机型无关：任何装了 NullMoth 驱动的机器都能跑，用来做健康基线对照。
#
# 用法（可以直接通过 SSH 在目标机上跑，不需要本地有画面）：
#   bash nm185-diag.sh --guide              # ★ 把整份测试手册打印到终端（不亮屏也能看）
#   sudo bash nm185-diag.sh                 # 输出到 /tmp
#   sudo bash nm185-diag.sh ~/Desktop       # 输出到桌面
#   bash nm185-diag.sh                      # 不加 sudo 也能跑，但会缺内核日志和崩溃报告
#
# 产出：
#   <输出目录>/nm185-<主机名>-<时间戳>.tar.gz   ← 打包好的全部证据
#   <输出目录>/nm185-<主机名>-<时间戳>/         ← 解包后的目录（方便先看）
#
# 设计原则：
#   1. 每一步都单独兜底，任何一步失败都不影响后面的步骤
#   2. 不改任何系统设置、不写 NVRAM、不动 EFI —— 纯只读取证
#   3. 大文件（完整 ioreg / 内核日志）单独存，小结论单独存，方便直接贴
#
# 兼容 bash 3.2（macOS 自带），不使用 mapfile / 关联数组。
# 许可证：MIT。与 NullMoth / NullMoth Systems 无关联。

set -u

VERSION="1.0.0"

# ---------------------------------------------------------------- 终端版手册
# 测试机的屏幕是不亮的，所有说明都必须能在 SSH 终端里读完。
# 内容与 index.html / RUNBOOK.md 一致，只是换成终端排版。
print_guide() {
/bin/cat <<'GUIDE'
================================================================
 nm185-diag 1.0.0    NullMoth 驱动 issue #185   测试手册（终端版）
================================================================

 目标机型  Lenovo Legion R9000P 2023 / Ryzen 9 7945HX
           RTX 4060 Laptop (10de:28e0, 8GB BAR1) 内屏 2560x1600
 驱动      NullMoth 2.3.5
 前提      能 SSH 进黑屏的系统（issue 里已确认可行）

 本脚本只读：不改系统设置、不写 NVRAM、不动 EFI。

----------------------------------------------------------------
 前置检查：先确认驱动真的被允许启动
----------------------------------------------------------------

 光把 kext 装进 /Library/Extensions 是不够的，OpenCore 还得给这几项。

 boot-args 必须含：

   nvfb=1  nvaccel=1  nvfbheads=4  -nvkmsnosmooth
   amfi_get_out_of_my_way=0x1  amfi=0x80  ipc_control_port_options=0

 且不能有：

   nv_disable=1    -wegnoegpu

 缺 nvfb=1 的典型症状：kext 全都加载、NVRM 也打印 PASS 2，
 但 NVRMFB 直接 "boot-arg nvfb=1 absent: NOT starting"，
 屏幕全黑 —— 看起来像驱动坏了，其实只是没配 OpenCore。

 本脚本开跑前会自动检查这一项，缺了会大声喊。

 补 boot-args 的两个办法：

   A) 用 1401 app 装（它自己会写）
   B) 手动写进 config.plist：
        NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> boot-args
        并且把 boot-args 同时加进 NVRAM -> Delete

 ★ 只加 Add 不加 Delete 是无效的：变量已经存在时 OC 不会覆盖。

----------------------------------------------------------------
 〇  判据：只看一行
----------------------------------------------------------------

 ioreg 里的 nvrm-bars：

   健康   ... bar1@0x14:0x7c00000000+0x200000000 ...
   #185   ... 没有 bar1@0x14 ...

 有没有 bar1@0x14，就是"真 BAR1 aperture 在不在"的唯一判据。

 配套看 sysctl debug.nvrmfb_vram_budget_bytes：

   健康 4294967296 (4GB)      #185 25165824 (24MB)

 24MB 装不下 2560x1600 的 16MB surface，WindowServer 所以崩。
 这就是后半段阻塞的完整因果链。

----------------------------------------------------------------
 一  安全网：改配置之前必须先做
----------------------------------------------------------------

 改 ResizeGpuBars 有开不了机的风险。先确认至少有一条后路：

   [ ] 1401 的 Remove NVIDIA driver 启动项可用
   [ ] 或 U 盘里有一份能启动的 EFI 副本
   [ ] 或能把硬盘拆到别的机器上挂 ESP

 都没有就先别改 ResizeGpuBars，只做 E0。

 随时回退（黑屏但 SSH 通时，逐行执行）：

   ARGS="nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth"
   ARGS="$ARGS amfi_get_out_of_my_way=0x1 amfi=0x80"
   ARGS="$ARGS ipc_control_port_options=0 -nvoff"
   sudo nvram boot-args="$ARGS"
   sudo reboot

 -nvoff 是驱动总开关（kexts/NVRM/nvrm_off.h），加上它 NVRM 和
 NVRMFB 都不 start，系统回到普通黑苹果状态。

----------------------------------------------------------------
 二  E0：用 2.3.5 复测一次（5 分钟，零风险）
----------------------------------------------------------------

 不改任何配置，只确认后半段阻塞还在。

   sudo bash /tmp/nm185-diag.sh

 跑完看输出末尾那两行："驱动:" 应为 2.3.5，"nvrm-bars" 看有没有
 bar1@0x14。判读：

   nvrm-bars 仍无 bar1@0x14   -> 阻塞还在，继续 E1
   预算不再是 24MB            -> 中间版本动过 BAR1 路径，先回报
   桌面居然起来了             -> 已修好，只需更新 issue

----------------------------------------------------------------
 三  E1：BAR 放置矩阵（关键一步）
----------------------------------------------------------------

 源码 kexts/NVRM/NVRM.cpp:1031-1053 有一段专为 #185 写的跳过逻辑：

   if (!newSize) {                                // BAR1 已 >= 4GB
     if (cur1 >= 4GB && inNub && !conInside) {
        LOG("... left in place, as NVIDIA's driver does");
        return true;                              // 不搬，保住 aperture
     }
   }

 三个条件缺一不可。现有日志显示它没触发，但不知道是哪个为假。
 这组实验就是把三种可能拆开。

 改哪里：OpenCore 的 config.plist（EFI/OC/config.plist）
 两个键不在同一节，别改错地方：

   ResizeGpuBars        ->  UEFI   -> Quirks   （固件层）
   ResizeAppleGpuBars   ->  Booter -> Quirks   （macOS 引导层）

 用 ProperTree 或 OCAuxiliaryTools 打开，只改这两个整数，其它别动。
 改完正常保存、让 EFI 分区正常卸载，再重启。

 ★ 组 C 已经有过一次"改完起不来"的记录。做之前先把上面的安全网走一遍。

 矩阵（ResizeGpuBars 的值 = log2(MB)：13=8GB, 12=4GB, 8=256MB）：

   组   ResizeGpuBars   ResizeAppleGpuBars   验证什么
   A    -1              0                   基线（Apple 小 BAR）
   B    -1              -1                  保留固件放置
   C    13              -1                  固件给 8GB 且不被缩回  <- 重点
   D    12              -1                  4GB 阈值边界
   E    8               -1                  对照组 256MB

 每组跑完：sudo bash /tmp/nm185-diag.sh
 留 kernlog-bar1-only.txt 和 nvrm-props.txt 这两个文件。

 每组要抓的六行：

   bar1: Resizable BAR capability @0x... says BAR1 = N MB
   bar1: BAR1 is N MB; will resize it to M MB
   bar1: BAR1 already N MB at 0x... (above 4 GB, in the nub, console ... outside it) - left in place
   bar1: placing BAR1 N MB @0x...
   bar1: placed in hardware but the aperture list could not be built (no memory)
   BAR1 (the VRAM window) has no address from macOS

----------------------------------------------------------------
 四  判读表
----------------------------------------------------------------

 C 组 left in place + 有 bar1@0x14 + 预算 4GB + 桌面起来
    -> 修好了，不用改代码，在 OpenCore 里固定这组值

 C 组 left in place 但仍黑屏、nvAllocVram 仍 REFUSED
    -> 不是 BAR1 放置的问题，看 NVKMS 的 VRAM 布局 / scanout

 C 组没有 left in place，仍是 placing BAR1 @0x3ffa...
    -> 跳过逻辑没触发，inNub 或 conInside 为假

 所有组都没有 left in place，且恒缺 bar1@0x14
    -> IOPCIFamily 从不给这个 BAR 建 aperture

 E 组或 A 组能起来
    -> 8GB BAR1 本身是问题，换 -nvrmsmallbar 方向

----------------------------------------------------------------
 五  汇报（贴这四样就够）
----------------------------------------------------------------

   1. kernlog-bar1-only.txt  全文
   2. nvrm-props.txt         里 nvrm-bars 那一行
   3. 这一组用的 ResizeGpuBars / ResizeAppleGpuBars
   4. 结果：桌面起来了 / 黑屏但 SSH 通 / 中途重启

 打包好的 tar.gz 可以直接传：
   scp <用户名>@<这台机器>:/tmp/nm185-*.tar.gz .

----------------------------------------------------------------
 六  脚本产出什么
----------------------------------------------------------------

   nvrm-props.txt          nvrm-bars 那一行（判决书）
   kernlog-bar1-only.txt   只留 bar1/aperture/RmInitAdapter，可直接贴
   sysctl.txt              VRAM 预算、flip 计数
   gpu-pci.txt             显卡 PCI 节点 + assigned-addresses
   pci-bridges.txt         根端口窗口（placeLargeBar1 改的就是这里）
   crashes.txt             WindowServer 崩溃循环状态
   ioreg-full.txt          完整 ioreg，兜底（3~4MB）

 跑完脚本末尾会自动打一句判读结论，先看那句。

================================================================
 第三方排障资料，与 NullMoth / NullMoth Systems 无关联。
 仓库 https://github.com/GeekAudio/nm185-diag   MIT
================================================================
GUIDE
}

print_help() {
/bin/cat <<'HELP'
nm185-diag.sh — NullMoth NVIDIA 驱动现场取证脚本（issue #185）

用法：
  bash nm185-diag.sh --guide            ★ 把整份测试手册打印到终端（不亮屏也能看）
  sudo bash nm185-diag.sh               取证，输出到 /tmp
  sudo bash nm185-diag.sh ~/Desktop     取证，输出到桌面
  bash nm185-diag.sh                    不加 sudo 也能跑，但会缺内核日志和崩溃报告
  bash nm185-diag.sh --version

产出：
  <输出目录>/nm185-<主机名>-<时间戳>.tar.gz   打包好的全部证据
  <输出目录>/nm185-<主机名>-<时间戳>/         解包后的目录（方便先看）

只读：不改系统设置、不写 NVRAM、不动 EFI。
兼容 bash 3.2（macOS 自带）。MIT。与 NullMoth / NullMoth Systems 无关联。
HELP
}

case "${1:-}" in
    -h|--help)    print_help; exit 0 ;;
    -g|--guide)   print_guide; exit 0 ;;
    -V|--version) echo "nm185-diag $VERSION"; exit 0 ;;
esac

# ---------------------------------------------------------------- 输出目录
HOST=$(hostname -s 2>/dev/null || echo unknown)
STAMP=$(date +%Y%m%d-%H%M%S)
BASE=${1:-/tmp}
OUT="$BASE/nm185-$HOST-$STAMP"

mkdir -p "$OUT" || { echo "无法创建 $OUT"; exit 1; }

if [ "$(id -u)" != "0" ]; then
    echo "警告：当前不是 root，部分内容（dmesg / 内核日志 / 崩溃报告）会缺失。"
    echo "      建议用：sudo bash $0"
    echo
fi

say() { printf '  %-42s %s\n' "$1" "$2"; }

# ---------------------------------------------------------------- 前置检查
# 装完驱动但没配 OpenCore 的机器很常见：kext 全加载了、NVRM 也起来了，
# 但 NVRMFB 因为缺 nvfb=1 直接 NOT starting，屏幕全黑，看起来像驱动坏了。
# 这一段先把这种情况喊出来，免得白抓一堆日志。
preflight() {
    ARGS=$(nvram boot-args 2>/dev/null | /usr/bin/sed 's/^boot-args[[:space:]]*//')
    NEED="nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0"
    MISS=""
    for a in $NEED; do
        case " $ARGS " in
            *" $a "*) ;;
            *) MISS="$MISS $a" ;;
        esac
    done
    BAD=""
    for b in nv_disable=1 -wegnoegpu -wegonogpu; do
        case " $ARGS " in
            *" $b "*) BAD="$BAD $b" ;;
        esac
    done
    {
        echo "### 当前 boot-args"
        echo "${ARGS:-(空)}"
        echo
        echo "### 缺失（README 要求）"
        echo "${MISS:-无}"
        echo
        echo "### 不该有"
        echo "${BAD:-无}"
    } > "$OUT/preflight.txt" 2>&1

    if [ -n "$MISS" ]; then
        echo
        echo "  ############################################################"
        echo "  #  ★ 前置检查未通过：boot-args 缺东西，驱动不会驱动显示器"
        echo "  #"
        echo "  #    缺：$MISS"
        echo "  #"
        echo "  #  症状就是黑屏，但 kext 全都加载了 —— 因为 NVRMFB 在"
        echo "  #  start() 里看到没有 nvfb=1 就直接 NOT starting。"
        echo "  #  这时候抓的日志对 issue #185 没有意义。"
        echo "  #"
        echo "  #  先补齐 boot-args（详见 --guide 的「前置检查」一节）再跑。"
        echo "  ############################################################"
        echo
    fi
    if [ -n "$BAD" ]; then
        echo "  ★ 警告：boot-args 里有会把显卡藏起来的参数：$BAD"
        echo
    fi
}

preflight


# 抓一个命令到文件。$1 = 文件名, 其余 = 命令
cap() {
    f="$1"; shift
    "$@" > "$OUT/$f" 2>&1
    rc=$?
    if [ $rc -eq 0 ] && [ -s "$OUT/$f" ]; then say "$f" "ok"
    else say "$f" "rc=$rc $([ -s "$OUT/$f" ] || echo '(空)')"; fi
}

# 抓命令输出并就地 grep（用于快速阅读的小文件）
capg() {
    f="$1"; pat="$2"; shift 2
    "$@" 2>&1 | /usr/bin/grep -E "$pat" > "$OUT/$f"
    n=$(/usr/bin/wc -l < "$OUT/$f" | /usr/bin/tr -d ' ')
    say "$f" "$n 行"
}

echo "== 1/7 系统与启动参数 =="
{
    echo "### 时间";        date
    echo; echo "### 系统";  sw_vers 2>/dev/null
    echo; echo "### 内核";  uname -a
    echo; echo "### 机型";  sysctl -n hw.model 2>/dev/null
    echo; echo "### CPU";   sysctl -n machdep.cpu.brand_string 2>/dev/null
    echo; echo "### 内存";  sysctl -n hw.memsize 2>/dev/null
    echo; echo "### 启动时间"; sysctl -n kern.boottime 2>/dev/null
} > "$OUT/system.txt" 2>&1
say "system.txt" ok

# boot-args 与 SIP 是这套驱动的命门，单独一个文件
{
    echo "### nvram boot-args"
    nvram -p 2>/dev/null | /usr/bin/grep -E "^boot-args" || echo "(无 boot-args)"
    echo; echo "### csr-active-config（十六进制）"
    nvram -p 2>/dev/null | /usr/bin/grep -E "^csr-active-config" || echo "(无)"
    echo; echo "### csrutil status"
    csrutil status 2>&1
    echo; echo "### spctl"
    spctl --status 2>&1
    echo; echo "### SIP 位解码（0x0A43 = kext 签名关 + unauthenticated root 开）"
    echo "  需要 csr-active-config 含 0x0A43"
} > "$OUT/bootargs.txt" 2>&1
say "bootargs.txt" ok

capg "nvram-all.txt" "." nvram -p

echo "== 2/7 驱动版本与加载状态 =="
{
    echo "### kmutil showloaded | nullmoth"
    kmutil showloaded --list-only 2>/dev/null | /usr/bin/grep -i nullmoth || echo "(没有 nullmoth 的 kext 加载)"
    echo
    for k in NVRM NVRMFB NVRMAGDC NVAccel; do
        p="/Library/Extensions/$k.kext/Contents/Info.plist"
        echo "### $k"
        if [ -f "$p" ]; then
            /usr/bin/plutil -p "$p" 2>/dev/null | /usr/bin/grep -E "CFBundleVersion|CFBundleShortVersionString"
        else
            echo "(未安装)"
        fi
        echo
    done
    echo "### GPUBundles"
    ls -la /Library/GPUBundles 2>/dev/null
    echo
    echo "### 固件"
    ls -la /Users/Shared/nvfw/nvidia/*/ 2>/dev/null | head -20
} > "$OUT/kexts.txt" 2>&1
say "kexts.txt" ok

echo "== 3/7 显示与 GPU 识别 =="
cap "displays.txt" system_profiler SPDisplaysDataType

echo "== 4/7 关键属性（★ 最重要） =="
# nvrm-bars 这一行就是判决书：
#   健康机器：bar0@0x10:...  bar1@0x14:<8GB 的地址>+0x200000000  bar2@0x1c:...
#   #185 机器：bar0@0x10:...  bar2@0x1c:...          ← 少了 bar1@0x14
capg "nvrm-props.txt" "nvrm-bars|nvrm-bar1-placed|nvrm-gpu-profile|nvrm-claimed|nvrm-boot-hold|nvrm-autogo|\"model\"" \
     ioreg -l -w0 -p IOService -n NVRM
# NVRMFB 的 BAR1 元数据与预算
capg "nvrmfb-props.txt" "NVRMNVDAFramebuffer|bar1|BAR1|budget" \
     ioreg -l -w0 -p IOService -c NVRMNVDAFramebuffer

# 显卡 PCI 节点（assigned-addresses / device memory 全在这里）
# 注意：节点在 IOService 平面的名字是 GFX0，不是 pci10de,xxxx（那个只出现在
# compatible 属性里，用 -n pci10de,xxxx 抓不到任何东西，早先的版本这里是个空文件）。
{
    echo "########## GFX0（显卡本体，含 assigned-addresses） ##########"
    ioreg -l -w0 -p IOService -n GFX0 -r 2>/dev/null
    echo
    echo "########## PEGP（上游根端口，含窗口寄存器） ##########"
    ioreg -l -w0 -p IOService -n PEGP -r 2>/dev/null
    echo
    echo "########## 兜底：所有 10de 设备的 device-id / assigned-addresses ##########"
    ioreg -l -w0 -p IOService -c IOPCIDevice 2>/dev/null | /usr/bin/grep -E '"device-id"|"assigned-addresses"|"IOName"'
} > "$OUT/gpu-pci.txt" 2>&1
say "gpu-pci.txt" "$(/usr/bin/wc -l < "$OUT/gpu-pci.txt" | /usr/bin/tr -d ' ') 行"

# 根端口 / 桥窗口（placeLargeBar1 改的就是这里）
capg "pci-bridges.txt" "IOPCI2PCIBridge|IOPCIBridge|assigned-addresses|ranges" \
     ioreg -l -w0 -p IOService -c IOPCIBridge

# 完整 ioreg 留档，防止漏掉任何东西
ioreg -l -w0 -p IOService > "$OUT/ioreg-full.txt" 2>&1
say "ioreg-full.txt" "$(/usr/bin/du -h "$OUT/ioreg-full.txt" | /usr/bin/cut -f1)"

echo "== 5/7 运行时计数器 =="
{
    for s in debug.nvrmfb_vram_budget_bytes debug.nvrmfb_vram_mapped_bytes \
             debug.nvrmfb_vram_display_bytes debug.nvrmfb_vram_display_aware \
             debug.nvrmfb_vram_grants debug.nvrmfb_vram_grant_bytes \
             debug.nvrmfb_vram_releases debug.nvrmfb_vram_release_bytes \
             debug.nvrmfb_flip_n debug.nvrmfb_flip_latch debug.nvrmfb_flip_latch_timeouts \
             debug.nvaccel_iop_flip debug.nvrm_physmap debug.nvrm_isr_count; do
        v=$(sysctl -n "$s" 2>/dev/null) && printf '%-42s %s\n' "$s" "$v"
    done
} > "$OUT/sysctl.txt" 2>&1
say "sysctl.txt" ok

echo "== 6/7 内核日志（NVRM / NVRM-fb） =="
# IOLog 同时走 kprintf 和统一日志，两条路都抓
if [ -x /usr/bin/log ]; then
    /usr/bin/log show --last boot --style compact \
        --predicate 'eventMessage CONTAINS "NVRM"' > "$OUT/kernlog-NVRM.txt" 2>&1
    n=$(/usr/bin/wc -l < "$OUT/kernlog-NVRM.txt" | /usr/bin/tr -d ' ')
    if [ "$n" -lt 5 ]; then
        # 有些机器默认级别不含 IOLog，再开 --info 抓一次
        /usr/bin/log show --last boot --style compact --info \
            --predicate 'eventMessage CONTAINS "NVRM"' > "$OUT/kernlog-NVRM.txt" 2>&1
        n=$(/usr/bin/wc -l < "$OUT/kernlog-NVRM.txt" | /usr/bin/tr -d ' ')
    fi
    say "kernlog-NVRM.txt" "$n 行"
    if [ "$n" -lt 5 ]; then
        # 统一日志拿不到（沙箱 / 权限 / 级别），退回内核环形缓冲区
        dmesg 2>/dev/null | /usr/bin/grep "NVRM" > "$OUT/kernlog-NVRM.txt"
        n=$(/usr/bin/wc -l < "$OUT/kernlog-NVRM.txt" | /usr/bin/tr -d ' ')
        say "kernlog-NVRM.txt (dmesg 兜底)" "$n 行"
    fi
    # 只要 bar1 决策那几行，单独一份，方便直接贴 issue
    /usr/bin/grep -E "bar1:|BAR1|aperture|nvAllocVram|PASS [12]|RmInitAdapter|kbusVerifyBar2|rm_init_adapter|auto-go|boot hold|nvfb=1 absent|NOT starting" \
        "$OUT/kernlog-NVRM.txt" > "$OUT/kernlog-bar1-only.txt" 2>/dev/null
    say "kernlog-bar1-only.txt" "$(/usr/bin/wc -l < "$OUT/kernlog-bar1-only.txt" | /usr/bin/tr -d ' ') 行"
else
    say "kernlog-NVRM.txt" "无 /usr/bin/log"
fi
cap "dmesg.txt" dmesg

echo "== 7/7 崩溃现场 =="
{
    echo "### WindowServer 状态"
    launchctl print system/com.apple.WindowServer 2>&1 | head -40
    echo
    echo "### WindowServer 崩溃报告（最新 3 份，只留摘要）"
    for f in $(ls -t /Library/Logs/DiagnosticReports/WindowServer-*.ips 2>/dev/null | head -3); do
        echo "---------- $f"
        /usr/bin/grep -E '"exception"|"termination"|"faultingThread"|CoreDisplay|CGXDisplay|__assert_rtn|ktriageinfo' "$f" 2>/dev/null | head -12
        echo
    done
    echo "### 内核 panic（最新 2 份）"
    ls -lt /Library/Logs/DiagnosticReports/Kernel-*.panic 2>/dev/null | head -2
} > "$OUT/crashes.txt" 2>&1
say "crashes.txt" ok

# OpenCore 启动日志（如果 EFI 卷已挂载）
OC=$(ls -t /Volumes/EFI/opencore-*.txt 2>/dev/null | head -1)
if [ -n "${OC:-}" ]; then
    /usr/bin/tail -400 "$OC" > "$OUT/opencore-tail.txt" 2>&1
    say "opencore-tail.txt" "$OC"
else
    echo "(EFI 卷未挂载，跳过 OpenCore 日志)" > "$OUT/opencore-tail.txt"
    say "opencore-tail.txt" "跳过"
fi

# ---------------------------------------------------------------- 打包
echo
echo "== 打包 =="
TGZ="$BASE/nm185-$HOST-$STAMP.tar.gz"
( cd "$BASE" && tar -czf "$TGZ" "nm185-$HOST-$STAMP" 2>/dev/null )
if [ -f "$TGZ" ]; then
    /usr/bin/shasum -a 256 "$TGZ" > "$TGZ.sha256" 2>/dev/null
    echo "  打包完成：$TGZ"
    echo "  大小：$(/usr/bin/du -h "$TGZ" | /usr/bin/cut -f1)"
    echo "  校验：$(/bin/cat "$TGZ.sha256")"
else
    echo "  打包失败，直接取目录：$OUT"
fi

echo
echo "== 一句话判读 =="
BARS=$(/usr/bin/grep -h "nvrm-bars" "$OUT/nvrm-props.txt" 2>/dev/null | /usr/bin/grep -o '"nvrm-bars" = ".*"' | head -1)
BUDGET=$(/usr/bin/grep "nvrmfb_vram_budget_bytes" "$OUT/sysctl.txt" 2>/dev/null | /usr/bin/awk '{print $2}')
B1SZ=$(echo "${BARS:-}" | /usr/bin/sed -n 's/.*bar1@0x14:0x[0-9a-f]*+0x\([0-9a-f]*\).*/\1/p')
B1MB=0
if [ -n "$B1SZ" ]; then
    B1B=$(printf '%d' "0x$B1SZ" 2>/dev/null) && B1MB=$((B1B / 1048576))
fi
echo "  nvrm-bars : ${BARS:-（没读到）}"
echo "  VRAM 预算 : ${BUDGET:-（没读到）} 字节"
case "${BARS:-}" in
    *"bar1@0x14"*)
        if [ "${B1MB:-0}" -ge 4096 ]; then
            echo "  → bar1@0x14 是 ${B1MB} MB（大 BAR1，跳过搬动的条件才可能成立）。"
            echo "    若仍黑屏，看 kernlog 里的 nvAllocVram / NVKMS 布局，不是 BAR1 放置。"
        else
            echo "  → bar1@0x14 只有 ${B1MB} MB（小 BAR1）。驱动会尝试 resize 到 8 GB 并把它搬走；"
            echo "    日志里若有 'aperture list could not be built'，就是 aperture 重建失败 —— #185 主路径。"
        fi
        ;;
    *) echo "  → ★ 缺 bar1@0x14：真 BAR1 aperture 不在 nub 里，和 issue #185 后半段阻塞一致。" ;;
esac
if /usr/bin/grep -q "nvfb=1 absent" "$OUT/kernlog-NVRM.txt" 2>/dev/null; then
    echo
    echo "  ★★ 但 NVRMFB 根本没启动（boot-arg nvfb=1 absent）——"
    echo "     屏幕是黑的，可上面这些 BAR1 分析还没轮到。先补 boot-args。"
fi
echo
echo "== 下一步 =="
echo "  1) 只贴两个文件就够（不用传整个包）："
echo "       $OUT/kernlog-bar1-only.txt"
echo "       $OUT/nvrm-props.txt"
echo
echo "  2) 要传整个包，从另一台机器上执行："
echo "       scp ${SUDO_USER:-$(whoami)}@$HOST:$TGZ ."
echo
echo "  3) 想看完整测试手册（屏幕不亮也能读，就在这个终端里）："
echo "       bash $0 --guide"
echo
echo "  想直接贴到聊天窗口的话，下面这段是已经截好的："
echo "  ----------------------------------------------------------"
echo "  机型: $(sysctl -n hw.model 2>/dev/null)  macOS: $(sw_vers -productVersion 2>/dev/null)"
echo "  驱动: $(/usr/bin/plutil -extract CFBundleVersion raw /Library/Extensions/NVRM.kext/Contents/Info.plist 2>/dev/null)"
echo "  boot-args: $(nvram boot-args 2>/dev/null | /usr/bin/sed 's/^boot-args\t//')"
echo "  $BARS"
echo "  VRAM 预算: ${BUDGET:-?} 字节"
echo "  ----------------------------------------------------------"

