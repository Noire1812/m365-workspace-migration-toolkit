@{
    RootModule        = 'ExoTenantAudit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5d0f3a52-8c1e-4a6e-9d43-2f6b7c1a9e10'
    Author            = 'Joseph Lyons'
    Description       = 'Read-only Exchange Online inventory for planning a mail migration.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Invoke-ExoTenantAudit'
        'Get-ExoDomainInventory'
        'Get-ExoMailboxInventory'
        'Get-ExoAliasInventory'
        'Get-ExoMailboxDelegation'
        'Get-ExoGroupInventory'
        'ConvertTo-ByteCount'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('ExchangeOnline', 'Microsoft365', 'Migration', 'Audit')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
