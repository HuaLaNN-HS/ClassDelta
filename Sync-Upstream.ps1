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
    param([Parameter(Mandatory = $true)][string]$GitPathName)

    $result = @(& git -C $script:RepoRoot rev-parse --git-path $GitPathName)
    if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) {
        throw "Unable to resolve Git metadata path: $GitPathName"
    }

    $path = (@($result) -join [Environment]::NewLine).Trim()
    if ([System.IO.Path]::IsPathRooted($path)) {
        return $path
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot $path))
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
    Assert-ClassDeltaRepository
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
    Assert-ClassDeltaRepository
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
    Assert-ClassDeltaRepository
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
    Assert-ClassDeltaRepository
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


function Get-RepositoryRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Repository path does not exist or is not a folder: $Path"
    }

    $output = & git -C $Path rev-parse --show-toplevel 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $null -eq $output) {
        throw "The selected folder is not inside a Git repository: $Path"
    }

    # Never index a scalar PowerShell string: $output[0] would return only its first character.
    $rootText = (@($output) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($rootText)) {
        throw "Git returned an empty repository path for: $Path"
    }
    return [System.IO.Path]::GetFullPath($rootText)
}

function Load-UserConfig {
    $configPath = $script:UserConfigPath
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]@{
            LastRepo = $script:RepoRoot
            LastBranch = ''
            LastRemote = 'origin'
        }
    }

    try {
        $loaded = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            LastRepo = [string]$loaded.LastRepo
            LastBranch = [string]$loaded.LastBranch
            LastRemote = [string]$loaded.LastRemote
        }
    }
    catch {
        Write-Host "WARNING: Could not read user settings at $configPath. Defaults will be used." -ForegroundColor Yellow
        return [pscustomobject]@{
            LastRepo = $script:RepoRoot
            LastBranch = ''
            LastRemote = 'origin'
        }
    }
}

function Save-UserConfig {
    $config = [pscustomobject]@{
        LastRepo = $script:UserConfig.LastRepo
        LastBranch = $script:UserConfig.LastBranch
        LastRemote = $script:UserConfig.LastRemote
        UpdatedAtUtc = [datetime]::UtcNow.ToString('o')
    }

    $directory = Split-Path -Parent $script:UserConfigPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = "$($script:UserConfigPath).tmp"
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $script:UserConfigPath -Force
}

function Set-ActiveRepository {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)

    $newRoot = Get-RepositoryRoot -Path $RepositoryPath
    $oldRoot = $script:RepoRoot

    if (-not [string]::Equals(
        $newRoot.TrimEnd([char[]]@('\', '/')),
        $oldRoot.TrimEnd([char[]]@('\', '/')),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        Write-Host ''
        Write-Host 'Repository switch requested:' -ForegroundColor Yellow
        Write-Host "  Current:  $oldRoot"
        Write-Host "  Selected: $newRoot"
        $confirmation = Read-Host 'Type SWITCH to confirm changing the active repository'
        if ($confirmation -cne 'SWITCH') {
            throw 'Repository switch cancelled. The active repository was not changed.'
        }
    }

    $script:RepoRoot = $newRoot
    Set-Location -LiteralPath $newRoot
    $script:UserConfig.LastRepo = $newRoot
    Save-UserConfig

    Write-Host "Active repository: $newRoot" -ForegroundColor Green
}

function Assert-ClassDeltaRepository {
    $remotes = @(Get-RemoteNames)
    foreach ($remote in $remotes) {
        $url = Get-RemoteUrl $remote
        if ($url -match '(?i)(github\.com[:/]HuaLaNN-HS/ClassDelta(?:\.git)?/?$)') {
            return
        }
    }

    Write-Host 'The upstream sync actions are intended only for HuaLaNN-HS/ClassDelta.' -ForegroundColor Yellow
    Write-Host "Active repository: $($script:RepoRoot)"
    throw 'No configured remote points to github.com/HuaLaNN-HS/ClassDelta. Use the Commit and Push task for other repositories.'
}

function Get-RemoteNames {
    return @(Get-GitOutput @('remote') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Get-RemoteUrl {
    param([Parameter(Mandatory = $true)][string]$RemoteName)

    $url = @(Get-GitOutput @('remote', 'get-url', $RemoteName))
    if ($url.Count -eq 0) {
        throw "No URL is configured for remote '$RemoteName'."
    }
    return ([string]$url[0]).Trim()
}

function Assert-NoChangesIncludingUntracked {
    $entries = @(Get-GitOutput @('status', '--porcelain', '--untracked-files=all'))
    if ($entries.Count -gt 0) {
        Write-Host 'The working tree must be clean before switching branches.' -ForegroundColor Yellow
        foreach ($entry in $entries) {
            Write-Host "  $entry"
        }
        throw 'Branch switch cancelled because the working tree is not clean.'
    }
}

function Switch-ToBranch {
    param(
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$Remote
    )

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw 'A branch name cannot be empty.'
    }

    $current = Get-CurrentBranch
    if ($current -eq $Branch) {
        return
    }

    Assert-NoChangesIncludingUntracked

    if ((Get-GitExitCode @('show-ref', '--verify', '--quiet', "refs/heads/$Branch")) -eq 0) {
        Invoke-Git @('switch', $Branch)
        return
    }

    Write-Host "Local branch '$Branch' does not exist. Checking remote '$Remote'..."
    Invoke-Git @('fetch', $Remote, '--prune')

    $remoteRef = "refs/remotes/$Remote/$Branch"
    if ((Get-GitExitCode @('show-ref', '--verify', '--quiet', $remoteRef)) -ne 0) {
        throw "Branch '$Branch' does not exist locally or on remote '$Remote'."
    }

    Invoke-Git @('switch', '--track', '-c', $Branch, "$Remote/$Branch")
}

function Get-BackupBranchNames {
    return @(
        Get-GitOutput @('for-each-ref', '--format=%(refname:short)', 'refs/heads/backup') |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
}

function Get-ProtectedBackupBranch {
    $statePath = Get-SyncStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return ''
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.Status -ne 'Undone' -and -not [string]::IsNullOrWhiteSpace([string]$state.BackupBranch)) {
            return [string]$state.BackupBranch
        }
    }
    catch {
        Write-Host 'WARNING: The sync state could not be read while checking protected backups.' -ForegroundColor Yellow
    }
    return ''
}

function Show-Backups {
    $branches = @(Get-BackupBranchNames)
    if ($branches.Count -eq 0) {
        Write-Host 'No local backup branches were found.'
        return
    }

    $protected = Get-ProtectedBackupBranch
    Write-Host ''
    Write-Host 'Local backup branches:' -ForegroundColor Cyan
    foreach ($branch in $branches) {
        $details = @(Get-GitOutput @('show', '-s', '--format=%h | %cI | %s', $branch))
        $marker = if ($branch -eq $protected) { ' [PROTECTED: referenced by sync state]' } else { '' }
        $detail = if ($details.Count -gt 0) { [string]$details[0] } else { '' }
        Write-Host "  $branch | $detail$marker"
    }
}

function Delete-BackupBranch {
    $branches = @(Get-BackupBranchNames)
    if ($branches.Count -eq 0) {
        Write-Host 'No local backup branches were found.'
        return
    }

    Show-Backups
    Write-Host ''
    $branch = Read-Host 'Enter the exact backup branch name to delete (or press Enter to cancel)'
    if ([string]::IsNullOrWhiteSpace($branch)) {
        Write-Host 'Cancelled. No backup branch was deleted.'
        return
    }
    if ($branches -notcontains $branch) {
        throw "The branch '$branch' is not a local backup branch under refs/heads/backup."
    }
    if ($branch -eq (Get-CurrentBranch)) {
        throw 'The active branch cannot be deleted.'
    }

    $protected = Get-ProtectedBackupBranch
    if ($branch -eq $protected) {
        Write-Host 'WARNING: This backup is referenced by the current sync state.' -ForegroundColor Yellow
        Write-Host 'Deleting it reduces rollback convenience. The sync record will be updated.'
    }

    $confirmation = Read-Host "Type DELETE $branch to confirm"
    if ($confirmation -cne "DELETE $branch") {
        Write-Host 'Cancelled. No backup branch was deleted.'
        return
    }

    # -d is intentionally used instead of -D. Git will refuse to delete an unmerged backup.
    Invoke-Git @('branch', '-d', $branch)

    if ($branch -eq $protected) {
        $statePath = Get-SyncStatePath
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $state.BackupBranch = $null
            $state.BackupDeletedAtUtc = [datetime]::UtcNow.ToString('o')
            Write-SyncState $state
        }
    }

    Write-Host "Backup branch deleted: $branch" -ForegroundColor Green
}

function Prune-MergedBackups {
    $branches = @(Get-BackupBranchNames)
    if ($branches.Count -eq 0) {
        Write-Host 'No local backup branches were found.'
        return
    }

    $current = Get-CurrentBranch
    $protected = Get-ProtectedBackupBranch
    $candidates = @()

    foreach ($branch in $branches) {
        if ($branch -eq $current -or $branch -eq $protected) {
            continue
        }
        if ((Get-GitExitCode @('merge-base', '--is-ancestor', $branch, 'HEAD')) -eq 0) {
            $candidates += $branch
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Host 'No safely removable merged backup branches were found.'
        Write-Host 'The current sync backup is protected, and unmerged backups are never force-deleted.'
        return
    }

    Write-Host ''
    Write-Host 'The following backups are ancestors of the current HEAD and are not protected:' -ForegroundColor Cyan
    foreach ($branch in $candidates) {
        Write-Host "  $branch"
    }

    $confirmation = Read-Host 'Type PRUNE to delete these branches using safe git branch -d'
    if ($confirmation -cne 'PRUNE') {
        Write-Host 'Cancelled. No backup branches were deleted.'
        return
    }

    foreach ($branch in $candidates) {
        try {
            Invoke-Git @('branch', '-d', $branch)
            Write-Host "Deleted: $branch" -ForegroundColor Green
        }
        catch {
            Write-Host "Kept: $branch. Git refused to delete it safely." -ForegroundColor Yellow
        }
    }
}

function Show-RepositoryStatus {
    $branch = Get-CurrentBranch
    Write-Host ''
    Write-Host "Repository: $($script:RepoRoot)"
    Write-Host "Branch:     $branch"
    Write-Host ''

    $remotes = @(Get-RemoteNames)
    if ($remotes.Count -eq 0) {
        Write-Host 'Remotes: none configured' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Remotes:'
        foreach ($remote in $remotes) {
            Write-Host "  $remote -> $(Get-RemoteUrl $remote)"
        }
    }

    Write-Host ''
    Invoke-Git @('status', '--short', '--branch')
    Write-Host ''
    Write-Host 'Recent commits:'
    Invoke-Git @('log', '-5', '--oneline', '--decorate')
}

function Resolve-RemoteSelection {
    param(
        [Parameter(Mandatory = $true)][string]$InputValue,
        [Parameter(Mandatory = $true)][string[]]$AvailableRemotes,
        [Parameter(Mandatory = $true)][string]$DefaultRemote
    )

    $value = $InputValue.Trim()
    if ($AvailableRemotes -contains $value) {
        if ($value -ne $DefaultRemote) {
            Write-Host "Remote switch requested: '$DefaultRemote' -> '$value'" -ForegroundColor Yellow
            $confirmation = Read-Host 'Type SWITCH REMOTE to confirm changing the push destination'
            if ($confirmation -cne 'SWITCH REMOTE') {
                throw 'Remote switch cancelled.'
            }
        }
        return $value
    }

    if ($value -match '^(https?://|ssh://|git@[^:]+:)') {
        foreach ($candidate in $AvailableRemotes) {
            $candidateUrl = (Get-RemoteUrl $candidate).Trim().TrimEnd('/')
            $inputUrl = $value.Trim().TrimEnd('/')
            if ($candidateUrl.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
                $candidateUrl = $candidateUrl.Substring(0, $candidateUrl.Length - 4)
            }
            if ($inputUrl.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
                $inputUrl = $inputUrl.Substring(0, $inputUrl.Length - 4)
            }

            if ([string]::Equals($candidateUrl, $inputUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($candidate -ne $DefaultRemote) {
                    Write-Host "Remote switch requested: '$DefaultRemote' -> '$candidate'" -ForegroundColor Yellow
                    $confirmation = Read-Host 'Type SWITCH REMOTE to confirm changing the push destination'
                    if ($confirmation -cne 'SWITCH REMOTE') {
                        throw 'Remote switch cancelled.'
                    }
                }
                return $candidate
            }
        }

        Write-Host ''
        Write-Host 'The specified repository URL is not configured as a Git remote.' -ForegroundColor Yellow
        Write-Host "URL: $value"
        $confirmation = Read-Host 'Type ADD REMOTE to add it as a new remote'
        if ($confirmation -cne 'ADD REMOTE') {
            throw 'Adding the remote was cancelled.'
        }

        $remoteName = 'push-target'
        $suffix = 1
        while ($AvailableRemotes -contains $remoteName) {
            $remoteName = "push-target-$suffix"
            $suffix++
        }

        Invoke-Git @('remote', 'add', $remoteName, $value)
        Write-Host "Added remote '$remoteName' -> $value" -ForegroundColor Green
        return $remoteName
    }

    throw "Remote '$value' is not configured. Enter an existing remote name or a repository URL."
}

function Invoke-CommitAndPush {
    $lastRepo = [string]$script:UserConfig.LastRepo
    if ([string]::IsNullOrWhiteSpace($lastRepo) -or -not (Test-Path -LiteralPath $lastRepo -PathType Container)) {
        $lastRepo = $script:RepoRoot
    }

    Write-Host ''
    $repoInput = Read-Host "Repository folder (press Enter to use last used: $lastRepo)"
    $requestedRepo = if ([string]::IsNullOrWhiteSpace($repoInput)) { $lastRepo } else { $repoInput }
    $resolvedRepo = Get-RepositoryRoot -Path $requestedRepo

    if (-not [string]::Equals(
        $resolvedRepo.TrimEnd([char[]]@('\', '/')),
        $script:RepoRoot.TrimEnd([char[]]@('\', '/')),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        Write-Host ''
        Write-Host 'You are about to switch the active repository.' -ForegroundColor Yellow
        Write-Host "  Current:  $($script:RepoRoot)"
        Write-Host "  Selected: $resolvedRepo"
        $switchConfirmation = Read-Host 'Type SWITCH to confirm'
        if ($switchConfirmation -cne 'SWITCH') {
            Write-Host 'Cancelled. Active repository unchanged.'
            return
        }
        $script:RepoRoot = $resolvedRepo
        Set-Location -LiteralPath $resolvedRepo
        $script:UserConfig.LastRepo = $resolvedRepo
        Save-UserConfig
    }

    $remotes = @(Get-RemoteNames)
    if ($remotes.Count -eq 0) {
        throw 'No Git remotes are configured in the selected repository.'
    }

    $defaultRemote = [string]$script:UserConfig.LastRemote
    if ([string]::IsNullOrWhiteSpace($defaultRemote) -or $remotes -notcontains $defaultRemote) {
        if ($remotes -contains 'origin') {
            $defaultRemote = 'origin'
        }
        else {
            $defaultRemote = [string]$remotes[0]
        }
    }

    Write-Host ''
    Write-Host 'Available remotes:'
    foreach ($remote in $remotes) {
        Write-Host "  $remote -> $(Get-RemoteUrl $remote)"
    }
    $remoteInput = Read-Host "Remote name or repository URL (press Enter to use last used: $defaultRemote)"
    $remoteChoice = if ([string]::IsNullOrWhiteSpace($remoteInput)) { $defaultRemote } else { $remoteInput.Trim() }
    $remote = Resolve-RemoteSelection -InputValue $remoteChoice -AvailableRemotes $remotes -DefaultRemote $defaultRemote
    $remoteUrl = Get-RemoteUrl $remote

    $currentBranch = Get-CurrentBranch
    $defaultBranch = [string]$script:UserConfig.LastBranch
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        $defaultBranch = $currentBranch
    }
    $branchInput = Read-Host "Target branch (press Enter to use last used: $defaultBranch)"
    $branch = if ([string]::IsNullOrWhiteSpace($branchInput)) { $defaultBranch } else { $branchInput.Trim() }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'A target branch must be selected.'
    }

    Switch-ToBranch -Branch $branch -Remote $remote

    $script:UserConfig.LastRepo = $script:RepoRoot
    $script:UserConfig.LastBranch = $branch
    $script:UserConfig.LastRemote = $remote
    Save-UserConfig

    Write-Host ''
    Write-Host 'Selected push target:'
    Write-Host "  Repository: $($script:RepoRoot)"
    Write-Host "  Branch:     $branch"
    Write-Host "  Remote:     $remote"
    Write-Host "  URL:        $remoteUrl"
    Write-Host ''

    $status = @(Get-GitOutput @('status', '--short', '--untracked-files=all'))
    if ($status.Count -eq 0) {
        Write-Host 'There are no working-tree changes to commit.'
        $confirmation = Read-Host "Type PUSH to push existing commits to '$remote/$branch', or press Enter to cancel"
        if ($confirmation -cne 'PUSH') {
            Write-Host 'Cancelled. No push was performed.'
            return
        }
        Invoke-Git @('push', '-u', $remote, $branch)
        Write-Host 'Push completed.' -ForegroundColor Green
        return
    }

    Write-Host 'The following changes are present:'
    foreach ($entry in $status) {
        Write-Host "  $entry"
    }

    $message = Read-Host 'Commit message (required; blank cancels)'
    if ([string]::IsNullOrWhiteSpace($message)) {
        Write-Host 'Cancelled. No files were staged, committed, or pushed.'
        return
    }

    Write-Host ''
    Write-Host 'This operation will run: git add ., git commit, and git push.'
    Write-Host 'All changes under the repository folder, including untracked files, may be staged.'
    Write-Host "Push destination: $remoteUrl ($remote/$branch)"
    $confirmation = Read-Host 'Type PUSH to continue'
    if ($confirmation -cne 'PUSH') {
        Write-Host 'Cancelled. No files were staged, committed, or pushed.'
        return
    }

    Invoke-Git @('add', '.')

    $staged = @(Get-GitOutput @('diff', '--cached', '--name-status'))
    if ($staged.Count -gt 0) {
        Write-Host ''
        Write-Host 'Staged changes:'
        foreach ($entry in $staged) {
            Write-Host "  $entry"
        }
        Invoke-Git @('commit', '-m', $message)
    }
    else {
        Write-Host 'No staged changes were found after git add .; no empty commit was created.'
    }

    try {
        Invoke-Git @('push', '-u', $remote, $branch)
        Write-Host 'Commit/push task completed successfully.' -ForegroundColor Green
    }
    catch {
        Write-Host 'The local commit, if created, remains in the repository, but the push failed.' -ForegroundColor Yellow
        throw
    }
}

function Switch-ActiveRepositoryMenu {
    $defaultRepo = [string]$script:UserConfig.LastRepo
    if ([string]::IsNullOrWhiteSpace($defaultRepo)) {
        $defaultRepo = $script:RepoRoot
    }

    $path = Read-Host "Repository folder to activate (press Enter to use last used: $defaultRepo)"
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $defaultRepo
    }

    Set-ActiveRepository -RepositoryPath $path
}

function Invoke-BackupDeleteTask {
    Delete-BackupBranch
}

function Invoke-BackupPruneTask {
    Prune-MergedBackups
}

function Invoke-SyncTask {
    Start-NewSync
}

function Invoke-PreviewTask {
    Preview-Sync
}

function Invoke-ContinueTask {
    Continue-PreviousSync
}

function Invoke-UndoTask {
    Undo-PreviousSync
}

try {
    $script:UserConfigPath = Join-Path $env:USERPROFILE '.classdelta-git-helper.json'

    # Find the repository from the script folder first, then from the current folder.
    $candidateFolders = @()
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidateFolders += $PSScriptRoot
    }
    $candidateFolders += (Get-Location).Path

    $script:RepoRoot = $null
    foreach ($folder in ($candidateFolders | Select-Object -Unique)) {
        try {
            $script:RepoRoot = Get-RepositoryRoot -Path $folder
            break
        }
        catch {
            # Try the next candidate folder.
        }
    }

    if (-not $script:RepoRoot) {
        throw 'Could not find a Git repository. Save this script inside a repository or run it from a repository folder.'
    }

    Set-Location -LiteralPath $script:RepoRoot
    $script:StateFileName = $StateFileName
    $script:TargetBranch = $TargetBranch
    $script:UpstreamUrl = $UpstreamUrl
    $script:UpstreamBranch = $UpstreamBranch
    $script:UpstreamRef = $UpstreamRef

    $script:UserConfig = Load-UserConfig
    if ([string]::IsNullOrWhiteSpace([string]$script:UserConfig.LastRepo) -or
        -not (Test-Path -LiteralPath ([string]$script:UserConfig.LastRepo) -PathType Container)) {
        $script:UserConfig.LastRepo = $script:RepoRoot
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:UserConfig.LastRemote)) {
        $script:UserConfig.LastRemote = 'origin'
    }
    Save-UserConfig

    while ($true) {
        $currentBranch = Get-CurrentBranch
        Write-Host ''
        Write-Host 'ClassDelta Git Helper'
        Write-Host '====================='
        Write-Host "Active repository: $($script:RepoRoot)"
        Write-Host "Current branch:    $currentBranch"
        Write-Host "Last used branch:  $($script:UserConfig.LastBranch)"
        Write-Host "Last used remote:  $($script:UserConfig.LastRemote)"
        Write-Host ''
        Write-Host '1. Start a new upstream sync'
        Write-Host '2. Preview eligible upstream commits'
        Write-Host '3. Continue an interrupted sync'
        Write-Host '4. Undo the last sync'
        Write-Host '5. Commit and push (git add ., git commit, git push)'
        Write-Host '6. List backup branches'
        Write-Host '7. Delete one backup branch'
        Write-Host '8. Prune safely merged backup branches'
        Write-Host '9. Show repository status and recent commits'
        Write-Host '10. Switch active repository'
        Write-Host '11. Exit'

        $mode = Read-Host 'Select a task (1-11)'

        try {
            switch ($mode) {
                '1' { Start-NewSync }
                '2' { Preview-Sync }
                '3' { Continue-PreviousSync }
                '4' { Undo-PreviousSync }
                '5' { Invoke-CommitAndPush }
                '6' { Show-Backups }
                '7' { Delete-BackupBranch }
                '8' { Prune-MergedBackups }
                '9' { Show-RepositoryStatus }
                '10' { Switch-ActiveRepositoryMenu }
                '11' {
                    Write-Host 'Exit. No further operation was requested.'
                    return
                }
                default {
                    Write-Host 'Invalid selection. Choose a number from 1 to 11.' -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host ''
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'No push was performed unless the push command had already started.'
        }

        Write-Host ''
        [void](Read-Host 'Press Enter to return to the main menu')
    }
}
catch {
    Write-Host ''
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No automatic push was performed.'
    return
}
