# CIS Google Chrome → Intune Settings Catalog

Builds an Intune **Settings Catalog** policy for the **CIS Google Chrome Benchmark** (Level 1 by default) from the CIS Build Kit GPO backup and the CIS benchmark workbook. It can also compare an existing policy against that expected set.

Every in-profile recommendation ends up in `coverage.md` with a status, and nothing is dropped silently. When a value can't be mapped to exactly one definition, it is flagged rather than guessed.

```
registry.pol (Build Kit) ─┐
                          ├─ join on registry value name ─┐
CIS workbook (.xlsx) ─────┘                               ├─ map ─► policy.json + coverage.md
Graph setting definitions (chromeintune*) ────────────────┘          │
                                                     -Create ◄───────┤  POST (unassigned)
                                                     -CompareTo ◄────┘  Missing / WrongValue / Extra
```

## Requirements

- PowerShell 7
- `Microsoft.Graph.Authentication` (for anything that talks to Graph)
- Pester 5+ (tests only)

Graph permissions follow least privilege: `DeviceManagementConfiguration.Read.All` for definitions and `-CompareTo`, and `DeviceManagementConfiguration.ReadWrite.All` only with `-Create`. An existing `Connect-MgGraph` session is reused when it already has the scope. Otherwise the script connects via `Connect-IntuneGraph`.

## Usage

```powershell
$gpo  = '.\CIS_..._Build Kit_Level_1\{F953080B-675B-43D3-A167-905A356CC185}'   # or ...\DomainSysvol\GPO\Machine\registry.pol
$xlsx = '.\CIS_Google_Chrome_Group_Policy_Benchmark_v1.1.1.xlsx'

# Dry run (default): writes policy.json + coverage.md, changes nothing in Intune.
# Caches definitions so later runs are fully offline.
.\tools\cis-chrome-catalog\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx `
    -DefinitionsPath .\cis-chrome-catalog-out\definitions.json

# Compare an existing policy
.\tools\cis-chrome-catalog\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx -CompareTo <policyId>

# Create (unassigned). -WhatIf shows what would be created.
.\tools\cis-chrome-catalog\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx -Create -WhatIf
.\tools\cis-chrome-catalog\Invoke-CisChromeCatalog.ps1 -GpoBackupPath $gpo -WorkbookPath $xlsx -Create
```

| Parameter | Default | Notes |
|---|---|---|
| `-GpoBackupPath` | (required) | GPO backup `{GUID}` folder or the `registry.pol` file |
| `-WorkbookPath` | (required) | CIS workbook; the sheet with a `Profile` column is used (`-WorksheetName` to override) |
| `-ProfilePattern` | `^\s*Level 1\b` | Regex on the Profile column |
| `-DefinitionNamespace` | `chromeintunev1`, `chromeintunev141` | ADMX namespaces to match against (see "Namespaces") |
| `-DefinitionsPath` | – | Definitions cache: read if present, else fetched and saved (`-RefreshDefinitions` to force a fetch) |
| `-OutputPath` | `.\cis-chrome-catalog-out` | `policy.json`, `coverage.md`, `compare-<id>.md` |
| `-PolicyName` | `CIS Google Chrome Benchmark v<ver> - L1` | Version is read from the workbook (`-BenchmarkVersion` to override) |
| `-Create` | off | POST to `/beta/deviceManagement/configurationPolicies` (windows10, mdm, unassigned). Refuses if the name exists unless `-Force` |
| `-CompareTo` | – | Policy id to diff |

The script returns an object (`PolicyName`, `SettingCount`, `Coverage`, `UnmatchedGpo`, `Diff`, `CreatedPolicyId`, file paths) for further scripting.

## How the mapping works

1. **registry.pol.** The tool parses the PReg file and keeps `Software\Policies\Google\Chrome`:
   - A value directly under `Chrome` is a **scalar** policy.
   - A `Chrome\<Policy>` subkey with values `1..N` is a **list** policy, in numeric order.
   - A subkey holding only `**delvals.` is the GPO **Disabled** state for a list. The CIS Build Kit uses this for many list policies.
   - Values under `Chrome\Recommended` are kept and flagged.
   - Entries outside `Chrome` (e.g. `Google\Update`) are reported, not used.
2. **Workbook.** For each recommendation the tool reads the CIS ID, title and profile. The registry value comes from the audit text. Every CIS form reduces to one policy name: `Chrome:Name`, `Chrome\Name`, `Chrome\Name\<number>`, `Chrome\Name:1` and `Chrome\Recommended:Name`.
   - The expected Enabled/Disabled state comes from the **remediation** text, not the title, because CIS titles are sometimes wrong. For example, 2.5.5's title says "Disabled" while its remediation says `Enabled: Do not download model`. When the title disagrees, a note is added.
3. **Definitions.** The tool reads `GET /beta/deviceManagement/configurationSettings` and keeps:
   - **root** definitions only (`rootDefinitionId == id`). Child definitions share the suffix, e.g. `…_downloadrestrictions_downloadrestrictions`.
   - **device scope** only. Real ids are `device_vendor_msft_policy_config_chromeintunev1~…`, and `user_vendor_…` twins are ignored.
   - the selected **namespace(s)**.
   - no `_recommended` variants. Those are "users can override", which is wrong for CIS.
4. **Match.** A policy name maps to the root whose id ends with `_<lowercase name>`. One match maps. Zero matches is `NoDefinition`, and more than one is `Ambiguous`.
5. **Instance.** The instance is built from the definition's structure. ADMX roots offer `<id>_0` (Disabled) and `<id>_1` (Enabled). Children are whatever `<id>_1`'s `dependedOnBy` lists:

   | registry.pol | Definition child | Setting |
   |---|---|---|
   | DWORD 0/1 | none (boolean) | choice `_0` / `_1` |
   | DWORD/SZ | choice (enum) | `_1` + child choice whose `optionValue` equals the registry value |
   | DWORD | simple integer | `_1` + `IntegerSettingValue` (range-checked) |
   | SZ | simple string | `_1` + `StringSettingValue` (length-checked) |
   | list `1..N` | simple collection | `_1` + `StringSettingValue` collection (count/length-checked) |
   | `**delvals.` only / `**del.` | any | `_0`, no children |

   Any other combination is `UnsupportedShape`, with the reason in the notes. Nothing is coerced.

### Namespaces

Intune publishes the Chrome ADMX in more than one namespace. Older policies are in `chromeintunev1`. Policies added later are published only in newer namespaces such as `chromeintunev141`, among them BuiltInAIAPIsEnabled, TranslatorAPIAllowed, CloudAPAuthEnabled and the Generative AI policies.

The default selects both `chromeintunev1` and `chromeintunev141`. As of November 2026 they share no policy names: 431 and 200 mandatory device roots respectively. Against benchmark v1.1.1 L1, v1 alone maps 65 recommendations and both together map 87.

If a policy ever appears in more than one selected namespace, it becomes `Ambiguous` rather than being picked silently. When Microsoft publishes a newer namespace, a `NoDefinition` row says the policy exists there, and the script prints the `-DefinitionNamespace` value that would include it. To restrict matching to the original namespace, pass `-DefinitionNamespace chromeintunev1`.

## coverage.md statuses

| Status | Meaning |
|---|---|
| `Mapped` | Setting is in `policy.json` |
| `NoDefinition` | No selected root definition ends with `_<name>` (notes name any definition outside the selection) |
| `Ambiguous` | More than one candidate (listed) |
| `UnsupportedShape` | GPO value or definition structure is not mappable (reason given) |
| `Conflict` | Mapped state contradicts the CIS remediation, or two recommendations need different values for one setting. Left out of the policy |
| `NotInGpo` | The recommendation's value is not in registry.pol (org-specific "Is Configured" items, Build Kit/workbook version drift) |
| `OutOfScope` | Registry path outside `Software\Policies\Google\Chrome` (e.g. Google Update) |
| `NoRegistryPath` | Audit text has no Google policy registry path |

A second table lists **GPO values that no in-profile recommendation claims**, e.g. a value the workbook assigns to L2, or one the workbook doesn't mention.

## Compare (`-CompareTo`)

The tool gets the policy with `$expand=settings` (following `settings@odata.nextLink`) and flattens each setting into `path → value` pairs: the root choice, then each child. List values are compared without regard to order, and choice ids without regard to case. Each top-level setting definition id is reported as:

- **Missing**: expected, not in the policy
- **WrongValue**: present, with the differing child values listed
- **Extra**: in the policy but not expected. This includes every non-Chrome setting and every setting from an unselected namespace. When an Extra setting belongs to a flagged recommendation, the note says so (e.g. "CIS 1.8 is Ambiguous").
- **Match**

## Tests

```powershell
Invoke-Pester .\tools\cis-chrome-catalog\tests
```

The suite is fully offline; Graph is mocked. Fixtures live in `tests/fixtures`:

- `registry.pol` and `workbook.xlsx` are generated by `New-Fixtures.ps1` (PReg and xlsx writers in `FixtureHelpers.ps1`). They hit every status above.
- `definitions.json` holds trimmed **real** Graph definitions: boolean, integer, string, enum, list, list with category, and a recommended variant. It also holds synthetic clones marked with `_fixture`, for ambiguous, v141-only, user-scope, recommended and conflict cases.
- `policy-actual.json` is a Graph-shaped existing policy that produces Match, Missing, WrongValue and Extra results.
