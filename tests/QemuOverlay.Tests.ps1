function New-EzVmQemuOverlayFixture {
    param([string]$Root)
    Add-Type -AssemblyName System.IO.Compression
    $fixture = New-EzVmQemuFixture -Root $Root
    $hooks = New-EzVmQemuFixtureHooks -Fixture $fixture
    $originalExpander = $hooks.QemuExpander
    $hooks.QemuExpander = {
        param($Extractor,$Installer,$Destination)
        $result=& $originalExpander $Extractor $Installer $Destination
        [IO.File]::WriteAllText((Join-Path $Destination 'share/firmware.bin'),'original reviewed firmware')
        return $result
    }.GetNewClosure()
    $original = Join-Path $Root 'original reference'
    $null = & $hooks.QemuExpander '' '' $original
    $baseDigest = & (Get-Module EzVm) { param($Path) Get-EzVmQemuBasePayloadDigest -Directory $Path } $original
    $names = @('qemu-system-x86_64.exe', 'qemu-img.exe', 'libglib-2.0-0.dll', 'libiconv-2.dll',
        'libintl-8.dll', 'libpcre2-8-0.dll', 'libslirp-0.dll', 'libwinpthread-1.dll', 'libzstd.dll', 'zlib1.dll')
    $files = @(); $contents = @{}
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($name in $names) {
            $bytes = [Text.Encoding]::UTF8.GetBytes('synthetic reviewed overlay ' + $name)
            $contents[$name] = $bytes
            $files += [pscustomobject]@{name=$name; sizeBytes=[long]$bytes.Length; sha256=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}
        }
    } finally { $hash.Dispose() }
    $archivePath = Join-Path $Root 'overlay fixture.zip'
    Write-EzVmOverlayFixtureZip -Path $archivePath -Names $names -Contents $contents
    $manifest = Read-EzVmJson -Path $fixture.ManifestPath
    $final = Join-Path $Root 'final reference'
    Copy-Item -LiteralPath $original -Destination $final -Recurse
    foreach ($name in $names) { [IO.File]::WriteAllBytes((Join-Path $final $name),$contents[$name]) }
    $installedDigest = & (Get-Module EzVm) { param($Path) Get-EzVmQemuBasePayloadDigest -Directory $Path } $final
    $overlay = [pscustomobject][ordered]@{
        version='11.1.2'; expectedVersionPrefix='11.1.2'
        artifact=[pscustomobject]@{url='https://github.com/techrote/ezvm/releases/download/qemu-whpx-fixture/qemu-whpx-fixture.zip'; filename='qemu-whpx-fixture.zip'; digestAlgorithm='SHA256'; digest=(Get-EzVmFileDigest -Path $archivePath -Algorithm SHA256); sizeBytes=[long](Get-Item -LiteralPath $archivePath).Length}
        baseProviderDigest=$manifest.qemu.digest; basePayloadSha256=$baseDigest; installedPayloadSha256=$installedDigest
        qemuSourceCommit=('1'*40); qemuSourceTree=('2'*40); buildManifestSha256=('3'*64); files=$files
    }
    $manifest | Add-Member -NotePropertyName whpxResetOverlay -NotePropertyValue $overlay
    Write-EzVmJson -Path $fixture.ManifestPath -Value $manifest
    $originalDownloader = $hooks.Downloader
    $hooks.Downloader = {
        param($Url,$Destination)
        if ($Url -match '/qemu-whpx-fixture.zip$') { [IO.File]::Copy($archivePath,$Destination,$false) }
        else { & $originalDownloader $Url $Destination }
    }.GetNewClosure()
    return [pscustomobject]@{Fixture=$fixture; Hooks=$hooks; Archive=$archivePath; Manifest=$manifest; Names=$names; Contents=$contents}
}

function Write-EzVmOverlayFixtureZip {
    param([string]$Path,[string[]]$Names,[hashtable]$Contents)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip=$null
    try {
        $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        foreach($name in $Names){
            $entry=$zip.CreateEntry($name);$output=$entry.Open()
            try {$bytes=$Contents[$name];if($null -eq $bytes){$bytes=[Text.Encoding]::UTF8.GetBytes('unexpected')};$output.Write($bytes,0,$bytes.Length)} finally {$output.Dispose()}
        }
    } finally {if($zip){$zip.Dispose()};$stream.Dispose()}
}

function Invoke-EzVmOverlayFixtureBootstrap {
    param([object]$Value,[string]$Root)
    Install-EzVmQemuRuntime -Root $Root -ManifestPath $Value.Fixture.ManifestPath -Downloader $Value.Hooks.Downloader -ExtractorBootstrapper $Value.Hooks.ExtractorBootstrapper -QemuExpander $Value.Hooks.QemuExpander -PayloadProbe $Value.Hooks.PayloadProbe
}

Add-EzVmTest -Name 'WHPX overlay: verified bootstrap, provenance and idempotence' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root=New-EzVmCheckoutFixture -Prefix 'WHPX overlay [verified]'
    try {
        $value=New-EzVmQemuOverlayFixture $root
        $result=Invoke-EzVmOverlayFixtureBootstrap $value $root
        Assert-EzVmEqual $result.version '11.1.2'
        $receipt=Read-EzVmJson -Path (Join-Path $result.runtimePath 'ezvm-provenance.json')
        Assert-EzVmEqual $receipt.whpxResetOverlay.qemuSourceCommit $value.Manifest.whpxResetOverlay.qemuSourceCommit
        foreach($file in $value.Manifest.whpxResetOverlay.files){Assert-EzVmEqual (Get-EzVmFileDigest -Path (Join-Path $result.runtimePath $file.name) -Algorithm SHA256) $file.sha256}
        $again=Invoke-EzVmOverlayFixtureBootstrap $value $root
        Assert-EzVmTrue $again.idempotent
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath (Get-EzVmPaths -Root $root).Runtime -Directory -Filter '.qemu-*').Count 0
    } finally {Remove-EzVmTestDirectory $root}
}

$overlayManifestCases=@(
    @{Name='foreign repository'; Change={param($m) $m.whpxResetOverlay.artifact.url=$m.whpxResetOverlay.artifact.url.Replace('/techrote/ezvm/','/someone/ezvm/')}},
    @{Name='query URL'; Change={param($m) $m.whpxResetOverlay.artifact.url+='?token=fixture'}},
    @{Name='provider mismatch'; Change={param($m) $m.whpxResetOverlay.baseProviderDigest='0'*128}},
    @{Name='duplicate files'; Change={param($m) $m.whpxResetOverlay.files[1].name=$m.whpxResetOverlay.files[0].name}},
    @{Name='traversal filename'; Change={param($m) $m.whpxResetOverlay.files[0].name='../outside.exe'}},
    @{Name='unreviewed DLL'; Change={param($m) $m.whpxResetOverlay.files[2].name='foreign.dll'}},
    @{Name='string size'; Change={param($m) $m.whpxResetOverlay.files[0].sizeBytes='123'}},
    @{Name='invalid source identity'; Change={param($m) $m.whpxResetOverlay.qemuSourceCommit='not-a-commit'}}
)
foreach($case in $overlayManifestCases){
    Add-EzVmTest -Name ('WHPX overlay: manifest refuses '+$case.Name) -SkipReason $qemuWindowsSkip -Data $case -ScriptBlock {
        param($Case)
        $root=New-EzVmCheckoutFixture -Prefix 'WHPX overlay manifest refusal'
        try {$value=New-EzVmQemuOverlayFixture $root;& $Case.Change $value.Manifest;Write-EzVmJson -Path $value.Fixture.ManifestPath -Value $value.Manifest;Assert-EzVmThrows {Get-EzVmQemuManifest -Root $root -ManifestPath $value.Fixture.ManifestPath}|Out-Null}
        finally {Remove-EzVmTestDirectory $root}
    }
}

foreach($kind in @('traversal','duplicate','extra','wrong-size','wrong-file-digest','wrong-archive-digest','wrong-base-payload','wrong-final-payload')){
    Add-EzVmTest -Name ('WHPX overlay: refuses '+$kind+' before promotion') -SkipReason $qemuWindowsSkip -Data $kind -ScriptBlock {
        param($Kind)
        $root=New-EzVmCheckoutFixture -Prefix 'WHPX overlay ZIP refusal'
        try {
            $value=New-EzVmQemuOverlayFixture $root
            $names=@($value.Names)
            switch($Kind){
                traversal {$names[9]='../outside-overlay-sentinel'}
                duplicate {$names[9]=$names[0]}
                extra {$names+='unexpected.dll'}
                wrong-size {$value.Manifest.whpxResetOverlay.files[0].sizeBytes++}
                wrong-file-digest {$value.Manifest.whpxResetOverlay.files[0].sha256='0'*64}
                wrong-archive-digest {$value.Manifest.whpxResetOverlay.artifact.digest='0'*64}
                wrong-base-payload {$value.Manifest.whpxResetOverlay.basePayloadSha256='0'*64}
                wrong-final-payload {$value.Manifest.whpxResetOverlay.installedPayloadSha256='0'*64}
            }
            Write-EzVmOverlayFixtureZip -Path $value.Archive -Names $names -Contents $value.Contents
            if($Kind -ne 'wrong-archive-digest'){$value.Manifest.whpxResetOverlay.artifact.digest=Get-EzVmFileDigest -Path $value.Archive -Algorithm SHA256}
            $value.Manifest.whpxResetOverlay.artifact.sizeBytes=[long](Get-Item -LiteralPath $value.Archive).Length
            Write-EzVmJson -Path $value.Fixture.ManifestPath -Value $value.Manifest
            $script:EzVmOverlayProbeCalled=$false
            $value.Hooks.PayloadProbe={param($Root,$Version) $script:EzVmOverlayProbeCalled=$true;throw 'Unverified payload reached execution'}
            Assert-EzVmThrows {Invoke-EzVmOverlayFixtureBootstrap $value $root}|Out-Null
            Assert-EzVmTrue (-not $script:EzVmOverlayProbeCalled)
            Assert-EzVmTrue (-not (Test-Path -LiteralPath (Get-EzVmPaths -Root $root).Qemu))
            Assert-EzVmTrue (-not (Test-Path -LiteralPath (Join-Path (Get-EzVmPaths -Root $root).Runtime 'outside-overlay-sentinel')))
        } finally {Remove-EzVmTestDirectory $root}
    }
}

foreach($kind in @('firmware','extra-DLL')){
    Add-EzVmTest -Name ('WHPX overlay: forged inventory cannot substitute '+$kind) -SkipReason $qemuWindowsSkip -Data $kind -ScriptBlock {
        param($Kind)
        $root=New-EzVmCheckoutFixture -Prefix 'WHPX overlay full payload forgery'
        try {
            $value=New-EzVmQemuOverlayFixture $root;$result=Invoke-EzVmOverlayFixtureBootstrap $value $root
            $relative=if($Kind -eq 'firmware'){'share/firmware.bin'}else{'unreviewed.dll'}
            $path=Join-Path $result.runtimePath $relative;[IO.File]::WriteAllText($path,'unreviewed replacement')
            $inventoryPath=Join-Path $result.runtimePath 'ezvm-payload.json';$inventory=Read-EzVmJson $inventoryPath
            $entry=[pscustomobject]@{path=$relative;sizeBytes=[long](Get-Item -LiteralPath $path).Length;sha256=(Get-EzVmFileDigest -Path $path -Algorithm SHA256)}
            $inventory.files=@($inventory.files|Where-Object{$_.path -cne $relative})+@($entry)
            Write-EzVmJson -Path $inventoryPath -Value $inventory
            $receiptPath=Join-Path $result.runtimePath 'ezvm-provenance.json';$receipt=Read-EzVmJson $receiptPath
            $receipt.payloadManifestSha256=Get-EzVmFileDigest -Path $inventoryPath -Algorithm SHA256;Write-EzVmJson -Path $receiptPath -Value $receipt
            $status=Get-EzVmManagedQemuStatus -Root $root -ManifestPath $value.Fixture.ManifestPath -PayloadProbe $value.Hooks.PayloadProbe
            Assert-EzVmTrue (-not $status.Valid);Assert-EzVmTrue ($status.Reason -match 'complete payload differs')
        } finally {Remove-EzVmTestDirectory $root}
    }
}

Add-EzVmTest -Name 'WHPX overlay: forged local inventory cannot replace reviewed executable pins' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root=New-EzVmCheckoutFixture -Prefix 'WHPX overlay forged inventory'
    try {
        $value=New-EzVmQemuOverlayFixture $root;$result=Invoke-EzVmOverlayFixtureBootstrap $value $root
        $system=Join-Path $result.runtimePath 'qemu-system-x86_64.exe'
        [IO.File]::WriteAllText($system,'forged binary')
        $inventoryPath=Join-Path $result.runtimePath 'ezvm-payload.json';$inventory=Read-EzVmJson $inventoryPath
        $entry=@($inventory.files|Where-Object{$_.path -ceq 'qemu-system-x86_64.exe'})[0]
        $entry.sha256=Get-EzVmFileDigest -Path $system -Algorithm SHA256;$entry.sizeBytes=[long](Get-Item -LiteralPath $system).Length
        Write-EzVmJson -Path $inventoryPath -Value $inventory
        $receiptPath=Join-Path $result.runtimePath 'ezvm-provenance.json';$receipt=Read-EzVmJson $receiptPath
        $receipt.payloadManifestSha256=Get-EzVmFileDigest -Path $inventoryPath -Algorithm SHA256;Write-EzVmJson -Path $receiptPath -Value $receipt
        $status=Get-EzVmManagedQemuStatus -Root $root -ManifestPath $value.Fixture.ManifestPath -PayloadProbe $value.Hooks.PayloadProbe
        Assert-EzVmTrue (-not $status.Valid);Assert-EzVmTrue ($status.Reason -match 'overlay inventory differs')
    } finally {Remove-EzVmTestDirectory $root}
}

Add-EzVmTest -Name 'WHPX overlay: hardlinked provider destination cannot alter an unrelated sentinel' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root=New-EzVmCheckoutFixture -Prefix 'WHPX overlay hardlink refusal'
    try {
        $value=New-EzVmQemuOverlayFixture $root;$expander=$value.Hooks.QemuExpander
        $sentinel=Join-Path $root 'unrelated sentinel.bin';[IO.File]::WriteAllText($sentinel,'fixture qemu-system-x86_64.exe')
        $before=Get-EzVmFileDigest -Path $sentinel -Algorithm SHA256
        $value.Hooks.QemuExpander={
            param($Extractor,$Installer,$Destination)
            $result=& $expander $Extractor $Installer $Destination
            $target=Join-Path $Destination 'qemu-system-x86_64.exe'
            [IO.File]::Delete($target);$null=New-Item -ItemType HardLink -Path $target -Target $sentinel
            return $result
        }.GetNewClosure()
        Assert-EzVmThrows {Invoke-EzVmOverlayFixtureBootstrap $value $root} -MessagePattern 'link'|Out-Null
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $sentinel -Algorithm SHA256) $before
        Assert-EzVmTrue (-not (Test-Path -LiteralPath (Get-EzVmPaths -Root $root).Qemu))
    } finally {Remove-EzVmTestDirectory $root}
}

Add-EzVmTest -Name 'WHPX overlay: staging cleanup failure remains a command failure' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root=New-EzVmCheckoutFixture -Prefix 'WHPX overlay cleanup failure'
    $module=Get-Module EzVm
    try {
        $value=New-EzVmQemuOverlayFixture $root
        & $module {
            $script:EzVmOverlayOriginalRemove=(Get-Command Remove-EzVmSafeTree).ScriptBlock
            Set-Item Function:script:Remove-EzVmSafeTree -Value {
                param($Path)
                if((Split-Path $Path -Leaf) -like '.qemu-overlay-*'){throw 'Synthetic overlay staging cleanup failure'}
                & $script:EzVmOverlayOriginalRemove -Path $Path
            }
        }
        Assert-EzVmThrows {Invoke-EzVmOverlayFixtureBootstrap $value $root} -MessagePattern 'Synthetic overlay staging cleanup failure'|Out-Null
    } finally {
        & $module {if(Test-Path Variable:script:EzVmOverlayOriginalRemove){Set-Item Function:script:Remove-EzVmSafeTree -Value $script:EzVmOverlayOriginalRemove;Remove-Variable EzVmOverlayOriginalRemove -Scope Script}}
        Remove-EzVmTestDirectory $root
    }
}

Add-EzVmTest -Name 'WHPX overlay: case-colliding canonical paths fail before probing' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root=New-EzVmTestDirectory -Prefix 'WHPX overlay case collision'
    $module=Get-Module EzVm
    try {
        $path=Join-Path $root 'file.bin';[IO.File]::WriteAllText($path,'case collision fixture')
        & $module {
            param($Directory)
            $script:EzVmOverlayOriginalTree=(Get-Command Get-EzVmSafeTree).ScriptBlock
            $script:EzVmOverlayCaseEntries=@((New-Object IO.FileInfo (Join-Path $Directory 'file.bin')),(New-Object IO.FileInfo (Join-Path $Directory 'FILE.BIN')))
            Set-Item Function:script:Get-EzVmSafeTree -Value {param($Path) return $script:EzVmOverlayCaseEntries}
        } $root
        Assert-EzVmThrows {& $module {param($Directory) Get-EzVmQemuBasePayloadDigest -Directory $Directory} $root} -MessagePattern 'case-ambiguous'|Out-Null
        Assert-EzVmThrows {& $module {param($Directory) Write-EzVmQemuPayloadInventory -RuntimeDirectory $Directory -ManifestDigest ('1'*64) -ExpectedCanonicalDigest ('2'*64)} $root} -MessagePattern 'case-ambiguous'|Out-Null
    } finally {
        & $module {if(Test-Path Variable:script:EzVmOverlayOriginalTree){Set-Item Function:script:Get-EzVmSafeTree -Value $script:EzVmOverlayOriginalTree;Remove-Variable EzVmOverlayOriginalTree,EzVmOverlayCaseEntries -Scope Script}}
        Remove-EzVmTestDirectory $root
    }
}
