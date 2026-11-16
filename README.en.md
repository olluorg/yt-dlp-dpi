# YouTube Downloader (Docker + zapret2)

A Docker-based tool for reliably downloading YouTube videos and audio from networks with DPI censorship (such as Russia) without third-party VPNs.

Powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [bol-van/zapret2](https://github.com/bol-van/zapret2) (`nfqws2`) with dynamic Lua packet desynchronization.

[Русская версия →](README.md)

## Usage

### Web UI

```bash
docker compose up -d
```

Open in browser: `http://localhost:8080`

### Command Line

```bash
# Download video (MP4)
docker run --rm --cap-add=NET_ADMIN -v "${PWD}/downloads:/downloads" ghcr.io/olluorg/yt-dlp-dpi:latest "https://youtu.be/aqz-KE-bpKQ"

# Download audio (MP3)
docker run --rm --cap-add=NET_ADMIN -v "${PWD}/downloads:/downloads" -e YT_DLP_OPTS="-x --audio-format mp3" ghcr.io/olluorg/yt-dlp-dpi:latest "https://youtu.be/aqz-KE-bpKQ"
```

Files are saved to `./downloads/`.

## Pre-built image

```bash
docker pull ghcr.io/olluorg/yt-dlp-dpi:latest
```

## Requirements

- Docker
- `--cap-add=NET_ADMIN` (or `--privileged`) for Linux kernel NFQUEUE manipulation.
