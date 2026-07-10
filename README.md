# TikTok Profile Backup

A Windows downloader for backing up **publicly accessible videos** from a TikTok profile.

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
- Uses browser cookies, `cookies.txt`, or anonymous access.
- Supports Brave, Chrome, Edge, and Firefox.
- Keeps full captions, post URLs, IDs, and dates in `catalog.csv`.
- Stores original yt-dlp metadata and timestamped logs.
- Automatically downloads and updates the official yt-dlp Windows binary.
- Handles invalid Windows filename characters and duplicate captions.
- Does not attempt to access private accounts.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or newer.
- Internet access.
- A browser logged into TikTok may be needed when anonymous access is blocked.

No Python installation is required.

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

## Folder layout

```text
downloads\
└── @username\
    ├── videos\                 Final renamed videos
    ├── _raw\                   Temporary downloads
    ├── _metadata\              Original yt-dlp metadata
    ├── _logs\                  Session and yt-dlp logs
    ├── catalog.csv             Full searchable catalog
    └── download_archive.txt    Prevents duplicate downloads
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

### Some profile videos are missing

TikTok profile extraction is not perfectly reliable and can change without notice. Update yt-dlp, try the nightly channel, retry later, and compare `catalog.csv` against the public profile.

### Windows Defender blocks yt-dlp

The script downloads the executable directly from the official yt-dlp GitHub release repository. Review the URL in the PowerShell script and allow it only if you are comfortable doing so.

## Limitations

- Public and otherwise accessible posts only.
- TikTok may rate-limit, block, or change profile extraction.
- Profile pagination can occasionally return an incomplete set.
- Deleted, region-restricted, age-restricted, friends-only, and private posts may be unavailable.
- The script does not remove watermarks.
- Windows is the supported operating system for this repository.

## Responsible use

Download only material you are permitted to store. Respect copyright, privacy, TikTok's terms, local law, and the creator's rights. Do not use this project to bypass access controls.

## License

MIT. See [LICENSE](LICENSE).
