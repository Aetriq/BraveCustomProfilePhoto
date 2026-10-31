<#
.SYNOPSIS
    Import your own photo as a Brave browser profile avatar.

.DESCRIPTION
    Brave only lets you pick from its built-in avatar icons. Under the hood,
    though, Brave is built on Chromium, and Chromium can show a per-profile
    photo ("Google Profile Picture.png" in the profile folder). Chrome fills
    that slot from your Google account; Brave switches that sync service off,
    so a photo placed there by this tool stays put.

    The tool:
      * crops/resizes your image to a square PNG (EXIF rotation respected),
      * writes it into the profile folder,
      * flips the matching switches in "Local State" and the profile's
        "Preferences" (only those keys - every other byte is left untouched),
      * backs both files up first, under "User Data\Custom Avatar Backups".

    Brave must be fully closed while the change is written, because Brave
    rewrites "Local State" when it exits. The tool can close it for you.

    Run with no arguments for the window, or use -List / -Image / -Remove
    from a console.

.EXAMPLE
    .\Brave-CustomAvatar.ps1
    Opens the window: pick a profile, choose a photo, adjust, Apply.

.EXAMPLE
    .\Brave-CustomAvatar.ps1 -List

.EXAMPLE
    .\Brave-CustomAvatar.ps1 -ProfileName "Personal" -Image C:\Pics\me.jpg -CloseBrave

.EXAMPLE
    .\Brave-CustomAvatar.ps1 -ProfileName "Profile 2" -Image .\logo.png -Mode Fit

.EXAMPLE
    .\Brave-CustomAvatar.ps1 -ProfileName "Personal" -Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    # Image file to import (PNG, JPEG, BMP, GIF, TIFF; WebP/HEIC if Windows has the codec).
    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [string]$Image,

    # Profile display name ("Personal") or folder name ("Default", "Profile 1").
    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Remove', Mandatory = $true)]
    [string]$ProfileName,

    # Remove the custom photo and go back to the built-in avatar.
    [Parameter(ParameterSetName = 'Remove', Mandatory = $true)]
    [switch]$Remove,

    # List profiles and whether each has a custom photo.
    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List,

    # Brave "User Data" folder. Defaults to the standard location for -Channel.
    [string]$UserDataDir,

    [ValidateSet('Stable', 'Beta', 'Nightly')]
    [string]$Channel = 'Stable',

    # Fill = crop to a square that fills the circle. Fit = keep the whole image.
    [Parameter(ParameterSetName = 'Set')]
    [ValidateSet('Fill', 'Fit')]
    [string]$Mode = 'Fill',

    # 1.0 - 4.0. Zooms in on the image before cropping.
    [Parameter(ParameterSetName = 'Set')]
    [ValidateRange(1.0, 4.0)]
    [double]$Zoom = 1.0,

    # Crop position, 0 = left edge, 0.5 = centre, 1 = right edge.
    [Parameter(ParameterSetName = 'Set')]
    [ValidateRange(0.0, 1.0)]
    [double]$FocusX = 0.5,

    # Crop position, 0 = top, 0.5 = centre, 1 = bottom.
    [Parameter(ParameterSetName = 'Set')]
    [ValidateRange(0.0, 1.0)]
    [double]$FocusY = 0.5,

    # Output size in pixels (square).
    [ValidateRange(64, 1024)]
    [int]$Size = 256,

    # Close Brave automatically if it is running (console mode).
    [switch]$CloseBrave
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Chromium constants (chrome/browser/profiles/*).
$script:AvatarFileName = 'Google Profile Picture.png'   # profiles::kGAIAPictureFileName
$script:PlaceholderAvatarIndex = 26                     # kPlaceholderAvatarIndex (desktop)
$script:CustomUrlMarker = 'brave-custom-avatar'         # any non-empty value; see Invoke-AvatarChange
$script:BraveExe = $null

# ---------------------------------------------------------------------------
# Minimal JSON scanner.
#
# Brave's settings files are edited in place: only the values we change are
# rewritten, everything else stays byte-for-byte identical. That avoids the
# well-known round-trip problems of ConvertFrom-Json/ConvertTo-Json in
# Windows PowerShell 5.1 (depth truncation, re-escaping, number formatting,
# case-insensitive duplicate keys).
# ---------------------------------------------------------------------------

$script:JsonNumberRx = New-Object System.Text.RegularExpressions.Regex '\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'

function New-JsonError([int]$Pos, [string]$Message) {
    return (New-Object System.FormatException ("Invalid JSON at offset {0}: {1}" -f $Pos, $Message))
}

function Skip-JsonWs([string]$s, [int]$i) {
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -ceq ' ' -or $c -ceq "`t" -or $c -ceq "`n" -or $c -ceq "`r") { $i++ } else { break }
    }
    return $i
}

# $s[$i] is the opening quote. Returns the index just past the closing quote.
function Skip-JsonString([string]$s, [int]$i) {
    $j = $i + 1
    while ($true) {
        $q = $s.IndexOf([char]'"', $j)
        if ($q -lt 0) { throw (New-JsonError $i 'unterminated string') }
        $k = $q - 1
        $backslashes = 0
        while ($k -gt $i -and $s[$k] -ceq '\') { $backslashes++; $k-- }
        if (($backslashes % 2) -eq 0) { return ($q + 1) }
        $j = $q + 1
    }
}

function ConvertFrom-JsonStringLiteral([string]$raw) {
    $body = $raw.Substring(1, $raw.Length - 2)
    if ($body.IndexOf('\') -lt 0) { return $body }
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $body.Length) {
        $c = $body[$i]
        if ($c -cne '\') { [void]$sb.Append($c); $i++; continue }
        $n = [string]$body[$i + 1]
        switch -CaseSensitive ($n) {
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            '/' { [void]$sb.Append('/') }
            'b' { [void]$sb.Append([char]8) }
            'f' { [void]$sb.Append([char]12) }
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            'u' {
                [void]$sb.Append([char][Convert]::ToInt32($body.Substring($i + 2, 4), 16))
                $i += 4
            }
            default { throw (New-JsonError $i ("bad escape \" + $n)) }
        }
        $i += 2
    }
    return $sb.ToString()
}

function ConvertTo-JsonStringLiteral([string]$value) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $value.ToCharArray()) {
        $code = [int]$ch
        if ($ch -ceq '"') { [void]$sb.Append('\"') }
        elseif ($ch -ceq '\') { [void]$sb.Append('\\') }
        elseif ($code -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JsonBool([bool]$value) {
    if ($value) { return 'true' } else { return 'false' }
}

# Parses (and validates) the object starting at $s[$i] == '{'.
# Returns @{ Open; End; Members = List of @{ Key; KeyStart; ValueStart; ValueEnd } }.
function Get-JsonObjectInfo([string]$s, [int]$i) {
    $i = Skip-JsonWs $s $i
    if ($i -ge $s.Length -or $s[$i] -cne '{') { throw (New-JsonError $i 'expected an object') }
    $open = $i
    $members = New-Object System.Collections.Generic.List[object]
    $i = Skip-JsonWs $s ($i + 1)
    if ($i -lt $s.Length -and $s[$i] -ceq '}') {
        return [pscustomobject]@{ Open = $open; End = $i + 1; Members = $members }
    }
    while ($true) {
        if ($i -ge $s.Length -or $s[$i] -cne '"') { throw (New-JsonError $i 'expected a key') }
        $keyStart = $i
        $keyEnd = Skip-JsonString $s $i
        $key = ConvertFrom-JsonStringLiteral $s.Substring($keyStart, $keyEnd - $keyStart)
        $i = Skip-JsonWs $s $keyEnd
        if ($i -ge $s.Length -or $s[$i] -cne ':') { throw (New-JsonError $i "expected ':'") }
        $valueStart = Skip-JsonWs $s ($i + 1)
        $valueEnd = Skip-JsonValue $s $valueStart
        $members.Add([pscustomobject]@{ Key = $key; KeyStart = $keyStart; ValueStart = $valueStart; ValueEnd = $valueEnd })
        $i = Skip-JsonWs $s $valueEnd
        if ($i -ge $s.Length) { throw (New-JsonError $i 'unterminated object') }
        if ($s[$i] -ceq ',') { $i = Skip-JsonWs $s ($i + 1); continue }
        if ($s[$i] -ceq '}') { return [pscustomobject]@{ Open = $open; End = $i + 1; Members = $members } }
        throw (New-JsonError $i "expected ',' or '}'")
    }
}

function Skip-JsonArray([string]$s, [int]$i) {
    $i = Skip-JsonWs $s ($i + 1)
    if ($i -lt $s.Length -and $s[$i] -ceq ']') { return ($i + 1) }
    while ($true) {
        $i = Skip-JsonValue $s $i
        $i = Skip-JsonWs $s $i
        if ($i -ge $s.Length) { throw (New-JsonError $i 'unterminated array') }
        if ($s[$i] -ceq ',') { $i = Skip-JsonWs $s ($i + 1); continue }
        if ($s[$i] -ceq ']') { return ($i + 1) }
        throw (New-JsonError $i "expected ',' or ']'")
    }
}

# Validates the value at $s[$i] and returns the index just past it.
function Skip-JsonValue([string]$s, [int]$i) {
    $i = Skip-JsonWs $s $i
    if ($i -ge $s.Length) { throw (New-JsonError $i 'unexpected end of data') }
    $c = $s[$i]
    if ($c -ceq '"') { return (Skip-JsonString $s $i) }
    if ($c -ceq '{') { return (Get-JsonObjectInfo $s $i).End }
    if ($c -ceq '[') { return (Skip-JsonArray $s $i) }
    foreach ($literal in @('true', 'false', 'null')) {
        if (($i + $literal.Length) -le $s.Length -and
            [string]::CompareOrdinal($s, $i, $literal, 0, $literal.Length) -eq 0) {
            return ($i + $literal.Length)
        }
    }
    $m = $script:JsonNumberRx.Match($s, $i)
    if ($m.Success -and $m.Length -gt 0) { return ($i + $m.Length) }
    throw (New-JsonError $i 'unexpected character')
}

function Test-JsonDocument([string]$s) {
    $end = Skip-JsonWs $s (Skip-JsonValue $s 0)
    if ($end -ne $s.Length) { throw (New-JsonError $end 'trailing data after the document') }
}

# Returns the start offset of the value at $Path (array of keys), or $null.
function Find-JsonPath([string]$s, [string[]]$Path) {
    $pos = Skip-JsonWs $s 0
    foreach ($key in $Path) {
        if ($pos -ge $s.Length -or $s[$pos] -cne '{') { return $null }
        $found = $null
        foreach ($m in (Get-JsonObjectInfo $s $pos).Members) {
            if ($m.Key -ceq $key) { $found = $m; break }
        }
        if ($null -eq $found) { return $null }
        $pos = $found.ValueStart
    }
    return $pos
}

# Decodes a scalar at $start (string/bool/null/number). Objects/arrays come back as raw text.
function Read-JsonValueAt([string]$s, [int]$start) {
    $end = Skip-JsonValue $s $start
    $raw = $s.Substring($start, $end - $start)
    $c = $s[$start]
    if ($c -ceq '"') { return (ConvertFrom-JsonStringLiteral $raw) }
    if ($raw -ceq 'true') { return $true }
    if ($raw -ceq 'false') { return $false }
    if ($raw -ceq 'null') { return $null }
    if ($c -ceq '{' -or $c -ceq '[') { return $raw }
    return [double]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)
}

# Sets (replaces or inserts) members of the object at $objStart.
# $Values maps key -> raw JSON text (e.g. 'true', '"text"', '0').
function Set-JsonMembers([string]$s, [int]$objStart, [System.Collections.IDictionary]$Values) {
    foreach ($key in @($Values.Keys)) {
        $raw = [string]$Values[$key]
        $obj = Get-JsonObjectInfo $s $objStart
        $existing = $null
        foreach ($m in $obj.Members) { if ($m.Key -ceq $key) { $existing = $m; break } }
        if ($null -ne $existing) {
            $s = $s.Substring(0, $existing.ValueStart) + $raw + $s.Substring($existing.ValueEnd)
        } else {
            $insert = (ConvertTo-JsonStringLiteral $key) + ':' + $raw
            if ($obj.Members.Count -gt 0) { $insert += ',' }
            $s = $s.Substring(0, $obj.Open + 1) + $insert + $s.Substring($obj.Open + 1)
        }
    }
    return $s
}

# Makes sure every object along $Path exists (creating empty ones as needed).
function Add-JsonObjectPath([string]$s, [string[]]$Path) {
    for ($n = 1; $n -le $Path.Count; $n++) {
        $prefix = @($Path[0..($n - 1)])
        if ($null -ne (Find-JsonPath $s $prefix)) { continue }
        if ($n -eq 1) { $parentPos = Skip-JsonWs $s 0 }
        else { $parentPos = Find-JsonPath $s @($Path[0..($n - 2)]) }
        $s = Set-JsonMembers $s $parentPos ([ordered]@{ ($Path[$n - 1]) = '{}' })
    }
    return $s
}

# ---------------------------------------------------------------------------
# Files and profiles
# ---------------------------------------------------------------------------

function Read-TextFile([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextFileAtomic([string]$Path, [string]$Text) {
    $tmp = $Path + '.custom-avatar-tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    # [NullString]: PowerShell would otherwise pass "" (not null) as the backup path.
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

function Resolve-UserDataDir([string]$Explicit, [string]$Channel) {
    if ($Explicit) {
        $full = [System.IO.Path]::GetFullPath($Explicit)
        if (-not (Test-Path -LiteralPath (Join-Path $full 'Local State'))) {
            throw "No 'Local State' file in '$full'. Point -UserDataDir at Brave's 'User Data' folder."
        }
        return $full
    }
    $suffix = @{ Stable = ''; Beta = '-Beta'; Nightly = '-Nightly' }[$Channel]
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA ("BraveSoftware\Brave-Browser$suffix\User Data"))
    }
    if ($env:HOME) {
        $candidates += (Join-Path $env:HOME ".config/BraveSoftware/Brave-Browser$suffix")
        $candidates += (Join-Path $env:HOME "Library/Application Support/BraveSoftware/Brave-Browser$suffix")
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c 'Local State')) { return $c }
    }
    throw "Couldn't find Brave's profile folder (looked in: $($candidates -join '; ')). Use -UserDataDir."
}

function Get-AvatarIndex([string]$AvatarIcon) {
    if ($AvatarIcon -match 'IDR_PROFILE_AVATAR_(\d+)$') { return [int]$Matches[1] }
    return -1
}

function Get-BraveProfiles([string]$UserData) {
    $s = Read-TextFile (Join-Path $UserData 'Local State')
    $cachePos = Find-JsonPath $s @('profile', 'info_cache')
    if ($null -eq $cachePos -or $s[$cachePos] -cne '{') {
        throw "Brave's 'Local State' has no profile list (profile.info_cache)."
    }
    $wanted = @('name', 'avatar_icon', 'use_gaia_picture', 'gaia_picture_file_name', 'is_using_default_avatar')
    $result = @()
    foreach ($m in (Get-JsonObjectInfo $s $cachePos).Members) {
        if ($s[$m.ValueStart] -cne '{') { continue }
        $v = @{ name = $null; avatar_icon = ''; use_gaia_picture = $false; gaia_picture_file_name = ''; is_using_default_avatar = $true }
        foreach ($em in (Get-JsonObjectInfo $s $m.ValueStart).Members) {
            if ($wanted -ccontains $em.Key) { $v[$em.Key] = Read-JsonValueAt $s $em.ValueStart }
        }
        $dir = Join-Path $UserData $m.Key
        $pic = ''
        if ($v.gaia_picture_file_name) { $pic = Join-Path $dir ([string]$v.gaia_picture_file_name) }
        $hasPhoto = [bool]($pic -and (Test-Path -LiteralPath $pic) -and ($v.use_gaia_picture -or $v.is_using_default_avatar))
        $name = [string]$v.name
        if (-not $name) { $name = $m.Key }
        $result += [pscustomobject]@{
            Folder         = $m.Key
            Name           = $name
            Path           = $dir
            AvatarIndex    = Get-AvatarIndex ([string]$v.avatar_icon)
            HasCustomPhoto = $hasPhoto
            PhotoPath      = $pic
        }
    }
    return $result
}

function Get-LastUsedProfileFolder([string]$UserData) {
    try {
        $s = Read-TextFile (Join-Path $UserData 'Local State')
        $pos = Find-JsonPath $s @('profile', 'last_used')
        if ($null -ne $pos) { return [string](Read-JsonValueAt $s $pos) }
    } catch { }
    return $null
}

function Resolve-BraveProfile($Profiles, [string]$NameOrFolder) {
    $byFolder = @($Profiles | Where-Object { $_.Folder -ieq $NameOrFolder })
    if ($byFolder.Count -eq 1) { return $byFolder[0] }
    $byName = @($Profiles | Where-Object { $_.Name -ieq $NameOrFolder })
    if ($byName.Count -eq 1) { return $byName[0] }
    if ($byName.Count -gt 1) {
        throw "More than one profile is called '$NameOrFolder'. Use the folder name instead: $(($byName | ForEach-Object { $_.Folder }) -join ', ')"
    }
    throw "No profile called '$NameOrFolder'. Run with -List to see the profiles."
}

# Writes (or removes, when $Avatar is $null) the custom photo for $Target.
# Returns the backup folder.
function Invoke-AvatarChange([string]$UserData, $Target, $Avatar) {
    $setting = ($null -ne $Avatar)
    $lsPath = Join-Path $UserData 'Local State'
    $profileDir = Join-Path $UserData $Target.Folder
    $prefsPath = Join-Path $profileDir 'Preferences'
    $picPath = Join-Path $profileDir $script:AvatarFileName

    if (-not (Test-Path -LiteralPath $profileDir)) { throw "Profile folder '$profileDir' doesn't exist." }

    # Same state transitions Chromium's own settings page makes:
    #  - ManageProfileHandler::HandleSetProfileIconToGaiaAvatar when setting,
    #  - profiles::SetDefaultProfileAvatarIndex when going back to an icon.
    if ($setting) { $usingDefault = $false }
    else { $usingDefault = ($Target.AvatarIndex -eq $script:PlaceholderAvatarIndex) }
    if ($setting) { $fileName = $script:AvatarFileName; $marker = $script:CustomUrlMarker }
    else { $fileName = ''; $marker = '' }

    # --- Local State: profile.info_cache.<folder>
    $ls = Read-TextFile $lsPath
    Test-JsonDocument $ls
    $entryPos = Find-JsonPath $ls @('profile', 'info_cache', $Target.Folder)
    if ($null -eq $entryPos -or $ls[$entryPos] -cne '{') { throw "Profile '$($Target.Folder)' isn't listed in Local State." }
    $newLs = Set-JsonMembers $ls $entryPos ([ordered]@{
        use_gaia_picture        = ConvertTo-JsonBool $setting
        gaia_picture_file_name  = ConvertTo-JsonStringLiteral $fileName
        is_using_default_avatar = ConvertTo-JsonBool $usingDefault
        # A non-empty value makes the Windows shortcut manager regenerate the
        # profile's taskbar/desktop .ico once the photo has loaded.
        last_downloaded_gaia_picture_url_with_size = ConvertTo-JsonStringLiteral $marker
    })
    Test-JsonDocument $newLs
    $check = Find-JsonPath $newLs @('profile', 'info_cache', $Target.Folder, 'use_gaia_picture')
    if ($null -eq $check -or (Read-JsonValueAt $newLs $check) -ne $setting) { throw 'Internal error: Local State edit did not verify.' }

    # --- Preferences: profile.using_gaia_avatar etc. (kept in sync so Brave
    # doesn't flip the photo back off the next time it syncs prefs -> Local State)
    $newPrefs = $null
    if (Test-Path -LiteralPath $prefsPath) {
        $prefs = Read-TextFile $prefsPath
        Test-JsonDocument $prefs
        $withProfile = Add-JsonObjectPath $prefs @('profile')
        $pPos = Find-JsonPath $withProfile @('profile')
        $newPrefs = Set-JsonMembers $withProfile $pPos ([ordered]@{
            using_gaia_avatar    = ConvertTo-JsonBool $setting
            using_default_avatar = ConvertTo-JsonBool $usingDefault
            icon_version         = '0'   # forces the Windows profile .ico to be rebuilt
        })
        Test-JsonDocument $newPrefs
    }

    # --- Backups
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupRoot = Join-Path (Join-Path $UserData 'Custom Avatar Backups') $stamp
    $backupProfile = Join-Path $backupRoot $Target.Folder
    New-Item -ItemType Directory -Path $backupProfile -Force | Out-Null
    Copy-Item -LiteralPath $lsPath -Destination (Join-Path $backupRoot 'Local State')
    $hadPrefs = Test-Path -LiteralPath $prefsPath
    if ($hadPrefs) { Copy-Item -LiteralPath $prefsPath -Destination (Join-Path $backupProfile 'Preferences') }
    $hadPic = Test-Path -LiteralPath $picPath
    if ($hadPic) { Copy-Item -LiteralPath $picPath -Destination (Join-Path $backupProfile $script:AvatarFileName) }

    # --- Write
    try {
        if ($setting) {
            $tmpPic = $picPath + '.custom-avatar-tmp'
            Save-AvatarPng $Avatar $tmpPic
            if ([System.IO.File]::Exists($picPath)) { [System.IO.File]::Replace($tmpPic, $picPath, [NullString]::Value) }
            else { [System.IO.File]::Move($tmpPic, $picPath) }
        } elseif ($hadPic) {
            Remove-Item -LiteralPath $picPath -Force
        }
        if ($null -ne $newPrefs) { Write-TextFileAtomic $prefsPath $newPrefs }
        Write-TextFileAtomic $lsPath $newLs
    } catch {
        $err = $_
        try {
            Copy-Item -LiteralPath (Join-Path $backupRoot 'Local State') -Destination $lsPath -Force
            if ($hadPrefs) { Copy-Item -LiteralPath (Join-Path $backupProfile 'Preferences') -Destination $prefsPath -Force }
            if ($hadPic) { Copy-Item -LiteralPath (Join-Path $backupProfile $script:AvatarFileName) -Destination $picPath -Force }
            elseif (Test-Path -LiteralPath $picPath) { Remove-Item -LiteralPath $picPath -Force }
        } catch { }
        throw $err
    }
    return $backupRoot
}

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

function Initialize-Drawing {
    Add-Type -AssemblyName System.Drawing
}

# Fallback decoder for formats GDI+ can't read (WebP, HEIC, AVIF...) using the
# Windows Imaging Component codecs installed on the machine. Returns an Image or $null.
function Read-ImageViaWic([byte[]]$Bytes) {
    try {
        Add-Type -AssemblyName PresentationCore
        $in = New-Object System.IO.MemoryStream (, $Bytes)
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
            $in,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $decoder.Frames[0]
        $orientation = 1
        try {
            $q = $frame.Metadata.GetQuery('System.Photo.Orientation')
            if ($null -ne $q) { $orientation = [int]$q }
        } catch { }
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($frame))
        $out = New-Object System.IO.MemoryStream
        $encoder.Save($out)
        $out.Position = 0
        $img = [System.Drawing.Image]::FromStream($out)
        $bmp = New-Object System.Drawing.Bitmap $img
        $img.Dispose()
        $out.Dispose()
        $in.Dispose()
        Invoke-Orientation $bmp $orientation
        return $bmp
    } catch {
        return $null
    }
}

function Invoke-Orientation([System.Drawing.Image]$Img, [int]$Orientation) {
    $flip = switch ($Orientation) {
        2 { 'RotateNoneFlipX' }
        3 { 'Rotate180FlipNone' }
        4 { 'Rotate180FlipX' }
        5 { 'Rotate90FlipX' }
        6 { 'Rotate90FlipNone' }
        7 { 'Rotate270FlipX' }
        8 { 'Rotate270FlipNone' }
        default { $null }
    }
    if ($flip) { $Img.RotateFlip([System.Drawing.RotateFlipType]$flip) }
}

# Loads an image file into a 32-bit bitmap, upright (EXIF orientation applied)
# and capped at $MaxSide pixels on the long edge.
function Read-SourceImage([string]$Path, [int]$MaxSide = 3000) {
    Initialize-Drawing
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $stream = New-Object System.IO.MemoryStream (, $bytes)
    $img = $null
    try {
        try { $img = [System.Drawing.Image]::FromStream($stream, $true, $true) } catch { $img = $null }
        if ($null -ne $img) {
            if (@($img.PropertyIdList) -contains 0x0112) {
                $prop = $img.GetPropertyItem(0x0112)
                Invoke-Orientation $img ([int][BitConverter]::ToUInt16($prop.Value, 0))
            }
        } else {
            $img = Read-ImageViaWic $bytes
        }
        if ($null -eq $img) {
            throw "Couldn't read '$Path' as an image. Try saving it as PNG or JPEG first."
        }
        return (New-ScaledCopy $img $MaxSide)
    } finally {
        if ($null -ne $img) { $img.Dispose() }
        $stream.Dispose()
    }
}

# Kept separate so Invoke-AvatarChange (and -Remove) never touches System.Drawing types.
function Save-AvatarPng($Bitmap, [string]$Path) {
    $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
}

function Set-HighQuality([System.Drawing.Graphics]$G) {
    $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $G.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $G.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
}

function New-ScaledCopy([System.Drawing.Image]$Img, [int]$MaxSide) {
    $scale = [Math]::Min(1.0, $MaxSide / [double][Math]::Max($Img.Width, $Img.Height))
    $w = [Math]::Max(1, [int][Math]::Round($Img.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Round($Img.Height * $scale))
    $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $attr = New-Object System.Drawing.Imaging.ImageAttributes
    try {
        Set-HighQuality $g
        $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $g.DrawImage($Img, (New-Object System.Drawing.Rectangle 0, 0, $w, $h),
            0, 0, $Img.Width, $Img.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
    } finally {
        $attr.Dispose()
        $g.Dispose()
    }
    return $bmp
}

# Renders the square avatar. Fill scales the short side to the square, Fit the
# long side; Zoom enlarges further; FocusX/FocusY place the image (0..1).
function New-AvatarBitmap([System.Drawing.Image]$Source, [int]$Size, [string]$Mode, [double]$Zoom, [double]$FocusX, [double]$FocusY) {
    $w = [double]$Source.Width
    $h = [double]$Source.Height
    if ($Mode -eq 'Fit') { $scale = $Size * $Zoom / [Math]::Max($w, $h) }
    else { $scale = $Size * $Zoom / [Math]::Min($w, $h) }
    $dw = $w * $scale
    $dh = $h * $scale
    $dx = ($Size - $dw) * $FocusX
    $dy = ($Size - $dh) * $FocusY
    $dest = New-Object System.Drawing.Rectangle ([int][Math]::Round($dx)), ([int][Math]::Round($dy)), ([int][Math]::Max(1, [Math]::Round($dw))), ([int][Math]::Max(1, [Math]::Round($dh)))

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $attr = New-Object System.Drawing.Imaging.ImageAttributes
    try {
        Set-HighQuality $g
        $g.Clear([System.Drawing.Color]::Transparent)
        $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $g.DrawImage($Source, $dest, 0, 0, $Source.Width, $Source.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
    } finally {
        $attr.Dispose()
        $g.Dispose()
    }
    return $bmp
}

# ---------------------------------------------------------------------------
# Brave process handling
# ---------------------------------------------------------------------------

function Get-BraveProcesses {
    return , @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue)
}

function Find-BraveExe {
    if ($script:BraveExe -and (Test-Path -LiteralPath $script:BraveExe)) { return $script:BraveExe }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ }
    foreach ($r in $roots) {
        $p = Join-Path $r 'BraveSoftware\Brave-Browser\Application\brave.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# Closes every Brave window, waits for Brave to exit, then ends any leftover
# background processes. Returns $true when no brave process is left.
function Close-Brave([int]$TimeoutSeconds = 20) {
    foreach ($p in (Get-BraveProcesses)) {
        try { if ($p.Path) { $script:BraveExe = $p.Path; break } } catch { }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $procs = Get-BraveProcesses
        if ($procs.Count -eq 0) { return $true }
        $windows = @($procs | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
        if ($windows.Count -eq 0) { break }
        foreach ($p in $windows) { try { [void]$p.CloseMainWindow() } catch { } }
        Start-Sleep -Milliseconds 700
    }
    # Give the browser process a few seconds to finish its own shutdown.
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline -and (Get-BraveProcesses).Count -gt 0) { Start-Sleep -Milliseconds 500 }
    $left = Get-BraveProcesses
    if ($left.Count -gt 0) {
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    return ((Get-BraveProcesses).Count -eq 0)
}

function Assert-BraveClosedCli([bool]$AllowClose) {
    if ((Get-BraveProcesses).Count -eq 0) { return }
    if (-not $AllowClose) {
        throw 'Brave is running. Close it completely (including any tray icon) and run this again, or add -CloseBrave.'
    }
    Write-Host 'Closing Brave...'
    if (-not (Close-Brave)) { throw "Couldn't close Brave. Close it yourself and try again." }
}

# ---------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------

function Show-AvatarGui([string]$UserData, [int]$OutputSize) {
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $ui = @{
        Profiles      = @()
        Source        = $null   # working copy of the chosen image
        PreviewSource = $null   # small copy for fast previews
        Preview       = $null   # what the circle shows
        ImagePath     = $null
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Brave - custom profile photo'
    $form.ClientSize = New-Object System.Drawing.Size 640, 440
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object System.Drawing.Font 'Segoe UI', 9

    function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W = 300, [int]$H = 20) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.Location = New-Object System.Drawing.Point $X, $Y
        $l.Size = New-Object System.Drawing.Size $W, $H
        $form.Controls.Add($l)
        return $l
    }
    function New-Slider([int]$X, [int]$Y, [int]$Min, [int]$Max, [int]$Value) {
        $t = New-Object System.Windows.Forms.TrackBar
        $t.Location = New-Object System.Drawing.Point $X, $Y
        $t.Size = New-Object System.Drawing.Size 250, 30
        $t.Minimum = $Min
        $t.Maximum = $Max
        $t.Value = $Value
        $t.AutoSize = $false
        $t.TickStyle = [System.Windows.Forms.TickStyle]::None
        $t.SmallChange = 1
        $t.LargeChange = 10
        $form.Controls.Add($t)
        return $t
    }

    [void](New-Label '1. Profile' 12 12 260)
    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point 12, 34
    $lst.Size = New-Object System.Drawing.Size 260, 340
    $lst.IntegralHeight = $false
    $form.Controls.Add($lst)

    [void](New-Label '2. Photo' 290 12 200)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Choose image...'
    $btnBrowse.Location = New-Object System.Drawing.Point 290, 34
    $btnBrowse.Size = New-Object System.Drawing.Size 140, 28
    $form.Controls.Add($btnBrowse)

    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point 290, 72
    $pic.Size = New-Object System.Drawing.Size 160, 160
    $form.Controls.Add($pic)

    $lblPreview = New-Label '' 290 236 330 20
    $lblPreview.ForeColor = [System.Drawing.Color]::DimGray

    $rbFill = New-Object System.Windows.Forms.RadioButton
    $rbFill.Text = 'Crop to fill'
    $rbFill.Location = New-Object System.Drawing.Point 470, 80
    $rbFill.Size = New-Object System.Drawing.Size 150, 22
    $rbFill.Checked = $true
    $form.Controls.Add($rbFill)
    $rbFit = New-Object System.Windows.Forms.RadioButton
    $rbFit.Text = 'Fit whole image'
    $rbFit.Location = New-Object System.Drawing.Point 470, 106
    $rbFit.Size = New-Object System.Drawing.Size 150, 22
    $form.Controls.Add($rbFit)

    [void](New-Label 'Zoom' 290 266 70)
    $tbZoom = New-Slider 370 262 100 400 100
    [void](New-Label 'Left / right' 290 300 80)
    $tbX = New-Slider 370 296 0 100 50
    [void](New-Label 'Up / down' 290 334 80)
    $tbY = New-Slider 370 330 0 100 50

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = 'Apply to profile'
    $btnApply.Location = New-Object System.Drawing.Point 290, 372
    $btnApply.Size = New-Object System.Drawing.Size 160, 32
    $form.Controls.Add($btnApply)

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = 'Remove custom photo'
    $btnRemove.Location = New-Object System.Drawing.Point 460, 372
    $btnRemove.Size = New-Object System.Drawing.Size 160, 32
    $form.Controls.Add($btnRemove)

    $status = New-Label '' 12 412 616 22
    $status.ForeColor = [System.Drawing.Color]::DimGray

    function Get-ModeName { if ($rbFit.Checked) { return 'Fit' } else { return 'Fill' } }

    function Set-Preview($Bitmap, [string]$Caption) {
        if ($null -ne $ui.Preview) { $ui.Preview.Dispose() }
        $ui.Preview = $Bitmap
        $lblPreview.Text = $Caption
        $pic.Invalidate()
    }

    function Update-Preview {
        if ($null -ne $ui.PreviewSource) {
            $b = New-AvatarBitmap $ui.PreviewSource $pic.Width (Get-ModeName) ($tbZoom.Value / 100.0) ($tbX.Value / 100.0) ($tbY.Value / 100.0)
            Set-Preview $b ('New photo, not applied yet: ' + [System.IO.Path]::GetFileName($ui.ImagePath))
            return
        }
        $sel = $lst.SelectedIndex
        if ($sel -ge 0 -and $ui.Profiles[$sel].HasCustomPhoto) {
            try {
                $cur = Read-SourceImage $ui.Profiles[$sel].PhotoPath 512
                Set-Preview $cur 'Current custom photo'
                return
            } catch { }
        }
        Set-Preview $null ''
    }

    function Update-ProfileList([string]$SelectFolder) {
        $ui.Profiles = @(Get-BraveProfiles $UserData)
        $lst.BeginUpdate()
        $lst.Items.Clear()
        $selectIndex = -1
        for ($n = 0; $n -lt $ui.Profiles.Count; $n++) {
            $p = $ui.Profiles[$n]
            $label = $p.Name
            if ($p.Name -ne $p.Folder) { $label += '   [' + $p.Folder + ']' }
            if ($p.HasCustomPhoto) { $label += '   * custom photo' }
            [void]$lst.Items.Add($label)
            if ($p.Folder -eq $SelectFolder) { $selectIndex = $n }
        }
        $lst.EndUpdate()
        if ($selectIndex -lt 0 -and $ui.Profiles.Count -gt 0) { $selectIndex = 0 }
        $lst.SelectedIndex = $selectIndex
    }

    function Show-Error([string]$Message) {
        [void][System.Windows.Forms.MessageBox]::Show($form, $Message, 'Brave custom profile photo',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }

    function Confirm-BraveClosed {
        if ((Get-BraveProcesses).Count -eq 0) { return $true }
        $answer = [System.Windows.Forms.MessageBox]::Show($form,
            "Brave is running. It has to be fully closed, or it will overwrite this change when it exits.`r`n`r`nClose Brave now? If Brave is set to continue where you left off, your tabs come back next time.",
            'Brave is running',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $status.Text = 'Closing Brave...'
        $form.Refresh()
        try { $ok = Close-Brave } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        if (-not $ok) {
            Show-Error "Couldn't close Brave. Close it yourself (check the tray icon too) and try again."
            return $false
        }
        $script:ClosedBraveForUser = $true
        return $true
    }

    function Invoke-OfferRestart {
        if (-not $script:ClosedBraveForUser) { return }
        $exe = Find-BraveExe
        if (-not $exe) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Done. Open Brave again now?', 'Brave custom profile photo',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath $exe
            $script:ClosedBraveForUser = $false
        }
    }

    $pic.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $rect = New-Object System.Drawing.Rectangle 0, 0, ($pic.Width - 1), ($pic.Height - 1)
        $g.FillEllipse([System.Drawing.Brushes]::Gainsboro, $rect)
        if ($null -ne $ui.Preview) {
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddEllipse($rect)
            $g.SetClip($path)
            $g.DrawImage($ui.Preview, 0, 0, $pic.Width, $pic.Height)
            $g.ResetClip()
            $path.Dispose()
        } else {
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Alignment = [System.Drawing.StringAlignment]::Center
            $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString('No photo', $form.Font, [System.Drawing.Brushes]::DimGray,
                (New-Object System.Drawing.RectangleF 0, 0, $pic.Width, $pic.Height), $fmt)
            $fmt.Dispose()
        }
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Silver), 1
        $g.DrawEllipse($pen, $rect)
        $pen.Dispose()
    })

    $lst.Add_SelectedIndexChanged({
        try {
            if ($null -eq $ui.PreviewSource) { Update-Preview }
            $sel = $lst.SelectedIndex
            $btnRemove.Enabled = ($sel -ge 0 -and $ui.Profiles[$sel].HasCustomPhoto)
        } catch { }
    })

    $btnBrowse.Add_Click({
        try {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Choose a photo'
            $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.jfif;*.bmp;*.gif;*.tif;*.tiff;*.ico;*.webp;*.heic;*.heif;*.avif|All files|*.*'
            if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            try {
                $src = Read-SourceImage $dlg.FileName
                $small = New-ScaledCopy $src 640
            } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
            if ($null -ne $ui.Source) { $ui.Source.Dispose() }
            if ($null -ne $ui.PreviewSource) { $ui.PreviewSource.Dispose() }
            $ui.Source = $src
            $ui.PreviewSource = $small
            $ui.ImagePath = $dlg.FileName
            $tbZoom.Value = 100
            $tbX.Value = 50
            $tbY.Value = 50
            Update-Preview
            $status.Text = 'Adjust the crop if you like, then click Apply.'
        } catch {
            Show-Error $_.Exception.Message
        }
    })

    foreach ($c in @($tbZoom, $tbX, $tbY)) { $c.Add_ValueChanged({ if ($null -ne $ui.PreviewSource) { Update-Preview } }) }
    $rbFill.Add_CheckedChanged({ if ($null -ne $ui.PreviewSource) { Update-Preview } })

    $btnApply.Add_Click({
        try {
            $sel = $lst.SelectedIndex
            if ($sel -lt 0) { Show-Error 'Pick a profile first.'; return }
            if ($null -eq $ui.Source) { Show-Error 'Choose an image first.'; return }
            $target = $ui.Profiles[$sel]
            if (-not (Confirm-BraveClosed)) { return }
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $avatar = New-AvatarBitmap $ui.Source $OutputSize (Get-ModeName) ($tbZoom.Value / 100.0) ($tbX.Value / 100.0) ($tbY.Value / 100.0)
            try { $backup = Invoke-AvatarChange $UserData $target $avatar }
            finally { $avatar.Dispose(); $form.Cursor = [System.Windows.Forms.Cursors]::Default }
            $ui.Source.Dispose(); $ui.Source = $null
            $ui.PreviewSource.Dispose(); $ui.PreviewSource = $null
            Update-ProfileList $target.Folder
            Update-Preview
            $status.Text = "Photo set for '" + $target.Name + "'. Backup: " + $backup
            Invoke-OfferRestart
        } catch {
            Show-Error $_.Exception.Message
        }
    })

    $btnRemove.Add_Click({
        try {
            $sel = $lst.SelectedIndex
            if ($sel -lt 0) { return }
            $target = $ui.Profiles[$sel]
            if (-not $target.HasCustomPhoto) { Show-Error 'This profile has no custom photo.'; return }
            $answer = [System.Windows.Forms.MessageBox]::Show($form,
                "Remove the custom photo from '" + $target.Name + "' and go back to its Brave avatar?",
                'Remove custom photo', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            if (-not (Confirm-BraveClosed)) { return }
            $backup = Invoke-AvatarChange $UserData $target $null
            Update-ProfileList $target.Folder
            Update-Preview
            $status.Text = "Custom photo removed from '" + $target.Name + "'. Backup: " + $backup
            Invoke-OfferRestart
        } catch {
            Show-Error $_.Exception.Message
        }
    })

    $script:ClosedBraveForUser = $false
    $form.Add_Shown({
        try {
            Update-ProfileList (Get-LastUsedProfileFolder $UserData)
            $status.Text = 'Brave data: ' + $UserData
        } catch {
            Show-Error $_.Exception.Message
            $form.Close()
        }
    })
    [void]$form.ShowDialog()
    foreach ($b in @($ui.Source, $ui.PreviewSource, $ui.Preview)) { if ($null -ne $b) { $b.Dispose() } }
    $form.Dispose()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $userData = Resolve-UserDataDir $UserDataDir $Channel
    switch ($PSCmdlet.ParameterSetName) {
        'List' {
            $rows = @(Get-BraveProfiles $userData) | ForEach-Object {
                [pscustomobject]@{ Folder = $_.Folder; Name = $_.Name; 'Custom photo' = $(if ($_.HasCustomPhoto) { 'yes' } else { '' }) }
            }
            Write-Host "Brave data: $userData"
            $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        }
        'Set' {
            $target = Resolve-BraveProfile @(Get-BraveProfiles $userData) $ProfileName
            $imagePath = (Resolve-Path -LiteralPath $Image).ProviderPath
            $src = Read-SourceImage $imagePath
            try { $avatar = New-AvatarBitmap $src $Size $Mode $Zoom $FocusX $FocusY } finally { $src.Dispose() }
            try {
                Assert-BraveClosedCli $CloseBrave.IsPresent
                $backup = Invoke-AvatarChange $userData $target $avatar
            } finally { $avatar.Dispose() }
            Write-Host "Custom photo set for '$($target.Name)' [$($target.Folder)]."
            Write-Host "Previous settings backed up to: $backup"
        }
        'Remove' {
            $target = Resolve-BraveProfile @(Get-BraveProfiles $userData) $ProfileName
            if (-not $target.HasCustomPhoto) {
                Write-Host "'$($target.Name)' has no custom photo; nothing to do."
            } else {
                Assert-BraveClosedCli $CloseBrave.IsPresent
                $backup = Invoke-AvatarChange $userData $target $null
                Write-Host "Custom photo removed from '$($target.Name)' [$($target.Folder)]."
                Write-Host "Previous settings backed up to: $backup"
            }
        }
        default {
            Show-AvatarGui $userData $Size
        }
    }
} catch {
    $msg = $_.Exception.Message
    if ($PSCmdlet.ParameterSetName -eq 'Gui') {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'Brave custom profile photo',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } catch { }
    }
    Write-Host "Error: $msg" -ForegroundColor Red
    exit 1
}
