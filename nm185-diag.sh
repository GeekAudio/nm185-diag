#!/bin/bash
# nm185-diag.sh — NullMoth NVIDIA 驱动现场取证脚本
#
# 为 GitHub issue #185（RTX 4060 Laptop + Ryzen 9 7945HX，BAR1 aperture 缺失导致黑屏）
# 而写，但脚本本身与机型无关：任何装了 NullMoth 驱动的机器都能跑，用来做健康基线对照。
#
# 用法（可以直接通过 SSH 在目标机上跑，不需要本地有画面）：
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

case "${1:-}" in
    -h|--help)  /usr/bin/sed -n '2,25p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
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
{
    for id in $(ioreg -p IOService -l -w0 2>/dev/null | /usr/bin/grep -o 'pci10de,[0-9a-f]*' | sort -u); do
        echo "########## $id ##########"
        ioreg -l -w0 -p IOService -n "$id" -r 2>/dev/null
        echo
    done
} > "$OUT/gpu-pci.txt" 2>&1
say "gpu-pci.txt" ok

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
    /usr/bin/grep -E "bar1:|BAR1|aperture|nvAllocVram|PASS [12]|RmInitAdapter|kbusVerifyBar2|rm_init_adapter|auto-go|boot hold" \
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
echo "  nvrm-bars : ${BARS:-（没读到）}"
echo "  VRAM 预算 : ${BUDGET:-（没读到）} 字节"
case "${BARS:-}" in
    *"bar1@0x14"*) echo "  → 真 BAR1 aperture 存在。若仍黑屏，问题不在 BAR1 放置，看 kernlog 里的 nvAllocVram。" ;;
    *)             echo "  → ★ 缺 bar1@0x14：真 BAR1 aperture 不在 nub 里，和 issue #185 后半段阻塞一致。" ;;
esac
echo
echo "请把 $TGZ 传回来，或者至少贴 kernlog-bar1-only.txt + nvrm-props.txt 这两个文件。"
