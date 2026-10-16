#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $Root) { $Root = Join-Path $PSScriptRoot '..' }
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
$prefix = $rootPath + [IO.Path]::DirectorySeparatorChar

function Resolve-PlanFile {
    param([string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) {
        throw "Plan file must be repository-relative: $Relative"
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Plan reference leaves repository: $Relative"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Missing plan reference: $Relative" }
    return $resolved
}

$catalogPath = Resolve-PlanFile 'docs/programme/dashboard/catalog.json'
$catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
if ($catalog.schemaVersion -is [string] -or $catalog.schemaVersion -ne 1) { throw 'Unsupported dashboard plan schemaVersion.' }
if ($catalog.baseline.commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Plan baseline requires an exact commit identity.' }
$null = Resolve-PlanFile $catalog.baseline.guide
$null = Resolve-PlanFile $catalog.baseline.verification
$researchPath = Resolve-PlanFile 'docs/research/TRIO-2026-10/observations.json'
$research = [IO.File]::ReadAllText($researchPath) | ConvertFrom-Json
$observations = @{}
foreach ($record in $research.observations) { $observations[$record.id] = $record }
$issues = @{}
$caseSet = @{}
$documents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$null = $documents.Add((Resolve-PlanFile 'docs/programme/dashboard/README.md'))

foreach ($issue in $catalog.issues) {
    if ($issue.id -cnotmatch '^DASH-[0-9]{2}$' -or $issues.ContainsKey($issue.id)) { throw "Duplicate/invalid issue ID: $($issue.id)" }
    if ($issue.priority -notin @('P0', 'P1', 'P2')) { throw "Invalid priority: $($issue.id)" }
    if ($issue.status -notin @('planned', 'ready', 'in-progress', 'review', 'accepted', 'blocked')) { throw "Invalid state: $($issue.id)" }
    if ($null -ne $issue.githubIssue -and $issue.githubIssue -notmatch '^https://github\.com/[^/]+/[^/]+/issues/[0-9]+$') { throw "Invalid published issue URL: $($issue.id)" }
    if ($issue.path -notmatch ('^docs/programme/dashboard/issues/' + [regex]::Escape($issue.id) + '-[^/]+\.md$')) { throw "Issue path/ID mismatch: $($issue.id)" }
    $file = Resolve-PlanFile $issue.path
    $null = $documents.Add($file)
    $body = [IO.File]::ReadAllText($file)
    if ($body -notmatch ('(?m)^# ' + [regex]::Escape($issue.id) + ' ')) { throw "Missing issue heading: $($issue.id)" }
    if (-not $body.Contains($issue.title) -or -not $body.Contains('Status: **' + $issue.status.ToUpperInvariant() + '**') -or -not $body.Contains('Priority: **' + $issue.priority + '**')) {
        throw "Catalogue/body metadata mismatch: $($issue.id)"
    }
    $dependencyLine = [regex]::Match($body, '(?m)^Dependencies: (?<list>[^\r\n]+)').Groups['list'].Value
    $bodyDependencies = @([regex]::Matches($dependencyLine, '\[(DASH-[0-9]{2})\]') | ForEach-Object { $_.Groups[1].Value })
    if (@($bodyDependencies).Count -ne @($issue.dependsOn).Count -or @($bodyDependencies | Where-Object { $_ -notin $issue.dependsOn }).Count -gt 0) {
        throw "Catalogue/body dependency mismatch: $($issue.id)"
    }
    foreach ($section in @('Problem and baseline', 'Implementation', 'Acceptance criteria', 'Test cases', 'Out of scope', 'Closure evidence')) {
        if ($body -notmatch ('(?m)^## ' + [regex]::Escape($section) + '\r?$')) { throw "Missing $section in $($issue.id)" }
    }
    if (@($issue.rag).Count -eq 0 -or @($issue.research).Count -eq 0 -or @($issue.testCases).Count -eq 0) { throw "Issue requires RAG, research and tests: $($issue.id)" }
    foreach ($path in $issue.rag) {
        if ($path -notmatch '^docs/rag/.+\.md$') { throw "Invalid RAG path: $path" }
        $null = $documents.Add((Resolve-PlanFile $path))
        if (-not $body.Contains([IO.Path]::GetFileName($path))) { throw "RAG missing from issue body: $path" }
    }
    foreach ($id in $issue.research) {
        if (-not $observations.ContainsKey($id) -or -not $body.Contains($id)) { throw "Invalid research reference $id in $($issue.id)" }
    }
    foreach ($id in $issue.testCases) {
        if ($id -cnotmatch ('^' + [regex]::Escape($issue.id) + '-T[0-9]{2}$') -or $caseSet.ContainsKey($id)) { throw "Duplicate/invalid case: $id" }
        if ([regex]::Matches($body, '\*\*' + [regex]::Escape($id) + ' ').Count -ne 1) { throw "Case must occur once in issue: $id" }
        $caseSet[$id] = $true
    }
    $issues[$issue.id] = $issue
}
if ($issues.Count -eq 0) { throw 'Empty issue catalogue cannot pass.' }

$visits = @{}
function Visit-PlanIssue {
    param([string]$Id)
    if (-not $issues.ContainsKey($Id)) { throw "Missing dependency issue: $Id" }
    if ($visits.ContainsKey($Id)) {
        if ($visits[$Id] -eq 'visiting') { throw "Dependency cycle at $Id" }
        return
    }
    $visits[$Id] = 'visiting'
    $body = [IO.File]::ReadAllText((Resolve-PlanFile $issues[$Id].path))
    $seen = @{}
    foreach ($dependency in $issues[$Id].dependsOn) {
        if ($seen.ContainsKey($dependency)) { throw "Duplicate dependency $dependency on $Id" }
        $seen[$dependency] = $true
        if (-not $body.Contains('[' + $dependency + ']')) { throw "Dependency missing from issue body: $Id -> $dependency" }
        Visit-PlanIssue $dependency
    }
    $visits[$Id] = 'complete'
}
foreach ($id in $issues.Keys) { Visit-PlanIssue $id }

foreach ($observation in $research.observations) {
    foreach ($action in $observation.proposed_actions) {
        if (-not $issues.ContainsKey($action) -or $observation.id -notin $issues[$action].research) {
            throw "Research action lacks issue trace: $($observation.id) -> $action"
        }
    }
}
$gateIds = @{}
foreach ($gate in $catalog.gates) {
    if ($gateIds.ContainsKey($gate.id) -or @($gate.requires).Count -eq 0) { throw "Duplicate/empty gate: $($gate.id)" }
    $gateIds[$gate.id] = $true
    foreach ($id in $gate.requires) { if (-not $issues.ContainsKey($id)) { throw "Missing gate issue: $id" } }
}

# Validate local Markdown file links in the issue set and all linked RAG documents.
# Anchors are navigation hints; this check validates file existence, not heading semantics.
$links = 0
foreach ($file in $documents) {
    $body = [IO.File]::ReadAllText($file)
    foreach ($match in [regex]::Matches($body, '(?<!!)\[[^\]]*\]\((?<target>[^)]+)\)')) {
        $target = $match.Groups['target'].Value
        if ($target -match '^(https?://|mailto:|#)') { continue }
        $target = ($target -split '#', 2)[0]
        if (-not $target) { continue }
        $absolute = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($file)) $target))
        if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
            throw "Broken/out-of-root Markdown link in $file : $target"
        }
        $links++
    }
}
Write-Output ('PASS dashboard plan: {0} issues, {1} test cases, {2} research observations, {3} gates, {4} local links; dependency graph acyclic. No VM/model calls.' -f $issues.Count, $caseSet.Count, $observations.Count, $gateIds.Count, $links)
