# 本机 ComfyUI 运维说明（非仓库内容，仅本机使用）

这个文件不是 ComfyUI 官方仓库的一部分，记录本机部署相关的服务启停方式。详细背景/历史决策见 `/mnt/data/minimax-h3/handoff.md`。

## 服务管理

服务名：`comfyui.service`（systemd **--user** 单元，不是系统级 root 服务）

```bash
systemctl --user status comfyui.service    # 查看状态
systemctl --user start comfyui.service     # 启动
systemctl --user stop comfyui.service      # 停止（会释放 ComfyUI 占用的显存）
systemctl --user restart comfyui.service   # 重启（改完 start_comfyui.sh 后用这个生效）
journalctl --user -u comfyui.service -f    # 服务的标准输出（启动日志、报错栈）
```

应用日志：

```bash
tail -f /mnt/data/ComfyUI/user/comfyui.log
```

> 服务运行时不要再手动执行 `start_comfyui.sh`，否则会因为 8189 端口被占用而启动失败。需要前台调试时，先执行 `systemctl --user stop comfyui.service`。

### 单元文件

位置：`~/.config/systemd/user/comfyui.service`。它不在仓库里，**重装系统后需要按下面的内容重建**（2026-09-15 创建）：

```ini
[Unit]
Description=ComfyUI (/mnt/data/ComfyUI, port 8189)
Documentation=file:///mnt/data/ComfyUI/README.local.md

[Service]
Type=simple
# 启动参数（含模型库路径 --models-directory）只在脚本里维护，这里不重复定义
ExecStart=/mnt/data/ComfyUI/start_comfyui.sh
# user 级服务无法依赖系统的挂载单元：开机时数据盘若还没挂好，脚本会失败退出，由这里自动重试
Restart=on-failure
RestartSec=30
# 给正在执行的任务一点时间收尾，超时后强制结束
TimeoutStopSec=60

[Install]
WantedBy=default.target
```

重建步骤（不需要 sudo）：

```bash
mkdir -p ~/.config/systemd/user
# 把上面的内容写入 ~/.config/systemd/user/comfyui.service
systemctl --user daemon-reload
systemctl --user enable --now comfyui.service
loginctl enable-linger "$USER"
```

- `Restart=on-failure`：进程异常退出（崩溃、被强制结束、开机时数据盘没挂好导致脚本失败）30 秒后自动重启。用 `systemctl --user stop` 正常停止时不会重启。2026-09-15 实测：`kill -9` 主进程后自动恢复。
- 服务默认的 PATH 是 `/usr/local/bin:/usr/bin:/bin…`，Manager 需要的 `git`（`/usr/bin`）和 `uv`（`.venv/bin/uv`）都能找到，不需要额外配置环境变量。

## 开机自启

已启用（2026-09-15 重装系统后重新配置）：

```bash
systemctl --user is-enabled comfyui.service   # 应显示 enabled
loginctl show-user "$USER" --property=Linger  # 应显示 Linger=yes
```

`loginctl enable-linger` 是关键一步——没有它的话，user 级 systemd 服务只有在用户登录（桌面或 SSH 会话）后才会启动；开了 linger 之后，哪怕没人登录，主机开机/重启后这个服务也会自动拉起。

## 启动参数从哪来

`comfyui.service` 的 `ExecStart` **只调用**这个脚本，不重复定义参数：

```
/mnt/data/ComfyUI/start_comfyui.sh
```

**这个脚本是启动参数的唯一来源**（局域网监听 `--listen 0.0.0.0`、性能调优 `--disable-comfy-compiler`、`PYTORCH_CUDA_ALLOC_CONF` 等都在里面）。它用 `exec` 直接把自己替换成 ComfyUI 进程，所以：

- **手动兜底启动**：systemd 有问题时可以直接跑 `bash /mnt/data/ComfyUI/start_comfyui.sh`（前台运行，Ctrl+C 停止），效果和走 systemd 完全一致，用的是同一份参数。
- **改参数**：改这个脚本，然后 `systemctl --user restart comfyui.service` 生效。一般不需要改 systemd unit 文件本身（`~/.config/systemd/user/comfyui.service`）。

## 局域网访问

监听 `0.0.0.0:8189`，同网段设备可通过主机 IP 访问，例如 `http://192.168.99.123:8189`（IP 可能变化，以实际为准）。

## 和 ollama 共用显存

本机的 ollama 服务（说明见 `/mnt/data/ollama/README.md`）和 ComfyUI 共用这块 24G 显存。跑 H3 这类大模型前，先执行 `ollama ps` 确认 ollama 没有加载模型，有的话用 `ollama stop <模型名>` 卸载。

## 模型路径

主模型库：`/mnt/data/ai_models/comfy`，由 `start_comfyui.sh` 的 `--models-directory` 参数指定（2026-09 迁移）。

- 不用软链接替换 `ComfyUI/models`：该目录下的占位文件受 git 管理，换成软链接后，官方一旦更新 `models/`，`git merge upstream/master` 就会中止。
- 不用 `extra_model_paths.yaml` 做主目录：它只追加搜索路径，写死使用 `folder_paths.models_dir` 的插件读不到。
- `extra_model_paths.yaml`（本地文件，已被 .gitignore 忽略）只用来追加额外的模型目录，里面有说明和示例。
- 仓库自带的 `ComfyUI/models/` 保留原样，不存放模型。

## Python 环境与依赖

- 虚拟环境 `.venv` 由 uv 创建，解释器是仓库内的 `.uv-python/cpython-3.12.13`，**整个环境都在数据盘上，不依赖系统 Python**，重装系统后可以直接使用。
- 2026-09-15 重装系统后检查：torch 2.14.0+cu130 能正常识别并使用 RTX 3090 Ti；`requirements.txt`、`manager_requirements.txt`、KJNodes 的依赖都满足。
- MiniMaxH3_Director 缺少的依赖已补装（音频提取、分段导出 mp4、智能分镜功能要用）：
  - `imageio-ffmpeg 0.6.0`：自带 ffmpeg 程序，系统里没有装 ffmpeg 也能用
  - `platformdirs`
  - `scenedetect 0.7.1`：**用 `--no-deps` 安装**。它的依赖声明要求 `opencv-python`（桌面版），和已装的 `opencv-python-headless` 都提供 `cv2`，装在一起会互相覆盖文件；而 0.6.x 版本又会把 `click` 从 8.5 降到 8.2（huggingface-hub 在用）
  - 所以 `uv pip check` 会报一条 "scenedetect requires opencv-python"，这是预期的，功能正常
- 检查依赖的方法：`uv pip check --python .venv/bin/python`，再加上对照 `requirements.txt` 和各插件目录下的 `requirements.txt`。

## Git 远程仓库

```bash
git remote -v
# origin    https://github.com/syfly007/ComfyUI.git   （自己的 fork，日常 push/pull 用这个）
# upstream  https://github.com/Comfy-Org/ComfyUI.git  （官方原项目，只用来同步更新，不直接 push）
```

### 从官方源（upstream）同步更新到本地

```bash
cd /mnt/data/ComfyUI
git status                      # 先确认工作区干净，没有未提交的改动
git fetch upstream
git merge upstream/master       # 不要用 git reset --hard / git clean，会清掉本地未跟踪的配置和文件
```

如果只想看看有什么更新、还不想合并：

```bash
git log HEAD..upstream/master --oneline
```

合并完确认没问题（`extra_model_paths.yaml`、`start_comfyui.sh`、`README.local.md` 这些本地文件不受影响，因为官方仓库里没有同名文件，正常不会冲突），再推回自己的 fork：

```bash
git push origin master
```

### 日常提交本地改动（脚本、说明文档等）

```bash
git add start_comfyui.sh README.local.md
git commit -m "说明改了什么"
git push origin master
```
