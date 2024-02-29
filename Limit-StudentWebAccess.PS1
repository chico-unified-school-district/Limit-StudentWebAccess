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
    $obj = '' | Select-Object stuId, stuNum, siteCode, grade, initiator, initiatorEmail,
    samid, guid, currentDN, rootOU, targOU, limitAccess, days, startDate, endDate
    $endDate = if ($_.ED.length -lt 1) { (Get-Date $_.DD).AddDays($_.DY) } else { Get-Date $_.ED }
    $obj.stuId = $_.ID
    $obj.stuNum = $_.SN
    $obj.siteCode = $_.SC
    $obj.grade = $_.GR
    $obj.days = $_.DY
    $obj.startDate = Get-Date $_.DD
    $obj.endDate = $endDate
    $obj.initiator = $_.IUN
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

function Get-StuADInfo {
  process {
    if ($global:missingInAD -contains $_.stuId) { return }
    $obj = Get-ADuser -Filter ("EmployeeId -eq '{0}'" -f $_.stuId)
    if (!$obj) {
      $global:missingInAD += $_.stuId
      $msg = $MyInvocation.MyCommand.Name, $_.stuId
      return (Write-Host ('{0},{1},AD Student obj not found' -f $msg ) -F Red)
    }
    $_.samid = $obj.SamAccountName
    $_.guid = $obj.ObjectGUID
    $_.currentDN = $obj.DistinguishedName
    $_
  }
}

function Send-OTPMsg ($url) {
  begin {
    $baseHtml = Get-Content '.\html\otp-msg.html' -Raw
    $params = @{
      From       = '<{0}>' -f $EmailCredential.Username
      Subject    = 'CUSD Student OTP'
      BodyAsHTML = $True
      Bcc        = $null
      SMTPServer = 'smtp.office365.com'
      Cred       = $EmailCredential # use a valid email account with flow rules in place to prevent SPAM warnings.
      UseSSL     = $True
      Port       = 587
    }
  }
  process {
    Write-Host ('{0},{1},{2},{3}' -f $MyInvocation.MyCommand.Name, $_.email, $_.samid, (Get-Date)) -F Blue
    $params.To = '<{0}>' -f $_.email
    $params.Body = $baseHtml -f $_.samid, $_.otp, $url , $_.grade
    if ( $Bcc ) { $params.Bcc = $Bcc } # Add Bcc to outgoing email messages.
    if (!$WhatIf) { Send-MailMessage @params }
    Write-Verbose ($params.body | out-string)
    $_
  }
}

function Show-Obj { Process { Write-Verbose ($MyInvocation.MyCommand.Name, $_ | Out-String) } }

function Test-ADSession {
  # AD Domain Controller Session
  if (($global:dc) -and (Test-ComputerSecureChannel -Server $global:dc)) { return }
  Clear-SessionData
  $global:dc = Select-DomainController $DomainControllers
  $adCmdLets = 'Get-ADUser', 'Set-ADUser', 'Set-ADAccountPassword', 'Remove-ADGroupMember', 'Add-ADGroupMember'
  New-ADSession -dc $dc -cmdlets $adCmdLets -cred $ADCredential
}

function Set-LimitStatus {
  begin { $now = Get-Date }
  process {
    $_.limitAccess = if ($now -lt $_.endDate) { $true } else { $false }
    $_
  }
}

function Get-TargetOU {
  begin {
  }
  process {
    Write-Host ('{0}' -f $MyInvocation.MyCommand.Name)
    $rootOU = $_.currentDN.Split(',')
  }
}

# =============================== Main ==================================
# Imported Functions
. .\lib\Clear-SessionData.ps1 # Useful function for querying SQL and returning results
. .\lib\Load-Module.ps1
. .\lib\New-ADSession.ps1
. .\lib\Select-DomainController.ps1
. .\lib\Show-TestRun.ps1

#TODO No gam present as of yet.
$gam = '.\bin\gam.exe'

Show-TestRun

'SqlServer' | Load-Module

$sqlParamsSIS = @{
  Server                 = $SISServer
  Database               = $SISDatabase
  Credential             = $SISCredential
  TrustServerCertificate = $true
}

$getSISLimitedStuData = Get-Content -Path .\sql\get-sis-limited-stu-data.sql -Raw

$waitInterval = 60
if (!$WhatIf) { "Runs every $waitInterval seconds" }
do {
  #TODO
  # Test-ADSession

  Invoke-SqlCmd @sqlParamsSIS -Query $getSISLimitedStuData | ConvertTo-Csv | ConvertFrom-Csv |
  Format-Obj |
  Get-Email |
  Get-StuADInfo |
  Set-LimitStatus |
  # Get-TargetOU | # Based of of lookup table or better still, from current ou and some smart logic
  # Move-ToLimitedOU | # Move OU?
  # Set-UserStatus |
  # Move-FromLimitedOU | # One could just set gecos to whatever minus 1 and the sync-student accounts will fix it.
  # Remove-FromLimited |
  Show-Obj

  if (!$WhatIf) { Start-Sleep $waitInterval }
} until ($WhatIf -or ((Get-Date) -ge (Get-Date $StopTime)))