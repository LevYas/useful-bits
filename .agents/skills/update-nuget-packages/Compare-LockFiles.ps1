# Prints how the resolved NuGet graph changed against HEAD across all committed packages.lock.json files:
# "+" added, "-" removed, "~" version changed, each with the projects affected.

$ErrorActionPreference = 'Stop'
Push-Location (git rev-parse --show-toplevel)

function readGraph($lockFile) {
    $graph = @{}
    foreach ($target in $lockFile.dependencies.PSObject.Properties) {
        foreach ($package in $target.Value.PSObject.Properties | Where-Object { $_.Value.type -ne 'Project' }) {
            $graph[$package.Name] = $package.Value.resolved
        }
    }
    $graph
}

$changes = foreach ($file in git ls-files '*packages.lock.json') {
    $old = readGraph (git show "HEAD:$file" | Out-String | ConvertFrom-Json)
    $new = readGraph (Get-Content $file -Raw | ConvertFrom-Json)
    foreach ($id in @($old.Keys) + @($new.Keys) | Sort-Object -Unique) {
        if ($old[$id] -ne $new[$id]) {
            [pscustomobject]@{ Id = $id; Before = $old[$id]; After = $new[$id]; Project = Split-Path (Split-Path $file) -Leaf }
        }
    }
}
Pop-Location

$lines = $changes | Group-Object Id, Before, After | ForEach-Object {
    $change = $_.Group[0]
    $what = if (-not $change.Before) { "+ $($change.Id) $($change.After)" }
    elseif (-not $change.After) { "- $($change.Id) $($change.Before)" }
    else { "~ $($change.Id) $($change.Before) -> $($change.After)" }
    "$what  in $($_.Group.Project -join ', ')"
}
# Additions first: each one needs a review
$lines | Sort-Object { '+-~'.IndexOf($_[0]) }, { $_ }
