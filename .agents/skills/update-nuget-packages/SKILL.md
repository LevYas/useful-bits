---
name: update-nuget-packages
description: Vet and apply NuGet package updates safely. Use when asked to update, bump, upgrade or check NuGet packages.
---

# Update NuGet packages

Goal: take every update that is safe and doesn't break us, hold the rest with a reason, and leave a report the user
reads in two minutes. Report only what matters to this repo: a break or behavior change that doesn't touch our code
is not worth a line. Never commit; leave every change for the user to review.

Scope follows the request: named packages limit the run to their families; "check" means stop after step 5 and
report what you would update.

Scripts live next to this file. Run them with PowerShell 7 from the repo root:

| Script | What it gives you |
|---|---|
| `Get-PackageUpdates.ps1` | Outdated, deprecated or vulnerable packages from every `Directory.Packages.props`: `Target` version, age, owners, repo, new dependencies, `Flags`. Writes `.tmp/nuget-update/packages.json` |
| `Get-ReleaseDiff.ps1 <Id> [-From x -To y] [-Path dir1,dir2] [-ShowDiff]` | Supply-chain review data for one update: license change, package content diff, commits, authors, risky files, pattern hits, changelog, repo identity, releases. Versions default to `Current`/`Target` from `packages.json`; pass `-From/-To` for transitive packages |
| `Compare-LockFiles.ps1` | Lockfile changes against `HEAD`: `+` added, `-` removed, `~` version changed, with the projects affected |

`NuGetApi.ps1` holds the nuget.org calls the scripts share.

## Policy

- **Microsoft packages** (`IsMicrosoft = true`): newest stable version, no age gate, no code review. The user
  accepts Microsoft's release pipeline as trusted. Read release notes only for changes that affect us.
- **Everything else**: newest stable version published at least 7 days ago (the script's `Target`; prerelease only
  when the current version is prerelease), plus the code review in step 3. Hijacked or broken releases usually
  surface within days, which is what the gate buys. A newer, too-fresh version is not a reason to wait: take the
  older eligible one.
- **Families update together**: packages sharing a `RepositoryUrl` (or an obvious id prefix with a shared version,
  e.g. `Microsoft.Extensions.*` + `Microsoft.EntityFrameworkCore.*`, `Dapper` + `Dapper.Rainbow`) move to one
  version, since mixed versions cause binding errors. If one member cannot move, hold the whole family. A package
  listed in several props files gets the same version in all of them.
- **Never pin a transitive package** (a new `PackageVersion` entry) to clear an advisory or get a fix. It becomes dead
  code once the direct dependency that brings it in updates; that update is the fix.
- **Held packages** need a migration, so they are skipped without review. An update that turns out to need
  substantial work is held too, with the reason in the report:

  | Package | Reason |
  |---|---|
  {{HELD_PACKAGES}}

## Workflow

### 1. Preconditions

{{SDK_PRECONDITION}}
- `git status` should be clean apart from your own work. Lockfile changes you did not make (IDE restores in the
  background, sometimes with a different SDK, producing junk) get overwritten by step 7.

### 2. Discover

```powershell
{{SKILL_DIR}}/Get-PackageUpdates.ps1
```

Rows come sorted by `Repository`, which groups most families. Drop held packages. A row without `Target` is a third-party
package whose only newer versions are under 7 days old: skip it silently. `Flags`: a vulnerable current version
raises the priority of its update (check it ships, see step 7); a deprecated one is held, with its replacement in the report.

### 3. Review each non-Microsoft family

```powershell
{{SKILL_DIR}}/Get-ReleaseDiff.ps1 Dapper
{{SKILL_DIR}}/Get-ReleaseDiff.ps1 Polly -Path src/Polly,src/Polly.Core      # monorepo: the package and its same-repo dependencies
{{SKILL_DIR}}/Get-ReleaseDiff.ps1 PreMailer.Net -ShowDiff                    # small diffs: read the code
```

For monorepos, the first run without `-Path` lists the changed folders; rerun with the package's folder and the
folders of its same-repo dependencies (e.g. `OpenTelemetry.Extensions.Hosting` → also `src/OpenTelemetry`,
`src/OpenTelemetry.Api`). Outputs are long: read the sections you need.

Before trusting a "commit is not in `<repo>`" or `fatal: not a git repository` result, delete the `Clone:` folder
from the script header and re-run once — a clone left over from an earlier interrupted run can be incomplete, which
makes the fetch fail silently and produces this exact false positive. Only mark it a red flag if the clean re-run
still reports it.

Mark the family **not safe** (❌, not updated, reason in the report) and stop reviewing it if any of these holds:

- the script reports a commit missing from the public repo, or the repo URL changed between versions
- the repo identity check reports a rename/transfer to an owner that is not clearly the same project, or the
  project site (`ProjectUrl`, fetch the page) no longer belongs to the same person/org
- new build-time entries in the package content (`build/`, `buildTransitive/`, `analyzers/`, `tools/`, `.ps1`,
  native code) that the release notes don't explain. Read any such `.targets` file before deciding
- a pattern hit the library's purpose doesn't explain (a downloader using `HttpClient` is expected; a mapper
  starting processes, reading environment variables or decoding long base64 blobs is not)
- telemetry/"sponsor" checks or phone-home code appear in shipped code
- a first-time contributor's commit touches shipped code and you cannot tell what it does. Inspect those commits:
  `git -C <Clone> show <hash> -- <src paths>`
- `AddedDependencies` brings a non-Microsoft package that fails the same owner/age/repo check

Normal and fine, not worth reporting: dependency-bot commits, CI/release workflow changes such as moving to NuGet
Trusted Publishing, maintainers committing under a new email (the script says so), docs churn.

**License.** Assume commercial use: a license that restricts it binds test-only packages too, e.g. FluentAssertions 8
became paid for commercial use; its free fork AwesomeAssertions is the usual way out. When the `License` section
flags a change, read the new text:

- permissive to permissive (MIT, Apache-2.0, BSD), reworded text: ignore
- anything else (non-commercial clause, revenue threshold, paid tier, copyleft such as GPL/AGPL) or a custom text
  you cannot classify: hold the family and explain it in the report's "License changes"

### 4. Microsoft families

Release notes, read only for what affects us:

- `dotnet/dotnet` family (`Microsoft.Extensions.*`, EF Core): `gh api repos/dotnet/core/contents/release-notes/<major.minor>/<ver>/<ver>.md -H "Accept: application/vnd.github.raw"`;
  patch releases are security/bug fixes
- others: `gh api "repos/<owner>/<repo>/releases?per_page=20"` or the package's `CHANGELOG.md` on the default branch
  (`gh api "repos/<o>/<r>/contents/<path>/CHANGELOG.md" -H "Accept: application/vnd.github.raw"`)
- no notes at all (e.g. `Microsoft.Windows.SDK.BuildTools`): fine

### 5. Impact on our code

For every declared break, behavior change, obsoletion and notable fix or feature, search our code (symbol search or
Grep over {{SOURCE_DIRS}}) for the affected API, setting or scenario. Keep only what touches us:

- **breaks us** — small, obvious fix: make it and say what you changed (⚠️). Substantial work: hold the family and
  say in one line what the migration involves (❌)
- **changes behavior we rely on** — say where and what to watch for after release (⚠️), e.g. a telemetry exporter
  changing how it flushes on shutdown, for an app that flushes by disposing the provider
- **improves us** — a fix or feature that makes some of our code unnecessary or simpler: a workaround, retry,
  custom helper, test fake, or cleanup step (`Dispose`/flush/delay) the library now handles itself. Read the code
  to confirm, then name the file and what could go. If it turns out to be still needed, leave it out unless the user
  asked about it
- **doesn't touch us** — omit it. Don't list declared breaks for APIs we don't call, targets we don't build, or
  features we don't use

Major version bumps (`MajorBump = true`; calendar versions like JetBrains `2025.x → 2026.x` are not majors) need
this search before applying; step 8 confirms it.

### 6. Apply

Edit versions in every `Directory.Packages.props` that lists the package.

### 7. Restore and review the graph

```powershell
dotnet restore {{SOLUTION}} --force-evaluate
{{SKILL_DIR}}/Compare-LockFiles.ps1
```

Transitive bumps inside reviewed families (e.g. Polly.Core, OpenTelemetry.Api) are covered by step 3.
Review the rest:

- non-Microsoft packages that change version in a **shipped** project ({{SHIPPED_PROJECTS}}):
  `Get-ReleaseDiff.ps1 AngleSharp -From 1.5.1 -To 1.7.2 -Path src/AngleSharp`. When the nuspec has no commit
  (the script stops after the package content), review by hand in the package's repository: commits and authors
  since the old version's publish date (`git log --since=<date> <new version tag> -- <src>`) and the GitHub releases
- every **added** non-Microsoft package: owner/age/repo/license check
  (`https://azuresearch-usnc.nuget.org/query?q=packageid:<id>`, license in `licenseUrl`), plus the review above if it ships
- test-only transitive changes: a glance at owner and age is enough

Restore prints NU1902/NU1903 for vulnerable packages, mostly transitive. Only advisories that reach a shipped project
matter (step 8 scan). The .NET 10+ SDK prunes packages the target framework provides, so apps take e.g.
`System.Security.Cryptography.*` from the runtime and libraries/tests show warnings the apps don't have. An advisory
that reaches no shipped project doesn't affect us: leave it out of the report.

Run `dotnet` commands one at a time (a parallel restore and build race on `obj/`), and don't pipe them through
`Select-Object -First`: it stops the process early and loses the exit code.

### 8. Verify

```powershell
dotnet restore {{SOLUTION}} --locked-mode
{{BUILD_COMMAND}}
# for each shipped project
dotnet list <project> package --vulnerable --include-transitive
{{TEST_COMMANDS}}
```

New obsoletion/nullable warnings from an update count as "breaks us" (fix or report). If a failure traces to one
family, revert that family, mark it ❌ with the failure, and re-run.

### 9. Report

Write `.tmp/nuget-update/report-<yyyy-MM-dd>.md`:

```markdown
# NuGet update <date>

Safe: ✅ code reviewed · 🟦 Microsoft, not code-reviewed · ❌ red flag
Impact: ✅ nothing for us to do · ⚠️ needed a change or affects behavior we rely on (see "What it means for us") · ❌ held

| Package(s) | From → To | What it means for us | Safe | Impact | Ready |
|---|---|---|---|---|---|

## Improvements now possible
<file: what can be simplified or removed, and which update enables it. Omit the section when empty>

## Watch after release
<behavior changes we rely on. Omit when empty>

## License changes
<per family, in plain words: what the new license forbids or costs and whether it hits us; the options (stay on the
last free version and get no more fixes, buy a license, switch to a free fork or alternative, drop the package) with
a recommendation. Omit when empty>

## Held
<package and reason; for a license hold the reason is "license, see License changes">

## Verification
<locked-mode, build, tests with numbers, vulnerable scan of shipped projects>
```

One row per family (list members in the first column). "What it means for us" is one short sentence about our
code or our customers; use "maintenance" when nothing applies. Don't explain the review itself when it found nothing.
In the chat reply, point to the report; don't repeat it.
