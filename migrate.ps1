<#
.SYNOPSIS
Migrate QQ Music and NetEase Cloud Music playlists to Spotify.

.DESCRIPTION
Supports an interactive menu, direct share-link import, and local CSV/JSON playlist imports.
Use `.\start-migrator.cmd` for the guided flow, or call this script directly for CLI usage.

.EXAMPLE
.\start-migrator.cmd

.EXAMPLE
.\migrate.ps1 help

.EXAMPLE
.\migrate.ps1 login -OpenBrowser

.EXAMPLE
.\migrate.ps1 import-link -SourceLink "https://music.163.com/playlist?id=26467411" -PlaylistName "Imported" -OpenBrowser
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'login', 'inspect-source', 'import', 'fetch-link', 'import-link')]
    [string]$Action,

    [Parameter(Position = 1)]
    [ValidateSet('csv', 'generic-json', 'netease-json', 'qqmusic-json')]
    [string]$Provider = 'csv',

    [string]$ConfigPath,
    [string]$SourcePath,
    [string]$SourceLink,
    [string]$PlaylistName,
    [string]$Description,
    [string]$ReportPath,
    [string]$OutputPath,
    [string]$Market,
    [switch]$Public,
    [switch]$DryRun,
    [switch]$OpenBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\PlaylistMigrator.psm1'
$errorLogPath = Join-Path $PSScriptRoot 'output\last-error.txt'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config\spotify.json'
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $PSScriptRoot 'output\last-report.json'
}

function Read-ChoiceValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedValues,

        [string]$DefaultValue
    )

    $allowedSet = @{}
    foreach ($value in $AllowedValues) {
        $allowedSet[$value] = $true
    }

    while ($true) {
        if ($DefaultValue) {
            $rawValue = Read-Host ('{0} [{1}]' -f $Prompt, $DefaultValue)
        }
        else {
            $rawValue = Read-Host $Prompt
        }

        if ([string]::IsNullOrWhiteSpace($rawValue)) {
            $rawValue = $DefaultValue
        }

        if ($rawValue -and $allowedSet.ContainsKey($rawValue)) {
            return $rawValue
        }

        Write-Host ('Please enter one of: {0}' -f ($AllowedValues -join ', ')) -ForegroundColor Yellow
    }
}

function Read-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }

        Write-Host 'This value cannot be empty.' -ForegroundColor Yellow
    }
}

function Read-OptionalValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$DefaultValue
    )

    if ($DefaultValue) {
        $value = Read-Host ('{0} [{1}]' -f $Prompt, $DefaultValue)
    }
    else {
        $value = Read-Host $Prompt
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value.Trim()
}

function Read-YesNoValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [bool]$DefaultValue = $true
    )

    $defaultToken = if ($DefaultValue) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-Host ('{0} [{1}]' -f $Prompt, $defaultToken)
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultValue
        }

        switch ($value.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
        }

        Write-Host 'Please answer y or n.' -ForegroundColor Yellow
    }
}

function Read-ProviderValue {
    param(
        [string]$DefaultProvider = 'csv'
    )

    Write-Host ''
    Write-Host 'Source file type:'
    Write-Host '1. csv'
    Write-Host '2. generic-json'
    Write-Host '3. netease-json'
    Write-Host '4. qqmusic-json'

    $defaultProviderChoice = switch ($DefaultProvider) {
        'generic-json' { '2' }
        'netease-json' { '3' }
        'qqmusic-json' { '4' }
        default { '1' }
    }

    $providerChoice = Read-ChoiceValue -Prompt 'Choose source file type' -AllowedValues @('1', '2', '3', '4') -DefaultValue $defaultProviderChoice

    switch ($providerChoice) {
        '1' { return 'csv' }
        '2' { return 'generic-json' }
        '3' { return 'netease-json' }
        '4' { return 'qqmusic-json' }
    }
}

function Show-Usage {
    Write-Host ''
    Write-Host 'PlaylistMigrator' -ForegroundColor Cyan
    Write-Host 'Move QQ Music or NetEase playlists to Spotify.'
    Write-Host ''
    Write-Host 'Recommended:'
    Write-Host '  .\start-migrator.cmd'
    Write-Host ''
    Write-Host 'CLI commands:'
    Write-Host '  .\migrate.ps1 help'
    Write-Host '  .\migrate.ps1 login -OpenBrowser'
    Write-Host '  .\migrate.ps1 fetch-link -SourceLink "<share-link>"'
    Write-Host '  .\migrate.ps1 import-link -SourceLink "<share-link>" -PlaylistName "<name>" -OpenBrowser'
    Write-Host '  .\migrate.ps1 inspect-source csv -SourcePath .\samples\generic-playlist.csv'
    Write-Host '  .\migrate.ps1 import qqmusic-json -SourcePath .\samples\qqmusic-playlist.json -PlaylistName "<name>" -OpenBrowser'
    Write-Host ''
    Write-Host 'Tips:'
    Write-Host '  - Run from the repository root when you use relative paths.'
    Write-Host '  - Check output\last-error.txt if a login or import fails.'
    Write-Host '  - Use -DryRun to preview matching without creating a Spotify playlist.'
}

function Start-InteractiveMode {
    Write-Host ''
    Write-Host 'PlaylistMigrator Interactive Mode' -ForegroundColor Cyan
    Write-Host 'Tip: choose 2 if you want to paste a playlist link and import it directly.'
    Write-Host '1. Login to Spotify'
    Write-Host '2. Import from a playlist link to Spotify'
    Write-Host '3. Fetch a playlist link and save it as a file'
    Write-Host '4. Import from a local file to Spotify'
    Write-Host '5. Inspect a local file'
    Write-Host ''

    $menuChoice = Read-ChoiceValue -Prompt 'Choose an action' -AllowedValues @('1', '2', '3', '4', '5') -DefaultValue '2'

    switch ($menuChoice) {
        '1' { $script:Action = 'login' }
        '2' { $script:Action = 'import-link' }
        '3' { $script:Action = 'fetch-link' }
        '4' { $script:Action = 'import' }
        '5' { $script:Action = 'inspect-source' }
    }
}

function Prompt-ForMissingParameters {
    $interactiveMode = [string]::IsNullOrWhiteSpace($Action)
    if ($interactiveMode) {
        Start-InteractiveMode
    }

    switch ($Action) {
        'login' {
            if ($interactiveMode) {
                $script:OpenBrowser = Read-YesNoValue -Prompt 'Open the browser automatically' -DefaultValue $true
            }
        }

        'fetch-link' {
            if (-not $SourceLink) {
                Write-Host ''
                $script:SourceLink = Read-RequiredValue -Prompt 'Paste the playlist share link'
            }
            if ($interactiveMode) {
                $script:OutputPath = Read-OptionalValue -Prompt 'Save path for the exported file (leave blank for default)' -DefaultValue $OutputPath
            }
        }

        'import-link' {
            if (-not $SourceLink) {
                Write-Host ''
                $script:SourceLink = Read-RequiredValue -Prompt 'Paste the playlist share link'
            }
            if ($interactiveMode) {
                $script:PlaylistName = Read-OptionalValue -Prompt 'Spotify playlist name (leave blank to auto-name)' -DefaultValue $PlaylistName
                $script:DryRun = Read-YesNoValue -Prompt 'Dry run only (do not create the playlist yet)' -DefaultValue $false
                if (-not $DryRun) {
                    $script:Public = Read-YesNoValue -Prompt 'Create the Spotify playlist as public' -DefaultValue $false
                }
                $script:OpenBrowser = Read-YesNoValue -Prompt 'Open the browser automatically if login is needed' -DefaultValue $true
            }
        }

        'import' {
            if ($interactiveMode) {
                $script:Provider = Read-ProviderValue -DefaultProvider $Provider
            }
            if (-not $SourcePath) {
                Write-Host ''
                $script:SourcePath = Read-RequiredValue -Prompt 'Enter the local source file path'
            }
            if ($interactiveMode) {
                $script:PlaylistName = Read-OptionalValue -Prompt 'Spotify playlist name (leave blank to auto-name)' -DefaultValue $PlaylistName
                $script:DryRun = Read-YesNoValue -Prompt 'Dry run only (do not create the playlist yet)' -DefaultValue $false
                if (-not $DryRun) {
                    $script:Public = Read-YesNoValue -Prompt 'Create the Spotify playlist as public' -DefaultValue $false
                }
                $script:OpenBrowser = Read-YesNoValue -Prompt 'Open the browser automatically if login is needed' -DefaultValue $true
            }
        }

        'inspect-source' {
            if ($interactiveMode) {
                $script:Provider = Read-ProviderValue -DefaultProvider $Provider
            }
            if (-not $SourcePath) {
                Write-Host ''
                $script:SourcePath = Read-RequiredValue -Prompt 'Enter the local source file path'
            }
        }
    }
}

try {
    Import-Module $modulePath -Force
    Prompt-ForMissingParameters

    switch ($Action) {
        'help' {
            Show-Usage
        }

        'login' {
            $token = Connect-Spotify -ConfigPath $ConfigPath -OpenBrowser:$OpenBrowser
            Write-Host ('Spotify login succeeded. Token saved to: {0}' -f $token.TokenPath)
        }

        'inspect-source' {
            if (-not $SourcePath) {
                throw 'inspect-source requires -SourcePath.'
            }

            $playlist = Import-SourcePlaylist -Provider $Provider -Path $SourcePath
            Write-Host ('Source playlist: {0}' -f $playlist.Name)
            Write-Host ('Track count: {0}' -f $playlist.Tracks.Count)
            $playlist.Tracks |
                Select-Object -First 15 `
                    @{ Name = 'Title'; Expression = { $_.Title } }, `
                    @{ Name = 'Artist'; Expression = { $_.ArtistText } }, `
                    @{ Name = 'Album'; Expression = { $_.Album } }, `
                    @{ Name = 'ISRC'; Expression = { $_.Isrc } } |
                Format-Table -AutoSize
        }

        'import' {
            if (-not $SourcePath) {
                throw 'import requires -SourcePath.'
            }

            $result = Start-PlaylistMigration `
                -ConfigPath $ConfigPath `
                -Provider $Provider `
                -SourcePath $SourcePath `
                -PlaylistName $PlaylistName `
                -Description $Description `
                -ReportPath $ReportPath `
                -Market $Market `
                -Public:$Public `
                -DryRun:$DryRun `
                -OpenBrowser:$OpenBrowser

            if ($DryRun) {
                Write-Host ('Dry run complete. Matched: {0}, Unmatched: {1}, Review: {2}' -f $result.Matched.Count, $result.Unmatched.Count, $result.ReportPath)
            }
            else {
                Write-Host ('Import complete. Matched: {0}, Unmatched: {1}' -f $result.Matched.Count, $result.Unmatched.Count)
                if ($result.PlaylistUrl) {
                    Write-Host ('Spotify playlist: {0}' -f $result.PlaylistUrl)
                }
                Write-Host ('Review report: {0}' -f $result.ReportPath)
            }
        }

        'fetch-link' {
            if (-not $SourceLink) {
                throw 'fetch-link requires -SourceLink.'
            }

            $export = Export-PlaylistFromShareLink -SourceText $SourceLink -OutputPath $OutputPath
            Write-Host ('Fetched provider: {0}' -f $export.ProviderLabel)
            Write-Host ('Playlist: {0}' -f $export.PlaylistName)
            Write-Host ('Track count: {0}' -f $export.TrackCount)
            Write-Host ('Saved import file: {0}' -f $export.OutputPath)
            if ($export.Warning) {
                Write-Warning $export.Warning
            }
        }

        'import-link' {
            if (-not $SourceLink) {
                throw 'import-link requires -SourceLink.'
            }

            $result = Start-PlaylistMigrationFromShareLink `
                -ConfigPath $ConfigPath `
                -SourceText $SourceLink `
                -OutputPath $OutputPath `
                -PlaylistName $PlaylistName `
                -Description $Description `
                -ReportPath $ReportPath `
                -Market $Market `
                -Public:$Public `
                -DryRun:$DryRun `
                -OpenBrowser:$OpenBrowser

            Write-Host ('Fetched import file: {0}' -f $result.ExportPath)
            if ($result.Warning) {
                Write-Warning $result.Warning
            }

            if ($DryRun) {
                Write-Host ('Dry run complete. Matched: {0}, Unmatched: {1}, Review: {2}' -f $result.Matched.Count, $result.Unmatched.Count, $result.ReportPath)
            }
            else {
                Write-Host ('Import complete. Matched: {0}, Unmatched: {1}' -f $result.Matched.Count, $result.Unmatched.Count)
                if ($result.PlaylistUrl) {
                    Write-Host ('Spotify playlist: {0}' -f $result.PlaylistUrl)
                }
                Write-Host ('Review report: {0}' -f $result.ReportPath)
            }
        }
    }
}
catch {
    $errorLogDirectory = Split-Path -Parent $errorLogPath
    if (-not (Test-Path -LiteralPath $errorLogDirectory)) {
        New-Item -ItemType Directory -Path $errorLogDirectory -Force | Out-Null
    }

    $errorReport = @(
        ('Timestamp: {0}' -f (Get-Date).ToString('o'))
        ('Action: {0}' -f $Action)
        ('Provider: {0}' -f $Provider)
        ('ConfigPath: {0}' -f $ConfigPath)
        ''
        'Message:'
        $_.Exception.Message
        ''
        'Details:'
        (($_ | Out-String).TrimEnd())
    ) -join [Environment]::NewLine

    Set-Content -LiteralPath $errorLogPath -Value $errorReport -Encoding UTF8
    Write-Host ('Error: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ('Full error details saved to: {0}' -f $errorLogPath) -ForegroundColor Yellow
    exit 1
}
