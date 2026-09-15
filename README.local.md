# 本机 ComfyUI 运维说明（非仓库内容，仅本机使用）

这个文件不是 ComfyUI 官方仓库的一部分，记录本机部署相关的服务启停方式。详细背景/历史决策见 `/mnt/data/minimax-h3/handoff.md`。

## 服务管理

服务名：`comfyui.service`（systemd **--user** 单元，不是系统级 root 服务）

```bash
systemctl --user status comfyui.service    # 查看状态
systemctl --user start comfyui.service     # 启动
systemctl --user stop comfyui.service      # 停止
systemctl --user restart comfyui.service   # 重启（改完 start_comfyui.sh 后用这个生效）
journalctl --user -u comfyui.service       # 查看 systemd 层日志（一般用不上，见下面的应用日志）
```

应用日志：

```bash
tail -f /mnt/data/ComfyUI/comfyui.log
```

## 开机自启

已启用：

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

## 模型路径

主模型库：`/mnt/data/ai_models/comfy`，由 `start_comfyui.sh` 的 `--models-directory` 参数指定（2026-09 迁移）。

- 不用软链接替换 `ComfyUI/models`：该目录下的占位文件受 git 管理，换成软链接后，官方一旦更新 `models/`，`git merge upstream/master` 就会中止。
- 不用 `extra_model_paths.yaml` 做主目录：它只追加搜索路径，写死使用 `folder_paths.models_dir` 的插件读不到。
- `extra_model_paths.yaml`（本地文件，已被 .gitignore 忽略）只用来追加额外的模型目录，里面有说明和示例。
- 仓库自带的 `ComfyUI/models/` 保留原样，不存放模型。

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
