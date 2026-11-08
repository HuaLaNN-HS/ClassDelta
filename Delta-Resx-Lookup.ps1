
# Delta-Resx-Lookup.ps1
# ClassDelta RESX search / audit tool
# Compatible with Windows PowerShell 5.1 and PowerShell 7+
# Read-only: never modifies RESX files.

param(
    [string]$Root = (Join-Path $PSScriptRoot "ClassIsland\Assets\Localization"),
    [string]$Id = "",
    [string]$Keyword = "",
    [switch]$Check
)

$ErrorActionPreference = "Stop"

function Read-ResxIndex {
    param([string]$Folder)

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "RESX directory not found: $Folder"
    }

    $baseDir = (Resolve-Path -LiteralPath $Folder).ProviderPath
    $baseDir = $baseDir.TrimEnd([char[]]@('\', '/'))

    $records = New-Object 'System.Collections.Generic.List[object]'
    $catalogs = New-Object 'System.Collections.Generic.List[object]'

    $files = @(Get-ChildItem -LiteralPath $baseDir -Filter "*.resx" -File -Recurse |
        Where-Object {
            $_.FullName -notmatch '[\\/](bin|obj|\.git)[\\/]'
        })

    foreach ($file in $files) {
        $stem = $file.BaseName
        $lang = "neutral"

        # Examples:
        # Strings.resx          -> neutral
        # Strings.en-US.resx    -> en-US
        # Strings.zh-Hans.resx  -> zh-Hans
        if ($stem -match '^(?<base>.+)\.(?<locale>[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)$') {
            $stem = $Matches["base"]
            $lang = $Matches["locale"]
        }

        $relativeDir = $file.DirectoryName.Substring($baseDir.Length)
        $relativeDir = $relativeDir.TrimStart([char[]]@('\', '/'))
        $relativeDir = $relativeDir.Replace('\', '/')

        if ($relativeDir -ne "") {
            $group = "$relativeDir/$stem"
        }
        else {
            $group = $stem
        }

        $catalogs.Add([pscustomobject]@{
            Group    = $group
            Language = $lang
            File     = $file.FullName
        })

        try {
            [xml]$xml = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        }
        catch {
            throw "Failed to read $($file.FullName): $($_.Exception.Message)"
        }

        foreach ($node in $xml.SelectNodes("/root/data")) {
            $key = $node.GetAttribute("name")

            # Only indexed resources: delta001, delta002, delta1000...
            if (-not [regex]::IsMatch($key, '^delta[0-9]{3,}$')) {
                continue
            }

            $valueNode = $node.SelectSingleNode("value")
            $value = if ($null -ne $valueNode) {
                $valueNode.InnerText
            }
            else {
                ""
            }

            $records.Add([pscustomobject]@{
                Group    = $group
                Language = $lang
                Id       = $key
                Value    = [string]$value
                File     = $file.FullName
            })
        }
    }

    return [pscustomobject]@{
        Records  = @($records.ToArray())
        Catalogs = @($catalogs.ToArray())
        FileCount = $files.Count
    }
}

function Normalize-DeltaId {
    param([string]$InputId)

    $InputId = $InputId.Trim()

    if ($InputId -match '^[0-9]+$') {
        return "delta" + $InputId.PadLeft(3, '0')
    }

    return $InputId
}

function Show-Entry {
    param(
        $Data,
        [string]$Group,
        [string]$Key
    )

    Write-Host ""
    Write-Host ("[{0}] {1}" -f $Group, $Key) -ForegroundColor Cyan

    $languages = @(
        $Data.Catalogs |
            Where-Object { $_.Group -eq $Group } |
            Select-Object -ExpandProperty Language -Unique |
            Sort-Object
    )

    foreach ($lang in $languages) {
        $values = @(
            $Data.Records |
                Where-Object {
                    $_.Group -eq $Group -and
                    $_.Language -eq $lang -and
                    $_.Id -eq $Key
                }
        )

        if ($values.Count -eq 0) {
            $value = "[MISSING]"
        }
        elseif ($values.Count -gt 1) {
            $value = "[DUPLICATE] " +
                (($values | ForEach-Object { $_.Value }) -join " | ")
        }
        elseif ([string]::IsNullOrWhiteSpace($values[0].Value)) {
            $value = "[EMPTY]"
        }
        else {
            $value = $values[0].Value
        }

        Write-Host ("  {0,-12} {1}" -f $lang, $value)
    }
}

function Find-ById {
    param($Data, [string]$InputId)

    $key = Normalize-DeltaId $InputId

    if ($key -notmatch '^delta[0-9]{3,}$') {
        Write-Host "Invalid ID. Example: delta001" -ForegroundColor Yellow
        return
    }

    $groups = @(
        $Data.Records |
            Where-Object { $_.Id -eq $key } |
            Select-Object -ExpandProperty Group -Unique |
            Sort-Object
    )

    if ($groups.Count -eq 0) {
        Write-Host "ID not found: $key" -ForegroundColor Yellow
        return
    }

    foreach ($group in $groups) {
        Show-Entry -Data $Data -Group $group -Key $key
    }
}

function Find-ByKeyword {
    param($Data, [string]$InputKeyword)

    # Multiple keywords separated by | are treated as OR.
    $words = @(
        $InputKeyword -split '\|' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" }
    )

    if ($words.Count -eq 0) {
        Write-Host "Please enter a keyword." -ForegroundColor Yellow
        return
    }

    $matches = @(
        foreach ($record in $Data.Records) {
            foreach ($word in $words) {
                if ($record.Value.IndexOf(
                    $word,
                    [StringComparison]::OrdinalIgnoreCase
                ) -ge 0) {
                    $record
                    break
                }
            }
        }
    )

    if ($matches.Count -eq 0) {
        Write-Host "No matching resources." -ForegroundColor Yellow
        return
    }

    $groups = @(
        $matches |
            Group-Object -Property Group, Id |
            Sort-Object Name
    )

    Write-Host ""
    Write-Host ("Found {0} matching IDs." -f $groups.Count) -ForegroundColor Green

    foreach ($matched in $groups) {
        $first = $matched.Group[0]
        Show-Entry -Data $Data -Group $first.Group -Key $first.Id
    }
}

function Test-ResxTranslations {
    param($Data)

    $issues = 0
    $keyCount = 0

    foreach ($group in @($Data.Catalogs | Group-Object Group)) {
        $name = $group.Name

        $languages = @(
            $group.Group |
                Select-Object -ExpandProperty Language -Unique
        )

        $ids = @(
            $Data.Records |
                Where-Object { $_.Group -eq $name } |
                Select-Object -ExpandProperty Id -Unique
        )

        $keyCount += $ids.Count

        foreach ($key in $ids) {
            foreach ($lang in $languages) {
                $rows = @(
                    $Data.Records |
                        Where-Object {
                            $_.Group -eq $name -and
                            $_.Id -eq $key -and
                            $_.Language -eq $lang
                        }
                )

                if ($rows.Count -eq 0) {
                    Write-Host "[MISSING] $name / $key / $lang" -ForegroundColor Yellow
                    $issues++
                }
                elseif ($rows.Count -gt 1) {
                    Write-Host "[DUPLICATE] $name / $key / $lang" -ForegroundColor Red
                    $issues++
                }
                elseif ([string]::IsNullOrWhiteSpace($rows[0].Value)) {
                    Write-Host "[EMPTY] $name / $key / $lang" -ForegroundColor Yellow
                    $issues++
                }
            }
        }

        $duplicateFiles = @(
            $group.Group |
                Group-Object Language |
                Where-Object { $_.Count -gt 1 }
        )

        foreach ($dup in $duplicateFiles) {
            Write-Host "[DUPLICATE FILE LOCALE] $name / $($dup.Name)" -ForegroundColor Red
            $issues++
        }
    }

    Write-Host ""
    Write-Host "RESX files: $($Data.FileCount)"
    Write-Host "Indexed resource keys: $keyCount"
    Write-Host "Issues: $issues"

    if ($keyCount -eq 0) {
        Write-Host "No deltaXXX keys yet." -ForegroundColor Yellow
    }
    elseif ($issues -eq 0) {
        Write-Host "Audit passed." -ForegroundColor Green
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host "========== ClassDelta RESX Lookup ==========" -ForegroundColor Cyan
    Write-Host "1. Look up ID (all languages)"
    Write-Host "2. Search text (any language, keywords separated by |)"
    Write-Host "3. Check missing / empty / duplicate translations"
    Write-Host "4. Change RESX directory"
    Write-Host "5. Reload RESX files"
    Write-Host "0. Exit"
    Write-Host "============================================"
}

try {
    $data = Read-ResxIndex $Root
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Noninteractive commands
if ($Id -ne "" -and $Keyword -ne "") {
    throw "Use -Id or -Keyword, not both."
}

if ($Id -ne "") {
    Find-ById -Data $data -InputId $Id
    exit 0
}

if ($Keyword -ne "") {
    Find-ByKeyword -Data $data -InputKeyword $Keyword
    exit 0
}

if ($Check) {
    Test-ResxTranslations -Data $data
    exit 0
}

# Interactive mode
while ($true) {
    Write-Host ""
    Write-Host "Directory: $Root"
    Write-Host "Loaded RESX files: $($data.FileCount)"

    Show-Menu
    $choice = Read-Host "Select"

    switch ($choice) {
        "1" {
            $inputId = Read-Host "Enter ID (delta001 or 001)"
            Find-ById -Data $data -InputId $inputId
        }

        "2" {
            $inputKeyword = Read-Host "Enter keyword(s)"
            Find-ByKeyword -Data $data -InputKeyword $inputKeyword
        }

        "3" {
            Test-ResxTranslations -Data $data
        }

        "4" {
            $newRoot = Read-Host "Enter new RESX directory"
            try {
                $newData = Read-ResxIndex $newRoot
                $Root = $newRoot
                $data = $newData
                Write-Host "Directory changed." -ForegroundColor Green
            }
            catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
        }

        "5" {
            try {
                $data = Read-ResxIndex $Root
                Write-Host "Reloaded." -ForegroundColor Green
            }
            catch {
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
        }

        "0" {
            exit 0
        }

        default {
            Write-Host "Invalid selection." -ForegroundColor Yellow
        }
    }
}
