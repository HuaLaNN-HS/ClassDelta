$ErrorActionPreference = 'Stop'

# Repository and upstream settings. These are deliberately fixed for this project.
$TargetBranch = 'dev/misha-preview'
$UpstreamUrl = 'https://github.com/ClassIsland/ClassIsland.git'
$UpstreamBranch = 'develop/v2/misha-alpha'
$UpstreamRef = 'refs/remotes/upstream-sync/develop-v2-misha-alpha'
$StateFileName = 'classdelta-upstream-sync-state.json'
$script:ScriptPath = $PSCommandPath

function Get-GitOutput {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    $output = @(& git @GitArgs)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Git command failed (exit code $exitCode): git $($GitArgs -join ' ')"
    }
    return $output
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    & git @GitArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Git command failed (exit code $exitCode): git $($GitArgs -join ' ')"
    }
}

function Get-GitExitCode {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    & git @GitArgs *> $null
    return $LASTEXITCODE
}

function Get-CurrentBranch {
    $result = @(Get-GitOutput @('branch', '--show-current'))
    if ($result.Count -eq 0) { return '' }
    return ([string]$result[0]).Trim()
}

function Get-CurrentHead {
    $result = @(Get-GitOutput @('rev-parse', 'HEAD'))
    return ([string]$result[0]).Trim()
}

function Resolve-GitPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitPathName
    )

    $output = @(
        & git -C $script:RepoRoot rev-parse --git-path $GitPathName
    )

    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
        throw "Unable to resolve Git metadata path: $GitPathName"
    }

    $path = ([string]$output[0]).Trim()

    if ([System.IO.Path]::IsPathRooted($path)) {
        return $path
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $script:RepoRoot $path)
    )
}

function Get-SyncStatePath {
    return (Resolve-GitPath -GitPathName $script:StateFileName)
}

function Read-SyncState {
    $path = Get-SyncStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'No previous sync state was found. There is nothing to resume or undo.'
    }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Write-SyncState {
    param([Parameter(Mandatory = $true)]$State)

    $path = Get-SyncStatePath
    $tempPath = "$path.tmp"
    $json = $State | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $tempPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $path -Force
}

function Get-DirtyEntries {
    $entries = @(Get-GitOutput @('status', '--porcelain', '--untracked-files=all'))

    # Allow this script itself to remain untracked when saved in the repository root.
    # All other untracked files and all tracked modifications still block a new sync.
    $relativeScriptPath = $null
    if ($script:ScriptPath) {
        $fullScriptPath = [System.IO.Path]::GetFullPath($script:ScriptPath)
        $root = $script:RepoRoot.TrimEnd([char[]]@('\', '/'))
        if ($fullScriptPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativeScriptPath = $fullScriptPath.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        }
    }

    $filtered = @()
    foreach ($entry in $entries) {
        if ($relativeScriptPath -and $entry.StartsWith('?? ')) {
            $reportedPath = $entry.Substring(3).Trim('"').Replace('\', '/')
            if ($reportedPath -eq $relativeScriptPath) {
                continue
            }
        }
        $filtered += $entry
    }
    return $filtered
}

function Assert-TargetBranch {
    $branch = Get-CurrentBranch
    if ($branch -ne $script:TargetBranch) {
        if ([string]::IsNullOrWhiteSpace($branch)) {
            throw "The repository is in a detached-HEAD state. Switch to '$($script:TargetBranch)' first."
        }
        throw "This script targets '$($script:TargetBranch)', but the current branch is '$branch'. No branch was switched."
    }
}

function Assert-CleanWorktree {
    $dirty = @(Get-DirtyEntries)
    if ($dirty.Count -gt 0) {
        Write-Host ''
        Write-Host 'The working tree is not clean. No sync operation was started.' -ForegroundColor Yellow
        Write-Host 'Please commit or stash your changes, then run this script again.'
        foreach ($entry in $dirty) {
            Write-Host "  $entry"
        }
        throw 'Working-tree safety check failed.'
    }
}

function Fetch-UpstreamBranch {
    Write-Host ''
    Write-Host 'Fetching the official branch using temporary upstream configuration...'
    Write-Host "  URL:    $($script:UpstreamUrl)"
    Write-Host "  Branch: $($script:UpstreamBranch)"

    # The upstream URL and fetch refspec exist only for this Git command.
    # This does not add or overwrite a permanent "upstream" remote in .git/config.
    $fetchRefspec = "+refs/heads/$($script:UpstreamBranch):$($script:UpstreamRef)"
    Invoke-Git @(
        '-c', "remote.upstream.url=$($script:UpstreamUrl)",
        '-c', "remote.upstream.fetch=$fetchRefspec",
        'fetch', '--no-tags', 'upstream',
        "refs/heads/$($script:UpstreamBranch):$($script:UpstreamRef)"
    )
}

function Read-StartDate {
    while ($true) {
        $yearText = Read-Host 'Enter the start year (YYYY)'
        $monthText = Read-Host 'Enter the start month (1-12)'
        $dayText = Read-Host 'Enter the start day (1-31)'

        if ($yearText -notmatch '^\d{4}$' -or
            $monthText -notmatch '^\d{1,2}$' -or
            $dayText -notmatch '^\d{1,2}$') {
            Write-Host 'Invalid date input. Please enter numeric year, month, and day values.' -ForegroundColor Yellow
            continue
        }

        $dateText = '{0:D4}-{1:D2}-{2:D2}' -f [int]$yearText, [int]$monthText, [int]$dayText
        $parsedDate = [datetime]::MinValue
        $valid = [datetime]::TryParseExact(
            $dateText,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedDate
        )

        if ($valid) {
            return $parsedDate.ToString('yyyy-MM-dd')
        }
        Write-Host 'That calendar date is invalid. Please try again.' -ForegroundColor Yellow
    }
}

function Get-AppliedLedger {
    $path = Get-SyncStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($state.Status -eq 'InProgress' -or $state.Status -eq 'Conflict') {
        throw "A previous sync is '$($state.Status)'. Continue or undo it before previewing or starting another sync."
    }

    if ($state.PSObject.Properties.Name -contains 'AppliedUpstreamCommits') {
        return @($state.AppliedUpstreamCommits)
    }

    # Compatibility fallback for a state file created by an earlier script version.
    if ($state.Status -eq 'Complete' -and $state.Commits) {
        return @($state.Commits)
    }
    return @()
}

function Get-CandidateCommits {
    param(
        [Parameter(Mandatory = $true)][string]$StartDate,
        [string[]]$AppliedLedger = @()
    )

    # Filter first-parent history by committer date, inclusive from 00:00:00 UTC.
    # Commits already reachable from local HEAD are excluded by "--not HEAD".
    $cutoff = "${StartDate}T00:00:00Z"
    $rawCommits = @(
        Get-GitOutput @(
            'rev-list',
            '--first-parent',
            '--reverse',
            '--topo-order',
            "--since-as-filter=$cutoff",
            $script:UpstreamRef,
            '--not',
            'HEAD'
        )
    )

    # "git cherry" detects patch-equivalent non-merge commits that may have been
    # cherry-picked earlier under different commit hashes.
    $patchEquivalent = @{}
    $cherryLines = @(Get-GitOutput @('cherry', '-v', 'HEAD', $script:UpstreamRef))
    foreach ($line in $cherryLines) {
        if ([string]$line -match '^- ([0-9a-fA-F]{40})\s') {
            $patchEquivalent[$matches[1].ToLowerInvariant()] = $true
        }
    }

    $filtered = @()
    foreach ($commit in $rawCommits) {
        if ($AppliedLedger -contains $commit) {
            continue
        }
        if ($patchEquivalent.ContainsKey(([string]$commit).ToLowerInvariant())) {
            continue
        }
        $filtered += $commit
    }
    return $filtered
}

function Show-CommitList {
    param([Parameter(Mandatory = $true)][string[]]$Commits)

    Write-Host ''
    Write-Host "Found $($Commits.Count) candidate commit(s):" -ForegroundColor Cyan
    foreach ($commit in $Commits) {
        $details = @(Get-GitOutput @('show', '-s', '--format=%h | %cI | %s', $commit))
        if ($details.Count -gt 0) {
            Write-Host "  $($details[0])"
        }
    }
}

function Show-ConflictDetails {
    param([Parameter(Mandatory = $true)][string]$Commit)

    $conflictPaths = @(Get-GitOutput @('diff', '--name-only', '--diff-filter=U'))
    Write-Host ''
    Write-Host "Conflict detected while applying commit: $Commit" -ForegroundColor Red

    if ($conflictPaths.Count -gt 0) {
        Write-Host 'Conflicting file paths:'
        foreach ($path in $conflictPaths) {
            $absolutePath = [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot $path))
            Write-Host "  $absolutePath" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host 'Git reported a cherry-pick failure, but no unmerged file was listed.'
    }

    $statusLines = @(Get-GitOutput @('status', '--short'))
    if ($statusLines.Count -gt 0) {
        Write-Host ''
        Write-Host 'Current Git status:'
        foreach ($line in $statusLines) {
            Write-Host "  $line"
        }
    }

    Write-Host ''
    Write-Host 'Operation status: PARTIAL. Earlier commits may already be applied locally.'
    Write-Host 'The current commit is not complete. No push was performed.'
    Write-Host 'Resolve the listed files, stage the resolved files with git add, then run this script and choose option 3 to continue.'
    Write-Host 'Alternatively, choose option 4 to undo this sync.'
}

function Apply-RemainingCommits {
    param([Parameter(Mandatory = $true)]$State)

    $commits = @($State.Commits)
    for ($index = [int]$State.NextIndex; $index -lt $commits.Count; $index++) {
        $commit = [string]$commits[$index]
        $State.Status = 'InProgress'
        $State.CurrentIndex = $index
        $State.CurrentCommit = $commit
        Write-SyncState $State

        $parentLine = @(Get-GitOutput @('rev-list', '--parents', '-n', '1', $commit))
        $parentCount = ([string]$parentLine[0] -split '\s+').Count - 1

        Write-Host ''
        Write-Host "Applying commit $($index + 1) of $($commits.Count): $commit"
        if ($parentCount -gt 1) {
            # Preserve the official branch's merge result by applying its diff against parent 1.
            & git cherry-pick -x --no-edit -m 1 $commit
        }
        else {
            & git cherry-pick -x --no-edit $commit
        }

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $State.Status = 'Conflict'
            Write-SyncState $State
            Show-ConflictDetails $commit
            return $false
        }

        $State.LastAppliedHead = Get-CurrentHead
        $ledger = @($State.AppliedUpstreamCommits)
        if ($ledger -notcontains $commit) { $State.AppliedUpstreamCommits = @($ledger + $commit) }
        $State.NextIndex = $index + 1
        $State.CurrentIndex = $null
        $State.CurrentCommit = $null
        Write-SyncState $State
        Write-Host "Commit applied successfully: $commit" -ForegroundColor Green
    }

    $State.Status = 'Complete'
    $State.PostSyncHead = Get-CurrentHead
    $State.FinishedAtUtc = [datetime]::UtcNow.ToString('o')
    $State.CurrentIndex = $null
    $State.CurrentCommit = $null
    Write-SyncState $State

    Write-Host ''
    Write-Host 'Sync completed successfully.' -ForegroundColor Green
    Write-Host "Start date (inclusive): $($State.StartDate) UTC"
    Write-Host "Commits applied: $($commits.Count)"
    Write-Host "Backup branch: $($State.BackupBranch)"
    Write-Host 'Operation status: COMPLETED LOCALLY. No push was performed.'
    Write-Host 'Please review the diff and run your tests before pushing.'
    return $true
}

function Start-NewSync {
    Assert-TargetBranch
    Assert-CleanWorktree

    $existingStatePath = Get-SyncStatePath
    if (Test-Path -LiteralPath $existingStatePath -PathType Leaf) {
        $oldState = Get-Content -LiteralPath $existingStatePath -Raw | ConvertFrom-Json
        if ($oldState.Status -eq 'InProgress' -or $oldState.Status -eq 'Conflict') {
            throw "A previous sync is '$($oldState.Status)'. Choose option 3 to continue it or option 4 to undo it before starting another sync."
        }
    }

    $startDate = Read-StartDate
    Fetch-UpstreamBranch
    $appliedLedger = @(Get-AppliedLedger)
    $commits = @(Get-CandidateCommits $startDate $appliedLedger)

    if ($commits.Count -eq 0) {
        Write-Host ''
        Write-Host "No eligible official commits were found on or after $startDate (UTC)." -ForegroundColor Yellow
        Write-Host 'No local commits were created. Eligible commits may already be present or patch-equivalent.'
        return
    }

    Show-CommitList $commits
    Write-Host ''
    Write-Host 'Only commits from the selected date onward will be considered.'
    Write-Host 'Older official changes are not included by this operation.'
    $confirmation = Read-Host "Type SYNC to apply these commits to '$($script:TargetBranch)'"
    if ($confirmation -cne 'SYNC') {
        Write-Host 'Cancelled. No commits were applied.'
        return
    }

    $preSyncHead = Get-CurrentHead
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupBranch = "backup/upstream-sync-$stamp"
    $suffix = 1
    while ((Get-GitExitCode @('show-ref', '--verify', '--quiet', "refs/heads/$backupBranch")) -eq 0) {
        $backupBranch = "backup/upstream-sync-$stamp-$suffix"
        $suffix++
    }

    Invoke-Git @('branch', $backupBranch, $preSyncHead)

    $state = [pscustomobject]@{
        Version = 1
        Status = 'InProgress'
        Branch = $script:TargetBranch
        StartDate = $startDate
        UpstreamUrl = $script:UpstreamUrl
        UpstreamBranch = $script:UpstreamBranch
        UpstreamRef = $script:UpstreamRef
        PreSyncHead = $preSyncHead
        LastAppliedHead = $preSyncHead
        PostSyncHead = $null
        BackupBranch = $backupBranch
        Commits = @($commits)
        LedgerBeforeSync = @($appliedLedger)
        AppliedUpstreamCommits = @($appliedLedger)
        NextIndex = 0
        CurrentIndex = $null
        CurrentCommit = $null
        StartedAtUtc = [datetime]::UtcNow.ToString('o')
        FinishedAtUtc = $null
    }
    Write-SyncState $state

    Write-Host ''
    Write-Host "Backup branch created: $backupBranch" -ForegroundColor Green
    $null = Apply-RemainingCommits $state
}

function Preview-Sync {
    Assert-TargetBranch

    $startDate = Read-StartDate
    Fetch-UpstreamBranch
    $appliedLedger = @(Get-AppliedLedger)
    $commits = @(Get-CandidateCommits $startDate $appliedLedger)

    if ($commits.Count -eq 0) {
        Write-Host ''
        Write-Host "No eligible official commits were found on or after $startDate (UTC)." -ForegroundColor Yellow
        Write-Host 'Preview only: no local branch commits were created. Eligible commits may already be present or patch-equivalent.'
        return
    }

    Show-CommitList $commits
    Write-Host ''
    Write-Host 'Preview only: no cherry-pick was performed and no push was made.'
}

function Continue-PreviousSync {
    Assert-TargetBranch
    $state = Read-SyncState

    if ($state.Status -ne 'Conflict' -and $state.Status -ne 'InProgress') {
        throw "The previous sync status is '$($state.Status)'. There is no interrupted sync to continue."
    }
    if ($state.Branch -ne (Get-CurrentBranch)) {
        throw "The saved sync belongs to branch '$($state.Branch)'. Switch to that branch before continuing."
    }

    $currentHead = Get-CurrentHead
    $cherryPickHeadPath = Resolve-GitPath 'CHERRY_PICK_HEAD'

    if (($state.Status -eq 'Conflict' -or $state.Status -eq 'InProgress') -and (Test-Path -LiteralPath $cherryPickHeadPath -PathType Leaf)) {
        $unmerged = @(Get-GitOutput @('diff', '--name-only', '--diff-filter=U'))
        if ($unmerged.Count -gt 0) {
            Write-Host 'Unresolved conflict files remain:' -ForegroundColor Yellow
            foreach ($path in $unmerged) {
                Write-Host "  $([System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot $path)))"
            }
            Write-Host 'Resolve these files and stage them with git add before choosing option 3 again.'
            return
        }

        $confirmation = Read-Host 'No unmerged files remain. Type CONTINUE to finish the current cherry-pick'
        if ($confirmation -cne 'CONTINUE') {
            Write-Host 'Cancelled. The interrupted cherry-pick remains in progress.'
            return
        }

        & git -c core.editor=: cherry-pick --continue
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Host 'Git could not continue the cherry-pick. No push was performed.' -ForegroundColor Red
            return
        }

        $state.LastAppliedHead = Get-CurrentHead
        $ledger = @($state.AppliedUpstreamCommits)
        if ($ledger -notcontains [string]$state.CurrentCommit) { $state.AppliedUpstreamCommits = @($ledger + [string]$state.CurrentCommit) }
        $state.NextIndex = [int]$state.CurrentIndex + 1
        $state.CurrentIndex = $null
        $state.CurrentCommit = $null
        $state.Status = 'InProgress'
        Write-SyncState $state
    }
    elseif ($currentHead -ne $state.LastAppliedHead) {
        throw 'HEAD differs from the last recorded sync commit. For safety, the script will not continue automatically. Review the repository state or choose undo.'
    }

    $null = Apply-RemainingCommits $state
}

function Undo-PreviousSync {
    $state = Read-SyncState

    $branch = Get-CurrentBranch
    if ($branch -ne $state.Branch) {
        throw "The saved sync belongs to '$($state.Branch)', but the current branch is '$branch'. No branch was switched."
    }

    if ($state.Status -eq 'Undone') {
        throw 'The last recorded sync has already been undone.'
    }
    if ($state.Status -ne 'Complete' -and $state.Status -ne 'Conflict' -and $state.Status -ne 'InProgress') {
        throw "The saved sync status is '$($state.Status)' and cannot be undone by this script."
    }

    if ($state.Status -eq 'Complete') {
        Assert-CleanWorktree
        $currentHead = Get-CurrentHead
        if ($currentHead -ne $state.PostSyncHead) {
            throw 'HEAD has changed since the recorded sync completed. For safety, automatic undo was refused.'
        }
    }
    else {
        # A failed cherry-pick can leave conflict markers and staged files. Since the
        # worktree was clean before sync, these are treated as changes from this sync.
        $cherryPickHeadPath = Resolve-GitPath 'CHERRY_PICK_HEAD'
        if (Test-Path -LiteralPath $cherryPickHeadPath -PathType Leaf) {
            Write-Host 'Aborting the in-progress cherry-pick...'
            Invoke-Git @('cherry-pick', '--abort')
        }

        $currentHead = Get-CurrentHead
        if ($currentHead -ne $state.LastAppliedHead) {
            throw 'HEAD does not match the last recorded sync commit. For safety, automatic undo was refused.'
        }

        $dirty = @(Get-DirtyEntries)
        if ($dirty.Count -gt 0) {
            Write-Host 'The working tree still has changes after aborting the cherry-pick:' -ForegroundColor Yellow
            foreach ($entry in $dirty) { Write-Host "  $entry" }
            throw 'Automatic undo was stopped to avoid deleting unexpected changes.'
        }
    }

    if ((Get-CurrentHead) -ne $state.PreSyncHead) {
        Invoke-Git @('reset', '--hard', $state.PreSyncHead)
    }

    $state.AppliedUpstreamCommits = @($state.LedgerBeforeSync)
    $state.Status = 'Undone'
    $state.UndoneAtUtc = [datetime]::UtcNow.ToString('o')
    Write-SyncState $state

    Write-Host ''
    Write-Host 'The last sync was undone locally.' -ForegroundColor Green
    Write-Host "Restored commit: $($state.PreSyncHead)"
    Write-Host "Backup branch retained: $($state.BackupBranch)"
    Write-Host 'Operation status: UNDONE LOCALLY. No push was performed.'
}

try {
    # Locate the repository from the script folder first, then from the current folder.
    $candidateFolders = @()
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $candidateFolders += $PSScriptRoot }
    $candidateFolders += (Get-Location).Path

    $script:RepoRoot = $null

foreach ($folder in ($candidateFolders | Select-Object -Unique)) {
    $rootOutput = & git -C $folder rev-parse --show-toplevel 2>$null
    $gitExitCode = $LASTEXITCODE

    if ($gitExitCode -eq 0 -and $null -ne $rootOutput) {
        # Git may return a scalar string rather than an array.
        # Convert the output to an array before joining it.
        $rootText = (@($rootOutput) -join [Environment]::NewLine).Trim()

        if (-not [string]::IsNullOrWhiteSpace($rootText)) {
            $script:RepoRoot = [System.IO.Path]::GetFullPath($rootText)
            break
        }
    }
}

    if (-not $script:RepoRoot) {
        throw 'Could not find a Git repository. Save this script in the repository or run it from the repository folder.'
    }

    Set-Location $script:RepoRoot
    $script:StateFileName = $StateFileName

    Write-Host ''
    Write-Host 'ClassDelta Upstream Sync'
    Write-Host '========================'
    Write-Host "Repository:     $($script:RepoRoot)"
    Write-Host "Target branch:  $TargetBranch"
    Write-Host "Upstream URL:   $UpstreamUrl"
    Write-Host "Upstream branch: $UpstreamBranch"
    Write-Host ''
    Write-Host '1. Start a new sync'
    Write-Host '2. Preview eligible commits (no cherry-pick)'
    Write-Host '3. Continue an interrupted sync after resolving conflicts'
    Write-Host '4. Undo the last sync'
    Write-Host '5. Exit'

    $mode = Read-Host 'Select a mode (1-5)'
    switch ($mode) {
        '1' { Start-NewSync }
        '2' { Preview-Sync }
        '3' { Continue-PreviousSync }
        '4' { Undo-PreviousSync }
        '5' { Write-Host 'Exit. No operation was requested.'; return }
        default { throw 'Invalid menu selection. Run the script again and choose 1, 2, 3, 4, or 5.' }
    }
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No push was performed.'
    return
}