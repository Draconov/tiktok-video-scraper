# TikTok Profile Backup

A Windows downloader for backing up **publicly accessible videos** from a TikTok profile at the highest available quality exposed by yt-dlp, while excluding formats explicitly marked as watermarked.

Paste any TikTok profile URL, `@username`, or username. The script downloads the profile with [yt-dlp](https://github.com/yt-dlp/yt-dlp), keeps a per-profile download archive, renames each video from its post date and author caption, and writes a searchable CSV catalog.

## Filename format

```text
YYYY-MM-DD_description written by the author.mp4
```

When the post has no description:

```text
YYYY-MM-DD_без_названия_1.mp4
YYYY-MM-DD_без_названия_2.mp4
```

Long captions are shortened only in the Windows filename. The complete original caption remains in `catalog.csv`.

## Features

- Accepts a full profile URL, `@username`, or plain username.
- Creates a separate backup folder for each TikTok account.
- Downloads only new posts when run again.
- Selects the highest-quality format available without forcing H.264.
- Excludes formats that yt-dlp explicitly labels as watermarked.
- Automatically installs FFmpeg/FFprobe for merging and audio verification.
- Checks every new download for a real audio stream.
- Scans previously downloaded videos and repairs silent files.
- Retries a silent video from a fresh TikTok extraction using the same quality and codec policy.
- Quarantines files that remain silent after all retries and removes their IDs from the archive so a later run can try again.
- Uses browser cookies, `cookies.txt`, or anonymous access.
- Supports Brave, Chrome, Edge, and Firefox.
- Keeps full captions, post URLs, IDs, audio status, retry counts, and hashes in `catalog.csv`.
- Stores original yt-dlp metadata and timestamped logs.
- Handles invalid Windows filename characters and duplicate captions.
- Does not attempt to access private accounts.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or newer.
- Internet access.
- A browser logged into TikTok may be needed when anonymous access is blocked.

No Python installation is required.

On the first run, the script downloads:

- `yt-dlp.exe` from the official yt-dlp GitHub releases.
- `ffmpeg.exe` and `ffprobe.exe` from the BtbN FFmpeg Windows builds.

These tools are stored in `.tools/`, which is excluded by `.gitignore`.

## Quick start

1. Download or clone this repository.
2. Open TikTok in your browser and make sure the target public profile loads.
3. Close the browser so its cookie database is not locked.
4. Double-click `Run_TikTok_Profile_Backup.bat`.
5. Paste a profile link such as:

   ```text
   https://www.tiktok.com/@username
   ```

6. Find the downloaded files under:

   ```text
   downloads\@username\videos
   ```

## Command-line use

Open PowerShell in the repository folder:

```powershell
.\TikTok-Profile-Backup.ps1 "https://www.tiktok.com/@username"
```

Use a specific browser:

```powershell
.\TikTok-Profile-Backup.ps1 "@username" -Browser brave
```

Available browser values:

```text
auto, brave, chrome, edge, firefox, none
```

Use the official yt-dlp nightly channel when TikTok support is temporarily broken in the stable release:

```powershell
.\TikTok-Profile-Backup.ps1 "@username" -Channel nightly
```

Use a custom output folder:

```powershell
.\TikTok-Profile-Backup.ps1 "@username" -OutputRoot "D:\TikTok Backups"
```

Skip the yt-dlp update check:

```powershell
.\TikTok-Profile-Backup.ps1 "@username" -SkipUpdate
```

Choose how many fresh retries are made when a file has no audio stream:

```powershell
.\TikTok-Profile-Backup.ps1 "@username" -SilentRetryCount 3
```

Skip the scan of previously downloaded videos while still checking new downloads:

```powershell
.\TikTok-Profile-Backup.ps1 "@username" -SkipExistingAudioScan
```

Disable FFprobe checking and silent-file repair entirely:

```powershell
.\TikTok-Profile-Backup.ps1 "@username" -SkipAudioCheck
```

## Folder layout

```text
downloads\
└── @username\
    ├── videos\                 Final renamed videos with verified audio streams
    ├── _raw\                   Temporary downloads
    ├── _metadata\              Original yt-dlp metadata
    ├── _logs\                  Session and yt-dlp logs
    ├── _silent\                Files still silent after all retries
    ├── catalog.csv              Full searchable catalog and audio status
    └── download_archive.txt     Prevents duplicate downloads
```

The `.tools` directory is created automatically and contains `yt-dlp.exe`.

## Browser cookies

The default `-Browser auto` mode tries installed browsers and then anonymous access.

For the cleanest cookie extraction:

1. Log into TikTok in the browser.
2. Confirm the profile opens.
3. Close the browser completely.
4. Run the downloader.

You can also export TikTok cookies in Netscape `cookies.txt` format and place `cookies.txt` beside the PowerShell script. The file is ignored by Git and must never be committed.

## Updating an existing backup

Run the same profile again. `download_archive.txt` makes yt-dlp skip videos that were already downloaded.


## Audio verification and retry behavior

The script does not trust TikTok's metadata alone. After downloading a file, it asks FFprobe whether the finished container actually contains an audio stream.

When no audio stream is detected:

1. The script performs a completely fresh download of that individual TikTok post.
2. It uses the same browser/cookie method that succeeded for the profile.
3. It uses the same unrestricted codec policy—**H.264 is never forced**.
4. It again selects the highest-quality format that is not explicitly marked as watermarked.
5. It calculates a SHA-256 hash for each silent result and writes the hashes to the log and `catalog.csv`.
6. It retries up to `-SilentRetryCount` times.
7. If every retry is still silent, the file is moved into `_silent`, its catalog status becomes `silent_after_retries`, and its ID is removed from `download_archive.txt` so a future run can try again.

FFprobe checks whether an audio stream exists. It does not analyze whether an existing audio track contains audible volume. An intentionally silent TikTok post will therefore be treated as missing audio only when the file has no audio stream at all.

## Troubleshooting

### The window shows no videos

- Confirm the profile is public.
- Confirm it opens normally in your browser.
- Log into TikTok.
- Close the browser before running the downloader.
- Try a specific browser with `-Browser brave`, `chrome`, `edge`, or `firefox`.
- Try the nightly yt-dlp channel:

  ```powershell
  .\TikTok-Profile-Backup.ps1 "@username" -Channel nightly
  ```

- Check the profile's `_logs` folder.

### Cookie database or decryption error

Close every window and background process belonging to that browser. If it still fails, try another logged-in browser or use a manually exported `cookies.txt`.


### A video is silent

Run the same profile again. Version 1.1.0 scans existing files, queues any file without an audio stream, and retries it automatically.

Check:

```text
downloads\@username\_logs
downloads\@username\_silent
downloads\@username\catalog.csv
```

A catalog status of `repaired_audio_after_retry_1` (or a later number) means a fresh retry worked. `silent_after_retries` means TikTok kept returning a file without an audio stream. The script does not force H.264.

### Some profile videos are missing

TikTok profile extraction is not perfectly reliable and can change without notice. Update yt-dlp, try the nightly channel, retry later, and compare `catalog.csv` against the public profile.

### Windows Defender blocks yt-dlp

The script downloads the executable directly from the official yt-dlp GitHub release repository. Review the URL in the PowerShell script and allow it only if you are comfortable doing so.

## Limitations

- Public and otherwise accessible posts only.
- TikTok may rate-limit, block, or change profile extraction.
- Profile pagination can occasionally return an incomplete set.
- Deleted, region-restricted, age-restricted, friends-only, and private posts may be unavailable.
- The script excludes formats that yt-dlp explicitly identifies as watermarked; it does not modify pixels or remove creator-burned logos/text.
- TikTok or extractor metadata can be incomplete, so a watermark-free result cannot be guaranteed for every post.
- FFprobe detects missing audio streams, not tracks that technically exist but contain silence.
- Windows is the supported operating system for this repository.

## Responsible use

Download only material you are permitted to store. Respect copyright, privacy, TikTok's terms, local law, and the creator's rights. Do not use this project to bypass access controls.

## License

MIT. See [LICENSE](LICENSE).
