#!/usr/bin/env python3
"""
HTTP-сервер для скачивания видео через zapret DPI bypass с автоподбором стратегии.

GET /                                        → HTML-форма
GET /info?url=<URL>                          → JSON с метаданными видео
GET /search?query=<query>                    → JSON с первым результатом поиска
GET /download?url=<URL>&format=mp4|mp3       → скачать видео/аудио
             &start=HH:MM:SS&end=HH:MM:SS   → опциональная обрезка
GET /strategy                                → JSON с текущей стратегией DPI
GET /probe                                   → запуск подбора стратегии
"""

import glob
import http.server
import json
import logging
import os
import socketserver
import subprocess
import tempfile
import urllib.parse
import uuid

SERVER_PORT = int(os.environ.get("SERVER_PORT", "8080"))
COOKIES_FILE = os.environ.get("COOKIES_FILE", "/cookies.txt")

HTML = """\
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <title>Video Downloader</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 600px; margin: 50px auto; padding: 0 16px; color: #222; }
    h2 { margin-bottom: 20px; }
    input[type=text] { width: 100%; padding: 10px; font-size: 1em; box-sizing: border-box; border: 1px solid #ccc; border-radius: 6px; }
    select, button { padding: 10px 18px; font-size: 1em; margin-top: 10px; border-radius: 6px; }
    button { background: #0066cc; color: #fff; border: none; cursor: pointer; }
    button:hover { background: #0052a3; }
    .status-card { margin-top: 30px; padding: 14px 18px; background: #f8f9fa; border: 1px solid #e2e8f0; border-radius: 8px; font-size: 0.9em; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.8em; font-weight: bold; background: #28a745; color: white; }
    .badge.off { background: #dc3545; }
    .code { font-family: monospace; background: #eaecf0; padding: 2px 6px; border-radius: 4px; font-size: 0.85em; word-break: break-all; }
    .actions { margin-top: 8px; }
    .actions a { color: #0066cc; text-decoration: none; font-size: 0.9em; }
    .actions a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <h2>Video Downloader</h2>
  <form action="/download">
    <input type="text" name="url" placeholder="https://www.youtube.com/watch?v=..." required>
    <br>
    <select name="format">
      <option value="mp4">Видео (MP4)</option>
      <option value="mp3">Аудио (MP3)</option>
    </select>
    <button type="submit">Скачать</button>
  </form>

  <div class="status-card">
    <div style="margin-bottom: 6px;">
      <strong>DPI Bypass:</strong> <span class="badge" id="bypass-badge">Проверка...</span>
    </div>
    <div style="margin-bottom: 6px;">
      <strong>Стратегия:</strong> <span class="code" id="strat-val">определяется...</span>
    </div>
    <div class="actions">
      <a href="/probe">🔄 Подобрать стратегию заново</a>
    </div>
  </div>

  <script>
    fetch('/strategy')
      .then(r => r.json())
      .then(d => {
        const badge = document.getElementById('bypass-badge');
        badge.textContent = d.active ? 'Активен' : 'Отключен';
        if (!d.active) badge.classList.add('off');
        document.getElementById('strat-val').textContent = d.strategy || 'не выбрана';
      })
      .catch(() => {
        document.getElementById('strat-val').textContent = 'auto';
      });
  </script>
</body>
</html>
"""


def get_current_strategy() -> str:
    cache_file = os.path.join(os.environ.get("OUTPUT_DIR", "/downloads"), ".zapret_strategy")
    if os.path.isfile(cache_file):
        try:
            with open(cache_file, "r") as f:
                content = f.read().strip()
                if content:
                    return content
        except OSError:
            pass
    return os.environ.get("NFQWS2_OPT", "--lua-desync=multidisorder:pos=1,midsld")


def is_nfqws_alive() -> bool:
    pid_file = "/var/run/nfqws2.pid"
    if os.path.isfile(pid_file):
        try:
            with open(pid_file, "r") as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            return False
    return False


def trigger_probe(force=True) -> tuple[bool, str]:
    if not os.path.isfile("/app/probe.sh"):
        return False, "probe.sh not found"
    env = dict(os.environ, FORCE_PROBE="1" if force else "0")
    res = subprocess.run(["/app/probe.sh", "--auto"], env=env, capture_output=True, text=True)
    return res.returncode == 0, res.stdout or res.stderr


def yt_dlp_base_cmd():
    cmd = [
        "yt-dlp",
        "--no-playlist",
        "--no-warnings",
    ]
    proxy = os.environ.get("PROXY_URL") or os.environ.get("HTTP_PROXY")
    if proxy:
        cmd += ["--proxy", proxy]
    if os.path.isfile(COOKIES_FILE):
        cmd += ["--cookies", COOKIES_FILE]
    return cmd


class VideoHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        req_id = uuid.uuid4().hex[:8]
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/":
            logging.info("[%s] [%s] GET /", req_id, self.client_address[0])
            self._send_html(HTML)
            return

        if parsed.path == "/strategy":
            self._handle_strategy()
            return

        if parsed.path == "/probe":
            self._handle_probe(req_id, params)
            return

        if parsed.path == "/info":
            url = params.get("url", [None])[0]
            if not url:
                self.send_error(400, "Missing 'url' parameter")
                return
            self._handle_info(req_id, url)
            return

        if parsed.path == "/search":
            query = params.get("query", [None])[0]
            if not query:
                self.send_error(400, "Missing 'query' parameter")
                return
            self._handle_search(req_id, query)
            return

        if parsed.path == "/download":
            url = params.get("url", [None])[0]
            if not url:
                self.send_error(400, "Missing 'url' parameter")
                return
            fmt   = params.get("format", ["mp4"])[0]
            start = params.get("start", [None])[0]
            end   = params.get("end",   [None])[0]
            self._download_and_send(req_id, url, fmt, start, end)
            return

        self.send_error(404)

    # ── /strategy & /probe ────────────────────────────────────────────────────

    def _handle_strategy(self):
        strat = get_current_strategy()
        alive = is_nfqws_alive()
        self._send_json({"strategy": strat, "active": alive})

    def _handle_probe(self, req_id: str, params: dict):
        client = self.client_address[0]
        logging.info("[%s] [%s] triggering strategy probe", req_id, client)
        ok, out = trigger_probe(force=True)
        strat = get_current_strategy()

        if "application/json" in self.headers.get("Accept", "") or params.get("format", [""])[0] == "json":
            self._send_json({"success": ok, "strategy": strat, "output": out})
        else:
            status_text = "Успешно найдена рабочая стратегия" if ok else "Ошибка: не удалось найти рабочую стратегию"
            status_color = "#28a745" if ok else "#dc3545"
            body = f"""<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <title>Результат подбора стратегии</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 650px; margin: 40px auto; padding: 0 16px; color: #222; }}
    pre {{ background: #f4f6f8; padding: 14px; border-radius: 6px; overflow-x: auto; font-size: 0.9em; }}
    .status {{ font-size: 1.1em; font-weight: bold; color: {status_color}; }}
    .card {{ background: #fafafa; border: 1px solid #ddd; border-radius: 8px; padding: 16px; margin: 20px 0; }}
    a {{ color: #0066cc; text-decoration: none; }}
  </style>
</head>
<body>
  <h2>Результат автоподбора стратегии DPI</h2>
  <div class="card">
    <p class="status">{status_text}</p>
    <p><strong>Текущая стратегия:</strong> <code>{strat}</code></p>
  </div>
  <h3>Лог проверки:</h3>
  <pre>{out}</pre>
  <p><a href="/">← Вернуться на главную форму</a></p>
</body>
</html>"""
            self._send_html(body)

    # ── /info ─────────────────────────────────────────────────────────────────

    def _handle_info(self, req_id: str, url: str):
        client = self.client_address[0]
        logging.info("[%s] [%s] info url=%s", req_id, client, url)

        cmd = yt_dlp_base_cmd() + [
            "--dump-json",
            "--skip-download",
            url,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 and os.path.isfile("/app/probe.sh") and os.environ.get("AUTO_RETRY", "1") == "1":
            logging.warning("[%s] [%s] info failed; re-probing DPI strategy...", req_id, client)
            ok, _ = trigger_probe(force=True)
            if ok:
                result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            logging.error("[%s] [%s] info failed url=%s", req_id, client, url)
            self.send_error(500, "Failed to fetch video info")
            return

        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.send_error(500, "Invalid response from yt-dlp")
            return

        info = {
            "title":     data.get("title"),
            "duration":  data.get("duration"),
            "uploader":  data.get("uploader"),
            "thumbnail": data.get("thumbnail"),
        }
        self._send_json(info)
        logging.info("[%s] [%s] info done title=%s", req_id, client, info["title"])

    # ── /search ───────────────────────────────────────────────────────────────

    def _handle_search(self, req_id: str, query: str):
        client = self.client_address[0]
        logging.info("[%s] [%s] search query=%s", req_id, client, query)

        cmd = yt_dlp_base_cmd() + [
            "--dump-json",
            "--skip-download",
            f"ytsearch1:{query}",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 and os.path.isfile("/app/probe.sh") and os.environ.get("AUTO_RETRY", "1") == "1":
            logging.warning("[%s] [%s] search failed; re-probing DPI strategy...", req_id, client)
            ok, _ = trigger_probe(force=True)
            if ok:
                result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            logging.error("[%s] [%s] search failed query=%s", req_id, client, query)
            self.send_error(500, "Search failed")
            return

        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.send_error(500, "Invalid response from yt-dlp")
            return

        info = {
            "url":      data.get("webpage_url") or data.get("url"),
            "title":    data.get("title"),
            "duration": data.get("duration"),
            "uploader": data.get("uploader"),
        }
        self._send_json(info)
        logging.info("[%s] [%s] search done title=%s", req_id, client, info["title"])

    # ── /download ─────────────────────────────────────────────────────────────

    def _download_and_send(self, req_id: str, url: str, fmt: str, start: str | None, end: str | None):
        client = self.client_address[0]
        logging.info("[%s] [%s] request  url=%s format=%s start=%s end=%s", req_id, client, url, fmt, start, end)

        with tempfile.TemporaryDirectory() as tmpdir:
            cmd = yt_dlp_base_cmd() + [
                "--output", f"{tmpdir}/%(title)s.%(ext)s",
            ]
            if fmt == "mp3":
                cmd += ["-x", "--audio-format", "mp3"]
            else:
                cmd += ["--merge-output-format", "mp4"]

            if start or end:
                section = f"*{start or '0'}-{end or 'inf'}"
                cmd += ["--download-sections", section, "--force-keyframes-at-cuts"]

            cmd.append(url)

            logging.info("[%s] [%s] downloading url=%s", req_id, client, url)
            result = subprocess.run(cmd)

            if result.returncode != 0 and os.path.isfile("/app/probe.sh") and os.environ.get("AUTO_RETRY", "1") == "1":
                logging.warning("[%s] [%s] download failed; re-probing DPI strategy...", req_id, client)
                ok, _ = trigger_probe(force=True)
                if ok:
                    logging.info("[%s] [%s] new strategy selected; retrying download...", req_id, client)
                    result = subprocess.run(cmd)

            if result.returncode != 0:
                logging.error("[%s] [%s] download failed url=%s", req_id, client, url)
                self.send_error(500, "Download failed")
                return

            files = glob.glob(f"{tmpdir}/*")
            if not files:
                logging.error("[%s] [%s] no output file url=%s", req_id, client, url)
                self.send_error(500, "No output file produced")
                return

            filepath = files[0]
            filename = os.path.basename(filepath)
            filesize = os.path.getsize(filepath)
            mime     = "audio/mpeg" if fmt == "mp3" else "video/mp4"

            logging.info("[%s] [%s] sending   file=%s size=%d", req_id, client, filename, filesize)

            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(filesize))
            encoded_filename = urllib.parse.quote(filename, encoding="utf-8")
            self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{encoded_filename}")
            self.end_headers()

            with open(filepath, "rb") as f:
                while chunk := f.read(1024 * 1024):
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        logging.warning("[%s] [%s] connection lost during transfer file=%s", req_id, client, filename)
                        break

            logging.info("[%s] [%s] done      file=%s size=%d", req_id, client, filename, filesize)

        logging.info("[%s] [%s] deleted   file=%s", req_id, client, filename)

    # ── helpers ───────────────────────────────────────────────────────────────

    def _send_json(self, data: dict):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html: str):
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # отключаем стандартный лог BaseHTTPRequestHandler


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="[server] %(message)s")
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("", SERVER_PORT), VideoHandler) as srv:
        logging.info("Listening on port %d", SERVER_PORT)
        srv.serve_forever()
