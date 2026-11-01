# Lists outdated, deprecated or vulnerable packages from all Directory.Packages.props files.
# Prints a table and writes .tmp/nuget-update/packages.json for Get-ReleaseDiff.ps1.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/NuGetApi.ps1"
Push-Location (git rev-parse --show-toplevel)

# nuget.org accounts that publish first-party Microsoft packages
$microsoftOwners = 'Microsoft', 'aspnet', 'dotnetframework', 'EntityFramework', 'azure-sdk', 'nugetvss'

# A package listed in both props files has the same version in both
$references = git ls-files '*Directory.Packages.props' |
    ForEach-Object { ([xml](Get-Content $_ -Raw)).Project.ItemGroup.ChildNodes } |
    Where-Object { $_.LocalName -in 'PackageVersion', 'GlobalPackageReference' } |
    Sort-Object Include -Unique

$now = [DateTimeOffset]::UtcNow
$results = foreach ($reference in $references) {
    $id = $reference.Include
    $current = $reference.Version
    $entries = @(getCatalogEntries $id)
    $currentIndex = @($entries.version).IndexOf($current)
    $currentEntry = $entries[$currentIndex]
    $takePrerelease = $current.Contains('-')
    $newer = @($entries | Select-Object -Skip ($currentIndex + 1) |
        Where-Object { $_.listed -ne $false -and ($takePrerelease -or -not $_.version.Contains('-')) } |
        ForEach-Object {
            [pscustomobject]@{
                Version = $_.version
                # Floor: an [int] cast rounds, which would let a 6.5-day-old release through the 7-day gate
                AgeDays = [Math]::Floor(($now - [DateTimeOffset]$_.published).TotalDays)
                Vulnerable = [bool]$_.vulnerabilities
            }
        })
    $flags = @(
        if ($currentEntry.deprecation) { "deprecated->$($currentEntry.deprecation.alternatePackage.id)" }
        if ($currentEntry.vulnerabilities) { 'VULNERABLE' }
    ) -join ' '
    if (-not $newer -and -not $flags) { continue }

    $owners = getOwners $id
    $isMicrosoft = [bool]($owners | Where-Object { $_ -in $microsoftOwners })
    # The age gate guards against hijacked or broken third-party releases; Microsoft releases are taken as they ship
    $minAgeDays = if ($isMicrosoft) { 0 } else { 7 }
    $target = $newer | Where-Object { $_.AgeDays -ge $minAgeDays -and -not $_.Vulnerable } | Select-Object -Last 1
    $latest = $newer | Select-Object -Last 1
    $currentSpec = getNuspec $id $current
    $targetSpec = if ($target) { getNuspec $id $target.Version }

    [pscustomobject]@{
        Id = $id
        Current = $current
        Target = $target.Version
        TargetAgeDays = $target.AgeDays
        Latest = $latest.Version
        LatestAgeDays = $latest.AgeDays
        MajorBump = $target -and ($target.Version -split '\.')[0] -ne ($current -split '\.')[0]
        IsMicrosoft = $isMicrosoft
        Owners = $owners
        ProjectUrl = $currentEntry.projectUrl
        RepositoryUrl = if ($targetSpec.RepoUrl) { $targetSpec.RepoUrl } else { $currentSpec.RepoUrl }
        AddedDependencies = @($targetSpec.Dependencies | Where-Object { $_ -notin $currentSpec.Dependencies })
        Flags = $flags
    }
}

New-Item -ItemType Directory -Force .tmp/nuget-update | Out-Null
$results | ConvertTo-Json -Depth 3 | Set-Content .tmp/nuget-update/packages.json
Pop-Location

$results | Sort-Object RepositoryUrl, Id | Format-Table -AutoSize Id, Current, Target, TargetAgeDays, Latest, LatestAgeDays,
    MajorBump, IsMicrosoft, @{ n = 'Repository'; e = { $_.RepositoryUrl -replace '^https://github\.com/' } }, Flags
