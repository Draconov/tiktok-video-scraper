#requires -Version 5.1
<#
.SYNOPSIS
    Downloads publicly accessible videos from a TikTok profile.

.DESCRIPTION
    Accepts a TikTok profile URL, @username, or username. Downloads videos with
    yt-dlp, renames them to YYYY-MM-DD_<post description>, and creates a CSV
    catalog. Re-running the script downloads only new posts.

.NOTES
    TikTok changes frequently. A profile that works today may temporarily fail
    until yt-dlp is updated.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Profile,

    [ValidateSet("auto", "brave", "chrome", "edge", "firefox", "none")]
    [string]$Browser = "auto",

    [ValidateSet("stable", "nightly")]
    [string]$Channel = "stable",

    [string]$OutputRoot = "",

    [ValidateRange(0, 10)]
    [int]$SilentRetryCount = 3,

    [switch]$SkipUpdate,

    [switch]$SkipAudioCheck,

    [switch]$SkipExistingAudioScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch {}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ScriptRoot "downloads"
}

$ToolDir = Join-Path $ScriptRoot ".tools"
$YtDlp = Join-Path $ToolDir "yt-dlp.exe"
$Ffmpeg = Join-Path $ToolDir "ffmpeg.exe"
$Ffprobe = Join-Path $ToolDir "ffprobe.exe"
$CookiesFile = Join-Path $ScriptRoot "cookies.txt"

# Keep the best available TikTok format while excluding formats that yt-dlp
# explicitly identifies as watermarked. No codec (including H.264) is forced.
$FormatSelector = "(bv*[format_note!*='watermarked']+ba[format_note!*='watermarked'])/b[format_note!*='watermarked']"

function Write-Status {
    param(
        [AllowEmptyString()]
        [string]$Message = "",

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    if ([string]::IsNullOrEmpty($Message)) {
        Write-Host ""
        return
    }

    Write-Host $Message -ForegroundColor $Color
}

function Get-NormalizedProfile {
    param([Parameter(Mandatory = $true)][string]$InputProfile)

    $value = $InputProfile.Trim()

    if ($value -match '^@(?<username>[A-Za-z0-9._-]+)$') {
        $username = $Matches.username
        return [pscustomobject]@{
            Username = $username
            Url      = "https://www.tiktok.com/@$username"
        }
    }

    if ($value -match '^[A-Za-z0-9._-]+$') {
        return [pscustomobject]@{
            Username = $value
            Url      = "https://www.tiktok.com/@$value"
        }
    }

    if ($value -match '^(?:https?://)?(?:www\.)?tiktok\.com/@(?<username>[A-Za-z0-9._-]+)(?:[/?#].*)?$') {
        $username = $Matches.username
        return [pscustomobject]@{
            Username = $username
            Url      = "https://www.tiktok.com/@$username"
        }
    }

    throw "That is not a supported TikTok profile link. Paste something like https://www.tiktok.com/@username"
}

function Get-YtDlpDownloadUrl {
    param([ValidateSet("stable", "nightly")][string]$SelectedChannel)

    if ($SelectedChannel -eq "nightly") {
        return "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp.exe"
    }

    return "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
}

function Install-OrUpdateYtDlp {
    New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null

    if (-not (Test-Path -LiteralPath $YtDlp)) {
        $downloadUrl = Get-YtDlpDownloadUrl -SelectedChannel $Channel
        Write-Status "Downloading yt-dlp ($Channel channel)..." Cyan

        try {
            Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $YtDlp
        }
        catch {
            throw "Could not download yt-dlp. Check your internet connection or security software. $($_.Exception.Message)"
        }
    }
    elseif (-not $SkipUpdate) {
        Write-Status "Checking for yt-dlp updates..." DarkCyan

        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"

            if ($Channel -eq "nightly") {
                & $YtDlp --update-to nightly
            }
            else {
                & $YtDlp --update-to stable
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Status "Update check failed; continuing with the installed copy." Yellow
            }
        }
        finally {
            $ErrorActionPreference = $savedPreference
        }
    }

    if (-not (Test-Path -LiteralPath $YtDlp)) {
        throw "yt-dlp.exe is missing."
    }
}

function Install-FfmpegTools {
    if ((Test-Path -LiteralPath $Ffmpeg) -and (Test-Path -LiteralPath $Ffprobe)) {
        return
    }

    New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null

    $archiveUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl-shared.zip"
    $archivePath = Join-Path $ToolDir "ffmpeg-build.zip"
    $extractPath = Join-Path $ToolDir "_ffmpeg_extract"

    Write-Status "Downloading FFmpeg and FFprobe for audio verification..." Cyan
    Write-Status "This is a one-time download and may take a while." DarkGray

    try {
        if (Test-Path -LiteralPath $extractPath) {
            Remove-Item -LiteralPath $extractPath -Recurse -Force
        }

        Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $archivePath
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force

        $downloadedFfmpeg = Get-ChildItem -LiteralPath $extractPath -Filter "ffmpeg.exe" -File -Recurse |
            Select-Object -First 1

        $downloadedFfprobe = Get-ChildItem -LiteralPath $extractPath -Filter "ffprobe.exe" -File -Recurse |
            Select-Object -First 1

        if ($null -eq $downloadedFfmpeg -or $null -eq $downloadedFfprobe) {
            throw "The downloaded FFmpeg package did not contain ffmpeg.exe and ffprobe.exe."
        }

        $binaryDirectory = $downloadedFfprobe.Directory.FullName

        foreach ($binaryFile in (Get-ChildItem -LiteralPath $binaryDirectory -File)) {
            if ($binaryFile.Extension -in @(".exe", ".dll")) {
                Copy-Item -LiteralPath $binaryFile.FullName -Destination (Join-Path $ToolDir $binaryFile.Name) -Force
            }
        }
    }
    catch {
        throw "Could not install FFmpeg tools. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $extractPath) {
            Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $Ffmpeg) -or -not (Test-Path -LiteralPath $Ffprobe)) {
        throw "FFmpeg installation did not complete correctly."
    }
}

function Test-BrowserInstalled {
    param([string]$BrowserName)

    $candidatePaths = switch ($BrowserName) {
        "brave" {
            @(
                "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
                "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
                "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
            )
        }
        "chrome" {
            @(
                "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
            )
        }
        "edge" {
            @(
                "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
            )
        }
        "firefox" {
            @(
                "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
                "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
            )
        }
        default {
            @()
        }
    }

    foreach ($candidate in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $true
        }
    }

    return $false
}

function Get-DownloadMethods {
    param([string]$RequestedBrowser)

    $methods = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $CookiesFile) {
        $methods.Add([pscustomobject]@{
            Type  = "cookies-file"
            Value = $CookiesFile
            Label = "cookies.txt"
        })
    }

    if ($RequestedBrowser -eq "none") {
        $methods.Add([pscustomobject]@{
            Type  = "anonymous"
            Value = ""
            Label = "anonymous access"
        })
        return $methods
    }

    if ($RequestedBrowser -ne "auto") {
        $methods.Add([pscustomobject]@{
            Type  = "browser"
            Value = $RequestedBrowser
            Label = "$RequestedBrowser browser cookies"
        })

        $methods.Add([pscustomobject]@{
            Type  = "anonymous"
            Value = ""
            Label = "anonymous fallback"
        })

        return $methods
    }

    foreach ($candidate in @("brave", "chrome", "edge", "firefox")) {
        if (Test-BrowserInstalled -BrowserName $candidate) {
            $methods.Add([pscustomobject]@{
                Type  = "browser"
                Value = $candidate
                Label = "$candidate browser cookies"
            })
        }
    }

    $methods.Add([pscustomobject]@{
        Type  = "anonymous"
        Value = ""
        Label = "anonymous access"
    })

    return $methods
}

function Get-MethodArguments {
    param([object]$Method)

    $arguments = @()

    switch ($Method.Type) {
        "cookies-file" {
            $arguments += @("--cookies", [string]$Method.Value)
        }
        "browser" {
            $arguments += @("--cookies-from-browser", [string]$Method.Value)
        }
    }

    return $arguments
}

function Test-HasAudioStream {
    param([Parameter(Mandatory = $true)][string]$VideoPath)

    if (-not (Test-Path -LiteralPath $VideoPath)) {
        return $null
    }

    $savedPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $probeOutput = & $Ffprobe `
            "-v" "error" `
            "-select_streams" "a:0" `
            "-show_entries" "stream=codec_name" `
            "-of" "default=noprint_wrappers=1:nokey=1" `
            $VideoPath 2>$null

        $probeExitCode = $LASTEXITCODE

        if ($probeExitCode -ne 0) {
            Write-Status "FFprobe could not inspect: $([IO.Path]::GetFileName($VideoPath))" Yellow
            return $null
        }

        $audioCodec = ($probeOutput | Out-String).Trim()
        return (-not [string]::IsNullOrWhiteSpace($audioCodec))
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Get-SafeFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch {
        return ""
    }
}

function Remove-ArchiveEntry {
    param(
        [string]$ArchivePath,
        [string]$VideoId
    )

    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        return
    }

    $escapedId = [regex]::Escape($VideoId)
    $lines = @(Get-Content -LiteralPath $ArchivePath -ErrorAction SilentlyContinue)
    $remaining = @($lines | Where-Object { $_ -notmatch "(^|\s)$escapedId$" })

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllLines($ArchivePath, [string[]]$remaining, $utf8NoBom)
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $DefaultValue = ""
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function ConvertTo-CatalogRow {
    param($Entry)

    return [pscustomobject]@{
        date              = [string](Get-ObjectPropertyValue -Object $Entry -Name "date")
        username          = [string](Get-ObjectPropertyValue -Object $Entry -Name "username")
        video_id          = [string](Get-ObjectPropertyValue -Object $Entry -Name "video_id")
        filename          = [string](Get-ObjectPropertyValue -Object $Entry -Name "filename")
        full_description  = [string](Get-ObjectPropertyValue -Object $Entry -Name "full_description")
        source_url        = [string](Get-ObjectPropertyValue -Object $Entry -Name "source_url")
        downloaded_at     = [string](Get-ObjectPropertyValue -Object $Entry -Name "downloaded_at")
        status            = [string](Get-ObjectPropertyValue -Object $Entry -Name "status")
        audio_status      = [string](Get-ObjectPropertyValue -Object $Entry -Name "audio_status" -DefaultValue "unchecked")
        audio_retry_count = [string](Get-ObjectPropertyValue -Object $Entry -Name "audio_retry_count" -DefaultValue "0")
        silent_hashes     = [string](Get-ObjectPropertyValue -Object $Entry -Name "silent_hashes")
    }
}

function Get-DateFromMetadata {
    param($Metadata)

    $uploadDate = [string]$Metadata.upload_date

    if ($uploadDate -match '^\d{8}$') {
        try {
            return [DateTime]::ParseExact(
                $uploadDate,
                "yyyyMMdd",
                [Globalization.CultureInfo]::InvariantCulture
            ).ToString("yyyy-MM-dd")
        }
        catch {}
    }

    foreach ($propertyName in @("timestamp", "release_timestamp")) {
        $property = $Metadata.PSObject.Properties[$propertyName]

        if ($null -ne $property -and $null -ne $property.Value -and [string]$property.Value -match '^\d+(\.\d+)?$') {
            try {
                $seconds = [int64][double]$property.Value
                return [DateTimeOffset]::FromUnixTimeSeconds($seconds).UtcDateTime.ToString("yyyy-MM-dd")
            }
            catch {}
        }
    }

    return "0000-00-00"
}

function ConvertTo-SafeCaption {
    param([AllowEmptyString()][string]$Caption = "")

    if ($null -eq $Caption) {
        return ""
    }

    $safe = $Caption
    $safe = $safe -replace '[\r\n\t]+', ' '
    $safe = $safe -replace '[<>:"/\\|?*\x00-\x1F]', '-'
    $safe = $safe -replace '\s+', ' '
    $safe = $safe.Trim()
    $safe = $safe.TrimEnd([char[]]" .")

    return $safe
}

function Limit-TextElements {
    param(
        [AllowEmptyString()][string]$Text = "",
        [int]$Maximum
    )

    if ([string]::IsNullOrEmpty($Text) -or $Maximum -le 0) {
        return ""
    }

    $stringInfo = New-Object Globalization.StringInfo($Text)

    if ($stringInfo.LengthInTextElements -le $Maximum) {
        return $Text
    }

    return $stringInfo.SubstringByTextElements(0, $Maximum).TrimEnd()
}

function Find-RawVideo {
    param(
        [string]$RawDirectory,
        [string]$VideoId,
        [string]$PreferredExtension
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredExtension)) {
        $preferred = Join-Path $RawDirectory ("{0}.{1}" -f $VideoId, $PreferredExtension)

        if (Test-Path -LiteralPath $preferred) {
            return Get-Item -LiteralPath $preferred
        }
    }

    return Get-ChildItem -LiteralPath $RawDirectory -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.BaseName -eq $VideoId -and
            $_.Name -notlike "*.info.json" -and
            $_.Extension -notin @(".json", ".part", ".ytdl")
        } |
        Sort-Object Length -Descending |
        Select-Object -First 1
}

function Get-NextUntitledNumber {
    param(
        [string]$CatalogPath,
        [string]$VideosDirectory
    )

    $maximum = 0

    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            foreach ($row in (Import-Csv -LiteralPath $CatalogPath -Encoding UTF8)) {
                if ([string]$row.filename -match '_без_названия_(?<number>\d+)(?:_\d+)?\.[^.]+$') {
                    $value = [int]$Matches.number

                    if ($value -gt $maximum) {
                        $maximum = $value
                    }
                }
            }
        }
        catch {}
    }

    if (Test-Path -LiteralPath $VideosDirectory) {
        foreach ($file in (Get-ChildItem -LiteralPath $VideosDirectory -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -match '_без_названия_(?<number>\d+)(?:_\d+)?\.[^.]+$') {
                $value = [int]$Matches.number

                if ($value -gt $maximum) {
                    $maximum = $value
                }
            }
        }
    }

    return ($maximum + 1)
}

function Update-Catalog {
    param(
        [string]$CatalogPath,
        [object[]]$NewEntries
    )

    $rowsByVideoId = @{}

    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            foreach ($row in (Import-Csv -LiteralPath $CatalogPath -Encoding UTF8)) {
                $normalized = ConvertTo-CatalogRow -Entry $row

                if (-not [string]::IsNullOrWhiteSpace($normalized.video_id)) {
                    $rowsByVideoId[$normalized.video_id] = $normalized
                }
            }
        }
        catch {
            Write-Status "Existing catalog.csv could not be read; rebuilding it from new entries." Yellow
        }
    }

    foreach ($entry in @($NewEntries)) {
        if ($null -eq $entry) {
            continue
        }

        $normalized = ConvertTo-CatalogRow -Entry $entry

        if (-not [string]::IsNullOrWhiteSpace($normalized.video_id)) {
            $rowsByVideoId[$normalized.video_id] = $normalized
        }
    }

    $rows = @($rowsByVideoId.Values | Sort-Object date, video_id)

    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $CatalogPath -NoTypeInformation -Encoding UTF8
    }
}

function Rename-DownloadedVideos {
    param(
        [string]$Username,
        [string]$RawDirectory,
        [string]$VideosDirectory,
        [string]$MetadataDirectory,
        [string]$CatalogPath,
        [hashtable]$RepairInfoById
    )

    $infoFiles = @(
        Get-ChildItem -LiteralPath $RawDirectory -Filter "*.info.json" -File -ErrorAction SilentlyContinue
    )

    if ($infoFiles.Count -eq 0) {
        return [pscustomobject]@{
            Renamed = 0
            Missing = 0
            Entries = @()
        }
    }

    $records = foreach ($infoFile in $infoFiles) {
        try {
            $metadata = Get-Content -LiteralPath $infoFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

            [pscustomobject]@{
                InfoFile = $infoFile
                Metadata = $metadata
                Date     = Get-DateFromMetadata -Metadata $metadata
                Id       = [string]$metadata.id
            }
        }
        catch {
            Write-Status "Could not read metadata: $($infoFile.Name)" Yellow
        }
    }

    $records = @($records | Sort-Object Date, Id)
    $untitledNumber = Get-NextUntitledNumber -CatalogPath $CatalogPath -VideosDirectory $VideosDirectory
    $renamed = 0
    $missing = 0
    $catalogEntries = New-Object System.Collections.Generic.List[object]

    foreach ($record in $records) {
        $metadata = $record.Metadata
        $videoId = [string]$record.Id
        $date = [string]$record.Date
        $preferredExtension = [string]$metadata.ext

        $rawVideo = Find-RawVideo `
            -RawDirectory $RawDirectory `
            -VideoId $videoId `
            -PreferredExtension $preferredExtension

        $captionOriginal = [string]$metadata.description
        $captionSafe = ConvertTo-SafeCaption -Caption $captionOriginal

        if ([string]::IsNullOrWhiteSpace($captionSafe)) {
            $captionSafe = "без_названия_$untitledNumber"
            $untitledNumber++
        }

        $extension = if ($null -ne $rawVideo) {
            $rawVideo.Extension.TrimStart(".")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($preferredExtension)) {
            $preferredExtension
        }
        else {
            "mp4"
        }

        $prefix = "${date}_"
        $maximumBaseLength = 180
        $captionLimit = [Math]::Max(20, $maximumBaseLength - $prefix.Length)
        $captionForFilename = Limit-TextElements -Text $captionSafe -Maximum $captionLimit
        $baseName = $prefix + $captionForFilename

        $duplicateNumber = 1
        $destination = Join-Path $VideosDirectory ("{0}.{1}" -f $baseName, $extension)

        while (Test-Path -LiteralPath $destination) {
            $duplicateNumber++
            $suffix = "_$duplicateNumber"
            $trimmedCaption = Limit-TextElements `
                -Text $captionForFilename `
                -Maximum ([Math]::Max(10, $captionLimit - $suffix.Length))

            $baseName = $prefix + $trimmedCaption + $suffix
            $destination = Join-Path $VideosDirectory ("{0}.{1}" -f $baseName, $extension)
        }

        $status = "renamed"
        $audioRetryCount = 0
        $silentHashes = ""
        $finalFilename = ""

        if ($null -ne $RepairInfoById -and $RepairInfoById.ContainsKey($videoId)) {
            $repairInfo = $RepairInfoById[$videoId]
            $status = [string]$repairInfo.Status
            $audioRetryCount = [int]$repairInfo.RetryCount
            $silentHashes = [string]$repairInfo.Hashes
        }

        if ($null -eq $rawVideo) {
            $missing++
            $status = "video file missing"
            Write-Status "Metadata exists but the video file is missing: $videoId" Yellow
        }
        else {
            try {
                Move-Item -LiteralPath $rawVideo.FullName -Destination $destination
                $renamed++
                $finalFilename = [IO.Path]::GetFileName($destination)
                Write-Status ("Saved: {0}" -f $finalFilename) Green
            }
            catch {
                $missing++
                $status = "rename failed: $($_.Exception.Message)"
                Write-Status "Rename failed for video $videoId" Red
            }
        }

        $metadataDestination = Join-Path $MetadataDirectory ("{0}.info.json" -f $videoId)

        try {
            Move-Item -LiteralPath $record.InfoFile.FullName -Destination $metadataDestination -Force
        }
        catch {
            Write-Status "Could not move metadata for $videoId" Yellow
        }

        $webpageUrl = [string]$metadata.webpage_url

        if ([string]::IsNullOrWhiteSpace($webpageUrl)) {
            $webpageUrl = "https://www.tiktok.com/@$Username/video/$videoId"
        }

        $catalogEntries.Add([pscustomobject]@{
            date              = $date
            username          = "@$Username"
            video_id          = $videoId
            filename          = $finalFilename
            full_description  = $captionOriginal
            source_url        = $webpageUrl
            downloaded_at     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            status            = $status
            audio_status      = if ([string]::IsNullOrWhiteSpace($finalFilename)) { "unknown" } else { "present" }
            audio_retry_count = $audioRetryCount
            silent_hashes     = $silentHashes
        })
    }

    return [pscustomobject]@{
        Renamed = $renamed
        Missing = $missing
        Entries = $catalogEntries
    }
}

function Invoke-ProfileDownload {
    param(
        [object]$Method,
        [string]$ProfileUrl,
        [string]$RawDirectory,
        [string]$ArchivePath,
        [string]$DownloadLog
    )

    $arguments = @(
        "--ignore-errors",
        "--continue",
        "--no-overwrites",
        "--download-archive", $ArchivePath,
        "--write-info-json",
        "--no-clean-info-json",
        "--format", $FormatSelector,
        "--ffmpeg-location", $ToolDir,
        "--output", (Join-Path $RawDirectory "%(id)s.%(ext)s"),
        "--retries", "10",
        "--fragment-retries", "10",
        "--extractor-retries", "10",
        "--file-access-retries", "5",
        "--socket-timeout", "30",
        "--sleep-requests", "1",
        "--sleep-interval", "1",
        "--max-sleep-interval", "3",
        "--concurrent-fragments", "1",
        "--windows-filenames",
        "--newline"
    )

    $arguments += @(Get-MethodArguments -Method $Method)
    $arguments += $ProfileUrl

    Write-Status ""
    Write-Status "Trying $($Method.Label)..." Cyan
    Write-Status "Close that browser first if cookie extraction fails." DarkGray
    Write-Status ""

    $savedPreference = $ErrorActionPreference
    $exitCode = 1

    try {
        $ErrorActionPreference = "Continue"

        & $YtDlp @arguments 2>&1 |
            Tee-Object -FilePath $DownloadLog -Append |
            ForEach-Object { Write-Host $_ }

        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    return $exitCode
}

function Invoke-SingleVideoDownload {
    param(
        [object]$Method,
        [string]$VideoUrl,
        [string]$RetryDirectory,
        [string]$DownloadLog,
        [int]$Attempt
    )

    if (Test-Path -LiteralPath $RetryDirectory) {
        Remove-Item -LiteralPath $RetryDirectory -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $RetryDirectory | Out-Null

    $arguments = @(
        "--no-playlist",
        "--force-overwrites",
        "--no-continue",
        "--no-cache-dir",
        "--no-download-archive",
        "--write-info-json",
        "--no-clean-info-json",
        "--format", $FormatSelector,
        "--ffmpeg-location", $ToolDir,
        "--output", (Join-Path $RetryDirectory "%(id)s.%(ext)s"),
        "--retries", "10",
        "--fragment-retries", "10",
        "--extractor-retries", "10",
        "--file-access-retries", "5",
        "--socket-timeout", "30",
        "--sleep-requests", "1",
        "--sleep-interval", "1",
        "--max-sleep-interval", "3",
        "--concurrent-fragments", "1",
        "--windows-filenames",
        "--newline"
    )

    $arguments += @(Get-MethodArguments -Method $Method)
    $arguments += $VideoUrl

    Write-Status ""
    Write-Status "Fresh audio retry $Attempt using $($Method.Label)..." Cyan

    $savedPreference = $ErrorActionPreference
    $exitCode = 1

    try {
        $ErrorActionPreference = "Continue"

        & $YtDlp @arguments 2>&1 |
            Tee-Object -FilePath $DownloadLog -Append |
            ForEach-Object { Write-Host $_ }

        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    return $exitCode
}

function Move-ExistingSilentVideosToRaw {
    param(
        [string]$Username,
        [string]$VideosDirectory,
        [string]$RawDirectory,
        [string]$MetadataDirectory,
        [string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        return 0
    }

    $catalogRows = @(Import-Csv -LiteralPath $CatalogPath -Encoding UTF8)
    $moved = 0

    foreach ($videoFile in (Get-ChildItem -LiteralPath $VideosDirectory -File -ErrorAction SilentlyContinue)) {
        $audioState = Test-HasAudioStream -VideoPath $videoFile.FullName

        if ($null -eq $audioState -or $audioState) {
            continue
        }

        $row = $catalogRows |
            Where-Object { [string]$_.filename -eq $videoFile.Name } |
            Select-Object -First 1

        if ($null -eq $row -or [string]::IsNullOrWhiteSpace([string]$row.video_id)) {
            Write-Status "Silent file found but no catalog mapping exists: $($videoFile.Name)" Yellow
            continue
        }

        $videoId = [string]$row.video_id
        $rawDestination = Join-Path $RawDirectory ("{0}{1}" -f $videoId, $videoFile.Extension)

        try {
            Get-ChildItem -LiteralPath $RawDirectory -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -eq $videoId } |
                Remove-Item -Force -ErrorAction SilentlyContinue

            Move-Item -LiteralPath $videoFile.FullName -Destination $rawDestination -Force

            $metadataSource = Join-Path $MetadataDirectory ("{0}.info.json" -f $videoId)
            $metadataDestination = Join-Path $RawDirectory ("{0}.info.json" -f $videoId)

            if (Test-Path -LiteralPath $metadataSource) {
                Copy-Item -LiteralPath $metadataSource -Destination $metadataDestination -Force
            }
            else {
                $minimalMetadata = [ordered]@{
                    id          = $videoId
                    description = [string]$row.full_description
                    webpage_url = if ([string]::IsNullOrWhiteSpace([string]$row.source_url)) {
                        "https://www.tiktok.com/@$Username/video/$videoId"
                    }
                    else {
                        [string]$row.source_url
                    }
                    upload_date = ([string]$row.date -replace "-", "")
                    ext         = $videoFile.Extension.TrimStart(".")
                }

                $minimalMetadata |
                    ConvertTo-Json -Depth 5 |
                    Set-Content -LiteralPath $metadataDestination -Encoding UTF8
            }

            $moved++
            Write-Status "Queued existing silent file for repair: $($videoFile.Name)" Yellow
        }
        catch {
            Write-Status "Could not queue silent file for repair: $($videoFile.Name)" Red
        }
    }

    return $moved
}

function Repair-SilentRawVideos {
    param(
        [string]$Username,
        [object]$Method,
        [string]$RawDirectory,
        [string]$RetryRoot,
        [string]$SilentDirectory,
        [string]$ArchivePath,
        [string]$DownloadLog,
        [int]$RetryCount
    )

    $repairInfoById = @{}
    $failureEntries = New-Object System.Collections.Generic.List[object]
    $repaired = 0
    $quarantined = 0

    New-Item -ItemType Directory -Force -Path $RetryRoot, $SilentDirectory | Out-Null

    $infoFiles = @(
        Get-ChildItem -LiteralPath $RawDirectory -Filter "*.info.json" -File -ErrorAction SilentlyContinue
    )

    foreach ($infoFile in $infoFiles) {
        try {
            $metadata = Get-Content -LiteralPath $infoFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-Status "Could not inspect metadata for audio repair: $($infoFile.Name)" Yellow
            continue
        }

        $videoId = [string]$metadata.id
        $preferredExtension = [string]$metadata.ext
        $rawVideo = Find-RawVideo `
            -RawDirectory $RawDirectory `
            -VideoId $videoId `
            -PreferredExtension $preferredExtension

        if ($null -eq $rawVideo) {
            continue
        }

        $audioState = Test-HasAudioStream -VideoPath $rawVideo.FullName

        if ($null -eq $audioState) {
            continue
        }

        if ($audioState) {
            continue
        }

        Write-Status ""
        Write-Status "No audio stream detected: $($rawVideo.Name)" Red
        Write-Status "Retrying the same highest-quality, non-watermarked selection. No H.264 fallback." Yellow

        $sourceUrl = [string]$metadata.webpage_url

        if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
            $sourceUrl = "https://www.tiktok.com/@$Username/video/$videoId"
        }

        $hashes = New-Object System.Collections.Generic.List[string]
        $initialHash = Get-SafeFileHash -Path $rawVideo.FullName

        if (-not [string]::IsNullOrWhiteSpace($initialHash)) {
            $hashes.Add($initialHash)
            Write-Status "Initial silent SHA-256: $initialHash" DarkGray
        }

        $repairSucceeded = $false
        $successfulAttempt = 0

        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            $attemptDirectory = Join-Path $RetryRoot ("{0}\attempt-{1}" -f $videoId, $attempt)

            $exitCode = Invoke-SingleVideoDownload `
                -Method $Method `
                -VideoUrl $sourceUrl `
                -RetryDirectory $attemptDirectory `
                -DownloadLog $DownloadLog `
                -Attempt $attempt

            $retryVideo = Find-RawVideo `
                -RawDirectory $attemptDirectory `
                -VideoId $videoId `
                -PreferredExtension ""

            if ($exitCode -ne 0 -or $null -eq $retryVideo) {
                Write-Status "Retry $attempt did not produce a complete video file." Yellow
                continue
            }

            $retryHash = Get-SafeFileHash -Path $retryVideo.FullName

            if (-not [string]::IsNullOrWhiteSpace($retryHash)) {
                $hashes.Add($retryHash)
                Write-Status "Retry $attempt SHA-256: $retryHash" DarkGray
            }

            $retryAudioState = Test-HasAudioStream -VideoPath $retryVideo.FullName

            if ($null -eq $retryAudioState) {
                Write-Status "Retry $attempt could not be verified by FFprobe." Yellow
                continue
            }

            if (-not $retryAudioState) {
                Write-Status "Retry $attempt is still silent." Yellow
                continue
            }

            Get-ChildItem -LiteralPath $RawDirectory -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.BaseName -eq $videoId -and
                    $_.Name -notlike "*.info.json"
                } |
                Remove-Item -Force -ErrorAction SilentlyContinue

            $replacementPath = Join-Path $RawDirectory $retryVideo.Name
            Move-Item -LiteralPath $retryVideo.FullName -Destination $replacementPath -Force

            $retryInfo = Join-Path $attemptDirectory ("{0}.info.json" -f $videoId)

            if (Test-Path -LiteralPath $retryInfo) {
                Move-Item -LiteralPath $retryInfo -Destination $infoFile.FullName -Force
            }

            $repairSucceeded = $true
            $successfulAttempt = $attempt
            $repaired++
            Write-Status "Audio verified after retry $attempt." Green
            break
        }

        $hashSummary = $hashes -join "|"

        if ($repairSucceeded) {
            $repairInfoById[$videoId] = [pscustomobject]@{
                Status     = "repaired_audio_after_retry_$successfulAttempt"
                RetryCount = $successfulAttempt
                Hashes     = $hashSummary
            }

            continue
        }

        $currentRawVideo = Find-RawVideo `
            -RawDirectory $RawDirectory `
            -VideoId $videoId `
            -PreferredExtension $preferredExtension

        $quarantineFilename = ""

        if ($null -ne $currentRawVideo) {
            $quarantineFilename = "{0}{1}" -f $videoId, $currentRawVideo.Extension
            $quarantinePath = Join-Path $SilentDirectory $quarantineFilename

            if (Test-Path -LiteralPath $quarantinePath) {
                $quarantineFilename = "{0}_{1}{2}" -f $videoId, (Get-Date -Format "yyyyMMdd_HHmmss"), $currentRawVideo.Extension
                $quarantinePath = Join-Path $SilentDirectory $quarantineFilename
            }

            Move-Item -LiteralPath $currentRawVideo.FullName -Destination $quarantinePath -Force
        }

        $quarantineInfo = Join-Path $SilentDirectory ("{0}.info.json" -f $videoId)
        Move-Item -LiteralPath $infoFile.FullName -Destination $quarantineInfo -Force

        Remove-ArchiveEntry -ArchivePath $ArchivePath -VideoId $videoId

        $date = Get-DateFromMetadata -Metadata $metadata
        $description = [string]$metadata.description
        $sourceUrl = [string]$metadata.webpage_url

        if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
            $sourceUrl = "https://www.tiktok.com/@$Username/video/$videoId"
        }

        $failureEntries.Add([pscustomobject]@{
            date              = $date
            username          = "@$Username"
            video_id          = $videoId
            filename          = if ([string]::IsNullOrWhiteSpace($quarantineFilename)) { "" } else { "_silent\$quarantineFilename" }
            full_description  = $description
            source_url        = $sourceUrl
            downloaded_at     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            status            = "silent_after_retries"
            audio_status      = "missing"
            audio_retry_count = $RetryCount
            silent_hashes     = $hashSummary
        })

        $quarantined++
        Write-Status "Still silent after $RetryCount retries; moved to _silent and removed from the archive." Red
    }

    if (Test-Path -LiteralPath $RetryRoot) {
        Remove-Item -LiteralPath $RetryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Repaired       = $repaired
        Quarantined    = $quarantined
        RepairInfoById = $repairInfoById
        FailureEntries = $failureEntries
    }
}


$transcriptStarted = $false

try {
    Write-Status "TikTok Profile Backup" Magenta
    Write-Status "Version 1.1.0" DarkGray
    Write-Status ""

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        $Profile = Read-Host "Paste a TikTok profile link, @username, or username"
    }

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw "No TikTok profile was provided."
    }

    $normalized = Get-NormalizedProfile -InputProfile $Profile
    $username = [string]$normalized.Username
    $profileUrl = [string]$normalized.Url

    $profileDirectory = Join-Path $OutputRoot ("@{0}" -f $username)
    $videosDirectory = Join-Path $profileDirectory "videos"
    $rawDirectory = Join-Path $profileDirectory "_raw"
    $metadataDirectory = Join-Path $profileDirectory "_metadata"
    $logsDirectory = Join-Path $profileDirectory "_logs"
    $retryRoot = Join-Path $profileDirectory "_retry"
    $silentDirectory = Join-Path $profileDirectory "_silent"
    $archivePath = Join-Path $profileDirectory "download_archive.txt"
    $catalogPath = Join-Path $profileDirectory "catalog.csv"

    New-Item -ItemType Directory -Force -Path `
        $ToolDir,
        $OutputRoot,
        $profileDirectory,
        $videosDirectory,
        $rawDirectory,
        $metadataDirectory,
        $logsDirectory,
        $silentDirectory | Out-Null

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $downloadLog = Join-Path $logsDirectory "yt-dlp_$timestamp.log"
    $transcriptLog = Join-Path $logsDirectory "session_$timestamp.log"

    try {
        Start-Transcript -LiteralPath $transcriptLog -Append | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Status "Session transcript could not be started; continuing." Yellow
    }

    Write-Status "Profile: @$username" Green
    Write-Status "URL:     $profileUrl" DarkGray
    Write-Status "Folder:  $profileDirectory" DarkGray
    Write-Status "Policy:  highest available quality, formats marked watermarked excluded" DarkGray
    Write-Status "Codec:   unrestricted; H.264 is not forced" DarkGray
    Write-Status ""

    Install-OrUpdateYtDlp

    # FFmpeg is also needed when yt-dlp has to merge the highest-quality
    # video and audio streams, so it is installed even when probing is disabled.
    Install-FfmpegTools

    $methods = @(Get-DownloadMethods -RequestedBrowser $Browser)

    if ($methods.Count -eq 0) {
        throw "No download method is available."
    }

    $archiveHadEntries = $false

    if (Test-Path -LiteralPath $archivePath) {
        $archiveHadEntries = (Get-Item -LiteralPath $archivePath).Length -gt 0
    }

    $downloadAttemptSucceeded = $false
    $activeMethod = $methods[0]

    foreach ($method in $methods) {
        $activeMethod = $method

        $beforeMetadataCount = @(
            Get-ChildItem -LiteralPath $rawDirectory -Filter "*.info.json" -File -ErrorAction SilentlyContinue
        ).Count

        $exitCode = Invoke-ProfileDownload `
            -Method $method `
            -ProfileUrl $profileUrl `
            -RawDirectory $rawDirectory `
            -ArchivePath $archivePath `
            -DownloadLog $downloadLog

        $afterMetadataCount = @(
            Get-ChildItem -LiteralPath $rawDirectory -Filter "*.info.json" -File -ErrorAction SilentlyContinue
        ).Count

        if ($afterMetadataCount -gt $beforeMetadataCount) {
            $downloadAttemptSucceeded = $true
            break
        }

        if ($exitCode -eq 0 -and $archiveHadEntries) {
            Write-Status "No new videos were found." Green
            $downloadAttemptSucceeded = $true
            break
        }

        Write-Status "That method returned no new video metadata. Trying the next method..." Yellow
    }

    $existingSilentQueued = 0

    if (-not $SkipAudioCheck -and -not $SkipExistingAudioScan) {
        Write-Status ""
        Write-Status "Scanning existing videos for missing audio streams..." Cyan

        $existingSilentQueued = Move-ExistingSilentVideosToRaw `
            -Username $username `
            -VideosDirectory $videosDirectory `
            -RawDirectory $rawDirectory `
            -MetadataDirectory $metadataDirectory `
            -CatalogPath $catalogPath
    }

    $repairResult = [pscustomobject]@{
        Repaired       = 0
        Quarantined    = 0
        RepairInfoById = @{}
        FailureEntries = @()
    }

    if (-not $SkipAudioCheck) {
        Write-Status ""
        Write-Status "Checking downloaded files for an actual audio stream..." Cyan

        $repairResult = Repair-SilentRawVideos `
            -Username $username `
            -Method $activeMethod `
            -RawDirectory $rawDirectory `
            -RetryRoot $retryRoot `
            -SilentDirectory $silentDirectory `
            -ArchivePath $archivePath `
            -DownloadLog $downloadLog `
            -RetryCount $SilentRetryCount
    }

    Write-Status ""
    Write-Status "Applying requested filenames..." Cyan

    $renameResult = Rename-DownloadedVideos `
        -Username $username `
        -RawDirectory $rawDirectory `
        -VideosDirectory $videosDirectory `
        -MetadataDirectory $metadataDirectory `
        -CatalogPath $catalogPath `
        -RepairInfoById $repairResult.RepairInfoById

    $catalogEntries = @()
    $catalogEntries += @($renameResult.Entries)
    $catalogEntries += @($repairResult.FailureEntries)

    Update-Catalog -CatalogPath $catalogPath -NewEntries $catalogEntries

    $videoCount = @(
        Get-ChildItem -LiteralPath $videosDirectory -File -ErrorAction SilentlyContinue
    ).Count

    Write-Status ""
    Write-Status "Finished." Green
    Write-Status "Videos in this profile backup: $videoCount" Green
    Write-Status "New or repaired videos saved this run: $($renameResult.Renamed)" Green

    if (-not $SkipAudioCheck) {
        Write-Status "Existing silent videos queued: $existingSilentQueued" DarkGray
        Write-Status "Silent downloads repaired: $($repairResult.Repaired)" Green
        Write-Status "Still silent and quarantined: $($repairResult.Quarantined)" Yellow
    }

    Write-Status "Video folder: $videosDirectory" Cyan

    if (Test-Path -LiteralPath $catalogPath) {
        Write-Status "Catalog:      $catalogPath" Cyan
    }

    Write-Status "Logs:         $logsDirectory" DarkGray

    if ($repairResult.Quarantined -gt 0) {
        Write-Status "Silent files: $silentDirectory" Yellow
        Write-Status "Their IDs were removed from download_archive.txt, so a later run can try again." Yellow
    }

    if (-not $downloadAttemptSucceeded -and $renameResult.Renamed -eq 0 -and $repairResult.Quarantined -eq 0) {
        Write-Status ""
        Write-Status "TikTok returned no downloadable profile data." Red
        Write-Status "Confirm the profile is public and opens in your browser." Yellow
        Write-Status "Log into TikTok, close the browser, and run the script again." Yellow
        Write-Status "You can also place a Netscape-format cookies.txt beside this script." Yellow
        exit 2
    }

    if ($renameResult.Missing -gt 0) {
        Write-Status "Items needing attention: $($renameResult.Missing)" Yellow
    }
}
catch {
    Write-Status ""
    Write-Status "Fatal error: $($_.Exception.Message)" Red
    exit 1
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {}
    }

    Write-Status ""
}
