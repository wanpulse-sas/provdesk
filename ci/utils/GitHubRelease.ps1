. (Join-Path $PSScriptRoot 'GitHubApp.ps1')

function Invoke-GitHubCli([string[]]$Arguments) {
    $executable = (Get-Command gh -CommandType Application -ErrorAction Stop).Source
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $output = & $executable @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($null -eq $code -or $code -ne 0) {
        throw "GitHub CLI failed (exit $code). Check repository access and release/tag conflicts."
    }
    return ($output | ForEach-Object { $_.ToString() }) -join "`n"
}

function Get-GitHubReleaseRepository {
    $repository = $env:GITHUB_RELEASE_REPOSITORY
    if ([string]::IsNullOrWhiteSpace($repository)) { $repository = 'wanpulse-sas/provdesk' }
    if ($repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') {
        throw 'GITHUB_RELEASE_REPOSITORY must be owner/repository.'
    }
    return $repository
}

function Assert-GitHubReleaseAccess {
    if ($env:BITBUCKET_BRANCH -cne 'master') { throw 'GitHub publication is restricted to master.' }
    if ($env:BITBUCKET_COMMIT -notmatch '\A[0-9a-fA-F]{40}\z' -or
        [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        throw 'GitHub publication requires BITBUCKET_COMMIT and a GitHub App installation token.'
    }
    $repository = Get-GitHubReleaseRepository
    $ref = Invoke-GitHubCli -Arguments @('api', "repos/$repository/git/ref/heads/master", '--hostname', 'github.com') | ConvertFrom-Json
    if ($ref.object.type -ne 'commit') { throw 'GitHub master must reference a commit.' }
}

function Sync-GitHubMaster {
    Assert-GitHubReleaseAccess
    $repository = Get-GitHubReleaseRepository
    $executable = (Get-Command git -CommandType Application -ErrorAction Stop).Source
    $previousPreference = $ErrorActionPreference
    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        # Use the scoped App token through gh, without persisting credentials or pushing build patches.
        $null = & $executable -c http.extraHeader= -c credential.helper= -c 'credential.helper=!gh auth git-credential' `
            -c credential.interactive=false -c core.askPass= -c push.recurseSubmodules=no `
            push --no-force --no-follow-tags "https://github.com/$repository.git" "${env:BITBUCKET_COMMIT}:refs/heads/master" 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        $env:GIT_TERMINAL_PROMPT = $previousPrompt
    }
    if ($null -eq $code -or $code -ne 0) {
        throw "GitHub master synchronization failed (exit $code). Check divergence, App permissions and branch protection; publication stopped."
    }
    Write-Host "GitHub master synchronized to signed build commit $env:BITBUCKET_COMMIT."
}

function Publish-SignedGitHubRelease([string]$OutputDirectory) {
    Assert-GitHubReleaseAccess
    $manifest = Get-Content -LiteralPath "$OutputDirectory/build.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($env:BITBUCKET_BUILD_NUMBER -notmatch '\A[0-9]+\z' -or
        $manifest.BuildNumber -ne $env:BITBUCKET_BUILD_NUMBER -or
        $manifest.SourceCommit -ne $env:BITBUCKET_COMMIT -or
        $manifest.PipelineCommit -ne $env:BITBUCKET_COMMIT) {
        throw 'GitHub publication requires the signed output of the current Bitbucket build.'
    }
    $installer = Join-Path $OutputDirectory 'ProVdesk.exe'
    Assert-Signature $installer
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    if ($hash -ne $manifest.FinalSHA256 -or (Get-InstallerVersion $installer) -cne $manifest.Version) {
        throw 'The signed installer does not match its build manifest.'
    }
    if ($manifest.Version -notmatch '\A(?:[0-9]+\.){3}([0-9]+)\z' -or $Matches[1] -cne $env:BITBUCKET_BUILD_NUMBER) {
        throw "Expected a four-part product version ending in Bitbucket build $env:BITBUCKET_BUILD_NUMBER, got '$($manifest.Version)'."
    }
    if ((Get-Content -LiteralPath "$installer.sha256" -Raw).Trim() -cne "$hash  ProVdesk.exe") {
        throw 'The installer checksum file does not match the signed executable.'
    }
    $repository = Get-GitHubReleaseRepository
    $tag = "provdesk-$($manifest.Version)"
    $directory = New-Item -ItemType Directory -Path "$OutputDirectory/github-release" -Force
    $assetName = "ProVdesk-$($manifest.Version)-windows-x86_64.exe"
    $releaseExe = Join-Path $directory.FullName $assetName
    Copy-Item -LiteralPath $installer -Destination $releaseExe -Force
    if ((Get-FileHash -LiteralPath $releaseExe -Algorithm SHA256).Hash -ne $hash) {
        throw 'Release staging changed the signed installer.'
    }
    Set-Content -LiteralPath "$releaseExe.sha256" -Value "$hash  $assetName" -Encoding ASCII
    $files = @($releaseExe, "$releaseExe.sha256", "$OutputDirectory/build.json")
    $notices = Join-Path $OutputDirectory 'THIRD-PARTY.txt'
    if (-not (Test-Path -LiteralPath $notices -PathType Leaf)) { throw 'Missing third-party notices.' }
    $files += $notices
    $notes = @"
## Downloads

| Architecture | Windows |
| --- | --- |
| x86-64 (64-bit) | [Signed EXE](https://github.com/$repository/releases/download/$tag/$assetName) |

[Third-party notices and component sources](https://github.com/$repository/releases/download/$tag/THIRD-PARTY.txt)

## ProVdesk

- ProVdesk application branding and Windows installer by WanPulse SAS.
- Configurable servers, enforced WebSocket transport and provdesk:// links.
- Installer and bundled application binaries signed with the WanPulse SAS signing framework.

## Build

- Product version: $($manifest.Version)
- Bitbucket build: $($manifest.BuildNumber)
- Source commit: $($manifest.SourceCommit)
- [Matching sources](https://github.com/$repository/tree/$tag)
- Installer SHA-256: $hash

The checksum file and build.json provide download verification and build provenance.
"@
    $notesPath = Join-Path $directory.FullName 'release-notes.md'
    [IO.File]::WriteAllText($notesPath, $notes, (New-Object Text.UTF8Encoding($false)))
    Sync-GitHubMaster
    # Creating the ref fails if it already exists; never move a tag or replace release assets.
    $null = Invoke-GitHubCli -Arguments @('api', "repos/$repository/git/refs", '--hostname', 'github.com',
        '--method', 'POST', '--raw-field', "ref=refs/tags/$tag", '--raw-field', "sha=$($manifest.SourceCommit)")
    $null = Invoke-GitHubCli -Arguments (@('release', 'create', $tag, '--repo', "github.com/$repository",
        '--verify-tag', '--draft', '--title', "ProVdesk $($manifest.Version)",
        '--notes-file', $notesPath) + $files)
    $release = Invoke-GitHubCli -Arguments @('release', 'view', $tag, '--repo', "github.com/$repository", '--json', 'databaseId') | ConvertFrom-Json
    $endpoint = "repos/$repository/releases/$($release.databaseId)"
    $uploaded = Invoke-GitHubCli -Arguments @('api', $endpoint, '--hostname', 'github.com') | ConvertFrom-Json
    if (-not $uploaded.draft -or @($uploaded.assets).Count -ne $files.Count) {
        throw 'The GitHub draft release does not contain the expected assets.'
    }
    foreach ($file in $files) {
        $asset = @($uploaded.assets | Where-Object { $_.name -ceq [IO.Path]::GetFileName($file) })
        $digest = 'sha256:' + (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($asset.Count -ne 1 -or $asset[0].state -ne 'uploaded' -or $asset[0].digest -cne $digest) {
            throw 'GitHub asset verification failed; the release remains a draft.'
        }
    }
    $null = Invoke-GitHubCli -Arguments @('release', 'edit', $tag, '--repo', "github.com/$repository", '--verify-tag', '--draft=false')
    $published = Invoke-GitHubCli -Arguments @('api', $endpoint, '--hostname', 'github.com') | ConvertFrom-Json
    if ($published.draft) { throw 'GitHub release publication was not confirmed.' }
    Write-Host "Published GitHub release: https://github.com/$repository/releases/tag/$tag"
}
