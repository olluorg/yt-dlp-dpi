# YouTube Downloader (Docker + zapret2)

Инструмент для стабильного скачивания видео и аудио с YouTube из России без сторонних VPN.

Внутри работает [yt-dlp](https://github.com/yt-dlp/yt-dlp) в связке с [bol-van/zapret2](https://github.com/bol-van/zapret2) (`nfqws2`) с динамической десинхронизацией пакетов на Lua.

[English version →](README.en.md)

## Использование

### Веб-интерфейс

```bash
docker compose up -d
```

Открыть в браузере: `http://localhost:8080`

Вставить ссылку, выбрать формат — файл скачается напрямую в браузер.

### Командная строка

**Linux / WSL2 (Windows):**
```bash
# Скачать видео (MP4)
docker run --rm --cap-add=NET_ADMIN -v "${PWD}/downloads:/downloads" ghcr.io/olluorg/yt-dlp-dpi:latest "https://youtu.be/aqz-KE-bpKQ"

# Скачать аудио (MP3)
docker run --rm --cap-add=NET_ADMIN -v "${PWD}/downloads:/downloads" -e YT_DLP_OPTS="-x --audio-format mp3" ghcr.io/olluorg/yt-dlp-dpi:latest "https://youtu.be/aqz-KE-bpKQ"
```

**macOS / Зарубежные серверы (без DPI bypass):**
```bash
docker run --rm -v "${PWD}/downloads:/downloads" ghcr.io/olluorg/yt-dlp-dpi:latest "https://youtu.be/aqz-KE-bpKQ"
```

Файлы сохраняются в папку `./downloads/`.

## Готовый образ

```bash
docker pull ghcr.io/olluorg/yt-dlp-dpi:latest
```

Образ автоматически пересобирается через CI/CD при каждом обновлении репозитория.

## Сборка вручную

```bash
docker build -t yt-dlp-dpi .
```

## REST API

### `GET /`
Веб-форма для скачивания через браузер.

---

### `GET /info`
Возвращает метаданные видео без скачивания.

**Параметры:** `url` (обязательный)  
**Пример:** `GET /info?url=https://youtu.be/aqz-KE-bpKQ`

---

### `GET /search`
Ищет видео на YouTube и возвращает первый результат.

**Параметры:** `query` (обязательный)  
**Пример:** `GET /search?query=rick+astley`

---

### `GET /download`
Скачивает видео или аудио и отдаёт файл напрямую в ответе.

| Параметр | Обязательный | Значения | По умолчанию | Описание |
|---|---|---|---|---|
| `url` | да | любая ссылка yt-dlp | — | Ссылка на видео |
| `format` | нет | `mp4`, `mp3` | `mp4` | Формат файла |
| `start` | нет | `HH:MM:SS` | — | Начало обрезки |
| `end` | нет | `HH:MM:SS` | — | Конец обрезки |

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `SERVER_PORT` | `8080` | Порт веб-интерфейса |
| `NFQUEUE_NUM` | `200` | Номер очереди NFQUEUE |
| `NFQWS2_OPT` | `--lua-desync=multidisorder:pos=1,midsld` | Параметры десинхронизации zapret2 |
| `OUTPUT_DIR` | `/downloads` | Папка для сохранения файлов |
| `COOKIES_FILE` | `/cookies.txt` | Путь к файлу cookies внутри контейнера |
| `YT_DLP_OPTS` | — | Дополнительные флаги yt-dlp |

## Cookies (обход проверки бота)

YouTube может требовать авторизацию. Экспортируйте cookies из браузера и передайте их в контейнер:

```bash
docker run --rm --cap-add=NET_ADMIN -v "${PWD}/downloads:/downloads" -v "${PWD}/cookies.txt:/cookies.txt:ro" ghcr.io/olluorg/yt-dlp-dpi:latest "https://youtu.be/aqz-KE-bpKQ"
```

Для веб-интерфейса добавьте в `docker-compose.yml`:
```yaml
volumes:
  - ./cookies.txt:/cookies.txt:ro
```

## Требования

- Docker
- `--cap-add=NET_ADMIN` (или `--privileged`) для работы модуля перехвата очередей NFQUEUE.

## Основано на

- [bol-van/zapret2](https://github.com/bol-van/zapret2)
- [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp)
