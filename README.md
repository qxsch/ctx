# ctx - tenant / login switcher for Azure CLI, Az PowerShell, PIM and Microsoft Graph

One command to jump between your tenants:

```powershell
ctx emea -Admin      # switch Azure CLI + Az PowerShell, activate Global Admin (PIM), prepare Graph for daily admin work
```

**Environment = tenant + login.** You give every tenant/login pair a name (`switzerland`, `emea`, `emea3`, `germany`, ...).
The same tenant with the same login is the same environment (ctx refuses duplicates). The same tenant with a different login is a different environment.

## Install

Requires Windows and PowerShell 7.2+. Azure CLI, `Az.Accounts` (3.0+) and `Microsoft.Graph.Authentication` (2.0+) are each optional; ctx uses whatever is installed.

Install the Az and Microsoft.Graph modules **machine-wide** on each device, from an elevated pwsh: `Install-PSResource Az.Accounts, Microsoft.Graph.Authentication -Scope AllUsers`. With the default `CurrentUser` scope they land in `Documents\PowerShell\Modules`, which syncs via OneDrive. That 1.5 GB copy then goes to every device and shadows newer machine-wide versions, because the Documents folder comes first in `PSModulePath`. `ctx doctor` warns about both.

```powershell
git clone https://github.com/qxsch/ctx.git
cd ctx
.\Install.ps1          # deploys the module to OneDrive, adds Import-Module Ctx to your profile, checks prerequisites
```

**What syncs and what stays local:**

| Synced via OneDrive (same on every device) | Local to each device (never synced) |
|---|---|
| Module: `Documents\PowerShell\Modules\Ctx` | Environments, state, settings, CLI logins: `%LOCALAPPDATA%\ctx` |
| Profile: `Documents\PowerShell\profile.ps1` (ctx block) | Az PowerShell contexts: `~\.Azure` |
| | Graph tokens: memory of each terminal only |
| | Browser profiles, the `AZURE_CONFIG_DIR` / `AZURE_EXTENSION_DIR` user variables |

- **Code:** this repo is the source. `Install.ps1` copies a bundled build (a single `Ctx.psm1`, which starts faster) into your user module folder. That folder lives in OneDrive when Documents is backed up by OneDrive.
  - The profile imports ctx **by name**, with no machine-specific path, so every device that syncs Documents loads it.
  - After changing the source, run `.\Install.ps1` again. It copies only changed files.
- **Other devices** need no install. Open a terminal and `ctx` is there. Install Azure CLI on each device (`winget install Microsoft.AzureCLI`); Az autosave is enabled automatically on first use.
  - Environments are per device: `ctx export <file>` on one device, copy the file over, `ctx import <file>` on the other, then `ctx <name>` signs in with a device code. The file holds definitions only, no tokens.
  - `ctx doctor` shows where the module and the data live and warns if the data folder would end up inside OneDrive.
- **Prerequisites:** missing or outdated modules are installed with `Install-PSResource` from the `azure-powershell` repository (package proxy) when it is registered, else from PSGallery. Override with `-Repository`. They are installed for all users only when `Install.ps1` runs elevated. Otherwise it prints the elevated command, so nothing lands in OneDrive.
- **Profile block:** idempotent and marked `# >>> ctx >>>`. With oh-my-posh or starship it goes into the profile that sets up your prompt, so the badge wraps your prompt. Otherwise it goes into `profile.ps1` (all hosts, including VS Code).
- **Signing:** `-SigningCertificate <thumbprint>` Authenticode-signs the installed module with a code-signing certificate from `Cert:\CurrentUser\My` (optionally `-TimestampServer <url>`). See [Security](#security).
- **Options:** `-ModulePath <Modules folder>`, `-ProfilePath <file>`, `-Repository <name>`, `-SigningCertificate <thumbprint>`, `-TimestampServer <url>`, `-NoProfile`, `-Yes`, `-Force`.

**Uninstall:** run `.\Uninstall.ps1`.
- It removes the profile block and the installed module. Both are shared, so ctx is gone on all devices.
- It restores `AZURE_CONFIG_DIR` / `AZURE_EXTENSION_DIR` on this device. `-KeepModule` cleans up this device only, and `-RemoveData` also deletes `%LOCALAPPDATA%\ctx` and the `ctx:*` Az contexts. `-WhatIf` is supported.
  - `-RemoveData` deletes the data folder only when it holds nothing but ctx data and is not a protected folder (drive root, user profile, Documents, OneDrive, ...). This matters when `CTX_HOME` points somewhere else.
- Other devices keep their user variables until you reset them there.

## Everyday use

| Command | What it does |
|---|---|
| `ctx` | Picker (↑/↓, Enter; `a` = switch + admin, `l` = this terminal only, `1-9` jump) |
| `ctx <name>` | Switch everywhere: Azure CLI + Az PowerShell, back where you left off (prefixes work: `ctx ger`) |
| `ctx <name> -Admin` | Switch, activate Global Admin via PIM, connect Graph with the focused `Admin` profile |
| `ctx <name> -Local` | Switch this terminal only |
| `ctx -` | Back to the previous environment |
| `ctx sync` | Make a terminal opened before the last switch follow the global environment |
| `ctx add <name> [tenant]` | Create an environment (device code sign-in); `-Tags prod`, `-Tools cli,az`, `-Color`, `-Subscription` |
| `ctx list` / `ctx ls` | List environments (`*` = this terminal, `+` = global, PIM time left) |
| `ctx rename <old> <new>` | Rename (CLI folder and Az context move along, the browser profile is kept) |
| `ctx rm <name>` | Remove (`-SignOut` signs out of CLI/Az, `-RemoveBrowserProfile`, `-WhatIf`) |
| `ctx set [name] ...` | `-AddTag/-RemoveTag/-Tags`, `-Color`, `-Description`, `-Tools`, `-PimRole`, `-PimHours`, `-PimReason`, `-TicketSystem`, `-GraphProfile`, `-GraphClientId`, `-AdminOnSwitch Ask/Always/Never/Default` |
| `ctx pim [role]` | Activate a PIM role (default Global Administrator) + Graph; `-Hours -Reason -Ticket -NoGraph -Wait` |
| `ctx pim -List` / `-Deactivate` / `-Renew` | Eligible/active roles, end an activation early, start a fresh one |
| `ctx graph [profile]` | Reuse/renew Graph, or use device code if needed; `Admin`, `ReadOnly`, `Pim`, `All`, custom or `"Scope1,Scope2"` |
| `ctx graph -AddScopes "Scope1,Scope2"` | Add permissions to this terminal's session; try silent consent reuse first |
| `ctx graph -Relogin` | Explicitly request a fresh device-code sign-in |
| `ctx st [-Check]` | Status of this terminal (`-Check` verifies the tokens) |
| `ctx sub [name]` | Pick a subscription (CLI + Az); remembered per environment |
| `ctx portal [azure\|entra\|pim\|intune\|security\|...]` | Open a portal in the environment's own browser profile (`-InPrivate`) |
| `ctx exec <names\|all> { ... }` | Run a script block in several environments, `$_` = environment; the terminal is restored afterwards. Production environments ask for a typed confirmation first (`-Force` skips it) |
| `ctx doctor [-Deep]` | Check prerequisites, profile, variables and every login |
| `ctx export \| import <file>` | Share environment definitions (no tokens). Import validates every entry and asks before keeping a custom Graph client (`-AllowGraphClientId`) |
| `ctx config [key value]` | Settings (`-Reset`, `-Edit`) |
| `ctx help` | Cheat sheet |

Tab completion covers environment names, verbs, roles, portals, subscriptions, Graph profiles and config keys. All `Get-Help` topics are available (`Get-Help Switch-CtxEnvironment -Full`).

## How switching works

- **Azure CLI**: every environment has its own config dir, `%LOCALAPPDATA%\ctx\cli\<name>`, with its own token cache and default subscription.
  - A global switch sets the user variable `AZURE_CONFIG_DIR`, so every new terminal, VS Code and scripts use that environment.
  - CLI extensions are shared through `AZURE_EXTENSION_DIR`, so they are installed only once.
- **Az PowerShell**: every environment has a named context, `ctx:<name>`. A global switch selects it with `-Scope CurrentUser`, which needs autosave (enabled by `Install.ps1`).
- **Where you left off**: before leaving an environment, ctx remembers the subscription you were on (CLI and Az) and restores it next time.
- **Expired logins**: when the token check fails, ctx renews the login with a device code. The code is copied to the clipboard and the device login page opens in the environment's own browser profile, so the right account is already there.
  - The account is verified (tenant + object id); signing in with the wrong account is rejected.
- **`-Local`** changes only the current terminal (`*` in the badge).
- Terminals that were already open keep their environment until `ctx sync`. The badge shows `→other` when the global environment differs.
- **Graph** is per terminal. It is disconnected when you switch to another environment.

## PIM + Graph flow

`ctx pim` (or `ctx <name> -Admin`, or answering *yes* after a switch):

1. Reuse a matching Graph session or refresh token; otherwise try the environment's cached Az login. Only tokens for the correct tenant + user with the required Graph scopes are accepted.
   - If device authentication is necessary, request the selected profile **and PIM scopes together**, rather than signing in separately for each.
   - `-NoGraph`, `-List` and `-Deactivate` only need the small PIM scope set.
2. Self-activation of the role. ctx asks for the justification, with your last one as the default.
   - Ticket details, a shorter duration or a longer justification are only asked when the role's policy rejects the request.
   - An MFA/authentication-context requirement opens the PIM portal in the environment's browser profile.
   - Approval-required roles can be waited for (`-Wait`).
   - Hours, reason and ticket system are remembered per environment (`ctx set -PimHours 2`).
3. If the role was newly activated, refresh the Graph token silently. If it was already active, keep the existing suitable session. A new access token does not normally require another login.
   - Normally this means **zero Graph device codes** when suitable credentials can be reused, or **one** otherwise.
   - New consent, revoked credentials, or Conditional Access/MFA can require interaction. If initial admin consent needs an active role, use `ctx pim -NoGraph` first, then `ctx graph`.
   - Az's token API cannot force a new token after activation. In that case ctx can use one device-code sign-in for a fresh Graph token, then keep renewing it itself.
   - `All` remains opt-in (`ctx graph All`). If that oversized request fails, ctx can fall back to `Admin`; explicit `-AddScopes` requests are never silently dropped.

Activations are cached locally. The badge shows the time left (`GA 1h34m`, yellow below 10 minutes), and a one-time reminder is printed shortly before and right after expiry. `ctx pim -Renew` starts a new activation.

### Graph sign-in and token renewal

ctx gives the access token to the SDK with `Connect-MgGraph -AccessToken`, so every `*-Mg*` cmdlet and `Invoke-MgGraphRequest` uses it. When a login is needed, ctx runs the device-code flow against Entra itself.
- **Why:** this avoids the SDK's *"DeviceCodeCredential authentication failed: Object reference not set to an instance of an object"* failure ([msgraph-sdk-powershell#3495](https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/3495)).
- **Identity check:** the token's tenant and object ID are checked against the environment *before* the token is handed over. Signing in with the wrong account fails without connecting anything.
- **Renewal:** ctx uses its in-memory refresh token (`offline_access`), or obtains another token from the same named Az context. It checks 15 minutes before expiry at the prompt, on Graph/PIM commands, and on a 4-minute timer while PowerShell can process events. Long-running commands can delay the timer.
  - If renewal fails, a one-time hint appears at the next prompt. `ctx graph` retries; network errors do not cause pointless new device logins.
  - Renewal stops `graphMaxSessionHours` (default 12) after the sign-in, so an idle terminal does not keep privileged Graph access alive indefinitely. The last token stays valid until it expires; then `ctx graph` signs in again. `0` disables the limit.
  - `ctx status` shows how long the token is valid and until when it renews.
- **Storage:** ctx's Graph refresh token stays only in terminal memory. Az manages its existing device-local token cache; ctx does not copy its refresh tokens. New terminals can reuse Az when its Graph permissions suffice; otherwise they need one Graph device login.
- **Separate clients:** Azure CLI, Az PowerShell and Graph have different OAuth clients and token caches. A browser's portal session is not a shared PowerShell token cache, and Global Admin does not automatically grant every Graph OAuth scope.
- If another account or client replaces the Graph connection, ctx stops renewing its old session.

### Daily Graph scopes

The default `Admin` profile is **11 delegated Graph scopes**, derived from the application, user, group and authentication work in the microhack-hub scripts:

| Work | Scopes |
|---|---|
| Applications, service principals, federated credentials | `Application.Read.All`, `Application.ReadWrite.All` |
| Grant application permissions | `AppRoleAssignment.ReadWrite.All` |
| Users and groups | `User.ReadWrite.All`, `Group.ReadWrite.All` |
| User authentication methods / Temporary Access Passes | `UserAuthenticationMethod.ReadWrite.All` |
| Read authentication-method policy | `Policy.Read.AuthenticationMethod` |
| Read tenant domains | `Domain.Read.All` |
| Directory roles and PIM | `RoleManagement.ReadWrite.Directory`, `RoleEligibilitySchedule.Read.Directory`, `RoleAssignmentSchedule.ReadWrite.Directory` |

`Application.Read.All` is retained alongside its write equivalent because the Fabric setup script checks for that exact scope. Permissions that the scripts grant to an application are not automatically permissions needed by the signed-in operator. For example, `Application.ReadWrite.OwnedBy` is an application permission, not a delegated scope.

The fixed profiles do not depend on the SDK's permission catalogue, which can lag behind supported Graph permissions. `All` still uses that catalogue. Existing explicit environment/profile overrides are preserved.

Add permissions only when you need them:

```powershell
ctx graph -AddScopes "AuditLog.Read.All,Policy.ReadWrite.AuthenticationMethod"
ctx graph -AddScopes User.EnableDisableAccount.All
ctx graph Admin                 # replace session additions with the baseline again
```

Additions accumulate in the current terminal and survive token renewal and repeated `ctx pim` calls with the same profile. They are not written to configuration or synced. Scope expansion first uses the refresh token; a device code is requested only if interactive consent/authentication is required. To keep a different set permanently, use a custom profile:

```powershell
ctx config graphScopeProfiles.Intune "DeviceManagementManagedDevices.ReadWrite.All,DeviceManagementConfiguration.ReadWrite.All"
ctx set germany -GraphProfile Intune
ctx set germany -GraphClientId <app id>     # your own public client app (device code allowed) instead of Microsoft Graph Command Line Tools
```

## Prompt badge

`[!emea:graph GA 1h34m→germany]`

| Part | Meaning |
|---|---|
| `!` | production (tags `prod`/`production`); the name is red and the switch shows a banner |
| `:graph` | Graph connected in this terminal |
| `GA 1h34m` | active PIM role and time left |
| `*` | switched for this terminal only |
| `→germany` | the global environment is different |

The badge wraps your existing prompt. Load ctx after oh-my-posh/starship, or turn it off with `ctx config promptBadge off` and put `Get-CtxPromptBadge` into your own prompt.

## Settings (`ctx config`)

| Key | Default | |
|---|---|---|
| `defaultGraphProfile` | `Admin` | Focused daily Graph scope profile after PIM |
| `fallbackGraphProfile` | `Admin` | used when the All sign-in fails |
| `askAdminOnSwitch` | `on` | offer PIM + Graph after a switch (per environment: `ctx set -AdminOnSwitch`) |
| `verifyOnSwitch` | `on` | check tokens while switching (renews expired logins right away) |
| `promptBadge` | `on` | prompt badge + PIM reminders |
| `pimDefaultRole` / `pimDefaultHours` | Global Administrator / 4 | |
| `pimReminderMinutes` | 10 | |
| `pimBootstrapScopes` | see above | scopes of the PIM sign-in |
| `deviceCodeClipboard` / `deviceCodeBrowser` | on / on | copy the code, open the login page in the environment's browser profile |
| `browserPath` | auto (Edge) | any Chromium browser, e.g. Chrome |
| `prodTags` | `prod, production` | |
| `shareCliExtensions` | `on` | one CLI extension folder for all environments |
| `graphMaxSessionHours` | 12 | stop renewing a Graph session this many hours after its sign-in (`0` = no limit) |
| `graphScopeProfiles.<name>` | | custom Graph scope profiles |

## Data

Everything persistent is stored locally on each device in `%LOCALAPPDATA%\ctx`, which OneDrive does not sync. You can override this with `$env:CTX_HOME`, but keep it outside OneDrive.

- `environments.json`: environments, current/previous, subscriptions, cached PIM activations, original variables. A `.bak` is kept.
- `config.json`: your setting overrides only.
- `cli\<name>\`: Azure CLI config/token cache per environment.
- `graph-permissions.json`: cache of the delegated Graph permission names.

Stored outside that folder:

- The Az PowerShell contexts live in the normal Az profile (`~\.Azure\AzureRmContext.json`) and are named `ctx:<name>`.
- The browser profiles are `ctx-<name>` profiles of Edge (or the configured browser) in its normal *User Data* folder.

ctx stores no secrets itself. Azure CLI and Az tokens stay in their token caches. Graph tokens exist only in the memory of the terminal that signed in.

## Security

- **Export files are untrusted input.** `ctx import` reads only the portable fields. Tenant, user, client and subscription IDs must be GUIDs, and the tenant domain must be a domain name; other entries are skipped. Terminal control characters are stripped. A custom `graphClientId` is dropped unless you confirm it or pass `-AllowGraphClientId`, because Graph sign-ins for that environment grant consent to that application. `ctx doctor` flags stored environments that fail these checks.
- **No command or argument injection.** `az` is a batch file (`az.cmd`) whose command line cmd.exe parses again, so ctx refuses any `az` argument with cmd.exe metacharacters. Browsers get one argument per value with a canonical http(s) URL. Device-code pages are opened only on Microsoft sign-in hosts.
- **Bounded Graph sessions.** See `graphMaxSessionHours`. The default `Admin` profile is powerful (application, role and authentication-method write access); use `ctx graph ReadOnly` when you only read.
- **Synced code runs in admin terminals.** The module and profile sync via OneDrive and load in every terminal, including those that hold Global Administrator tokens. Anyone who can change files in your OneDrive can change that code. Mark of the Web does not apply to OneDrive-synced files, so `RemoteSigned` gives no protection here.
  - Sign the module: `.\Install.ps1 -SigningCertificate <thumbprint>`. `ctx doctor` then reports a changed module (`HashMismatch`). With the `AllSigned` execution policy, PowerShell refuses unsigned or changed code; your profile must then be signed too.
  - Or keep the code local: `.\Install.ps1 -ModulePath <folder outside OneDrive>`. Other devices then need their own install.
- **Safe defaults for changes.** `ctx rm`, `ctx rename`, `ctx set` and `ctx config` support `-WhatIf`. Removing a production environment requires typing its name. State and config are written atomically under a per-user lock.

## Tests

```powershell
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path .\Ctx -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The tests run offline. They use a temporary `CTX_HOME` and set `CTX_SANDBOX_USERENV`, which redirects all user environment variable writes to a JSON file, and they mock every Azure/Graph call. Use the same two variables for manual experiments that must not touch your real setup.

To test the installed (bundled) copy instead of the source, set `$env:CTX_TEST_MODULE` to its `Ctx.psd1` before running Pester.

GitHub Actions ([ci.yml](.github/workflows/ci.yml)) runs PSScriptAnalyzer and Pester on every push and pull request.

## Limitations

- Windows only.
- Azure public cloud only.
- Switching is user-wide for **new** processes. Terminals that are already open follow after `ctx sync`. Graph is always per terminal.
- `ctx add` signs in with a device code, so Conditional Access policies that block device code flow will block it.
- The **All** scope profile requests several hundred scopes. Some tenants reject such a large request; the automatic fallback to `Admin` covers that.
- PIM for Entra roles only (no Azure resource roles and no PIM for groups).

## License

[MIT](LICENSE)
