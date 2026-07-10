# Changelog

## 1.1.0 — 2026-07-10

- Added highest-quality format selection while excluding formats explicitly marked as watermarked.
- Kept codec selection unrestricted; H.264 is never forced.
- Added automatic FFmpeg and FFprobe installation.
- Added post-download audio-stream verification.
- Added fresh same-policy retries for videos with no audio stream.
- Added scanning and repair of previously downloaded silent videos.
- Added SHA-256 logging for silent attempts.
- Added `_silent` quarantine and automatic archive removal after failed retries.
- Added audio status, retry count, and silent hashes to `catalog.csv`.
- Added `-SilentRetryCount`, `-SkipExistingAudioScan`, and `-SkipAudioCheck`.

## 1.0.0 — 2026-07-10

- Initial GitHub-ready release.
- Accepts any TikTok profile URL, `@username`, or username.
- Separate output and archive for every profile.
- Brave, Chrome, Edge, Firefox, `cookies.txt`, and anonymous modes.
- Stable and nightly yt-dlp channels.
- Requested `YYYY-MM-DD_description` filename format.
- Numbered `без_названия_N` fallback for posts without captions.
- CSV catalog, metadata retention, logs, and resumable downloads.
- GitHub Actions PowerShell syntax validation.
