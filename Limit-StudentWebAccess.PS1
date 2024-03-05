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
  [string]$StopTime = "11:00 PM",
  [Parameter(Mandatory = $false)]
  [string]$PrimaryGroup,
  [Parameter(Mandatory = $true)]
  [string]$SecondaryGroup,
  [Alias('wi')]
  [SWITCH]$WhatIf
)

function Format-Obj {
  process {
    $obj = '' | Select-Object stuId, fn, ln, stuNum, siteCode, siteName, grade, initiator, initiatorEmail, sendMsg,
    samid, guid, currentDN, rootOU, targetOU, originalOU, limitAccess, days, startDate, endDate
    $endDate = if ($_.ED.length -lt 1) { (Get-Date $_.DD).AddDays($_.DY) } else { Get-Date $_.ED }
    $obj.stuId = $_.ID
    $obj.fn = $_.FN
    $obj.ln = $_.LN
    $obj.stuNum = $_.SN
    $obj.siteCode = $_.SC
    $obj.grade = $_.GR
    $obj.days = $_.DY
    $obj.startDate = Get-Date $_.DD
    $obj.endDate = (Get-Date $endDate).AddHours(23.9) # Ensure that the last full day is recognized
    $obj.initiator = $_.IUN
    $obj.sendMsg = $false
    $obj
  }
}

function Get-Email {
  process {
    if ($_.initiator.length -lt 1) { return $_ }
    $obj = Get-ADuser -Filter ("SamAccountName -eq '{0}'" -f $_.initiator) -Properties Mail
    if (!$obj) { Write-Host ('{0},{1},AD Staff obj not found' -f $msg ) -F Red }
    $_.initiatorEmail = $obj.Mail
    $_
  }
}

function Get-SqlData ($params, $query) {
  begin {
  }
  process {
    # Write-Host ('{0}' -f $MyInvocation.MyCommand.Name)
    Invoke-SqlCmd @params -Query $query | ConvertTo-Csv | ConvertFrom-Csv
  }
}

function Get-StuADInfo {
  process {
    if ($global:missingInAD -contains $_.stuId) { return }
    $obj = Get-ADuser -Filter ("EmployeeId -eq '{0}'" -f $_.stuId) -Properties *
    if (!$obj) {
      $global:missingInAD += $_.stuId
      $msg = $MyInvocation.MyCommand.Name, $_.stuId
      return (Write-Host ('{0},{1},AD Student obj not found' -f $msg ) -F Red)
    }
    $_.samid = $obj.SamAccountName
    $_.guid = $obj.ObjectGUID
    $_.currentDN = $obj.DistinguishedName
    # $_.rootOU = $obj.DistinguishedName.Split(',')[1..100] -join ','
    $_
  }
}

function Get-TargetOU {
  begin {
    $lookUpTable = Get-Content -Path .\json\lookup-table.json -Raw | ConvertFrom-Json
    function Format-Grade ($grade) {
      switch ($grade) {
        -1 { 'Prek' }; -2 { 'Prek ' }; 0 { 'K' }; 1 { '1st' }; 2 { '2nd' }; 3 { '3rd' }; 4 { '4th' }; 5 { '5th' };
        6 { '6th' }; 7 { '7th' }; 8 { '8th' }; 9 { '9th' }; 10 { '10th' }; 11 { '11th' }; 12 { '12th' };
        13 { '12th' }; 14 { '12th' }; 17 { 'Prek' }; 18 { 'Prek' }
      }
    }
    function Format-OrgUnitPath {
      process {
        # Skip Handling of School 19 (Special Education) and Grades Over the 18th Level
        if (([int]$_.grade -le 18) -and ([int]$_.departmentNumber -ne 19)) {
          # Build proper OU path based on grade level
          'OU={0},{1}' -f (Format-Grade $_.grade), $_.rootOU
        }
        else { $_.OrgUnit }
      }
    }
  }
  process {
    $siteCode = $_.siteCode
    $site = $lookUpTable.Where({ [int]$_.SiteCode -eq [int]$siteCode }) | ConvertTo-Csv | ConvertFrom-Csv
    $_.siteName = $site.SiteName
    $_.rootOU = $site.OrgUnit
    $targOU = if ($_.limitAccess -eq $true) { 'OU=Penalty Box,' + $_.rootOU } else { $_ | Format-OrgUnitPath }
    $_.targetOU = $targOU
    $_
  }
}

function Move-ToLimitedOU {
  process {
    if ($_.limitAccess -eq $False) { return $_ }
    if ( $_.currentDN -match 'Penalty Box' ) { return $_ }

    Write-Host ('{0},{1}' -f $MyInvocation.MyCommand.Name, $_.samid)
    Set-ADUser -Identity $_.guid -Division $_.originalOU -Confirm:$False -WhatIf:$WhatIf
    Move-ADObject -Identity $_.guid -TargetPath $_.targetOU -Confirm:$false -WhatIf:$WhatIf
    $_.sendMsg = $true
    if (!$WhatIF) { Start-Sleep 15 }
    $_
  }
}

function Move-ToRegularOU {
  process {
    if (($_.currentDN -match 'Penalty Box') -and ($_.limitAccess -eq $False )) {
      if (!$_.originalOU) {
        # If origianlOU is null then have external process set the correct OU
        Write-Host ('{0},{1},Original OU missing. Trying alternate method.' -f $MyInvocation.MyCommand.Name, $_.samid)
        Set-ADUser -Identity $_.guid -Replace @{gecos = ([int]$_.grade + 1) } -Confirm:$False -WhatIf:$WhatIf
        return $_
      }
      Write-Host ('{0},{1}' -f $MyInvocation.MyCommand.Name, $_.samid)
      Set-ADUser -Identity $_.guid -Clear Division -Confirm:$False -WhatIf:$WhatIf
      Move-ADObject -Identity $_.guid -TargetPath $_.originalOU -Confirm:$false -WhatIf:$WhatIf
    }
    $_
  }
}

function Send-PenaltyBoxMsg ($url) {
  begin {
    $baseHtml = Get-Content '.\html\msg.html' -Raw
    $params = @{
      From       = '<{0}>' -f $EmailCredential.Username
      Subject    = 'CUSD Student Moved to Penalty Box'
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
    Write-Host ('{0},{1},{2},{3}' -f $MyInvocation.MyCommand.Name, $_.initiatorEmail, $_.samid, (Get-Date)) -F Blue
    $params.To = '<{0}>' -f $_.initiatorEmail
    $params.Body = $baseHtml -f $_.fn, $_.ln, $_.startDate, $_.endDate, $_.stuId, $_.siteName, $_.grade
    if ( $Bcc ) { $params.Bcc = $Bcc } # Add Bcc to outgoing email messages.
    Write-Verbose ($params | out-string)
    if (!$WhatIf) { Send-MailMessage @params }
    $_
  }
}

function Set-LimitStatus {
  begin { $now = Get-Date }
  process {
    $_.limitAccess = if ($now -lt $_.endDate) { $true } else { $false }
    $_
  }
}

function Show-Obj { Process { Write-Verbose ($MyInvocation.MyCommand.Name, $_ | Out-String) } }

function Test-ADSession {
  # AD Domain Controller Session
  if (($global:dc) -and (Test-ComputerSecureChannel -Server $global:dc)) { return }
  Clear-SessionData
  $global:dc = Select-DomainController $DomainControllers
  $adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Move-ADObject'
  New-ADSession -dc $dc -cmdlets $adCmdLets -cred $ADCredential
}

# =============================== Main ==================================
# Imported Functions
. .\lib\Clear-SessionData.ps1 # Useful function for querying SQL and returning results
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

$getSISLimitedStuData = Get-Content -Path .\sql\get-sis-limited-stu-data.sql -Raw
#TODO
$waitInterval = 10
if (!$WhatIf) { "Runs every $waitInterval seconds" }
do {
  #TODO
  # Test-ADSession

  Get-SqlData $sqlParamsSIS $getSISLimitedStuData |
  Format-Obj |
  Get-Email |
  Get-StuADInfo |
  Set-LimitStatus |
  Get-TargetOU | # Based of of lookup table or better still, from current ou and some smart logic
  Move-ToLimitedOU | # Move OU?
  Send-PenaltyBoxMsg |
  Move-ToRegularOU | # One could just set gecos to whatever minus 1 and the sync-student accounts will fix it.
  Show-Obj

  if (!$WhatIf) { Start-Sleep $waitInterval }
} until ($WhatIf -or ((Get-Date) -ge (Get-Date $StopTime)))