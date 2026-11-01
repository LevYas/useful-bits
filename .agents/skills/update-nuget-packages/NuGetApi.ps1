# nuget.org API helpers shared by the skill scripts

# Registration leaves come in ascending NuGet version order, so list position is version order
function getCatalogEntries([string]$id) {
    $index = Invoke-RestMethod "https://api.nuget.org/v3/registration5-gz-semver2/$($id.ToLowerInvariant())/index.json"
    foreach ($page in $index.items) {
        # Large registrations keep leaves on separate pages
        $leaves = if ($page.items) { $page.items } else { (Invoke-RestMethod $page.'@id').items }
        $leaves.catalogEntry
    }
}

function getNuspec([string]$id, [string]$version) {
    $lower = $id.ToLowerInvariant()
    [xml]$nuspec = (Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$lower/$($version.ToLowerInvariant())/$lower.nuspec").Content
    $metadata = $nuspec.package.metadata
    $repoUrl = if ($metadata.repository.url) { $metadata.repository.url }
    elseif ($metadata.projectUrl -match '^https://github\.com/[^/]+/[^/]+') { $Matches[0] }
    [pscustomobject]@{
        RepoUrl = if ($repoUrl) { ($repoUrl -replace '\.git$', '').TrimEnd('/') }
        Commit = $metadata.repository.commit
        # SPDX expression, path of a license file inside the package, or a legacy URL
        License = if ($metadata.license) { $metadata.license.InnerText } else { $metadata.licenseUrl }
        LicenseIsFile = $metadata.license.type -eq 'file'
        # Union over all target framework groups
        Dependencies = @($nuspec.SelectNodes('//*[local-name()="dependency"]') | ForEach-Object id | Sort-Object -Unique)
    }
}

function getOwners([string]$id) {
    $result = Invoke-RestMethod "https://azuresearch-usnc.nuget.org/query?q=packageid:$id&prerelease=true&semVerLevel=2.0.0"
    @(($result.data | Where-Object id -eq $id).owners)
}
