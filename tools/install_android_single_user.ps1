param(
  [string]$DeviceId = "",
  [ValidateSet("debug", "release", "profile")]
  [string]$Mode = "release",
  [string]$PackageName = "com.example.noon_chat"
)

$ErrorActionPreference = "Stop"

$adb = Join-Path $env:LOCALAPPDATA "Android\sdk\platform-tools\adb.exe"
if (-not (Test-Path $adb)) {
  throw "adb not found at: $adb"
}

if ([string]::IsNullOrWhiteSpace($DeviceId)) {
  $deviceLines = (& $adb devices) |
    Select-String -Pattern "^\S+\s+device$" |
    ForEach-Object { $_.Line.Split("`t")[0].Trim() }
  if (-not $deviceLines -or $deviceLines.Count -eq 0) {
    throw "No connected Android device found."
  }
  $DeviceId = $deviceLines[0]
}

Write-Host "Using device: $DeviceId" -ForegroundColor Cyan

Write-Host "Building APK ($Mode)..." -ForegroundColor Cyan
if ($Mode -eq "release") {
  flutter build apk --release
} elseif ($Mode -eq "profile") {
  flutter build apk --profile
} else {
  flutter build apk --debug
}

$apk = switch ($Mode) {
  "release" { "build\app\outputs\flutter-apk\app-release.apk" }
  "profile" { "build\app\outputs\flutter-apk\app-profile.apk" }
  default { "build\app\outputs\flutter-apk\app-debug.apk" }
}

if (-not (Test-Path $apk)) {
  throw "APK not found: $apk"
}

Write-Host "Detecting non-owner users..." -ForegroundColor Cyan
$usersRaw = (& $adb -s $DeviceId shell pm list users) | Out-String
$allUserIds = [regex]::Matches($usersRaw, "UserInfo\{(\d+):") |
  ForEach-Object { $_.Groups[1].Value } |
  Select-Object -Unique
$extraUserIds = $allUserIds | Where-Object { $_ -ne "0" }

Write-Host "Installing on user 0 only..." -ForegroundColor Cyan
& $adb -s $DeviceId install -r --user 0 $apk | Out-Host

foreach ($uid in $extraUserIds) {
  Write-Host "Removing package from user $uid (if exists)..." -ForegroundColor Yellow
  try {
    & $adb -s $DeviceId shell pm uninstall --user $uid $PackageName | Out-Host
  } catch {
    # Ignore if not installed for that user.
  }
}

Write-Host "Verification:" -ForegroundColor Cyan
Write-Host "- user 0:"
& $adb -s $DeviceId shell pm list packages --user 0 | Select-String -Pattern $PackageName | Out-Host
if ($extraUserIds.Count -eq 0) {
  Write-Host "- no extra users found" -ForegroundColor Green
} else {
  foreach ($uid in $extraUserIds) {
    Write-Host "- user $uid:"
    & $adb -s $DeviceId shell pm list packages --user $uid | Select-String -Pattern $PackageName | Out-Host
  }
}

Write-Host "Done. App stays single on user 0." -ForegroundColor Green
