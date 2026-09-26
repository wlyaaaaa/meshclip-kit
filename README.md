# MeshClip Kit

1. **这是什么：**让两台不同网络的 Windows 11 电脑通过 Tailscale 和 KDE Connect 共享文字剪贴板、互传文件；安卓平板仍是后续目标。
2. **我怎么用：**按 [Windows 安装说明](docs/WINDOWS.md)在两台电脑分别安装、指定对方并确认配对；日常双击 `MeshClip控制中心.vbs` 查看或暂停自动恢复。
3. **怎么知道它正常：**两端运行 `pwsh -File .\scripts\doctor.ps1 -Peer <对方设备名>`，再亲自双向复制文字、传文件并核对内容；诊断通过不能代替传输验收。
4. **坏了怎么提醒我：**控制中心显示运行和待恢复状态，但没有主动通知；发现异常直接跟 AI 说，先看 [排障说明](docs/TROUBLESHOOTING.md)。
5. **让 AI 做什么：**先读 [项目约定](AGENTS.md)、[产品边界](docs/PRODUCT.md)、[恢复与控制](docs/RECOVERY-AND-CONTROL.md)，帮我诊断和恢复，保留配对、其他设备设置及尚未验收的需求。

部署前还需读 [安全约定](SECURITY.md)；本仓库不传输剪贴板文字或文件。
