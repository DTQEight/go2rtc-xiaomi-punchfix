# go2rtc — 小米 MISS “read punch” 修复

[English](README.md) | **简体中文**

针对小米摄像头（如 `chuangmi.camera.81ac1` / 小米 C700）在 [go2rtc](https://github.com/AlexxIT/go2rtc)
里始终无法出流、日志报下面错误的问题：

```
WRN [rtsp] error="streams: miss: read punch: read udp [::]:PORT: i/o timeout" stream=camera1
```

## 根因

部分小米摄像头固件在回复 MISS 的 LAN search 包（`0x30`）时，会把**源 IP 写成网关地址**，而不是
摄像头自己的 IP。在 go2rtc 主机上抓包如下：

| 方向 | 源 MAC | 源 IP:端口 | 目的 IP:端口 | 载荷 |
|---|---|---|---|---|
| 主机 → 摄像头 | 主机 MAC | 192.168.1.10:50554 | 192.168.1.50:32108 | `f1 30 00 00` |
| 摄像头 → 主机 | **摄像头 MAC**，TTL 64 | **192.168.1.1**:11237 | 192.168.1.10:50554 | `f1 41 ...` |

源 MAC 和 TTL 都说明这个包确实是摄像头发的，但源 IP 被填成了路由器/网关。

而 `pkg/xiaomi/miss/client.go` 的 `writeAndWait()` 会丢弃所有源 IP 与摄像头 IP 不一致的包：

```go
if string(addr.IP) != string(c.addr.IP) {
    continue // skip messages from another IP
}
```

于是 punch 回包被丢掉，握手永远完不成，最终超时。**v1.9.13 和 v1.9.14 都有这段判断，所以升降级都没有用。**

另一个细节：从同一 AP 下的 Wi-Fi 客户端发包时，摄像头回的源 IP 是它自己的，一切正常；只有部分路径
（我们这里是**有线主机**）会触发“源 IP 变成网关”的回包。

## 补丁

只对 punch 回包放宽源 IP 校验，其余逻辑完全不动：

```diff
-		if string(addr.IP) != string(c.addr.IP) {
+		if string(addr.IP) != string(c.addr.IP) && waitMsg != msgPunchPkt {
 			continue // skip messages from another IP
 		}
```

收到回包后只从中学习端口，`c.addr.IP` 仍然是摄像头真实地址，后续所有包直接发往摄像头。

补丁文件：[punch.patch](punch.patch)，适用于 go2rtc `v1.9.13`，向前移植（新版本）也很简单。

## 构建

### 方式 A — `build.sh`（不需要访问 Docker Hub）

依赖：`bash`、`curl`、`patch`、`docker`，并且需要 **root 权限**（或用户在 `docker` 组里）。

```bash
sudo ./build.sh
```

脚本会：下载 go2rtc `v1.9.13` 源码 → 应用 `punch.patch` → 从 `golang.google.cn` 下载 Go 工具链 →
静态编译 → 基于 `ghcr.io/alexxit/go2rtc:1.9.13` 生成镜像 `go2rtc:1.9.13-punchfix`。

可用环境变量：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `GO2RTC_VERSION` | `v1.9.13` | 要构建的 go2rtc tag |
| `GO_VERSION` | `1.24.0` | Go 工具链版本 |
| `IMAGE` | `go2rtc:<ver>-punchfix` | 输出镜像 tag |
| `COMPOSE_FILE` | 无 | 如果设置，构建完后执行 `docker compose -f $COMPOSE_FILE up -d` |

### 方式 B — Dockerfile

```bash
git clone --branch v1.9.13 https://github.com/AlexxIT/go2rtc src
cp punch.patch src/ && (cd src && patch -p1 < punch.patch)
docker build -t go2rtc:1.9.13-punchfix src
```

Dockerfile 的构建阶段使用 `golang:1.24-alpine`，所以这条路径需要能访问 Docker Hub。

## 使用

参考 [docker-compose.example.yml](docker-compose.example.yml)：

```yaml
services:
  go2rtc:
    image: go2rtc:1.9.13-punchfix
    pull_policy: never
    network_mode: host
    volumes:
      - ./config:/config
```

## 注意事项

- go2rtc 配置里的摄像头 IP 必须是真实 IP（补丁对任何 IP 都适用）。
- C700 输出的是 H.265（HEVC），浏览器 WebRTC（Chrome）不支持，需要转码：
  `ffmpeg:camera1#video=h264#width=1920`，或者改用支持 H.265 的客户端。
- 上游 issue：[AlexxIT/go2rtc#2048](https://github.com/AlexxIT/go2rtc/issues/2048)
- 测试环境：go2rtc `v1.9.13` + `chuangmi.camera.81ac1`（小米 C700），Debian NAS + Docker。

## 许可证

MIT，见 [LICENSE](LICENSE)。补丁作用于 [go2rtc](https://github.com/AlexxIT/go2rtc)（MIT 协议）。
