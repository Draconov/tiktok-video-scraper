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

    [switch]$SkipUpdate
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
$CookiesFile = Join-Path $ScriptRoot "cookies.txt"

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

    $allEntries = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $CatalogPath) {
        try {
            foreach ($row in (Import-Csv -LiteralPath $CatalogPath -Encoding UTF8)) {
                $allEntries.Add($row)
            }
        }
        catch {
            Write-Status "Existing catalog.csv could not be read; rebuilding it from new entries." Yellow
        }
    }

    foreach ($entry in $NewEntries) {
        $existingIndex = -1

        for ($index = 0; $index -lt $allEntries.Count; $index++) {
            if ([string]$allEntries[$index].video_id -eq [string]$entry.video_id) {
                $existingIndex = $index
                break
            }
        }

        if ($existingIndex -ge 0) {
            $allEntries[$existingIndex] = $entry
        }
        else {
            $allEntries.Add($entry)
        }
    }

    if ($allEntries.Count -gt 0) {
        $allEntries |
            Sort-Object date, video_id |
            Export-Csv -LiteralPath $CatalogPath -NoTypeInformation -Encoding UTF8
    }
}

function Rename-DownloadedVideos {
    param(
        [string]$Username,
        [string]$RawDirectory,
        [string]$VideosDirectory,
        [string]$MetadataDirectory,
        [string]$CatalogPath
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

        if ($null -eq $rawVideo) {
            $missing++
            $status = "video file missing"
            Write-Status "Metadata exists but the video file is missing: $videoId" Yellow
        }
        else {
            try {
                Move-Item -LiteralPath $rawVideo.FullName -Destination $destination
                $renamed++
                Write-Status ("Saved: {0}" -f [IO.Path]::GetFileName($destination)) Green
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
            date             = $date
            username         = "@$Username"
            video_id         = $videoId
            filename         = if ($null -ne $rawVideo) { [IO.Path]::GetFileName($destination) } else { "" }
            full_description = $captionOriginal
            source_url       = $webpageUrl
            downloaded_at    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            status           = $status
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

    switch ($Method.Type) {
        "cookies-file" {
            $arguments += @("--cookies", $Method.Value)
        }
        "browser" {
            $arguments += @("--cookies-from-browser", $Method.Value)
        }
    }

    $arguments += $ProfileUrl

    Write-Status ""
    Write-Status "Trying $($Method.Label)..." Cyan
    Write-Status "Close that browser first if cookie extraction fails." DarkGray
    Write-Status ""

    $savedPreference = $ErrorActionPreference
    $exitCode = 1

    try {
        # yt-dlp writes both warnings and real errors to stderr. They must remain
        # visible without PowerShell treating every warning as a fatal exception.
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

$transcriptStarted = $false

try {
    Write-Status "TikTok Profile Backup" Magenta
    Write-Status "Version 1.0.0" DarkGray
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
    $archivePath = Join-Path $profileDirectory "download_archive.txt"
    $catalogPath = Join-Path $profileDirectory "catalog.csv"

    New-Item -ItemType Directory -Force -Path `
        $ToolDir,
        $OutputRoot,
        $profileDirectory,
        $videosDirectory,
        $rawDirectory,
        $metadataDirectory,
        $logsDirectory | Out-Null

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
    Write-Status ""

    Install-OrUpdateYtDlp

    $methods = @(Get-DownloadMethods -RequestedBrowser $Browser)

    if ($methods.Count -eq 0) {
        throw "No download method is available."
    }

    $archiveHadEntries = $false

    if (Test-Path -LiteralPath $archivePath) {
        $archiveHadEntries = (Get-Item -LiteralPath $archivePath).Length -gt 0
    }

    $downloadAttemptSucceeded = $false

    foreach ($method in $methods) {
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

    Write-Status ""
    Write-Status "Applying requested filenames..." Cyan

    $renameResult = Rename-DownloadedVideos `
        -Username $username `
        -RawDirectory $rawDirectory `
        -VideosDirectory $videosDirectory `
        -MetadataDirectory $metadataDirectory `
        -CatalogPath $catalogPath

    Update-Catalog -CatalogPath $catalogPath -NewEntries $renameResult.Entries

    $videoCount = @(
        Get-ChildItem -LiteralPath $videosDirectory -File -ErrorAction SilentlyContinue
    ).Count

    Write-Status ""
    Write-Status "Finished." Green
    Write-Status "Videos in this profile backup: $videoCount" Green
    Write-Status "New videos saved this run: $($renameResult.Renamed)" Green
    Write-Status "Video folder: $videosDirectory" Cyan

    if (Test-Path -LiteralPath $catalogPath) {
        Write-Status "Catalog:      $catalogPath" Cyan
    }

    Write-Status "Logs:         $logsDirectory" DarkGray

    if (-not $downloadAttemptSucceeded -and $renameResult.Renamed -eq 0) {
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
