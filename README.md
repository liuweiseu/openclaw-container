# openclaw-vnc

一个带 VNC 桌面（xfce4 + Firefox）、装好 [openclaw](https://github.com/openclaw/openclaw)（CLI/Gateway）、GitHub CLI（`gh`）和 Claude Code CLI（`claude`）的 Ubuntu 26.04 容器镜像。容器 PID 1 是真正的系统级 `systemd`，`openclaw gateway install/start/stop/restart` 走标准 systemd 服务管理。

## 前置要求

- 一台 Linux 主机（本仓库基于 Ubuntu 开发验证，其它发行版原理相同）
- [Podman](https://podman.io/)，rootless 模式，建议 5.x（本仓库在 podman 5.7 上开发验证）
- 当前用户已经分配了 subuid/subgid 段位（现代发行版 `useradd` 时通常自动配置好；可用下面的命令确认）：

  ```bash
  grep "^$(whoami):" /etc/subuid /etc/subgid
  ```

  如果没有输出，需要先用 `sudo usermod --add-subuids 231072-296607 --add-subgids 231072-296607 $(whoami)` 之类的命令分配一段，然后重新登录。

## 快速开始

```bash
git clone <this-repo-url> openclaw-container
cd openclaw-container

# 1. 建三个运行时数据目录（仓库里没有带，见下面"目录说明"）
mkdir -p data openclaw_data openclaw_systemd_user

# 2. 修正属主：rootless podman 里容器内 node 用户(uid 1001)对应宿主机上的一个
#    subuid，不是宿主机当前用户，普通 chown 做不到，要用 podman unshare
podman unshare chown -R 1001:1001 data openclaw_data openclaw_systemd_user

# openclaw 自己有个安全检查，要求它的 systemd 服务目录不能是 group/other 可写
chmod 700 openclaw_systemd_user

# 3. 构建镜像（第一次会下载 Node.js / Firefox / npm 依赖，比较久）
podman build -t openclaw-vnc:ubuntu26.04 .

# 4. 启动容器 —— 必须带 --systemd=always，见下面"为什么必须 --systemd=always"
podman run -d \
  --name openclaw \
  --systemd=always \
  -p 5901:5901 \
  -p 18789:18789 \
  -v ./data:/mnt \
  -v ./openclaw_data:/home/node/.openclaw \
  -v ./openclaw_systemd_user:/home/node/.config/systemd/user \
  --restart unless-stopped \
  localhost/openclaw-vnc:ubuntu26.04
```

启动后确认一下状态：

```bash
podman ps -a --filter name=openclaw          # 应该是 Up
podman exec openclaw systemctl --failed      # 应该是 0 loaded units
```

## 连接桌面

用任意 VNC 客户端连 `<宿主机IP>:5901`，密码默认 `openclaw`（可以在 `podman run` 里加 `-e VNC_PASSWORD=你的密码` 覆盖，容器每次启动都会按这个环境变量重新生成密码文件）。

桌面是 xfce4（Greybird 主题 + elementary-xfce 图标），默认浏览器是 Firefox，装了中日韩字体，中文网页不会乱码。

## 首次配置 openclaw

镜像里只装好了 openclaw **软件本身**，不包含任何 agent / Discord 账号 / 网关鉴权之类的**配置**——那些东西本来就不该打进镜像（涉及 token 等密钥），是运行时状态，存在 `openclaw_data/` 和 `openclaw_systemd_user/` 这两个卷里。全新机器第一次跑起来，需要自己配置一遍：

```bash
# 以 node 身份进容器（容器默认 exec 用户是 root，因为 PID 1 必须是 root 的 systemd）
podman exec -it -u node -e HOME=/home/node -e XDG_RUNTIME_DIR=/run/user/1001 openclaw bash

# 进去之后：
openclaw configure          # 交互式配置模型/网关/鉴权
openclaw channels add       # 按提示添加 Discord/Telegram 等账号
openclaw agents add <id>    # 需要的话创建额外 agent
openclaw agents bind --agent <id> --bind discord:<accountId>   # 绑定路由

# 网关默认只监听 loopback，容器外连不到，需要改成 lan：
openclaw config set gateway.bind lan

# 把网关装成 systemd 服务（持久化到 openclaw_systemd_user 卷里，以后重建容器不用重装）
openclaw gateway install
```

想更方便地进容器，跑一下仓库自带的宿主机便利配置安装脚本（见下面"宿主机便利配置"一节），装好之后直接：

```bash
openclaw-shell
```

## 宿主机便利配置

`host-config/` 目录放的是跟容器本身无关、纯粹方便你在**宿主机**上操作的东西（目前是 `openclaw-shell` 这个 alias）。跑一次安装脚本就行，可重复运行，已经装过会自动跳过：

```bash
./host-config/install.sh
source ~/.bashrc   # 或者重新开一个终端
```

它做的事很简单：往 `~/.bash_aliases` 里追加一行 `source "<repo路径>/host-config/bash_aliases"`，不会覆盖你已有的内容。以后想加新的宿主机别名/函数，直接编辑 `host-config/bash_aliases` 就行，不用重新跑安装脚本。

## 常用操作

```bash
# 网关服务管理（以 node 身份，需要 XDG_RUNTIME_DIR）
openclaw gateway status
openclaw gateway start | stop --force | restart

# 看网关日志
systemctl --user status openclaw-gateway
journalctl --user -u openclaw-gateway -f

# 看桌面/VNC 那侧的日志
systemctl status openclaw-desktop
```

## 目录说明

| 路径（宿主机） | 挂载到容器内 | 内容 | 是否随仓库提供 |
| --- | --- | --- | --- |
| `data/` | `/mnt` | 你自己的工作区/项目文件，给 agent 用 | 否，需要自己建 |
| `openclaw_data/` | `/home/node/.openclaw` | openclaw 的全部状态：配置、会话、密钥、agent workspace | 否，需要自己建 |
| `openclaw_systemd_user/` | `/home/node/.config/systemd/user` | `openclaw gateway install` 生成的 systemd 服务单元 | 否，需要自己建 |

这三个目录都被 `.gitignore` 排除了（要么是大文件/私有数据，要么含密钥，要么是运行时生成的状态），换机器/重新 clone 之后需要重新执行"快速开始"里第 1、2 步。

## 默认账号密码（记得改）

| 用途 | 用户名 | 默认密码 | 怎么改 |
| --- | --- | --- | --- |
| VNC | - | `openclaw` | `podman run -e VNC_PASSWORD=xxx ...` |
| 容器内 Linux 账户（在 sudo 组） | `node` | `node` | 进容器后 `passwd node` |

这两个默认值是为了开箱即用设的，容器一旦暴露在公网/不受信网络上，务必先改掉。

## 为什么必须 `--systemd=always`

容器 PID 1 直接是系统级 `/lib/systemd/systemd`，`openclaw gateway install` 会主动探测系统级 `systemctl` 确认没有别的服务管理器占用同名单元（避免两个管理器互相打架），这个探测必须要有一个真正在跑的系统级 systemd 才能通过。不加 `--systemd=always`，podman 不会把 `/sys/fs/cgroup` 挂成读写，systemd 起不来，容器基本等于起不来。

## 疑难排查

- **`systemctl --failed` 里有东西 / 容器起不来**：先确认是不是忘了 `--systemd=always`。
- **容器里报 `EPERM` / `Permission denied`，尤其是操作 `~/.openclaw` 或 `/mnt` 下的文件**：rootless podman 的 UID 映射导致宿主机目录属主和容器内 node 用户对不上，用 `podman unshare chown -R 1001:1001 <宿主机目录>` 修（不能用普通 `chown`，宿主机上的你没权限改成别的 UID）。
- **`openclaw gateway install` 报 "unsafe-permissions"**：`~/.config/systemd/user`（即 `openclaw_systemd_user/`）权限太开放，`chmod 700 openclaw_systemd_user` 即可。
- **重建容器后网关"消失"了**：确认 `podman run` 里带了 `-v ./openclaw_systemd_user:/home/node/.config/systemd/user`，这个服务单元文件不在 `~/.openclaw` 里，漏挂这一条就会丢。
