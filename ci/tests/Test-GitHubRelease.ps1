#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../utils/GitHubRelease.ps1')
$saved = @{}
foreach ($name in @('BITBUCKET_BRANCH', 'BITBUCKET_COMMIT', 'BITBUCKET_BUILD_NUMBER', 'GH_TOKEN', 'GITHUB_RELEASE_REPOSITORY')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $env:BITBUCKET_BRANCH = 'master'
    $env:BITBUCKET_COMMIT = 'a' * 40
    $env:BITBUCKET_BUILD_NUMBER = '19'
    $env:GH_TOKEN = 'fixture-token'
    $env:GITHUB_RELEASE_REPOSITORY = 'fixture/product'
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $fixture = Join-Path $root ('work/github-release-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Set-Content "$fixture/ProVdesk.exe" 'signed fixture'
    $hash = (Get-FileHash "$fixture/ProVdesk.exe").Hash
    Set-Content "$fixture/ProVdesk.exe.sha256" "$hash  ProVdesk.exe"
    $fixtureManifest = @{ Version = '1.5.0.19'; SourceCommit = $env:BITBUCKET_COMMIT; PipelineCommit = $env:BITBUCKET_COMMIT;
        BuildNumber = '19'; FinalSHA256 = $hash }
    $fixtureManifest | ConvertTo-Json | Set-Content "$fixture/build.json"
    Set-Content "$fixture/THIRD-PARTY.txt" 'notices fixture'
    function Assert-Signature([string]$FilePath) {
        if ($script:mode -eq 'invalid-signature') { throw 'Invalid fixture signature.' }
        $script:signatureChecked = $true
    }
    function Get-InstallerVersion([string]$FilePath) { return $fixtureManifest.Version }
    function Get-Command { return @{ Source = 'Invoke-FixtureGit' } }
    function Invoke-FixtureGit {
        if (-not $script:signatureChecked) { throw 'Synchronization before signature verification.' }
        $global:LASTEXITCODE = 0
        $script:pushAttempted = $true
        if ('--no-force' -notin $args -or '--no-follow-tags' -notin $args -or
            $args[-2] -cne 'https://github.com/fixture/product.git' -or
            $args[-1] -cne "${env:BITBUCKET_COMMIT}:refs/heads/master") {
            throw 'Synchronization did not push only the exact built commit without force.'
        }
        if ('credential.helper=!gh auth git-credential' -notin $args -or $env:GIT_TERMINAL_PROMPT -ne '0') {
            throw 'Synchronization did not use non-interactive App authentication.'
        }
        $global:LASTEXITCODE = 0
        if ($script:mode -eq 'sync-rejected') { $global:LASTEXITCODE = 1; return }
    }
    function Invoke-GitHubCli([string[]]$Arguments) {
        $command = $Arguments[0] + ' ' + $Arguments[1]
        if ($command -eq 'api repos/fixture/product/git/ref/heads/master') {
            if ($script:pushAttempted) { throw 'Unexpected GitHub master read after push.' }
            return (@{ object = @{ type = 'commit'; sha = 'b' * 40 } } | ConvertTo-Json)
        }
        if ($command -eq 'api repos/fixture/product/git/refs') {
            if (-not $script:signatureChecked) { throw 'Unsigned upload attempted.' }
            $script:tagCommit = ($Arguments | Where-Object { $_ -like 'sha=*' }).Substring(4)
            if (-not $script:pushAttempted) { throw 'Tag creation before push.' }
            if ('ref=refs/tags/provdesk-1.5.0.19' -notin $Arguments) { throw 'Incorrect release tag.' }
            return '{}'
        }
        if ($command -eq 'release create') {
            if ($Arguments[2] -cne 'provdesk-1.5.0.19') { throw 'Incorrect release tag_name.' }
            $titleIndex = [array]::IndexOf($Arguments, '--title')
            if ($titleIndex -lt 0 -or $Arguments[$titleIndex + 1] -cne 'ProVdesk 1.5.0.19') { throw 'Incorrect release title.' }
            $script:draft = $true
            $script:assets = @($Arguments | Where-Object { $_ -like "$fixture*" -and $_ -notlike '*release-notes.md' } | ForEach-Object {
                @{ name = [IO.Path]::GetFileName($_); state = 'uploaded'; digest = 'sha256:' + (Get-FileHash $_).Hash.ToLowerInvariant() }
            })
            if ($script:mode -eq 'asset-mismatch') { $script:assets[0].digest = 'sha256:' + ('0' * 64) }
            return ''
        }
        if ($command -eq 'release view') { return '{"databaseId": 123}' }
        if ($command -eq 'api repos/fixture/product/releases/123') {
            return (@{ draft = $script:draft; assets = $script:assets } | ConvertTo-Json -Depth 5)
        }
        if ($command -eq 'release edit') { $script:draft = $false; $script:published = $true; return '' }
        throw "Unexpected fixture request: $command"
    }
    foreach ($script:mode in @('success', 'invalid-signature', 'asset-mismatch', 'sync-rejected')) {
        $script:pushAttempted = $false
        $script:signatureChecked = $false
        $script:published = $false
        $script:draft = $false
        $script:tagCommit = ''
        $script:assets = @()
        $failed = $false
        Assert-GitHubReleaseAccess
        try { Publish-SignedGitHubRelease $fixture } catch { $failed = $true }
        if ($script:mode -eq 'success') {
            if ($failed -or -not $script:pushAttempted -or -not $script:published -or $script:draft -or $script:tagCommit -ne $env:BITBUCKET_COMMIT) {
                throw 'Signed release was not published for the built commit.'
            }
            if (($script:assets.name | Sort-Object) -join ',' -cne 'build.json,ProVdesk-1.5.0.19-windows-x86_64.exe,ProVdesk-1.5.0.19-windows-x86_64.exe.sha256,THIRD-PARTY.txt') {
                throw 'Unexpected release assets.'
            }
        } elseif (-not $failed -or $script:published) { throw 'Invalid release was published.' }
        if ($script:mode -eq 'invalid-signature' -and ($script:pushAttempted -or $script:tagCommit)) { throw 'Invalid signature changed the remote.' }
        if ($script:mode -eq 'sync-rejected' -and (-not $script:pushAttempted -or $script:tagCommit)) { throw 'Failed synchronization did not block release creation.' }
        if ($script:mode -eq 'asset-mismatch' -and -not $script:draft) { throw 'Failed upload did not remain a draft.' }
    }
    $script:mode = 'success'
    foreach ($invalidVersion in @('1.5.19', '1.5.0.0.19', '1.5.x.19', '1.5.0.18')) {
        $fixtureManifest.Version = $invalidVersion
        $fixtureManifest | ConvertTo-Json | Set-Content "$fixture/build.json"
        $script:pushAttempted = $false
        $script:tagCommit = ''
        $failed = $false
        try { Publish-SignedGitHubRelease $fixture } catch {
            if ($_.Exception.Message -notlike 'Expected a four-part product version*') { throw }
            $failed = $true
        }
        if (-not $failed -or $script:pushAttempted -or $script:tagCommit) {
            throw "Expected version $invalidVersion to be rejected before synchronization."
        }
    }
    Write-Host 'Signed build synchronization, push refusal and release checks passed (offline fixtures).'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
