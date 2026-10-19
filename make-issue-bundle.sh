#!/bin/bash
# 把一次取证的结果压成一个小包，直接拖进 GitHub issue 当附件。
#
#   sudo bash make-issue-bundle.sh            # 先自动跑一次取证再打包
#   sudo bash make-issue-bundle.sh <取证目录>  # 只打包已有的目录
#
# 产物：./nm185-issue-<主机名>-<时间>.zip（几十 KB，含一个 summary.txt）
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=""

if [ $# -ge 1 ] && [ -d "$1" ]; then
    SRC=$(cd "$1" && pwd)
else
    echo "== 先跑一次取证"
    bash "$HERE/nm185-diag.sh" "$HOME/Desktop" >/dev/null 2>&1 || { echo "取证失败"; exit 1; }
    SRC=$(ls -dt "$HOME"/Desktop/nm185-*/ 2>/dev/null | head -1)
    SRC=${SRC%/}
fi

[ -d "${SRC:-}" ] || { echo "找不到取证目录"; exit 1; }
echo "== 取证目录：$SRC"

HOST=$(hostname -s 2>/dev/null || echo unknown)
OUT="$HOME/Desktop/nm185-issue-$HOST-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || exit 1

# 只挑作者真正需要的几个文件，别把整个包塞进 issue
for f in kernlog-bar1-only.txt nvrm-props.txt sysctl.txt bootargs.txt crashes.txt system.txt; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$OUT/"
done

{
    echo "=== system"
    /usr/bin/grep -E "ProductVersion|BuildVersion" "$SRC/system.txt" 2>/dev/null
    /usr/bin/grep -E "^Darwin" "$SRC/system.txt" 2>/dev/null
    /usr/bin/grep -A1 "### 机型" "$SRC/system.txt" 2>/dev/null | /usr/bin/tail -1
    echo
    echo "=== boot-args"
    /usr/bin/grep "^boot-args" "$SRC/nvram-all.txt" 2>/dev/null
    echo
    echo "=== driver"
    /usr/bin/grep "nullmoth" "$SRC/kexts.txt" 2>/dev/null
    echo
    echo "=== nvrm-bars"
    /usr/bin/grep -o '"nvrm-bars" = "[^"]*"' "$SRC/nvrm-props.txt" 2>/dev/null | head -1
    /usr/bin/grep -o '"nvrm-autogo" = "[^"]*"' "$SRC/nvrm-props.txt" 2>/dev/null | head -1
    echo
    echo "=== nvrmfb counters"
    /usr/bin/grep "nvrmfb_vram_budget_bytes\|nvrmfb_vram_mapped_bytes\|nvrmfb_flip_n" "$SRC/sysctl.txt" 2>/dev/null
    echo
    echo "=== WindowServer"
    /usr/bin/grep -E "runs =|successive crashes|last terminating signal" "$SRC/crashes.txt" 2>/dev/null
    echo
    echo "=== last NVRM lines"
    /usr/bin/grep -E "bar1:|PASS [12]|NOT starting|nvAllocVram|applyModeSetConfig|ENUMERATED" "$SRC/kernlog-NVRM.txt" 2>/dev/null \
        | /usr/bin/awk '!seen[$0]++' | tail -25
} > "$OUT/summary.txt" 2>&1

cd "$HOME/Desktop" || exit 1
ZIP="$OUT.zip"
rm -f "$ZIP"
/usr/bin/zip -r -q "$ZIP" "$(basename "$OUT")" && rm -rf "$OUT"

echo
echo "== 好了：$ZIP"
ls -lh "$ZIP" | /usr/bin/awk '{print "   " $5}'
echo
echo "下一步：把这个 zip 拖进 GitHub issue 的评论框当附件。"
echo "正文自己写几句就行 —— 仓库要求 issue 由本人撰写。"
