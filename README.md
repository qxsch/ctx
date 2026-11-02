# ctx - tenant / login switcher for Azure CLI, Az PowerShell, PIM and Microsoft Graph

One command to jump between your tenants, on Windows, Linux and macOS:

```powershell
ctx emea -Admin      # switch Azure CLI + Az PowerShell, activate Global Admin (PIM), prepare Graph for daily admin work
```

**Environment = tenant + login.** You give every tenant/login pair a name (`switzerland`, `emea`, `germany`, ...).
The same tenant with the same login is the same environment (ctx refuses duplicates). The same tenant with a different login is a different environment.

**Few sign-ins.** Whenever an existing login of the environment can supply a token (this terminal's Graph session, saved Graph credentials, the Az PowerShell or Azure CLI login), ctx asks it first. You sign in only when none of them can, and then once per command, with the environment's [sign-in method](#sign-in-methods): device code (default), browser or the Windows account broker.

## Install

Requires PowerShell 7.2+ on Windows, Linux or macOS. Azure CLI, `Az.Accounts` (3.0+) and `Microsoft.Graph.Authentication` (2.0+) are each optional; ctx uses whatever is installed.

```powershell
git clone https://github.com/qxsch/ctx.git
cd ctx
./Install.ps1          # installs the module, adds Import-Module Ctx to your profile, checks prerequisites
```

### Windows: code and profile sync via OneDrive

Install the Az and Microsoft.Graph modules **machine-wide** on each device, from an elevated pwsh: `Install-PSResource Az.Accounts, Microsoft.Graph.Authentication -Scope AllUsers`. With the default `CurrentUser` scope they land in `Documents\PowerShell\Modules`, which syncs via OneDrive. That 1.5 GB copy then goes to every device and shadows newer machine-wide versions, because the Documents folder comes first in `PSModulePath`. `ctx doctor` warns about both.

| Synced via OneDrive (same on every device) | Local to each device (never synced) |
|---|---|
| Module: `Documents\PowerShell\Modules\Ctx` | Environments, state, settings, CLI logins: `%LOCALAPPDATA%\ctx` |
| Profile: `Documents\PowerShell\profile.ps1` (ctx block) | Az PowerShell contexts: `~\.Azure` |
| | Graph tokens: memory of each terminal (plus an encrypted file, only for environments with `-SaveGraphCredentials On`) |
| | Browser profiles, the `AZURE_CONFIG_DIR` / `AZURE_EXTENSION_DIR` user variables |

- **Code:** this repo is the source. `Install.ps1` copies a bundled build (a single `Ctx.psm1`, which starts faster) into your user module folder. That folder lives in OneDrive when Documents is backed up by OneDrive.
  - The profile imports ctx **by name**, with no machine-specific path, so every device that syncs Documents loads it.
  - After changing the source, run `.\Install.ps1` again. It copies only changed files.
- **Other devices** need no install. Open a terminal and `ctx` is there. Install Azure CLI on each device (`winget install Microsoft.AzureCLI`); Az autosave is enabled automatically on first use.
- **Prerequisites:** they are installed for all users only when `Install.ps1` runs elevated. Otherwise it prints the elevated command, so nothing lands in OneDrive.
- **Signing:** `-SigningCertificate <thumbprint>` Authenticode-signs the installed module with a code-signing certificate from `Cert:\CurrentUser\My` (optionally `-TimestampServer <url>`). See [Security](#security).

### Linux and macOS: installed per device

Nothing syncs: run `./Install.ps1` on each device. Install Azure CLI first (`brew install azure-cli` on macOS; [Linux instructions](https://learn.microsoft.com/cli/azure/install-azure-cli-linux)).

| Installed by `Install.ps1` | Local data of ctx (owner-only folder, mode 700) |
|---|---|
| Module: `~/.local/share/powershell/Modules/Ctx` | Linux: `$XDG_DATA_HOME/ctx` (default `~/.local/share/ctx`) |
| PowerShell profile: `~/.config/powershell/profile.ps1` (ctx block) | macOS: `~/Library/Application Support/ctx` |
| Shell profiles: `~/.bashrc`, `~/.zshenv`, `~/.profile` (when present), `~/.config/fish/conf.d/ctx.fish` | Az PowerShell contexts: `~/.Azure`; browser profiles |

- **Prerequisites:** missing modules are offered for the current user (nothing syncs, so there is no shadowing problem); as root, for all users.
- **Shell profiles:** Windows hands the global environment to new processes through user variables. Linux and macOS have no such store, so ctx writes `AZURE_CONFIG_DIR` / `AZURE_EXTENSION_DIR` to `global.env` in its data folder, and the ctx block in your bash, zsh, sh and fish profiles reads exactly these two variables from it (it never sources the file). On macOS, ctx also sets them with `launchctl setenv`, so apps started later from Finder or the Dock follow too. `-NoShellProfile` skips these blocks; then only PowerShell follows the global environment.
- **Signing** is not available (Authenticode is Windows-only); the module is installed locally and does not sync.
- **WSL** counts as Linux. Without a Linux browser, ctx uses the Windows Edge (`/mnt/c/...`), which also serves browser sign-ins (WSL2 forwards `localhost`).

### All platforms

- **Environments are per device:** `ctx export <file>` on one device, copy the file over, `ctx import <file>` on the other, then `ctx <name>` signs in with the environment's sign-in method. The file holds definitions only, no tokens.
- **Prerequisites:** missing or outdated modules are installed with `Install-PSResource` from the `azure-powershell` repository (package proxy) when it is registered, else from PSGallery. Override with `-Repository`.
- **Profile block:** idempotent and marked `# >>> ctx >>>`. With oh-my-posh or starship it goes into the profile that sets up your prompt, so the badge wraps your prompt. Otherwise it goes into `profile.ps1` (all hosts, including VS Code).
- `ctx doctor` shows where the module and the data live, warns if the data folder would end up inside OneDrive, and on Linux/macOS checks the folder permissions and which shell profiles read `global.env`.
- **Options:** `-ModulePath <Modules folder>`, `-ProfilePath <file>`, `-Repository <name>`, `-SigningCertificate <thumbprint>` and `-TimestampServer <url>` (Windows), `-NoProfile`, `-NoShellProfile` (Linux/macOS), `-Yes`, `-Force`.

**Uninstall:** run `./Uninstall.ps1`.
- It removes the profile blocks and the installed module. On Windows both are shared via OneDrive, so ctx is gone on all devices.
- It restores `AZURE_CONFIG_DIR` / `AZURE_EXTENSION_DIR` on this device (Windows: user variables; Linux/macOS: `global.env` and `launchctl`). `-KeepModule` cleans up this device only, and `-RemoveData` also deletes the data folder, the `ctx:*` Az contexts and, on Linux/macOS, the key of saved Graph credentials in the Keychain / Secret Service. `-WhatIf` is supported.
  - `-RemoveData` deletes the data folder only when it holds nothing but ctx data and is not a protected folder (drive root, home, Documents, OneDrive, `~/.local/share`, ...). This matters when `CTX_HOME` points somewhere else.
- Other Windows devices keep their user variables until you reset them there.

## Everyday use

| Command | What it does |
|---|---|
| `ctx` | Picker (↑/↓, Enter; `a` = switch + admin, `l` = this terminal only, `1-9` jump) |
| `ctx <name>` | Switch everywhere: Azure CLI + Az PowerShell, back where you left off (prefixes work: `ctx ger`) |
| `ctx <name> -Admin` | Switch, activate Global Admin via PIM, connect Graph with the focused `Admin` profile |
| `ctx <name> -Local` | Switch this terminal only |
| `ctx -` | Back to the previous environment |
| `ctx sync` | Make a terminal opened before the last switch follow the global environment |
| `ctx add <name> [tenant]` | Create an environment (signs in with device code, or `-SignIn Browser\|Broker`); `-Tags prod`, `-Tools cli,az`, `-Color`, `-Subscription` |
| `ctx list` / `ctx ls` | List environments (`*` = this terminal, `+` = global, PIM time left) |
| `ctx rename <old> <new>` | Rename (CLI folder and Az context move along, the browser profile is kept) |
| `ctx rm <name>` | Remove (`-SignOut` signs out of CLI/Az, `-RemoveBrowserProfile`, `-WhatIf`) |
| `ctx set [name] ...` | `-AddTag/-RemoveTag/-Tags`, `-Color`, `-Description`, `-Tools`, `-SignIn DeviceCode/Browser/Broker/Default`, `-PimRole`, `-PimHours`, `-PimReason`, `-TicketSystem`, `-GraphProfile`, `-GraphClientId`, `-AdminOnSwitch Ask/Always/Never/Default`, `-SaveGraphCredentials On/Off` |
| `ctx pim [role]` | Activate a PIM role (default Global Administrator) + Graph; `-Hours -Reason -Ticket -NoGraph -Wait` |
| `ctx pim -List` / `-Deactivate` / `-Renew` | Eligible/active roles, end an activation early, start a fresh one |
| `ctx graph [profile]` | Reuse Graph (session, saved credentials, Az or CLI login), or sign in once if needed; `Admin`, `ReadOnly`, `Pim`, custom or `"Scope1,Scope2"` |
| `ctx graph -AddScopes "Scope1,Scope2"` | Add permissions to this terminal's session; try silent consent reuse first |
| `ctx graph -Relogin` | Explicitly sign in again with the environment's sign-in method |
| `ctx st [-Check]` | Status of this terminal (`-Check` verifies the tokens) |
| `ctx sub [name]` | Pick a subscription (CLI + Az); remembered per environment. Long lists scroll in a terminal-sized window (↑/↓, Home/End) |
| `ctx portal [azure\|entra\|pim\|intune\|security\|...]` | Open a portal in the environment's own browser profile (`-InPrivate`) |
| `ctx exec <names\|all> { ... }` | Run a script block in several environments, `$_` = environment; the terminal is restored afterwards. Production environments ask for a typed confirmation first (`-Force` skips it) |
| `ctx doctor [-Deep]` | Check prerequisites, profile, variables and every login |
| `ctx export \| import <file>` | Share environment definitions (no tokens). Import validates every entry and asks before keeping a custom Graph client (`-AllowGraphClientId`) |
| `ctx config [key value]` | Settings (`-Reset`, `-Edit`) |
| `ctx help` | Cheat sheet |

Tab completion covers environment names, verbs, roles, portals, subscriptions, Graph profiles and config keys. All `Get-Help` topics are available (`Get-Help Switch-CtxEnvironment -Full`).

Interactive pickers show at most the terminal height minus two item rows, reserving space for controls and a spare line. The window follows the selection and adapts to terminal resizing on the next keypress.

## Sign-in methods

Every environment signs in with one method: the one set for it, otherwise **device code**. ctx never picks another method on its own. The method applies to every interactive sign-in of the environment: `ctx add`, renewing an expired Azure CLI or Az PowerShell login, and Microsoft Graph for `ctx graph` / `ctx pim` / `-Admin`.

```powershell
ctx add fabrikam fabrikam.onmicrosoft.com -SignIn Browser   # Conditional Access blocks device code in this tenant
ctx set contoso -SignIn Broker                              # Windows account manager (WAM), e.g. for compliant-device policies
ctx set contoso -SignIn Default                             # back to device code
```

| Method | Azure CLI | Az PowerShell | Microsoft Graph (ctx's own sign-in) | Where |
|---|---|---|---|---|
| `DeviceCode` (default) | `az login --use-device-code` | `Connect-AzAccount -UseDeviceAuthentication` | device-code flow | everywhere, also over SSH |
| `Browser` | `az login` in the environment's browser profile; WAM off in the environment's CLI config | `Connect-AzAccount -AccountId <upn>` with WAM off for that call; opens the **default** browser (Az cannot choose a profile) | authorization code flow with PKCE and a `http://localhost:<port>` redirect, in the environment's browser profile, with the account as login hint | needs a local browser (not over plain SSH or on Linux without a display) |
| `Broker` | `az login` with WAM on in the environment's CLI config | `Connect-AzAccount -AccountId <upn>` with WAM on for that call | WAM through the Graph SDK (`Connect-MgGraph`), then handed over like every other token | Windows only |

- **Device codes** are copied to the clipboard, and the device login page opens in the environment's own browser profile, so the right account is already there.
- **The account is always verified** (tenant + object ID); a sign-in with the wrong account is rejected.
- **Changing the method** keeps existing logins; it applies from the next sign-in on. The setting travels with `ctx export` / `ctx import` (Conditional Access is a tenant policy). `ctx list`, `ctx st` and `ctx doctor` show it, and doctor warns where it cannot work (for example `Broker` on Linux).
- **Errors explain the fix:** when device code is blocked by Conditional Access (`AADSTS53003`), the message names `-SignIn Browser`. A browser sign-in in an SSH session fails right away and names `-SignIn DeviceCode`.
- **Custom Graph app** (`ctx set -GraphClientId`): `Browser` needs the redirect URI `http://localhost`, `Broker` needs `ms-appx-web://microsoft.aad.brokerplugin/<client id>` (both under *Mobile and desktop applications*). The default Microsoft Graph Command Line Tools app has both.
- **Az PowerShell's WAM setting** is changed only for the sign-in call (`Update-AzConfig -Scope Process`) and then put back; your own Az configuration is not touched.

### Fewer sign-ins: existing logins first

Before any interactive sign-in, ctx asks the environment's existing logins for a token, through their official token APIs only:

1. this terminal's Graph session (and its refresh token, also to add scopes),
2. the saved Graph credentials of the environment, if [enabled](#saved-graph-credentials),
3. the environment's Az PowerShell login (`Get-AzAccessToken`),
4. the environment's Azure CLI login (`az account get-access-token --resource-type ms-graph`),
5. only then: one sign-in with the environment's method, requesting every scope the command needs.

A reused token must belong to the same tenant and user, be meant for Microsoft Graph, and carry all required scopes; otherwise the next source is asked. Az and Azure CLI tokens come from Microsoft's own apps with fixed Graph permissions, so they often suffice for PIM and read work but not for scope-heavy profiles like `Admin`. ctx never reads or copies another tool's token cache. Azure CLI and Az PowerShell keep separate logins, so a tool whose own login has expired still needs its own sign-in; with `Browser`, the second sign-in completes in the same browser session without a password or MFA prompt, and with `Broker` it is usually silent.

## How switching works

- **Azure CLI**: every environment has its own config dir, `<data folder>/cli/<name>`, with its own token cache and default subscription.
  - A global switch points `AZURE_CONFIG_DIR` there for new processes: as a user variable on Windows (every new terminal, VS Code and scripts follow), through `global.env` and the shell profiles on Linux/macOS (plus `launchctl setenv` for apps on macOS).
  - CLI extensions are shared through `AZURE_EXTENSION_DIR`, so they are installed only once.
- **Az PowerShell**: every environment has a named context, `ctx:<name>`. A global switch selects it with `-Scope CurrentUser`, which needs autosave (enabled by `Install.ps1`).
- **Where you left off**: before leaving an environment, ctx remembers the subscription you were on (CLI and Az) and restores it next time.
- **Expired logins**: when the token check fails, ctx renews the login with the environment's [sign-in method](#sign-in-methods). The account is verified (tenant + object id); signing in with the wrong account is rejected.
- **`-Local`** changes only the current terminal (`*` in the badge).
- Terminals that were already open keep their environment until `ctx sync`. The badge shows `→other` when the global environment differs.
- **Graph** is per terminal. It is disconnected when you switch to another environment.

## PIM + Graph flow

`ctx pim` (or `ctx <name> -Admin`, or answering *yes* after a switch):

1. Reuse existing logins first ([order](#fewer-sign-ins-existing-logins-first)): this terminal's Graph session or refresh token, saved Graph credentials, then the environment's Az PowerShell and Azure CLI logins. Only tokens for the correct tenant + user with the required Graph scopes are accepted.
   - If a sign-in is necessary, request the selected profile **and PIM scopes together**, in one sign-in with the environment's method, rather than signing in separately for each.
   - `-NoGraph`, `-List` and `-Deactivate` only need the small PIM scope set.
2. Self-activation of the role. ctx asks for the justification, with your last one as the default.
   - Ticket details, a shorter duration or a longer justification are only asked when the role's policy rejects the request.
   - An MFA/authentication-context requirement opens the PIM portal in the environment's browser profile.
   - Approval-required roles can be waited for (`-Wait`).
   - Hours, reason and ticket system are remembered per environment (`ctx set -PimHours 2`).
3. If the role was newly activated, get a fresh Graph token silently. If it was already active, keep the existing suitable session. A new access token does not normally require another login.
   - Normally this means **zero Graph sign-ins** when suitable credentials can be reused, or **one** otherwise.
   - A token reused from Az PowerShell or Azure CLI counts after an activation only when it already reflects the role: its `wids` claim lists the role, or (without `wids`) it was issued after the activation started. Their token APIs cannot force a new token, so a cached token from before the activation is skipped, and ctx signs in once with the environment's method (then keeps renewing that session itself).
   - New consent, revoked credentials, or Conditional Access/MFA can require interaction. If initial admin consent needs an active role, use `ctx pim -NoGraph` first, then `ctx graph`.
   - There is no "all scopes" profile: requesting every delegated permission violates least privilege and Entra rejects such requests. Use a focused profile and add what you need with `-AddScopes`; explicit additions are never silently dropped.

Activations are cached locally. The badge shows the time left (`GA 1h34m`, yellow below 10 minutes), and a one-time reminder is printed shortly before and right after expiry. `ctx pim -Renew` starts a new activation.

### Graph sign-in and token renewal

ctx gives the access token to the SDK with `Connect-MgGraph -AccessToken`, so every `*-Mg*` cmdlet and `Invoke-MgGraphRequest` uses it. When a sign-in is needed, ctx runs the device-code flow or the browser flow (auth code + PKCE) against Entra itself; with `Broker` it takes the token from a WAM connection of the Graph SDK, which it disconnects right away.
- **Why its own flows:** this avoids the SDK's *"DeviceCodeCredential authentication failed: Object reference not set to an instance of an object"* failure ([msgraph-sdk-powershell#3495](https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/3495)), and lets the browser sign-in open in the environment's own browser profile.
- **Identity check:** the token's tenant and object ID are checked against the environment *before* the token is handed over. Signing in with the wrong account fails without connecting anything.
- **Renewal:** sessions from ctx's own sign-ins renew with the in-memory refresh token (`offline_access`); sessions taken from Az PowerShell or Azure CLI ask that login again. ctx checks 15 minutes before expiry at the prompt, on Graph/PIM commands, and on a 4-minute timer while PowerShell can process events. Long-running commands can delay the timer. A session from the Windows broker renews only on ctx commands (`ctx graph`, `ctx pim`, `-Admin`), because WAM may show its dialog, which must never pop up unannounced from the timer or while the prompt is drawn; the prompt shows a one-time hint before it expires.
  - If renewal fails, a one-time hint appears at the next prompt. `ctx graph` retries; network errors do not cause pointless new sign-ins.
  - Renewal stops `graphMaxSessionHours` (default 8) after the sign-in, so an idle terminal does not keep privileged Graph access alive indefinitely. The last token stays valid until it expires; then `ctx graph` signs in again. `0` disables the limit.
  - `ctx status` shows how long the token is valid and until when it renews.
- **Storage:** by default ctx's Graph refresh token stays only in terminal memory. Az and Azure CLI manage their own device-local token caches; ctx does not copy their refresh tokens. New terminals can reuse those logins when their Graph permissions suffice; otherwise they need one Graph sign-in. To skip that sign-in, opt in per environment: see [Saved Graph credentials](#saved-graph-credentials).
- **Separate clients:** Azure CLI, Az PowerShell and Graph have different OAuth clients and token caches. A browser's portal session is not a shared PowerShell token cache, and Global Admin does not automatically grant every Graph OAuth scope.
- If another account or client replaces the Graph connection, ctx stops renewing its old session.

### Saved Graph credentials

Off by default. Turn it on for the environments where you want to avoid a Graph sign-in in every new terminal:

```powershell
ctx set emea -SaveGraphCredentials On     # Off (default) stops saving and deletes the saved copy
ctx emea -Admin                            # later, in any new terminal: Graph is restored silently, no sign-in
```

- **What is saved:** only the Graph refresh token of ctx's own device-code or browser sign-ins and the time of the original sign-in, one file per environment: `<data folder>/graph/<name>.dat`. Access tokens are never stored. The file is never exported or synced (`ctx export` and `ctx import` ignore the setting).
- **How it is encrypted:**
  - **Windows:** DPAPI for your user on this device, so it cannot be read by other users or on other devices.
  - **macOS / Linux:** AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC; a changed file is rejected) with a random key kept in the macOS Keychain or the Linux Secret Service (`secret-tool`: GNOME Keyring, KWallet). The key is passed to these tools through stdin, never on a command line.
  - **Without a keyring** (servers, containers, many WSL setups), saving is refused unless you opt in with `ctx config graphCredentialStore file`: the key then lives in `<data folder>/graph/.key`, readable only by you (mode 600). That protects against other users, like Azure CLI's own token cache on Linux, but not against your own processes.
- **When it is saved:** after each Graph sign-in or token renewal in an opted-in environment. Turning the setting on while Graph is connected in this terminal saves that session right away.
- **When it is restored:** whenever Graph is connected for the environment of the terminal: `ctx <name> -Admin` (also the picker's `a`, `AdminOnSwitch Always` and answering *yes*), `ctx pim` and `ctx graph`. A plain `ctx <name>` does not connect Graph, so nothing is restored. `ctx graph -Relogin` ignores the saved credentials and replaces them with the new sign-in.
  - The saved token is exchanged for a new access token with the requested scopes and checked like any other sign-in (tenant, user, scopes). If that fails (expired, revoked, new consent or MFA needed), ctx falls back to reusing the Az/CLI logins or one sign-in, and the new sign-in is saved.
- **Still bounded:** restoring keeps the original sign-in time, so `graphMaxSessionHours` (default 8) applies across terminals and reboots. After that the saved file is deleted and the next Graph connect needs one sign-in.
- **Cleanup:** the file is deleted by `ctx set <name> -SaveGraphCredentials Off`, `ctx rm`, an expired or revoked refresh token and `Uninstall.ps1 -RemoveData` (which also removes the Keychain / Secret Service key); `ctx rename` moves it. `ctx st` and `ctx doctor` show its state.
- **Trade-off:** any process running as your user can decrypt the file (DPAPI, or the keyring while it is unlocked), as with the Az token cache. Leave it off for environments where that is not acceptable.

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

The fixed profiles do not depend on the SDK's permission catalogue, which can lag behind supported Graph permissions; the catalogue only feeds tab completion for `-AddScopes`. Existing explicit environment/profile overrides are preserved. A stored `All` profile from older versions falls back to the default (`Admin`).

Add permissions only when you need them:

```powershell
ctx graph -AddScopes "AuditLog.Read.All,Policy.ReadWrite.AuthenticationMethod"
ctx graph -AddScopes User.EnableDisableAccount.All
ctx graph Admin                 # replace session additions with the baseline again
```

Additions accumulate in the current terminal and survive token renewal and repeated `ctx pim` calls with the same profile. They are not written to configuration or synced. Scope expansion first uses the refresh token; a sign-in is requested only if interactive consent/authentication is required. To keep a different set permanently, use a custom profile:

```powershell
ctx config graphScopeProfiles.Intune "DeviceManagementManagedDevices.ReadWrite.All,DeviceManagementConfiguration.ReadWrite.All"
ctx set germany -GraphProfile Intune
ctx set germany -GraphClientId <app id>     # your own public client app instead of Microsoft Graph Command Line Tools (see Sign-in methods for its redirect URIs)
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
| `askAdminOnSwitch` | `on` | offer PIM + Graph after a switch (per environment: `ctx set -AdminOnSwitch`) |
| `verifyOnSwitch` | `on` | check tokens while switching (renews expired logins right away) |
| `promptBadge` | `on` | prompt badge + PIM reminders |
| `pimDefaultRole` / `pimDefaultHours` | Global Administrator / 4 | |
| `pimReminderMinutes` | 10 | |
| `pimBootstrapScopes` | see above | scopes of the PIM sign-in |
| `deviceCodeClipboard` / `deviceCodeBrowser` | on / on | copy the code, open the login page in the environment's browser profile |
| `browserPath` | auto (Edge) | any Chromium browser (Chrome, Chromium), on macOS also an `.app` bundle |
| `prodTags` | `prod, production` | |
| `shareCliExtensions` | `on` | one CLI extension folder for all environments |
| `graphMaxSessionHours` | 8 | stop renewing a Graph session this many hours after its sign-in, also for saved credentials (`0` = no limit) |
| `graphCredentialStore` | `keyring` | Linux/macOS: where the key of saved Graph credentials lives: `keyring` (Keychain / Secret Service) or `file` (owner-only key file, for devices without a keyring). Windows always uses DPAPI |
| `graphScopeProfiles.<name>` | | custom Graph scope profiles |

The sign-in method is a per-environment setting (`ctx set -SignIn`), not a `ctx config` key: without it an environment uses device code.

## Data

Everything persistent is stored locally on each device, in a folder no sync client picks up by default:

| Windows | macOS | Linux |
|---|---|---|
| `%LOCALAPPDATA%\ctx` | `~/Library/Application Support/ctx` | `$XDG_DATA_HOME/ctx` (default `~/.local/share/ctx`) |

You can override this with `$env:CTX_HOME`, but keep it outside OneDrive (on Linux/macOS, export it in your shell profile too, so the shell blocks find it). On Linux/macOS ctx creates the folder for its owner only (mode 700), because it holds the Azure CLI token caches; `ctx doctor` warns if it is readable by others.

- `environments.json`: environments (with their sign-in method), current/previous, subscriptions, cached PIM activations, original variables. A `.bak` is kept.
- `config.json`: your setting overrides only.
- `cli/<name>/`: Azure CLI config/token cache per environment (its config also holds the WAM setting for `Browser` / `Broker`).
- `graph-permissions.json`: cache of the delegated Graph permission names.
- `graph/<name>.dat`: encrypted Graph refresh token, only for environments with `-SaveGraphCredentials On`; `graph/.key` only with `graphCredentialStore file`.
- Linux/macOS: `global.env` (the variables for new shells) and `.lock` (the per-user lock for state and config writes; Windows uses a named mutex).

Stored outside that folder:

- The Az PowerShell contexts live in the normal Az profile (`~/.Azure/AzureRmContext.json`) and are named `ctx:<name>`.
- The browser profiles are `ctx-<name>` profiles of Edge (or the configured browser) in its normal *User Data* folder (Windows `%LOCALAPPDATA%\Microsoft\Edge\User Data`, macOS `~/Library/Application Support/Microsoft Edge`, Linux `~/.config/microsoft-edge`).
- Linux/macOS: the key of saved Graph credentials in the Keychain / Secret Service (item `ctx.graph-credentials`), and the ctx blocks in your shell profiles.

ctx stores no secrets in plain text (except the key file you opt in to with `graphCredentialStore file`). Azure CLI and Az tokens stay in their token caches. Graph tokens exist only in the memory of the terminal that signed in, unless you opt in to [saved Graph credentials](#saved-graph-credentials) for an environment.

## Security

- **Export files are untrusted input.** `ctx import` reads only the portable fields. Tenant, user, client and subscription IDs must be GUIDs, and the tenant domain must be a domain name; other entries are skipped. An unknown sign-in method falls back to device code. Terminal control characters are stripped. A custom `graphClientId` is dropped unless you confirm it or pass `-AllowGraphClientId`, because Graph sign-ins for that environment grant consent to that application. `ctx doctor` flags stored environments that fail these checks.
- **No command or argument injection.** On Windows `az` is a batch file (`az.cmd`) whose command line cmd.exe parses again, so ctx refuses any `az` argument with cmd.exe metacharacters (on every OS). Browsers get one argument per value with a canonical http(s) URL. Device-code pages are opened only on Microsoft sign-in hosts. The `BROWSER` command that lets Azure CLI open the environment's browser profile is built only from a browser path and profile name without quotes, `%`, `$` or backticks.
- **Browser sign-in (auth code + PKCE).** The redirect listener binds to the loopback interface only (127.0.0.1 / ::1) on a random port, for one sign-in, at most 5 minutes. It accepts only `GET /` with the random `state` of the running sign-in; other requests are answered and ignored, so a stray local request can neither end nor hijack it. The PKCE verifier never leaves the process, and the reply page contains no token or request data.
- **Shell profiles never execute ctx data.** On Linux/macOS the ctx block reads `global.env` line by line and exports only `AZURE_CONFIG_DIR` and `AZURE_EXTENSION_DIR`; it never sources the file, and ctx refuses multi-line values.
- **Owner-only data on Linux/macOS.** The data folder is created with mode 700 (it holds the Azure CLI token caches, which az keeps unencrypted on Linux). The opt-in key file is mode 600.
- **Bounded Graph sessions.** See `graphMaxSessionHours`. The default `Admin` profile is powerful (application, role and authentication-method write access); use `ctx graph ReadOnly` when you only read.
- **Saved Graph credentials are opt-in per environment.** The refresh token is encrypted (DPAPI on Windows; AES-256 + HMAC with a keyring key on Linux/macOS), bound to the environment's tenant, user and Graph client, bounded by `graphMaxSessionHours`, and never exported, imported or synced. An import file cannot switch the setting on.
- **Synced code runs in admin terminals (Windows).** The module and profile sync via OneDrive and load in every terminal, including those that hold Global Administrator tokens. Anyone who can change files in your OneDrive can change that code. Mark of the Web does not apply to OneDrive-synced files, so `RemoteSigned` gives no protection here.
  - Sign the module: `.\Install.ps1 -SigningCertificate <thumbprint>`. `ctx doctor` then reports a changed module (`HashMismatch`). With the `AllSigned` execution policy, PowerShell refuses unsigned or changed code; your profile must then be signed too.
  - Or keep the code local: `.\Install.ps1 -ModulePath <folder outside OneDrive>`. Other devices then need their own install.
  - On Linux/macOS the module is installed per device and does not sync; Authenticode is not available there.
- **Safe defaults for changes.** `ctx rm`, `ctx rename`, `ctx set` and `ctx config` support `-WhatIf`. Removing a production environment requires typing its name. State and config are written atomically under a per-user lock (a named mutex on Windows, a lock file on Linux/macOS).

## Tests

```powershell
Invoke-Pester -Path ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path ./Ctx -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The tests run offline on Windows, Linux and macOS. They use a temporary `CTX_HOME` and set `CTX_SANDBOX_USERENV`, which redirects all writes of the variables for new processes (Windows user variables, `global.env`) to a JSON file, and they mock every Azure/Graph call. The browser sign-in tests use a real loopback listener on a random local port. Use the same two variables for manual experiments that must not touch your real setup.

To test the installed (bundled) copy instead of the source, set `$env:CTX_TEST_MODULE` to its `Ctx.psd1` before running Pester.

GitHub Actions ([ci.yml](.github/workflows/ci.yml)) runs PSScriptAnalyzer and Pester on Windows, Ubuntu and macOS on every push and pull request.

## Limitations

- Azure public cloud only.
- Switching is user-wide for **new** processes. Terminals that are already open follow after `ctx sync`. Graph is always per terminal. On Linux/macOS, only shells with the ctx block (bash, zsh, sh login shells, fish) and apps started from them (plus, on macOS, apps started from Finder or the Dock) follow; other processes keep az's default `~/.azure`.
- `Broker` sign-in (WAM) is Windows-only. `Browser` sign-in needs a local browser, so over SSH (or on Linux without a display) use `DeviceCode` for that environment.
- With `Browser`, Az PowerShell opens your default browser instead of the environment's browser profile (Az offers no way to choose); the account hint and the identity check still apply.
- After a PIM activation, the Windows broker may hand out its cached Graph token from before the activation; ctx warns, and the token picks up the role when it renews.
- Saved Graph credentials on Linux need a Secret Service (`secret-tool`) or the opt-in key file.
- PIM for Entra roles only (no Azure resource roles and no PIM for groups).

## License

[MIT](LICENSE)
