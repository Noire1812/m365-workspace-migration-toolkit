#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Run with: Invoke-Pester ./powershell/ExoTenantAudit/Tests
# No tenant is needed: every Exchange Online cmdlet is replaced by a mock.

BeforeAll {
    # Stand-ins so the tests run without ExchangeOnlineManagement installed.
    # Pester can only mock commands that exist, and a -ParameterFilter can only
    # see parameters the command declares, so the stubs declare the ones used.
    $stubs = @(
        'Get-ConnectionInformation', 'Get-AcceptedDomain', 'Get-EXOMailbox',
        'Get-EXOMailboxStatistics', 'Get-EXOMailboxPermission', 'Get-EXORecipientPermission',
        'Get-DistributionGroup', 'Get-DistributionGroupMember', 'Get-UnifiedGroup', 'Get-UnifiedGroupLinks'
    )
    foreach ($name in $stubs) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value {
                [CmdletBinding()]
                param($Identity, $ResultSize, $Properties, $LinkType)
            }
        }
    }
    Import-Module (Join-Path $PSScriptRoot '..' 'ExoTenantAudit.psd1') -Force

    function New-TestMailbox($Smtp, $Type, [string[]] $Addresses = @()) {
        [pscustomobject]@{
            DisplayName              = $Smtp.Split('@')[0]
            PrimarySmtpAddress       = $Smtp
            RecipientTypeDetails     = $Type
            ExternalDirectoryObjectId = "id-$Smtp"
            EmailAddresses           = @("SMTP:$Smtp") + $Addresses
            LitigationHoldEnabled    = $false
            RetainDeletedItemsFor    = '30.00:00:00'
            ArchiveStatus            = 'None'
        }
    }
}

Describe 'ConvertTo-ByteCount' {
    It 'reads the exact byte figure from REST size text' {
        ConvertTo-ByteCount '1.234 GB (1,325,000,000 bytes)' | Should -Be 1325000000
    }
    It 'accepts a plain number' {
        ConvertTo-ByteCount '4096' | Should -Be 4096
    }
    It 'returns 0 for null or unreadable input' {
        ConvertTo-ByteCount $null | Should -Be 0
        ConvertTo-ByteCount 'Unlimited' | Should -Be 0
    }
}

Describe 'Get-ExoAliasInventory' {
    BeforeAll {
        Mock -ModuleName ExoTenantAudit Get-EXOMailbox {
            New-TestMailbox 'ana@contoso.com' 'UserMailbox' @('smtp:Ana.Smith@contoso.com', 'X500:/o=legacy', 'smtp:ana@contoso.net')
        }
    }
    It 'returns only secondary SMTP addresses, lowercased' {
        $rows = @(Get-ExoAliasInventory)
        $rows.Count | Should -Be 2
        $rows.Alias | Should -Contain 'ana.smith@contoso.com'
        $rows.Alias | Should -Contain 'ana@contoso.net'
    }
    It 'never returns the primary address or non-SMTP addresses' {
        $rows = @(Get-ExoAliasInventory)
        $rows.Alias | Should -Not -Contain 'ana@contoso.com'
        ($rows.Alias -match 'x500') | Should -BeNullOrEmpty
    }
}

Describe 'Get-ExoMailboxInventory' {
    BeforeAll {
        Mock -ModuleName ExoTenantAudit Get-EXOMailbox {
            New-TestMailbox 'ana@contoso.com' 'UserMailbox'
            New-TestMailbox 'billing@contoso.com' 'SharedMailbox'
        }
        Mock -ModuleName ExoTenantAudit Get-EXOMailboxStatistics {
            [pscustomobject]@{ ItemCount = 1200; TotalItemSize = '2 GB (2,147,483,648 bytes)' }
        }
    }
    It 'returns one row per mailbox with size in bytes' {
        $rows = @(Get-ExoMailboxInventory)
        $rows.Count | Should -Be 2
        $rows[0].TotalItemSizeBytes | Should -Be 2147483648
        $rows[0].ItemCount | Should -Be 1200
        $rows[1].RecipientTypeDetails | Should -Be 'SharedMailbox'
    }
}

Describe 'Get-ExoMailboxDelegation' {
    BeforeAll {
        Mock -ModuleName ExoTenantAudit Get-EXOMailbox { New-TestMailbox 'billing@contoso.com' 'SharedMailbox' }
        Mock -ModuleName ExoTenantAudit Get-EXOMailboxPermission {
            [pscustomobject]@{ User = 'NT AUTHORITY\SELF'; AccessRights = 'FullAccess'; IsInherited = $false }
            [pscustomobject]@{ User = 'Ana@contoso.com'; AccessRights = 'FullAccess'; IsInherited = $false }
            [pscustomobject]@{ User = 'admin@contoso.com'; AccessRights = 'FullAccess'; IsInherited = $true }
        }
        Mock -ModuleName ExoTenantAudit Get-EXORecipientPermission {
            [pscustomobject]@{ Trustee = 'NT AUTHORITY\SELF'; AccessRights = 'SendAs' }
            [pscustomobject]@{ Trustee = 'bo@contoso.com'; AccessRights = 'SendAs' }
        }
    }
    It 'keeps explicit grants and drops SELF and inherited entries' {
        $rows = @(Get-ExoMailboxDelegation)
        $rows.Count | Should -Be 2
        ($rows | Where-Object Right -eq 'FullAccess').Delegate | Should -Be 'ana@contoso.com'
        ($rows | Where-Object Right -eq 'SendAs').Delegate | Should -Be 'bo@contoso.com'
    }
}

Describe 'Get-ExoGroupInventory' {
    BeforeAll {
        Mock -ModuleName ExoTenantAudit Get-DistributionGroup {
            [pscustomobject]@{ Identity = 'staff'; PrimarySmtpAddress = 'Staff@contoso.com'; RequireSenderAuthenticationEnabled = $true }
            [pscustomobject]@{ Identity = 'old'; PrimarySmtpAddress = 'old@contoso.com'; RequireSenderAuthenticationEnabled = $false }
        }
        Mock -ModuleName ExoTenantAudit Get-DistributionGroupMember -ParameterFilter { $Identity -eq 'staff' } {
            [pscustomobject]@{ PrimarySmtpAddress = 'ana@contoso.com' }
            [pscustomobject]@{ PrimarySmtpAddress = 'bo@contoso.com' }
        }
        Mock -ModuleName ExoTenantAudit Get-DistributionGroupMember -ParameterFilter { $Identity -eq 'old' } { }
        Mock -ModuleName ExoTenantAudit Get-UnifiedGroup {
            [pscustomobject]@{ Identity = 'ops'; PrimarySmtpAddress = 'ops@contoso.com'; RequireSenderAuthenticationEnabled = $true }
        }
        Mock -ModuleName ExoTenantAudit Get-UnifiedGroupLinks -ParameterFilter { $LinkType -eq 'Owners' } {
            [pscustomobject]@{ PrimarySmtpAddress = 'ana@contoso.com' }
        }
        Mock -ModuleName ExoTenantAudit Get-UnifiedGroupLinks -ParameterFilter { $LinkType -eq 'Members' } {
            [pscustomobject]@{ PrimarySmtpAddress = 'ana@contoso.com' }
            [pscustomobject]@{ PrimarySmtpAddress = 'cy@contoso.com' }
        }
    }
    It 'lists distribution group members with the internal-only flag' {
        $rows = @(Get-ExoGroupInventory | Where-Object Group -eq 'staff@contoso.com')
        $rows.Count | Should -Be 2
        $rows[0].InternalOnly | Should -BeTrue
    }
    It 'keeps empty groups visible so they can be reviewed for cleanup' {
        $row = Get-ExoGroupInventory | Where-Object Group -eq 'old@contoso.com'
        $row.Role | Should -Be '(empty group)'
    }
    It 'records Microsoft 365 group owners and members separately' {
        $rows = @(Get-ExoGroupInventory | Where-Object GroupType -eq 'Microsoft365')
        @($rows | Where-Object Role -eq 'Owner').Count | Should -Be 1
        @($rows | Where-Object Role -eq 'Member').Count | Should -Be 2
    }
}

Describe 'Invoke-ExoTenantAudit' {
    It 'refuses to run without an Exchange Online session' {
        Mock -ModuleName ExoTenantAudit Get-ConnectionInformation { }
        { Invoke-ExoTenantAudit -OutputPath (Join-Path $TestDrive 'out') } | Should -Throw '*Connect-ExchangeOnline*'
    }
}
