# Lolek

Lolek is a Telegram bot. Send it a link to a social media post, and it sends the post back to the chat as one Telegram rich message. The message looks like the original post: author, text with links, media, quoted post, parent post, date, and counters.

Supported sites: X/Twitter, Bluesky, Threads, Instagram, TikTok, Facebook, Coub, YouTube Shorts, and YouTube posts.

## How it works

1. Lolek reads the post metadata from the public Bluesky API, gallery-dl, page data (Threads, YouTube posts), or yt-dlp.
2. Lolek downloads the media with gallery-dl or yt-dlp, and converts it with ffmpeg to a format that Telegram accepts.
3. Lolek sends one rich message (`sendRichMessage`) with up to 50 media files, and caches the Telegram file_ids for the next requests.

## Run

```bash
cp config/.env.default config/.env   # set LOLEK_BOT_TOKEN
make start_compose                   # docker compose up --build
```
