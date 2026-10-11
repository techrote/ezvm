Add-EzVmTest -Name 'Base recipe: reviewed baseline contains the stable coding prerequisites' -ScriptBlock {
    $recipe = Get-EzVmBaseRecipe -Root $script:EzVmRepositoryRoot
    Assert-EzVmEqual -Actual $recipe.recipeVersion -Expected '1'
    Assert-EzVmEqual -Actual $recipe.machine -Expected 'q35'
    Assert-EzVmEqual -Actual $recipe.seedGuestAddress -Expected '10.0.2.100'
    Assert-EzVmEqual -Actual $recipe.seedGuestPort -Expected 8000
    foreach ($package in @(
        'openssh-server', 'git', 'build-essential', 'cmake', 'ninja-build',
        'python3', 'python3-venv', 'curl', 'wget', 'jq', 'ripgrep',
        'unzip', 'zip', 'rsync', 'tmux'
    )) {
        Assert-EzVmTrue -Condition (@($recipe.packages) -ccontains $package) -Message "Baseline recipe omitted '$package'."
    }
}

Add-EzVmTest -Name 'Base recipe: generated NoCloud seed is build-specific, credential-free and cleans golden-image identity' -ScriptBlock {
    $buildId = '0123456789abcdef0123456789abcdef'
    $seed = New-EzVmBaseSeedData -Root $script:EzVmRepositoryRoot -BuildId $buildId
    Assert-EzVmTrue -Condition ($seed.MetaData -match ('instance-id: ezvm-base-' + $buildId))
    Assert-EzVmTrue -Condition ($seed.UserData -match 'package_update: true')
    Assert-EzVmTrue -Condition ($seed.UserData -match 'cloud-init clean --logs --machine-id')
    Assert-EzVmTrue -Condition ($seed.UserData -match 'rm -f /etc/ssh/ssh_host_')
    Assert-EzVmTrue -Condition ($seed.UserData -match 'systemd-run')
    Assert-EzVmTrue -Condition ($seed.UserData -match 'cloud-init status --wait') -Message 'Finalization must wait on cloud-init completion state.'
    Assert-EzVmTrue -Condition ($seed.UserData -notmatch 'systemctl is-active --quiet cloud-final') -Message 'cloud-final remains active after exit on supported cloud-init units; do not use it as completion state.'
    Assert-EzVmTrue -Condition ($seed.UserData -match 'EZVM_BASE_READY=1')
    Assert-EzVmTrue -Condition ($seed.UserData -notmatch '__[A-Z0-9_]+__')
    Assert-EzVmTrue -Condition ($seed.UserData -notmatch '(?im)PRIVATE KEY|github_pat_|ghp_[A-Za-z0-9]')
    Assert-EzVmTrue -Condition ($seed.ProvisioningDigest -match '^[a-f0-9]{64}$')
}

Add-EzVmTest -Name 'Base recipe: provisioning digest changes when reviewed recipe source changes' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'base digest source'
    try {
        $before = Get-EzVmBaseProvisioningDigest -Root $root
        $path = (Get-EzVmPaths -Root $root).BaseMetaDataTemplate
        [IO.File]::AppendAllText($path, [Environment]::NewLine + '# fixture change')
        $after = Get-EzVmBaseProvisioningDigest -Root $root
        Assert-EzVmTrue -Condition ($before -cne $after) -Message 'Provisioning digest must cover every reviewed seed source.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Base recipe: QEMU arguments use explicit UEFI, virtio and loopback guest forwarding' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'base qemu args with spaces'
    try {
        $recipe = Get-EzVmBaseRecipe -Root $script:EzVmRepositoryRoot
        $disk = Join-Path $root 'staging disk.qcow2'
        $code = Join-Path $root 'edk2 code.fd'
        $vars = Join-Path $root 'edk2 vars.fd'
        $serial = Join-Path $root 'serial log.txt'
        foreach ($path in @($disk, $code, $vars)) { [IO.File]::WriteAllText($path, 'fixture') }

        $command = New-EzVmBaseQemuArguments -BuildId '0123456789abcdef0123456789abcdef' -Recipe $recipe -StagingDisk $disk -FirmwareCode $code -FirmwareVariables $vars -SerialLog $serial -SeedHostPort 32123 -Accelerator whpx
        $joined = $command.Arguments -join [char]10
        Assert-EzVmEqual -Actual $command.SeedUrl -Expected 'http://10.0.2.100:8000/'
        Assert-EzVmEqual -Actual $command.GuestForward -Expected 'guestfwd=tcp:10.0.2.100:8000-tcp:127.0.0.1:32123'
        Assert-EzVmTrue -Condition ($joined -match '(?m)^q35$')
        Assert-EzVmTrue -Condition ($joined -match 'virtio-blk-pci,drive=osdisk')
        Assert-EzVmTrue -Condition ($joined -match 'virtio-net-pci,netdev=net0')
        Assert-EzVmTrue -Condition ($joined -match 'readonly=on')
        Assert-EzVmTrue -Condition ($joined -match 'ds=nocloud;s=http://10\.0\.2\.100:8000/')
        Assert-EzVmTrue -Condition ($joined -match '(?m)^whpx$')
        Assert-EzVmTrue -Condition ($joined -notmatch '(?i)hostfwd=|0\.0\.0\.0|cloud-localds|mkisofs')
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Base recipe: TCG is explicit qualification mode and never substituted into WHPX arguments' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'base accelerator args'
    try {
        $recipe = Get-EzVmBaseRecipe -Root $script:EzVmRepositoryRoot
        $disk = Join-Path $root 'disk.qcow2'
        $code = Join-Path $root 'code.fd'
        $vars = Join-Path $root 'vars.fd'
        $serial = Join-Path $root 'serial.txt'
        foreach ($path in @($disk, $code, $vars)) { [IO.File]::WriteAllText($path, 'fixture') }

        $whpx = New-EzVmBaseQemuArguments -BuildId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -Recipe $recipe -StagingDisk $disk -FirmwareCode $code -FirmwareVariables $vars -SerialLog $serial -SeedHostPort 32001 -Accelerator whpx
        $tcg = New-EzVmBaseQemuArguments -BuildId 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -Recipe $recipe -StagingDisk $disk -FirmwareCode $code -FirmwareVariables $vars -SerialLog $serial -SeedHostPort 32002 -Accelerator tcg
        Assert-EzVmTrue -Condition (($whpx.Arguments -join ' ') -match ' -accel whpx ')
        Assert-EzVmTrue -Condition (($whpx.Arguments -join ' ') -notmatch 'tcg')
        Assert-EzVmTrue -Condition (($tcg.Arguments -join ' ') -match 'tcg,thread=multi')
        Assert-EzVmTrue -Condition (($tcg.Arguments -join ' ') -match ' -cpu max ')
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Base recipe: invalid package or command tokens fail before cloud-init generation' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'base invalid recipe'
    try {
        $path = (Get-EzVmPaths -Root $root).BaseBaseline
        $recipe = Read-EzVmJson -Path $path
        $recipe.packages[0] = 'bad package'
        Write-EzVmJson -Path $path -Value $recipe
        Assert-EzVmThrows -ScriptBlock { Get-EzVmBaseRecipe -Root $root } -MessagePattern 'package name' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
