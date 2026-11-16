# Supplemental Chrome policy values for Invoke-CisChromeCatalog.ps1 -SupplementalValuesPath.
#
# For L1 recommendations the CIS Build Kit (v1.1.0) does not set. Keys are Chrome policy names
# (registry value / list key names). Values:
#   integer        -> REG_DWORD (boolean 0 = Disabled / 1 = Enabled, or an enum/integer value)
#   'string'       -> REG_SZ
#   @('a', 'b')    -> list policy (Chrome\<Policy>\1..N)
# Each value still goes through definition matching and the CIS remediation-state check.
#
# Copy this file before putting real organization values in it.
@{
    # --- Prescribed by the v1.1.1 workbook, missing from the v1.1.0 Build Kit -----------------
    PasswordSharingEnabled                       = 0   # 2.11.4  Disabled
    RelatedWebsiteSetsEnabled                    = 0   # 2.13.1  Disabled
    RemoteAccessHostAllowRemoteAccessConnections = 0   # 2.14.3  Disabled
    ChromeVariations                             = 0   # 2.34    Enabled: Enable all variations (0)

    # --- "Is Configured" items: organization-specific (placeholders) ------------------------
    ClipboardAllowedForUrls          = @('example.org')   # 2.3.1   sites allowed to use the clipboard
    ClipboardBlockedForUrls          = @('example.org')   # 2.3.2   sites blocked from the clipboard
    HttpAllowlist                    = @('example.org')   # 2.54    hosts exempt from HTTPS upgrades/warnings
    RemoteAccessHostClientDomainList = @('example.org')   # 2.14.5  domains allowed as remote access clients

    # --- "Explicitly Configured" (CIS accepts either state) ----------------------------------
    PasswordManagerEnabled         = 0   # 2.11.2  Disabled: Chrome does not save passwords
    PasswordManagerPasskeysEnabled = 0   # 2.11.3  Disabled: Chrome does not save passkeys
}
