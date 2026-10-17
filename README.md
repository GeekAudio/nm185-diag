# nm185-diag

NullMoth NVIDIA 驱动（`nullmoth/nvidia-macos-driver`）的现场取证脚本，为
[GitHub issue #185](https://github.com/nullmoth/nvidia-macos-driver/issues/185)
（RTX 4060 Laptop + Ryzen 9 7945HX，真 BAR1 aperture 缺失 → WindowServer 崩溃 → 黑屏）而写。

脚本本身与机型无关：任何装了 NullMoth 驱动的机器都能跑，健康机器跑出来的结果可以当对照组。

**📖 测试手册（网页版）：<https://geekaudio.github.io/nm185-diag/>**

## 一键取证

在目标机上执行（**通过 SSH 在黑屏状态下也可以**）：

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
也可以只给这一条命令加：`curl -x http://127.0.0.1:7890 -fsSL …`

产出 `nm185-<主机名>-<时间戳>.tar.gz`，以及同名的解包目录。

## 它只读，不改任何东西

不写 NVRAM、不动 EFI、不改系统设置。只做：读 `ioreg` / `sysctl` / 内核日志 / 崩溃报告，
然后打包。每一步单独兜底，任何一步失败都不影响后面的步骤。

## 先看这两行

| 检查项 | 健康机器（RTX 3080 实测） | #185 机器 |
|---|---|---|
| `ioreg` 的 `nvrm-bars` | 含 `bar1@0x14:0x7c00000000+0x200000000` | **没有 `bar1@0x14`** |
| `debug.nvrmfb_vram_budget_bytes` | `4294967296`（4 GB） | `25165824`（24 MB） |

`bar1@0x14` 在不在，就是"真 BAR1 aperture 在不在"的唯一判据。

## 文件

| 文件 | 说明 |
|---|---|
| `nm185-diag.sh` | 取证脚本，bash 3.2 兼容（macOS 自带），无外部依赖 |
| `index.html` | 测试手册（网页版，含实验矩阵与判读表） |
| `RUNBOOK.md` | 同一份手册的 Markdown 版 |

## 许可证

MIT。与 NullMoth / NullMoth Systems 无关联，不代表其立场。
