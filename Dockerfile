# syntax=docker/dockerfile:1
FROM ubuntu:26.04

LABEL description="openclaw + VNC(xfce4) + Firefox 桌面环境"

ARG TARGETARCH
ARG OPENCLAW_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    NPM_CONFIG_LOGLEVEL=warn

# ---------------------------------------------------------------------------
# 基础系统依赖 + openclaw 原生模块编译所需的工具链 (build-essential/python3 用于
# node-pty / koffi 等原生依赖)，并确保 universe/multiverse 组件已启用
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg xz-utils git sudo \
        software-properties-common locales tzdata procps \
        python3 pkg-config build-essential \
    && add-apt-repository -y universe \
    && add-apt-repository -y multiverse \
    && apt-get update \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# VNC 服务器 + xfce4 桌面环境
# fonts-noto-cjk 修复中文页面在 Firefox 里显示乱码（缺中文字体导致方框/乱码）；
# greybird-gtk-theme + elementary-xfce-icon-theme 是 Xubuntu 系桌面的经典配色/
# 图标，裸装 xfce4 metapackage 默认只有 Adwaita 主题，视觉上和常见 xfce4 差异很大；
# xdg-utils + desktop-file-utils 用于注册系统级默认浏览器 (mimeapps.list)；
# dbus-user-session + systemd/systemd-sysv/dbus/libpam-systemd：容器 PID 1 直接跑
# 真正的系统级 systemd（见文件末尾 CMD），配合 logind + node 的 linger 标记，
# 让 node 拥有一个由 logind 正常管理的用户态 systemd 实例，`systemctl --user` /
# `openclaw gateway install|start|stop|restart` 才能通过它自带的"系统级 systemd
# 占用检测"（它会主动探测系统级 systemctl，探测失败就拒绝安装，见后面 openclaw-
# desktop.service 相关说明）；gh 是 GitHub CLI
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        tigervnc-standalone-server tigervnc-common openssl \
        xfce4 xfce4-terminal xfce4-session dbus-x11 dbus-user-session x11-apps xauth \
        fonts-liberation fonts-noto-color-emoji fonts-noto-cjk \
        greybird-gtk-theme elementary-xfce-icon-theme \
        xdg-utils desktop-file-utils gh \
        systemd systemd-sysv dbus libpam-systemd \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Firefox：Ubuntu 官方仓库中的 firefox 为 snap 转接包，容器内没有 snapd，
# 因此改为直接使用 Mozilla 官方 tar.xz 包，安装到 /opt/firefox
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgtk-3-0 libdbus-glib-1-2 libxt6 libx11-xcb1 libasound2t64 libpci3 \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/firefox.tar.xz \
        "https://download.mozilla.org/?product=firefox-latest&os=linux64&lang=zh-CN" \
    && tar -xJf /tmp/firefox.tar.xz -C /opt \
    && ln -s /opt/firefox/firefox /usr/local/bin/firefox \
    && rm -f /tmp/firefox.tar.xz

# 手动装的 Firefox 没有走 apt，系统不知道它是"浏览器"：注册标准 .desktop
# 条目 + x-www-browser alternative + mimeapps.list 默认关联，xdg-open/GIO/
# 面板菜单等各种"打开链接"路径才会统一指向它，而不是各自回退到别的行为
COPY scripts/firefox.desktop /usr/share/applications/firefox.desktop
COPY scripts/mimeapps.list /etc/xdg/mimeapps.list
RUN update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/firefox 200 \
    && update-alternatives --set x-www-browser /usr/local/bin/firefox \
    && update-desktop-database /usr/share/applications

# ---------------------------------------------------------------------------
# Node.js：直接使用官方二进制包，避免 NodeSource 脚本无法识别新发行版代号的问题。
# openclaw 要求 engines.node: ">=24.16.0 <25 || >=26.1.0"，这里安装最新的 Node 24.x
# ---------------------------------------------------------------------------
RUN case "${TARGETARCH:-amd64}" in \
        amd64) NODE_ARCH=x64 ;; \
        arm64) NODE_ARCH=arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt \
        | grep -o "node-v[0-9.]*-linux-${NODE_ARCH}.tar.xz" | head -n1 \
        | sed -E "s/node-v([0-9.]+)-linux-${NODE_ARCH}\.tar\.xz/\1/") \
    && curl -fsSL -o /tmp/node.tar.xz \
        "https://nodejs.org/dist/latest-v24.x/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.xz \
    && node -v && npm -v

# ---------------------------------------------------------------------------
# 安装最新版 openclaw（npm install 会一并解析并安装其全部依赖）+ Claude Code CLI
# ---------------------------------------------------------------------------
RUN npm install -g \
        --allow-scripts=openclaw,@google/genai,koffi,tree-sitter-bash,protobufjs,@anthropic-ai/claude-code \
        "openclaw@${OPENCLAW_VERSION}" \
        @anthropic-ai/claude-code \
    && npm cache clean --force

# ---------------------------------------------------------------------------
# 创建 node 账户，并准备其 .openclaw 与 tigervnc 配置目录。
# 注意：这里装的 tigervnc (1.15+) 已经把状态目录从旧版的 ~/.vnc 迁移到
# ~/.config/tigervnc；直接在这个新路径下创建，避免触发它自带的、在没有
# ~/.config 时会失败的旧目录迁移逻辑。
# ---------------------------------------------------------------------------
RUN useradd --create-home --shell /bin/bash --groups sudo node \
    && echo 'node:node' | chpasswd \
    && mkdir -p /home/node/.openclaw /home/node/.config/tigervnc \
        /home/node/.config/xfce4/xfconf/xfce-perchannel-xml \
    && chmod 700 /home/node/.openclaw \
    && sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /home/node/.bashrc

COPY --chown=node:node scripts/xstartup /home/node/.config/tigervnc/xstartup
COPY --chown=node:node scripts/runvnc /usr/local/bin/runvnc
# 预置 Greybird + elementary-xfce 主题，替换掉裸装 xfce4 的默认 Adwaita 观感
COPY --chown=node:node scripts/xsettings.xml /home/node/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml

RUN chmod 755 /home/node/.config/tigervnc/xstartup /usr/local/bin/runvnc \
    && chown -R node:node /home/node

# ---------------------------------------------------------------------------
# 容器 PID 1 直接跑系统级 systemd（见文件末尾 CMD），VNC/xfce4 桌面做成一个
# 普通的 systemd system unit（User=node），随系统自动启动；
# 给 node 打上 linger 标记，让 logind 在系统启动时就给它起一个正经的、被
# logind 正常管理/委托 cgroup 的用户态 systemd 实例（不再需要手工 chown
# /sys/fs/cgroup 或手工起 systemd --user 那些补丁）——这也是 openclaw gateway
# install 探测系统级 systemd 时不再被拒绝的关键：探测目标从"没有系统级
# systemd" 变成了"有，而且这个 unit 名确实不存在"。
# 顺手屏蔽几个在容器里必然起不来/没意义的单元，避免 `systemctl --failed` 里一堆
# 噪音（没有真实硬件/tty/内核热插拔事件可管）。
# ---------------------------------------------------------------------------
COPY scripts/openclaw-desktop.service /etc/systemd/system/openclaw-desktop.service
RUN mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/node \
    && systemctl enable openclaw-desktop.service \
    && systemctl mask \
        systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
        getty.target getty-static.service console-getty.service \
        systemd-firstboot.service systemd-machine-id-commit.service \
        systemd-remount-fs.service polkit.service

ENV VNC_PASSWORD=openclaw \
    VNC_RESOLUTION=1280x800 \
    VNC_COL_DEPTH=24 \
    DISPLAY=:1

# VNC 端口 (display :1 -> 5901)；18789 预留给 openclaw 网关服务，与 compose.yml 对应
EXPOSE 5901 18789

WORKDIR /home/node

# 容器 PID 1 就是系统级 systemd 本身（标准的 "systemd in a container" 用法，
# podman --systemd=always 就是为这种场景设计的）。所有实际工作（VNC 桌面、
# node 的用户态 systemd、以后 openclaw gateway 的服务）都由它拉起来的各个
# unit 承担，不再需要我们自己的 root 入口脚本。
# STOPSIGNAL 改成 SIGRTMIN+3：这是 systemd 期望收到的关机信号，`podman stop`
# 默认发 SIGTERM，systemd-as-PID1 不认，会导致每次都要等到超时才被强杀。
# 必须用 `podman run --systemd=always ...` 启动，否则 /sys/fs/cgroup 是只读的，
# systemd 拿不到 cgroup 委托，整个都起不来。
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
