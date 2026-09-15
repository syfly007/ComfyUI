# 本机 ComfyUI 运维说明（非仓库内容，仅本机使用）

这个文件不是 ComfyUI 官方仓库的一部分，记录本机部署相关的服务启停方式。详细背景/历史决策见 `/mnt/data/minimax-h3/handoff.md`。

## 服务管理

服务名：`comfyui.service`，**系统级** systemd 单元，以 `syfly007` 用户运行（2026-09-15 由 user 级改为系统级，原因见下方"为什么是系统级服务"）。

> 2026-09-15 16:53 已完成切换并验证：服务运行在 `/system.slice/comfyui.service`，运行用户是 syfly007，oomd 的监控列表里已经没有它。旧的 user 级单元文件保留为 `~/.config/systemd/user/comfyui.service.disabled-20260915165341`。

```bash
systemctl status comfyui.service           # 查看状态
sudo systemctl start comfyui.service       # 启动
sudo systemctl stop comfyui.service        # 停止（会释放 ComfyUI 占用的显存）
sudo systemctl restart comfyui.service     # 重启（改完 start_comfyui.sh 后用这个生效）
journalctl -u comfyui.service -f           # 服务的标准输出（启动日志、报错栈）
```

应用日志：

```bash
tail -f /mnt/data/ComfyUI/user/comfyui.log
```

> 服务运行时不要再手动执行 `start_comfyui.sh`，否则会因为 8189 端口被占用而启动失败。需要前台调试时，先执行 `sudo systemctl stop comfyui.service`。

### 单元文件与安装

| 文件 | 说明 |
|---|---|
| `/mnt/data/ComfyUI/comfyui.service` | **单元源文件，受 git 管理**。要改服务配置就改这份 |
| `/mnt/data/ComfyUI/install_comfyui_service.sh` | 安装 / 更新脚本 |
| `/etc/systemd/system/comfyui.service` | 部署后的副本，由安装脚本复制过去，**不要直接改** |

```bash
sudo bash /mnt/data/ComfyUI/install_comfyui_service.sh
```

安装脚本会依次：
1. **检查任务队列**：有任务在运行或排队、或者队列解析失败时，直接退出，不做任何改动（安装必然会重启 ComfyUI）。
2. 如果还有旧的 user 级服务：停止并取消自启，单元文件改名为 `.disabled-<时间戳>`。
3. 把源文件安装到 `/etc/systemd/system/`（内容有变化时先备份旧文件），`verify` → `daemon-reload` → `enable` → `restart`。
4. 等待 HTTP 就绪，输出状态、开机自启、运行用户、HTTP 状态码。

重装系统后也用这条命令恢复服务。修改了 `comfyui.service` 源文件后，同样重新执行这条命令。

- `Restart=on-failure`：进程异常退出（崩溃、被强制结束、开机时数据盘没挂好导致脚本失败）30 秒后自动重启；`systemctl stop` 正常停止时不会重启。
- `RequiresMountsFor=/mnt/data/ComfyUI /mnt/data/ai_models/comfy`：等数据盘挂载后再启动。
- 系统服务默认的 PATH 是 `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`，Manager 需要的 `git`（`/usr/bin`）和 `uv`（`.venv/bin/uv`）都能找到。
- `/dev/nvidia*` 权限为 666，以 syfly007 运行可以正常使用 GPU。

### 为什么是系统级服务

- Ubuntu 默认启用 systemd-oomd，它会监控 `user@1000.service`（该用户的所有 user 级服务和桌面程序）：**内存压力 > 50% 持续 20 秒就结束其中占内存最多的进程**。2026-09-15 H3 工作流就这样被结束过，见"故障记录"。
- 系统级服务运行在 `system.slice` 下，**不在 oomd 的监控范围内**，只受内核 OOM 兜底（内存真正耗尽时才结束进程）。ollama 也是系统级服务，两者管理方式一致。
- oomd 仍然保护桌面和其他 user 级程序，不需要关闭它，也不需要改系统默认阈值。
- 确认 oomd 的监控范围：`oomctl`，"Memory Pressure Monitored CGroups" 下不应出现 `comfyui.service`。

### 回滚到 user 级服务

```bash
sudo systemctl disable --now comfyui.service
sudo rm /etc/systemd/system/comfyui.service && sudo systemctl daemon-reload
mv ~/.config/systemd/user/comfyui.service.disabled-<时间戳> ~/.config/systemd/user/comfyui.service
systemctl --user daemon-reload && systemctl --user enable --now comfyui.service
```

## 开机自启

```bash
systemctl is-enabled comfyui.service          # 应显示 enabled（系统级服务开机即启动，不需要登录，也不需要 linger）
```

- 以前 user 级服务依赖 `loginctl enable-linger`（2026-09-15 开启过，`Linger=yes`）。换成系统级服务后已经不需要了，保留也没有影响。要关闭的话：`loginctl disable-linger syfly007`。

## 启动参数从哪来

`comfyui.service` 的 `ExecStart` **只调用**这个脚本，不重复定义参数：

```
/mnt/data/ComfyUI/start_comfyui.sh
```

**这个脚本是启动参数的唯一来源**（局域网监听 `--listen 0.0.0.0`、性能调优 `--disable-comfy-compiler`、`PYTORCH_CUDA_ALLOC_CONF` 等都在里面）。它用 `exec` 直接把自己替换成 ComfyUI 进程，所以：

- **手动兜底启动**：systemd 有问题时可以直接跑 `bash /mnt/data/ComfyUI/start_comfyui.sh`（前台运行，Ctrl+C 停止），效果和走 systemd 完全一致，用的是同一份参数。
- **改参数**：改这个脚本，然后 `sudo systemctl restart comfyui.service` 生效。一般不需要改单元文件；真要改的话，改 `/mnt/data/ComfyUI/comfyui.service`，再执行安装脚本。

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

## 故障记录

### 2026-09-15 H3 工作流跑到采样阶段进程被杀、服务自动重启

- **现象**：`minimax_h3_director_加速版_优化` 文生视频刚开始采样，ComfyUI 就突然消失，服务 30 秒后自动重启；htop 里多个核跑满。重装系统前在 20G 内存的虚拟机里能正常跑完。
- **是谁结束的进程**：操作系统里的 **systemd-oomd**，不是 ComfyUI 自己崩溃。
  - `journalctl -u systemd-oomd`：`Killed .../comfyui.service due to memory pressure ... being 85.51% > 50.00% for > 20s`
  - `journalctl --user -u comfyui.service`：`code=killed, status=9/KILL`，`Failed with result 'oom-kill'`
  - 内核日志里没有 OOM 记录，swap 只用了 0.5G：内存并没有真正耗尽，而是一直在回收，被判定为卡死
  - Ubuntu 默认给 `user@.service` 设置了 `ManagedOOMMemoryPressure=kill`，阈值 50%、持续 20 秒（`/usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf`）
- **根因**：ComfyUI 的锁页内存上限公式 `comfy/model_management.py:1604`：
  `max(ram*0.4, min(ram*0.9, ram-4G, ram+swap-16G))`
  - 本机 30G 内存 + 重装系统时自动创建的 16G `/swap.img` → 上限 **26G**（日志 `Enabled pinned memory 26661`）
  - 20G 内存、没有 swap 的虚拟机 → 上限只有 8G
  - 锁页内存不能回收。H3 要准备约 35G 模型（文本编码器 14956MB + 主模型 19995MB），通过 mmap 从**机械盘**读取，页缓存被挤到只剩几 G，系统只能不停地换出、再读回
- **与上游代码无关**：`git fetch upstream` 拉下来的 32 个提交没有合并，运行的代码和 9 月 10 日一样。
- **处理**：`start_comfyui.sh` 加 `--disable-pinned-memory`。
- **验证（同一工作流、同样参数）**：
  - 用户 cgroup 的内存压力（PSI）全程 0.00；可用内存始终在 23.7G 以上；页缓存最多 24.7G（可回收）
  - 采样 20 步用时 1:26（4.30s/it），整个工作流 415 秒完成，没有被结束，服务没有重启
- **以后如果还遇到类似问题**：先看 `journalctl -u systemd-oomd --since today | grep Killed`，确认是不是 oomd 结束的；再看启动日志里的 `Enabled pinned memory`，确认锁页内存有没有被重新打开。

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
