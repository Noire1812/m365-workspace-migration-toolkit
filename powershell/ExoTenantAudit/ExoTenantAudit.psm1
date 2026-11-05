#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only Exchange Online tenant audit for migration planning.

.DESCRIPTION
    Collects the inventory a mail migration needs before any data moves:
    accepted domains, mailboxes with size and item counts, secondary SMTP
    aliases, mailbox delegation (Full Access and Send As), and distribution
    and Microsoft 365 group membership. Every function only reads; nothing
    in this module changes the tenant.

    Requires the ExchangeOnlineManagement module (v3) and an existing
    session from Connect-ExchangeOnline.
#>

Set-StrictMode -Version 3.0

function Assert-ExoConnection {
    [CmdletBinding()]
    param()
    $cmd = Get-Command -Name Get-ConnectionInformation -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw 'ExchangeOnlineManagement v3 is not loaded. Run: Import-Module ExchangeOnlineManagement'
    }
    $live = @(Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' })
    if ($live.Count -eq 0) {
        throw 'No Exchange Online session. Run Connect-ExchangeOnline first.'
    }
}

function ConvertTo-ByteCount {
    <#
    .SYNOPSIS
        Turns an Exchange size value into a byte count.
    .DESCRIPTION
        Over the REST-based v3 cmdlets, sizes such as TotalItemSize arrive as
        text like "1.234 GB (1,325,000,000 bytes)". This reads the exact byte
        figure in brackets, so no unit conversion or rounding is involved.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(ValueFromPipeline)] $Size)
    process {
        if ($null -eq $Size) { return [long]0 }
        $text = "$Size"
        if ($text -match '\(([\d,]+) bytes\)') {
            return [long]($Matches[1] -replace ',', '')
        }
        if ($text -match '^\d+$') { return [long]$text }
        return [long]0
    }
}

function Get-ExoDomainInventory {
    [CmdletBinding()]
    param()
    Get-AcceptedDomain | ForEach-Object {
        [pscustomobject]@{
            DomainName = $_.DomainName.ToString()
            DomainType = "$($_.DomainType)"
            Default    = [bool]$_.Default
        }
    }
}

function Get-ExoMailboxInventory {
    <#
    .SYNOPSIS
        One row per mailbox: type, size, item count and retention settings.
    #>
    [CmdletBinding()]
    param()
    $props = 'LitigationHoldEnabled', 'RetainDeletedItemsFor', 'ArchiveStatus'
    Get-EXOMailbox -ResultSize Unlimited -Properties $props | ForEach-Object {
        $stats = Get-EXOMailboxStatistics -Identity $_.ExternalDirectoryObjectId -ErrorAction SilentlyContinue
        [pscustomobject]@{
            DisplayName           = $_.DisplayName
            PrimarySmtpAddress    = "$($_.PrimarySmtpAddress)".ToLowerInvariant()
            RecipientTypeDetails  = "$($_.RecipientTypeDetails)"
            ItemCount             = if ($stats) { [long]$stats.ItemCount } else { $null }
            TotalItemSizeBytes    = if ($stats) { ConvertTo-ByteCount $stats.TotalItemSize } else { $null }
            LitigationHoldEnabled = [bool]$_.LitigationHoldEnabled
            RetainDeletedItemsFor = "$($_.RetainDeletedItemsFor)"
            ArchiveStatus         = "$($_.ArchiveStatus)"
        }
    }
}

function Get-ExoAliasInventory {
    <#
    .SYNOPSIS
        One row per secondary SMTP address, so aliases can be recreated on the target.
    .DESCRIPTION
        In EmailAddresses an uppercase "SMTP:" prefix marks the primary address
        and a lowercase "smtp:" prefix marks a secondary one. The comparison is
        case-sensitive on purpose.
    #>
    [CmdletBinding()]
    param()
    Get-EXOMailbox -ResultSize Unlimited | ForEach-Object {
        $owner = "$($_.PrimarySmtpAddress)".ToLowerInvariant()
        foreach ($addr in @($_.EmailAddresses)) {
            if ("$addr".StartsWith('smtp:', [System.StringComparison]::Ordinal)) {
                [pscustomobject]@{
                    Mailbox = $owner
                    Alias   = "$addr".Substring(5).ToLowerInvariant()
                }
            }
        }
    }
}

function Get-ExoMailboxDelegation {
    <#
    .SYNOPSIS
        Full Access and Send As grants, the permission map a migration has to rebuild.
    .DESCRIPTION
        Skips inherited entries and the mailbox's own NT AUTHORITY\SELF entry,
        which every mailbox has and which do not need to be migrated.
    #>
    [CmdletBinding()]
    param()
    Get-EXOMailbox -ResultSize Unlimited | ForEach-Object {
        $mbx = "$($_.PrimarySmtpAddress)".ToLowerInvariant()
        $id = $_.ExternalDirectoryObjectId

        Get-EXOMailboxPermission -Identity $id -ErrorAction SilentlyContinue |
            Where-Object { -not $_.IsInherited -and $_.User -ne 'NT AUTHORITY\SELF' -and "$($_.AccessRights)" -match 'FullAccess' } |
            ForEach-Object {
                [pscustomobject]@{ Mailbox = $mbx; Delegate = "$($_.User)".ToLowerInvariant(); Right = 'FullAccess' }
            }

        Get-EXORecipientPermission -Identity $id -ErrorAction SilentlyContinue |
            Where-Object { $_.Trustee -ne 'NT AUTHORITY\SELF' -and "$($_.AccessRights)" -match 'SendAs' } |
            ForEach-Object {
                [pscustomobject]@{ Mailbox = $mbx; Delegate = "$($_.Trustee)".ToLowerInvariant(); Right = 'SendAs' }
            }
    }
}

function Get-ExoGroupInventory {
    <#
    .SYNOPSIS
        One row per group member, for distribution groups and Microsoft 365 groups.
    .DESCRIPTION
        InternalOnly reflects RequireSenderAuthenticationEnabled: when it is
        true, people outside the organization cannot send to the group. The
        target group should keep the same posting rule.
    #>
    [CmdletBinding()]
    param()
    Get-DistributionGroup -ResultSize Unlimited | ForEach-Object {
        $group = $_
        $members = @(Get-DistributionGroupMember -Identity $group.Identity -ResultSize Unlimited)
        if ($members.Count -eq 0) { $members = @($null) }
        foreach ($m in $members) {
            [pscustomobject]@{
                Group        = "$($group.PrimarySmtpAddress)".ToLowerInvariant()
                GroupType    = 'Distribution'
                InternalOnly = [bool]$group.RequireSenderAuthenticationEnabled
                Member       = if ($m) { "$($m.PrimarySmtpAddress)".ToLowerInvariant() } else { '' }
                Role         = if ($m) { 'Member' } else { '(empty group)' }
            }
        }
    }

    Get-UnifiedGroup -ResultSize Unlimited | ForEach-Object {
        $group = $_
        foreach ($linkType in 'Owners', 'Members') {
            foreach ($m in @(Get-UnifiedGroupLinks -Identity $group.Identity -LinkType $linkType -ResultSize Unlimited)) {
                [pscustomobject]@{
                    Group        = "$($group.PrimarySmtpAddress)".ToLowerInvariant()
                    GroupType    = 'Microsoft365'
                    InternalOnly = [bool]$group.RequireSenderAuthenticationEnabled
                    Member       = "$($m.PrimarySmtpAddress)".ToLowerInvariant()
                    Role         = $linkType.TrimEnd('s')
                }
            }
        }
    }
}

function Invoke-ExoTenantAudit {
    <#
    .SYNOPSIS
        Runs every inventory and writes one CSV per area plus a summary.
    .EXAMPLE
        Connect-ExchangeOnline -UserPrincipalName admin@contoso.com
        Invoke-ExoTenantAudit -OutputPath ./audit
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OutputPath
    )
    Assert-ExoConnection
    $null = New-Item -ItemType Directory -Path $OutputPath -Force

    $sets = [ordered]@{
        domains    = { Get-ExoDomainInventory }
        mailboxes  = { Get-ExoMailboxInventory }
        aliases    = { Get-ExoAliasInventory }
        delegation = { Get-ExoMailboxDelegation }
        groups     = { Get-ExoGroupInventory }
    }
    $results = [ordered]@{}
    foreach ($name in $sets.Keys) {
        Write-Verbose "Collecting $name"
        $rows = @(& $sets[$name])
        $results[$name] = $rows
        $rows | Export-Csv -Path (Join-Path $OutputPath "$name.csv") -NoTypeInformation -Encoding utf8
    }

    $mbx = $results['mailboxes']
    $summary = [ordered]@{
        GeneratedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        Domains         = $results['domains'].Count
        Mailboxes       = $mbx.Count
        UserMailboxes   = @($mbx | Where-Object RecipientTypeDetails -eq 'UserMailbox').Count
        SharedMailboxes = @($mbx | Where-Object RecipientTypeDetails -eq 'SharedMailbox').Count
        TotalItems      = [long](($mbx | Measure-Object ItemCount -Sum).Sum)
        TotalBytes      = [long](($mbx | Measure-Object TotalItemSizeBytes -Sum).Sum)
        Aliases         = $results['aliases'].Count
        DelegationGrants = $results['delegation'].Count
        Groups          = @($results['groups'] | Select-Object -ExpandProperty Group -Unique).Count
        OnLitigationHold = @($mbx | Where-Object LitigationHoldEnabled).Count
    }
    $summary | ConvertTo-Json | Set-Content -Path (Join-Path $OutputPath 'summary.json') -Encoding utf8
    [pscustomobject]$summary
}

Export-ModuleMember -Function @(
    'Invoke-ExoTenantAudit'
    'Get-ExoDomainInventory'
    'Get-ExoMailboxInventory'
    'Get-ExoAliasInventory'
    'Get-ExoMailboxDelegation'
    'Get-ExoGroupInventory'
    'ConvertTo-ByteCount'
)
