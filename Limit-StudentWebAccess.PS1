<#
https://groups.google.com/g/google-apps-manager/c/NyDVv8hGRUk
https://www.reddit.com/r/k12sysadmin/comments/oghqj8/how_to_disablereenable_devices_with_gam_using/
#>
[cmdletbinding()]
param (
  [Parameter(Mandatory = $True)]
  [Alias('DCs')]
  [string[]]$DomainControllers,
  [Parameter(Mandatory = $True)]
  [System.Management.Automation.PSCredential]$ADCredential,
  [Parameter(Mandatory = $True)]
  [string]$SISServer,
  [Parameter(Mandatory = $True)]
  [string]$SISDatabase,
  [Parameter(Mandatory = $True)]
  [System.Management.Automation.PSCredential]$SISCredential,
  [Parameter(Mandatory = $True)]
  [System.Management.Automation.PSCredential]$EmailCredential,
  [Parameter(Mandatory = $false)]
  [string[]]$Bcc,
  [string]$StopTime,
  [Alias('wi')]
  [SWITCH]$WhatIf
)

function Compare-SISActviePenalty ($data) {
  process {
    $id = $_.ad.EmployeeId
    $obj = $data | Where-Object { $_.permId -eq $id }
    if ($obj) { return } # If a match is found then skip entry, otherwise press on!
    $_
  }
}

function Format-FirstObj {
  process {
    $obj = '' | Select-Object sis, ad, site, days, targetOU, staffEmail, sendMsg, limitAccess
    $obj.sis = $_ # Drop entire converted sis object into 'sis' prop
    $obj.sendMsg = $false
    $obj
  }
}

function Format-SecondObj {
  process {
    $obj = '' | Select-Object -Property sis, ad, site, targetOU, limitAccess
    $obj.ad = $_
    $obj
  }
}

function Get-ADInPenaltyOU ($orgUnits) {
  $params = @{
    Filter     = "gecos -like '*' -and EmployeeId -like '*'"
    Properties = 'EmployeeID', 'gecos', 'departmentNumber'
  }
  Write-Verbose ('{0}' -f $MyInvocation.MyCommand.Name)
  $orgUnits | ForEach-Object { Get-ADUser @params -SearchBase $_.DistinguishedName }
}

function Get-Email {
  process {
    if ($_.sis.staffUsr.length -lt 1) { return $_ }
    $obj = Get-ADuser -Filter ("SamAccountName -eq '{0}'" -f $_.sis.staffUsr) -Properties Mail
    if (!$obj) { Write-Host ('{0},{1},AD Staff obj not found' -f $MyInvocation.MyCommand.Name, $_.sis.staffUsr) -F Red }
    $_.staffEmail = $obj.Mail
    $_
  }
}

function Get-StuSISEntry ($params, $baseSql) {
  process {
    $sql = $baseSql -f $_.ad.EmployeeID, $_.ad.departmentNumber[0]
    $_.sis = Invoke-SqlCmd @params -Query $sql | ConvertTo-Csv | ConvertFrom-Csv
    $_
  }
}

function Get-SiteData ($lookUpTable) {
  process {
    $siteCode = $_.ad.departmentNumber[0]
    $site = $lookUpTable.Where({ [int]$_.SiteCode -eq [int]$siteCode }) | ConvertTo-Csv | ConvertFrom-Csv
    $_.site = $site
    $_
  }
}

function Get-SISActivePenatly ($params, $query) {
  Invoke-SqlCmd @params -Query $query | ConvertTo-Csv | ConvertFrom-Csv
}

function Get-StuADInfo {
  process {
    if ($global:missingInAD -contains $_.sis.permId) { return }
    $properties = 'departmentNumber'
    $obj = Get-ADuser -Filter ("EmployeeId -eq '{0}'" -f $_.sis.permId) -Properties $properties
    if (!$obj) {
      $global:missingInAD += $_.sis.permId
      $msg = $MyInvocation.MyCommand.Name, $_.sis.permId
      return (Write-Host ('{0},{1},AD Student obj not found' -f $msg ) -F Red)
    }
    $_.ad = $obj
    $_
  }
}

function Get-TargetOU {
  begin {
    function Format-Grade ($grade) {
      switch ($grade) {
        -1 { 'Prek' }; -2 { 'Prek' }; 0 { 'K' }; 1 { '1st' }; 2 { '2nd' }; 3 { '3rd' }; 4 { '4th' }; 5 { '5th' };
        6 { '6th' }; 7 { '7th' }; 8 { '8th' }; 9 { '9th' }; 10 { '10th' }; 11 { '11th' }; 12 { '12th' };
        13 { '12th' }; 14 { '12th' }; 17 { 'Prek' }; 18 { 'Prek' }
      }
    }
    function Format-OrgUnitPath {
      process {
        # Skip Handling of School 19 (Special Education) and Grades Over the 18th Level
        # The departmentNumber attribute is an array so we reference the zeroth index
        # if (($_.sis.grade -le 18) -and ([int]$_.ad.departmentNumber[0] -ne 19)) {
        if ([int]$_.sis.grade -le 18) {
          # Build proper OU path based on grade level
          'OU={0},{1}' -f (Format-Grade $_.sis.grade), $_.site.OrgUnit
        }
        else {
          $_.site.OrgUnit
        }
      }
    }
  }
  process {
    $targOU = if ($_.limitAccess -eq $true) { 'OU=Penalty Box,' + $_.site.OrgUnit } else { $_ | Format-OrgUnitPath }
    $_.targetOU = $targOU
    $_
  }
}

function Move-ToTargetOU {
  process {
    $msg = $MyInvocation.MyCommand.Name, $_.ad.SamAccountName, ($_.targetOU.Split(',')[0..1] -join ',')
    $currentOU = $_.ad.DistinguishedName.Split(',')[1..100] -join ','
    Write-Verbose ($_.ad.SamAccountName, "Current: $currentOU", "Target:  $($_.targetOU)" | Out-String)
    if ($currentOU -eq $_.targetOU) { return $_ }

    try { Move-ADObject -Identity $_.ad.ObjectGUID -TargetPath $_.targetOU -Confirm:$false -WhatIf:$WhatIf }
    catch { return (Write-Error ('{0},{1},{2}' -f $msg)) }
    Write-Host ('{0},{1},{2}' -f $msg) -f Blue
    if ($_.limitAccess -eq $true) { $_.sendMsg = $true }
    $_
  }
}

function Send-Msg ($baseHtml) {
  begin {
    $params = @{
      From       = '<{0}>' -f $EmailCredential.Username
      Subject    = 'Student to Penalty Box'
      BodyAsHTML = $True
      Bcc        = $null
      SMTPServer = 'smtp.office365.com'
      Cred       = $EmailCredential # use a valid email account with flow rules in place to prevent SPAM warnings.
      UseSSL     = $True
      Port       = 587
    }
  }
  process {
    if ($_.sendMsg -eq $false) { return $_ }

    $msg = $MyInvocation.MyCommand.Name, $_.staffEmail, $_.ad.SamAccountName, $_.sis.startDate, $_.sis.endDate

    $params.To = '<{0}>' -f $_.staffEmail
    $params.Body = $baseHtml -f $_.sis.firstName, $_.sis.lastName, $_.sis.startDate, $_.sis.endDate,
    $_.sis.permId, $_.site.siteName, $_.sis.grade
    if ( $Bcc ) { $params.Bcc = $Bcc } # Add Bcc to outgoing email messages.
    if (!$WhatIf) {
      try { Send-MailMessage @params }
      catch { return (Write-Error ('{0},{1},{2},{3},{4}' -f $msg)) }
    }
    # Write-Verbose ($params.Body | Out-String)
    Write-Host ('{0},{1},{2},{3},{4}' -f $msg) -F Blue
    $_
  }
}

function Set-DayCount {
  process {
    # If dayCount is null or zero then it needs to be filled in. Otherwise defaults to user supplied value
    $_.days = if (([int]$_.sis.dayCount -gt 1) -and ($_.sis.pbType -ne 'PBN')) { $_.sis.dayCount }
    elseif ($_.sis.pbType -eq 'PBN') { 3650 }
    else { 7 }
    $_
  }
}

function Set-EndDate {
  process {
    # Ensure that the last full day is recognized via -Hour 23 param
    $_.sis.endDate = Get-Date ((Get-Date $_.sis.startDate).AddDays($_.days)) -Hour 23
    $_
  }
}


function Set-LimitStatus {
  begin { $now = Get-Date }
  process {
    $_.limitAccess = if ($now -lt $_.sis.endDate) { $true }
    $_
  }
}

function Set-StartDate {
  process {
    $_.sis.startDate = if ($_.sis.startDate.length -lt 1) { Get-Date } else { Get-Date $_.sis.startDate }
    $_
  }
}

function Show-Obj {
  begin { $i = 0 }
  Process {
    $i++
    Write-Verbose ($i, $MyInvocation.MyCommand.Name, $_ | Out-String)
    Write-Debug 'Proceed?'
  }
}

function Skip-NoGmail {
  process {
    if ($_.ad.DistinguishedName -match 'No Gmail') {
      return (Write-Verbose ('{0},{1}' -f $MyInvocation.MyCommand.Name, $_.ad.SamAccountName))
    }
    $_
  }
}

function Test-ADSession {
  # AD Domain Controller Session
  if (($global:dc) -and (Test-ComputerSecureChannel -Server $global:dc)) { return }
  Clear-SessionData
  $global:dc = Select-DomainController $DomainControllers
  $adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Move-ADObject', 'Get-ADOrganizationalUnit'
  New-ADSession -dc $dc -cmdlets $adCmdLets -cred $ADCredential
}

function Update-PenaltyDays ($params, $baseSql) {
  process {
    if (($_.sis.dayCount -lt 1) -or (($_.sis.pbType -eq 'PBN') -and ($_.sis.dayCount -ne 3650))) {
      $sql = $baseSql -f $_.days, $_.sis.permId, $_.sis.pbType
      Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.permId, $sql) -F Blue
      if (!$WhatIf) { Invoke-Sqlcmd @params -Query $sql }
    }
    $_
  }
}

function Update-StartDate ($params, $baseSql) {
  process {
    if ($_.sis.startDate.length -lt 1 ) {
      $sql = $baseSql -f $_.sis.permId, $_.sis.pbType
      Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.permId, $sql) -F Blue
      if (!$WhatIf) { Invoke-Sqlcmd @params -Query $sql }
    }
    $_
  }
}

# =============================== Main ==================================
# Imported Functions
. .\lib\Clear-SessionData.ps1
. .\lib\Load-Module.ps1
. .\lib\New-ADSession.ps1
. .\lib\Select-DomainController.ps1
. .\lib\Show-TestRun.ps1

Show-TestRun

'SqlServer' | Load-Module

$sqlParamsSIS = @{
  Server                 = $SISServer
  Database               = $SISDatabase
  Credential             = $SISCredential
  TrustServerCertificate = $true
}

$lookUpTable = Get-Content -Path .\json\lookupTable.json -Raw | ConvertFrom-Json
$htmlMsg = Get-Content '.\html\msg.html' -Raw
$getSISLimitedStuData = Get-Content -Path .\sql\get-sis-limited-stu-data.sql -Raw
$getStuSISEntry = Get-Content -Path .\sql\get-stu-sis.sql -Raw
$setDayCount = Get-Content -Path .\sql\set-daycount.sql -Raw
$setStartDate = Get-Content -Path .\sql\set-startdate.sql -Raw

Test-ADSession

$penaltyOrgUnits = Get-ADOrganizationalUnit -Filter "name -like '*Penalty*Box*'"

$waitInterval = 60
if (!$WhatIf) { "Runs every $waitInterval seconds" }
do {
  Test-ADSession

  $sisActivePenaltyData = Get-SISActivePenatly $sqlParamsSIS $getSISLimitedStuData

  # Process existing entries
  $sisActivePenaltyData |
  Format-FirstObj |
  Skip-NoGmail |
  Update-StartDate $sqlParamsSIS $setStartDate |
  Set-StartDate |
  Set-DayCount |
  Update-PenaltyDays $sqlParamsSIS $setDayCount |
  Set-EndDate |
  Get-StuADInfo |
  Get-SiteData $lookUpTable |
  Get-Email |
  Set-LimitStatus |
  Get-TargetOU |
  Move-ToTargetOU |
  Send-Msg ($htmlMsg) |
  Show-Obj

  # Process deleted/missing entries
  Get-ADInPenaltyOU $penaltyOrgUnits |
  Format-SecondObj |
  Skip-NoGmail |
  Compare-SISActviePenalty $sisActivePenaltyData |
  Get-StuSISEntry $sqlParamsSIS $getStuSISEntry |
  Get-SiteData $lookUpTable |
  Get-TargetOU |
  Move-ToTargetOU |
  Show-Obj

  if (!$WhatIf) {
    Write-Verbose "Waiting $waitInterval..."
    Start-Sleep $waitInterval
  }
} until ($WhatIf -or ((Get-Date) -ge (Get-Date $StopTime)))