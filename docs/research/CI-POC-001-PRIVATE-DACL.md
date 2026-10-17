# CI-POC-001: standard-user private-DACL repair

Upstream software tracker: [EzVM #47](https://github.com/techrote/ezvm/issues/47).
Physical/full-pilot tracker: [Runloc #21](https://github.com/techrote/runloc/issues/21).
This record concerns public source and disposable synthetic Windows fixtures.

## Finding and scope

On 17 October 2026, the existing [draft pilot #46](https://github.com/techrote/ezvm/pull/46)
reported 356 PASS / 2 FAIL under standard-user Windows PowerShell 5.1. Its exact
private-key preflight stopped at `SeSecurityPrivilege` before VM qualification.
The two original affected tests are the broad explicit-ACE removal and actual
Windows key-generation/staged-transfer cases in `tests/Security.Tests.ps1`.
They are retained unchanged. The fixture-only keypair is generated and removed
by the existing test; no owner key or private patch is imported.

The separate [hosted PR46 release failure](https://github.com/techrote/ezvm/actions/runs/39042709996/job/117425241318)
reached authenticated READY for two concurrent TCG guests, then timed out during
SSH banner exchange after restarting the source guest. Its final cleanup retained
STOPPING. That log does not establish an ACL cause or a WHPX performance result.
PR45's captured-start changes are outside this repair.

The PowerShell [filesystem security provider](https://github.com/PowerShell/PowerShell/blob/master/src/System.Management.Automation/namespaces/FileSystemSecurity.cs)
first persists `AccessControlSections.All`. Its `PrivilegeNotHeldException`
fallback compares the new descriptor's `AreAuditRulesProtected` against the old
descriptor's **DACL** protection flag when deciding whether to omit `Audit`.
Native `icacls /inheritance:r` leaves a protected DACL, so the fresh descriptor
can still request unrelated audit access. This explains the distinct failure
after native restriction and on repeated protection. The retained real Windows
reproduction, rather than source inspection alone, is the acceptance oracle.

Windows [SACL access](https://learn.microsoft.com/en-us/windows/win32/secauthz/sacl-access-right)
requires a distinct audit privilege. Private key confidentiality requires owner
and DACL handling, and does not require SACL mutation. The repaired code creates
the same exact owner-only protected descriptor and calls the supported .NET
[FileInfo.SetAccessControl](https://learn.microsoft.com/en-us/dotnet/api/system.io.fileinfo.setaccesscontrol?view=netframework-4.8.1)
and [DirectoryInfo.SetAccessControl](https://learn.microsoft.com/en-us/dotnet/api/system.io.directoryinfo.setaccesscontrol?view=netframework-4.8.1)
APIs on Windows PowerShell 5.1. PowerShell 7 uses
[FileSystemAclExtensions](https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemaclextensions).
Only owner and DACL have been modified on the new descriptor, so its persistence
does not ask the provider to copy unrelated sections. Explicit `Owner, Access`
readback verifies current-user ownership, one explicit FullControl allow ACE,
target protection and exact inheritance/propagation flags. Primary group and
audit policy are not rewritten. There is no privilege/elevation fallback.

## Retained controls

| Case | Required observation |
| --- | --- |
| Original broad explicit-ACE test | Old public module fails with `SeSecurityPrivilege`; fixed module removes broad rights. |
| Original actual Windows key-generation/staged-transfer test | Old public module fails at ACL protection; fixed module retains its existing creation, reuse, transfer-failure preservation and unchanged-key assertions. |
| Inherited Everyone ACE on a file | The negative precondition is observed before protection; fixed source removes inheritance and broad access, leaves bytes/group unchanged, and succeeds on repetition. |
| Directory with inherited Everyone and explicit Authenticated Users ACEs | Both negative preconditions are observed; fixed source leaves one inheritable current-user ACE, succeeds on a protected reapplication, and a new child inherits only private access. |
| Wrong object type or missing target | Refusal before mutation, unchanged file/directory ACLs and sentinel bytes, no created missing target. |
| DACL without WRITE_DAC | Actual persistence fails; descriptor and bytes stay unchanged. OWNER RIGHTS prevents the owner from implicitly recovering WRITE_DAC during the test. |
| Native ACL process fails on existing identity | No identity acceptance/key derivation; both existing key files remain unchanged. |
| Existing hardlink, path-redirection, pairing and new-key cleanup cases | All existing full-suite safeguards continue to execute. |

The [OWNER RIGHTS SID](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-security-identifiers)
is used only in a synthetic denied-write fixture. Removing that fixture uses its
containing directory's existing DELETE_CHILD right; no privilege or ownership
repair is performed.

## How standard-user evidence is produced

The dedicated `private-acl.yml` jobs check out the exact PR head with read-only
permissions and no persisted checkout credential. `Invoke-PrivateAclHosted.ps1`
refuses a non-GitHub-hosted environment. It creates one uniquely named ordinary
local user in the disposable host's Users group and grants file access only to
its new fixture tree. It never modifies existing account/group membership or
account privileges. The child uses a separate profile and creates its own clean
Git checkouts from the public bundle, avoiding copied checkout ownership and
global Git trust exceptions. PowerShell 7 uses the existing verified portable
runtime pin; PowerShell 5.1 uses the Windows system executable.

`Invoke-PrivateAclQualification.ps1` verifies no administrator SID (including a
filtered/deny-only administrator group) and no audit, ownership, backup or restore
privilege exists in the token. It executes the old module and original tests
from immutable `d5265c804d0d8494d8171482a85aca563b181e05`, plus the new
inherited-file/directory tests against that same module. All four must produce
the specific historical privilege failure. It then unloads the old module and
executes the candidate's actual `scripts/Test-Repository.ps1` and
`tests/Run-Tests.ps1`. A terminating error, missing required PASS, any skipped test,
source modification or changed token fails the run. This is real Windows ACL
execution, without a VM/hypervisor or live service credential.

The hosted child has a ten-minute wall inside a fifteen-minute job. The original
child process handle is retained for bounded timeout termination. Artifacts contain
the exact-source receipt, fixed-suite log, child stdout/stderr and account/fixture
cleanup receipt. Only the unique temporary account and guarded fixture tree are
removed. A failed run is retained as failed; no elevation or policy retry follows.
After a failed/interrupted child, fixture deletion is withheld because lightweight
descendant ownership may be unresolved. The host-fixture receipt records this
quarantine; disposable hosted-machine teardown owns final removal.
The disposable host's temporary user profile disappears with host teardown and
is never uploaded.

To run the qualification on an already authorized ordinary Windows account, use
two clean dedicated clones and the same pinned engines; the non-hosted entry
point makes no account changes:

```powershell
# baseline-checkout must be clean at d5265c804d0d8494d8171482a85aca563b181e05.
# Invoke from the exact reviewed candidate checkout. Evidence must be outside it.
.\scripts\Invoke-PrivateAclQualification.ps1 -BaselineRoot 'C:\lab\baseline-checkout' -ExpectedCommit '<exact candidate SHA>' -ExpectedMajor 5 -OutputDirectory 'C:\lab\new-acl-evidence-ps51'
```

Repeat using the repository-pinned PowerShell 7 executable and `-ExpectedMajor 7`
with a fresh output directory. Run the full immutable WHPX candidate's exact
synthetic preflight before downloads or fixture mutation, then preserve all
original release/portability assertions and its physical deadlines. ACL software
success alone does not qualify that full scenario.

## Authorship and evidence status

Implementation and initial self-review: the assigned ChatGPT coding subagent,
using public EzVM source and primary Microsoft/PowerShell references. No private
owner patch was read or copied. The primary assistant independently reviewed the
product/test/fixture diff and added fail-closed quarantine for an interrupted
hosted fixture. Exact Windows CI evidence must be recorded on the PR before
software acceptance. This document does not
claim a physical Windows/WHPX run, a completed release qualification, a speedup,
or closure of Runloc #21.
