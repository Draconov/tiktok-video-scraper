# Security Policy

## Sensitive files

Never commit or share:

- `cookies.txt`
- browser cookie databases
- downloaded account data that is not yours to distribute
- private logs containing local filesystem paths or session information

The repository's `.gitignore` excludes `cookies.txt`, `.tools`, and `downloads`.

## Binary download

The script downloads `yt-dlp.exe` directly from one of these official release repositories:

- `yt-dlp/yt-dlp`
- `yt-dlp/yt-dlp-nightly-builds`

For audio verification and merging, it also downloads a Windows FFmpeg build from:

- `BtbN/FFmpeg-Builds`

Review `TikTok-Profile-Backup.ps1` before running it if you need to audit the exact URLs.

## Reporting a vulnerability

Open a GitHub security advisory rather than a public issue when a report contains secrets, private data, or a reproducible security vulnerability.
