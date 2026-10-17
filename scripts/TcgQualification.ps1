#requires -Version 5.1
# Pure helpers for the explicitly opted-in, disposable release TCG fixture.
# This file is not imported by the public EzVM module or shipped in releases.

function New-EzVmTcgTimerQualificationSeed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Template)

    if ($Template.Length -gt 1048576) { throw 'TCG qualification seed exceeds the bounded template size.' }
    $text = $Template.Replace("`r`n", "`n")
    if (-not $text.StartsWith("#cloud-config`n", [StringComparison]::Ordinal) -or $text.Contains("`r")) {
        throw 'TCG qualification requires the expected cloud-config template.'
    }
    foreach ($marker in @("`nwrite_files:`n", "`nruncmd:`n")) {
        if (($text.Split(@($marker), [StringSplitOptions]::None)).Count -ne 2) {
            throw 'TCG qualification requires exactly one write_files and runcmd section.'
        }
    }
    if ($text -match 'no_timer_check|99-ezvm-tcg-qualification') {
        throw 'TCG qualification refuses a template with an existing timer override.'
    }
    $fragment = @'
  - path: /etc/default/grub.d/99-ezvm-tcg-qualification.cfg
    owner: root:root
    permissions: '0644'
    content: |
      # Disposable TCG qualification only; does not disable APIC or timers.
      GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} no_timer_check"
'@
    $text = $text.Replace("`nwrite_files:`n", "`nwrite_files:`n" + $fragment.Replace("`r`n", "`n") + "`n")
    # The existing finalizer waits for cloud-init success. A failed update-grub
    # therefore cannot promote a prepared base as READY.
    return $text.Replace("`nruncmd:`n", "`nruncmd:`n  - [update-grub]`n")
}

function Get-EzVmTcgTimerQualificationProbe {
    # Run only through the existing authenticated guest exec path after READY.
    # Timer self-check bypass is not evidence that APIC/timers were disabled.
    return @'
set -eu
cmdline="$(cat /proc/cmdline)"
count=0
for arg in $cmdline; do
  case "$arg" in
    no_timer_check) count=$((count + 1));;
    noapic|nolapic|nolapic_timer|mitigations=off) echo 'Unexpected broad guest override' >&2; exit 91;;
  esac
done
test "$count" -eq 1
awk '/IO-APIC/ {for (i=2; i<=NF && $i ~ /^[0-9]+$/; i++) total += $i} END {exit !(total > 0)}' /proc/interrupts
clock="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
case "$clock" in ''|*[!a-z0-9_-]*) exit 92;; esac
before="$(cut -d ' ' -f 1 /proc/uptime)"
sleep 1
after="$(cut -d ' ' -f 1 /proc/uptime)"
awk -v before="$before" -v after="$after" 'BEGIN {exit !(after > before)}'
printf 'EZVM012_TCG_TIMER_COMPATIBILITY=PASS; clocksource=%s; before=%s; after=%s\n' "$clock" "$before" "$after"
'@
}
