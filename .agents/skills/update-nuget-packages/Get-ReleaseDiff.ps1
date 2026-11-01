# Prints supply-chain review data for one package update; the sections are explained in SKILL.md step 3.
# Nothing from the cloned repository is executed: git only reads objects.
param(
    [Parameter(Mandatory)][string]$Id,
    # Default: Current and Target from packages.json
    [string]$From,
    [string]$To,
    # Monorepo folders of the package and its same-repo dependencies
    [string[]]$Path = '.',
    # Also print the code diff (non-test, non-doc files)
    [switch]$ShowDiff
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/NuGetApi.ps1"
$cacheDir = Join-Path ([System.IO.Path]::GetTempPath()) nuget-review

if (-not $From) {
    $package = Get-Content "$(git rev-parse --show-toplevel)/.tmp/nuget-update/packages.json" -Raw | ConvertFrom-Json | Where-Object Id -eq $Id
    $From = $package.Current
    $To = $package.Target
}

function section([string]$title) { ''; "== $title ==" }

$old = getNuspec $Id $From
$new = getNuspec $Id $To
$repoUrl = $new.RepoUrl
$clone = "$cacheDir/$(($repoUrl -replace '^https?://') -replace '[/:]', '_')"
"$Id $From -> $To"
"Repository: $repoUrl  Owners: $((getOwners $Id) -join ', ')"
"Clone: $clone"
if ($old.RepoUrl -ne $new.RepoUrl) { "!! Repository URL changed: $($old.RepoUrl) -> $($new.RepoUrl)" }
$addedDependencies = $new.Dependencies | Where-Object { $_ -notin $old.Dependencies }
if ($addedDependencies) { "!! New dependencies: $($addedDependencies -join ', ')" }

function getPackagePath([string]$version) {
    $name = "$($Id.ToLowerInvariant()).$($version.ToLowerInvariant())"
    $file = "$cacheDir/nupkg/$name.nupkg"
    if (-not (Test-Path $file)) {
        New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
        Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$($Id.ToLowerInvariant())/$($version.ToLowerInvariant())/$name.nupkg" -OutFile $file
    }
    $file
}

function getPackageFiles([string]$version) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead((getPackagePath $version))
    $zip.Entries.FullName | Where-Object { $_ -notmatch '^(_rels/|package/|\[Content_Types\]\.xml$|\.signature\.p7s$)|\.nuspec$' }
    $zip.Dispose()
}

function getLicenseText($nuspec, [string]$version) {
    if (-not $nuspec.LicenseIsFile) { return $nuspec.License }
    $zip = [System.IO.Compression.ZipFile]::OpenRead((getPackagePath $version))
    $reader = [System.IO.StreamReader]::new($zip.GetEntry($nuspec.License.Replace('\', '/')).Open())
    $reader.ReadToEnd()
    $reader.Dispose()
    $zip.Dispose()
}

function describeLicense($nuspec) {
    if ($nuspec.LicenseIsFile) { "file $($nuspec.License)" } elseif ($nuspec.License) { $nuspec.License } else { 'none' }
}

# Relicensing away from open source usually swaps an SPDX expression for a bundled license file
section 'License (!! = changed, may restrict commercial use)'
$oldLicense = getLicenseText $old $From
$newLicense = getLicenseText $new $To
# Copyright year bumps and reflowed text are not license changes
$ignored = '\s|\b(19|20)\d{2}\b'
if (($oldLicense -replace $ignored) -eq ($newLicense -replace $ignored)) { "unchanged: $(describeLicense $new)" }
else {
    "!! $(describeLicense $old) -> $(describeLicense $new)"
    if ($new.LicenseIsFile) { $newLicense -split "`r?`n" | Select-Object -First 80 }
}

# Package content is what actually reaches us; build-time entries execute inside our build
section 'Package content (!! = runs in our build or at install: MSBuild targets, analyzers, tools, scripts, native code)'
$buildTime = '(?i)^(build|buildTransitive|buildMultiTargeting|analyzers|tools)/|\.(ps1|targets|props)$|^runtimes/[^/]+/native/'
$oldFiles = @(getPackageFiles $From)
$newFiles = @(getPackageFiles $To)
$addedFiles = @($newFiles | Where-Object { $_ -notin $oldFiles })
"$($newFiles.Count) files; $($addedFiles.Count) added"
$addedFiles | ForEach-Object { "$(if ($_ -match $buildTime) { '!!' } else { '  ' }) + $_" }
$oldFiles | Where-Object { $_ -notin $newFiles } | ForEach-Object { "   - $_" }
$newFiles | Where-Object { $_ -match $buildTime -and $_ -notin $addedFiles } | ForEach-Object { "!!   (unchanged) $_" }

if (-not $repoUrl -or -not $old.Commit -or -not $new.Commit) {
    '!! Nuspec lacks repository URL or commit: review by hand (SKILL.md step 7)'
    exit 1
}

$base = $old.Commit
$head = $new.Commit
if (Test-Path $clone) { git -C $clone fetch --quiet --tags origin }
else { git clone --quiet --filter=blob:none --no-checkout $repoUrl $clone }

foreach ($sha in $base, $head) {
    # Release commits can sit on branches the clone doesn't track
    git -C $clone cat-file -e "$sha^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { git -C $clone fetch --quiet origin $sha 2>$null }
    git -C $clone cat-file -e "$sha^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        "!! Commit $sha is not in $($repoUrl): the package was built from code that is not public"
        exit 1
    }
}

section 'Commits (no merges)'
$commits = @(git -C $clone log --no-merges --date=short --format='%h|%ad|%an|%s' "$base..$head" -- $Path |
    ForEach-Object { $hash, $date, $author, $subject = $_ -split '\|', 4; [pscustomobject]@{ Hash = $hash; Date = $date; Author = $author; Subject = $subject } })
"$($commits.Count) commits"
$commits | Select-Object -First 60 | ForEach-Object { "$($_.Hash) $($_.Date) [$($_.Author)] $($_.Subject)" }

section 'Authors (prior = commits in the repo before the current version)'
foreach ($author in $commits | Group-Object Author | Sort-Object Count -Descending) {
    $prior = [int](git -C $clone rev-list --count --fixed-strings --author="$($author.Name) <" $base)
    $flag = if ($prior -eq 0 -and $author.Name -notmatch '\[bot\]|^GitHub Action') { '  !! first-time contributor' }
    "{0,4} in range, {1,5} prior  {2}{3}" -f $author.Count, $prior, $author.Name, $flag
}

section 'Changed files (!! = runs at build/install time, CI, or binary)'
$riskyFile = '(?i)\.(targets|props|ps1|psm1|sh|cmd|bat|exe|dll|so|dylib|zip|nupkg|bin)$|(^|/)(build|buildTransitive|tools)/|' +
    '(^|/)\.github/workflows/|(^|/)Directory\.Build\.|(^|/)nuget\.config$|(^|/)global\.json$'
$changedFiles = @(git -C $clone diff --numstat $base $head -- $Path | ForEach-Object { ($_ -split "`t", 3)[2] })
"$($changedFiles.Count) files"
$changedFiles | ForEach-Object { "$(if ($_ -match $riskyFile) { '!!' } else { '  ' }) $_" }

section 'Pattern hits in added non-test code (judge each: expected for this library or not?)'
$patterns = [ordered]@{
    'process' = 'Process\.Start|ProcessStartInfo|<Exec\b'
    'network' = 'HttpClient|WebClient|WebRequest|TcpClient|UdpClient|\bSocket\b|Dns\.|DownloadFile|Invoke-WebRequest|\bcurl\b|\bwget\b'
    'dynamic code' = 'Assembly\.Load|AssemblyLoadContext|Activator\.CreateInstance|Type\.GetType\(|Invoke-Expression|\biex\b|<UsingTask\b'
    'native' = 'DllImport|LibraryImport|Marshal\.|unsafe\b'
    'environment' = 'Environment\.GetEnvironmentVariable|Environment\.GetFolderPath|\bRegistry\.[A-Z]|RegistryKey|SpecialFolder'
    'file system' = 'File\.(Write|Delete|Copy|Move|Open)|Directory\.(Delete|Move)'
    'load-time code' = 'ModuleInitializer'
    'encoded data' = 'FromBase64String|[A-Za-z0-9+/]{120,}={0,2}'
    'sponsorware' = '(?i)sponsor'
    'hidden chars' = '[​‪-‮⁦-⁩]'
}
$codePaths = $Path + ':(exclude,icase)*test*', ':(exclude,icase)*benchmark*', ':(exclude)*.md', ':(exclude)*.txt',
    ':(exclude)*package-lock.json', ':(exclude)*packages.lock.json', ':(exclude)*.lock'
$hits = @{}
$file = $null
foreach ($line in git -C $clone diff -U0 $base $head -- $codePaths) {
    if ($line -like '+++ *') { $file = $line.Substring(6); continue }
    if ($line -notlike '+*') { continue }
    $kind = $patterns.Keys | Where-Object { $line -match $patterns[$_] } | Select-Object -First 1
    # Capped per kind so one noisy pattern doesn't hide the others
    if ($kind -and ++$hits[$kind] -le 15) {
        $text = $line.Substring(1).Trim()
        "[$kind] $($file): $($text.Substring(0, [Math]::Min(180, $text.Length)))"
    }
}
$hits.GetEnumerator() | Where-Object Value -gt 15 | ForEach-Object { "... $($_.Value - 15) more [$($_.Key)] hits" }
if (-not $hits.Count) { 'none' }

if ($ShowDiff) {
    section 'Diff of non-test code'
    git -C $clone diff $base $head -- $codePaths ':(exclude)docs/*' | Select-Object -First 600
}

section 'Changelog lines added in range'
$changelogs = @($changedFiles | Where-Object { $_ -match '(?i)(changelog|release-?notes|history|whatsnew)[^/]*\.md$' })
if ($changelogs) {
    git -C $clone diff -U0 $base $head -- $changelogs | Where-Object { $_ -like '+*' -and $_ -notlike '+++*' } |
        Select-Object -First 150 | ForEach-Object { $_.Substring(1) }
}
else { 'no changelog file changed in range' }

if ($repoUrl -match '^https://github\.com/([^/]+/[^/]+)') {
    $repo = $Matches[1]
    section 'GitHub repository identity'
    $info = gh api "repos/$repo" | ConvertFrom-Json
    "$($info.full_name) (owner type: $($info.owner.type), created $($info.created_at), stars $($info.stargazers_count), homepage: $($info.homepage))"
    # GitHub silently redirects renamed or transferred repositories
    if ($info.full_name -ne $repo) { "!! Repository answers as $($info.full_name): renamed or transferred, confirm the new owner is the same project" }
    if ($info.archived) { '!! Repository is archived' }

    section 'GitHub releases for versions in range'
    $versions = @(getCatalogEntries $Id | ForEach-Object version)
    $inRange = $versions[($versions.IndexOf($From) + 1)..$versions.IndexOf($To)]
    $releases = @(gh api "repos/$repo/releases?per_page=100" | ConvertFrom-Json |
        Where-Object { $tag = $_.tag_name; $inRange | Where-Object { $tag -match "(^|[^\d.])v?$([regex]::Escape($_))$" } })
    # Monorepos tag per package (e.g. "Azure.Monitor.OpenTelemetry.Exporter_1.10.0")
    $ownReleases = @($releases | Where-Object { $_.tag_name -like "*$Id*" })
    if ($ownReleases) { $releases = $ownReleases }
    if (-not $releases) { "no releases tagged with $($inRange -join ', ')" }
    foreach ($release in $releases | Sort-Object published_at) {
        "--- $($release.tag_name) by $($release.author.login) on $($release.published_at)"
        $release.body -split "`r?`n" | Select-Object -First 60
    }
}
