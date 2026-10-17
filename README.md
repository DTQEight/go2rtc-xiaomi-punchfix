# go2rtc — Xiaomi MISS "read punch" fix

**English** | [简体中文](README.zh-CN.md)

Patch for Xiaomi cameras (e.g. `chuangmi.camera.81ac1` / Xiaomi C700) that never start
streaming in [go2rtc](https://github.com/AlexxIT/go2rtc) and log:

```
WRN [rtsp] error="streams: miss: read punch: read udp [::]:PORT: i/o timeout" stream=camera1
```

## Root cause

Some Xiaomi camera firmwares answer the MISS LAN-search packet (`0x30`) with the **gateway
IP as the source address** instead of their own IP. Packet capture on the go2rtc host:

| direction | src MAC | src IP:port | dst IP:port | payload |
|---|---|---|---|---|
| host → camera | host MAC | 192.168.1.10:50554 | 192.168.1.50:32108 | `f1 30 00 00` |
| camera → host | **camera MAC**, TTL 64 | **192.168.1.1**:11237 | 192.168.1.10:50554 | `f1 41 ...` |

The source MAC and TTL show the frame is sent by the camera itself, but the source IP is the
router/gateway. `pkg/xiaomi/miss/client.go` (`writeAndWait`) rejects every packet whose source
IP differs from the configured camera IP:

```go
if string(addr.IP) != string(c.addr.IP) {
    continue // skip messages from another IP
}
```

The punch reply is dropped, the handshake never completes and the stream times out.
Both v1.9.13 and v1.9.14 contain this check, so downgrading or upgrading does not help.

Interesting detail: from a Wi-Fi client on the same AP the camera replies with its own IP and
everything works — only some paths (in our case a wired host) trigger the gateway-spoofed reply.

## Patch

Relax the source-IP check **only** for the punch reply; everything else stays untouched:

```diff
-		if string(addr.IP) != string(c.addr.IP) {
+		if string(addr.IP) != string(c.addr.IP) && waitMsg != msgPunchPkt {
 			continue // skip messages from another IP
 		}
```

Only the port is learned from the reply; `c.addr.IP` remains the real camera address, so all
subsequent packets are sent directly to the camera.

Patch file: [punch.patch](punch.patch) — applies to go2rtc `v1.9.13`, forward-ports trivially.

## Build

### Option A — `build.sh` (no Docker Hub required)

Requirements: `bash`, `curl`, `patch`, `docker` — run as root or as a user in the `docker` group
(e.g. `sudo ./build.sh`).

```bash
sudo ./build.sh
```

It downloads go2rtc `v1.9.13`, applies `punch.patch`, downloads a Go toolchain from
`golang.google.cn`, builds a static binary and produces the image `go2rtc:1.9.13-punchfix`
based on `ghcr.io/alexxit/go2rtc:1.9.13`.

Environment variables:

| variable | default | meaning |
|---|---|---|
| `GO2RTC_VERSION` | `v1.9.13` | go2rtc tag to build |
| `GO_VERSION` | `1.24.0` | Go toolchain version |
| `IMAGE` | `go2rtc:<ver>-punchfix` | output image tag |
| `COMPOSE_FILE` | – | if set, `docker compose -f $COMPOSE_FILE up -d` at the end |

### Option B — Dockerfile

```bash
git clone --branch v1.9.13 https://github.com/AlexxIT/go2rtc src
cp punch.patch src/ && (cd src && patch -p1 < punch.patch)
docker build -t go2rtc:1.9.13-punchfix src
```

The Dockerfile uses `golang:1.24-alpine` for the build stage, so it needs Docker Hub access.

## Use

See [docker-compose.example.yml](docker-compose.example.yml):

```yaml
services:
  go2rtc:
    image: go2rtc:1.9.13-punchfix
    pull_policy: never
    network_mode: host
    volumes:
      - ./config:/config
```

## Notes

- The camera IP in the go2rtc config must be the real camera IP (the patch works with any).
- H.265 cameras (C700 outputs HEVC) still need transcoding for browser WebRTC:
  `ffmpeg:camera1#video=h264#width=1920`.
- Upstream issue: [AlexxIT/go2rtc#2048](https://github.com/AlexxIT/go2rtc/issues/2048)
- Tested with go2rtc `v1.9.13` and `chuangmi.camera.81ac1` (Xiaomi C700).

## 中文摘要

小米摄像头（如 C700，`chuangmi.camera.81ac1`）对 LAN search 的 `0x41` 回包会把**源 IP 写成网关**
而不是摄像头自己，go2rtc 的 `miss` 客户端只接受“源 IP == 摄像头 IP”的包，于是回包被丢弃、
握手超时（`read punch: i/o timeout`）。1.9.13 / 1.9.14 都有这段校验，所以升降级无效。

补丁只对 punch 阶段放宽源 IP 校验，收到回包后仍向摄像头真实地址发包。

完整中文说明见 **[README.zh-CN.md](README.zh-CN.md)**。

## License

MIT — see [LICENSE](LICENSE). The patch targets [go2rtc](https://github.com/AlexxIT/go2rtc), MIT licensed.
