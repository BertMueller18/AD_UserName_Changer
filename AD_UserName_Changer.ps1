# AD UserName Changer Script
# Version 1.2.0
# Use:
#	Rename sAMAccountName in Domain to a New sAMAccountName.
#	Update Home Directory 
#	Update Roaming profile
#	Update Exchange SMTP addresses
#	Sends out e-mail to user, support and manager about the change
#	If -csv argument is not given then file select is dialog box is appears
#	Will create log file in same folder as Csv. 
#
# Dependencies
#   7-zip (http://www.7-zip.org/)
#   DelProf2 (https://helgeklein.com/free-tools/delprof2-user-profile-deletion-tool/)
#
## Variables
param (
	[string]$csv = $null
)
#############Main Variable Setup #########################################################################################################
#User Home Drive Share
$HomeDriveShare = "Home Drive Share"
#User Roming Profile shares Array.
$RomingProfiles = "Array","Of","Roming Profiles UNCs"
#Archive for Users RDS Profiles
$strArchiveHome = "Profiles Archive Share UNC"
#Current Script location
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
#XenApp Servers to clean
$XenAppServers ="Array","of","RDS","or","Citrix","servers","to Clean","Profiles","On"
#Sets Path for DelProf2.exe
$delpro2path = "$env:ProgramFiles (x86)\SysinternalsSuite\DelProf2.exe"
#Gets short Domain Name
$domainNameFQDN = $((gwmi Win32_ComputerSystem).Domain)
$domainName = $domainNameFQDN.Split(".")[0]
#URL to Company Logo
$strCompanyLogo='http://example.com/logos/email.png'
#CompanyName
$strCompanyName="Example Inc."
#Subject for ticket system to have records of changes in on ticket
$TicketSubject = "##000000## "
#Get Current Date
$StrDate = Get-Date -format yyyyMMdd
#Exchange Servers
$ExchangeServer = "Exchange.Server.FQDN"
$PSEmailServer = $ExchangeServer
#From E-Mail Address
$FromSMTP = "support@e.mail"

#First row Headers In CSV
#CSV Fields
$csv_migrate = "Migrate"
$csv_currentSAMAccountName = "Username"
$csv_NewSAMAccountName = "New UserName"
$csv_FirstName = "First Name"
$csv_LastName = "Last Name"
$csv_UpdatedLastName = "Updated Last Name"
$csv_EMail = "E-Mail"
$csv_ManagersSAMAccountName = "Manager AD Username"
#############Main Variable Setup #########################################################################################################

##Load Active Directory Module
# Load AD PSSnapins
If ((Get-Module | Where-Object {$_.Name -Match "ActiveDirectory"}).Count -eq 0 ) {
	Write-Host ("Loading Active Directory Plugins") -foregroundcolor "Green"
	Import-Module "ActiveDirectory"  -ErrorAction SilentlyContinue
} Else {
	Write-Host ("Active Directory Plug-ins Already Loaded") -foregroundcolor "Green"
}

# Load All Exchange PSSnapins 
If ((Get-PSSession | Where-Object { $_.ConfigurationName -Match "Microsoft.Exchange" }).Count -eq 0 ) {
	Write-Host ("Loading Exchange Plugins") -foregroundcolor "Green"
	If ($([System.Net.Dns]::GetHostByName(($env:computerName))).hostname -eq $([System.Net.Dns]::GetHostByName(($ExchangeServer))).hostname) {
		Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010 -ErrorAction SilentlyContinue
		. $env:ExchangeInstallPath\bin\RemoteExchange.ps1
		Connect-ExchangeServer -auto -AllowClobber
	} else {
		$ERPSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$ExchangeServer/PowerShell/ -Authentication Kerberos
		Import-PSSession $ERPSession -AllowClobber
	}
} Else {
	Write-Host ("Exchange Plug-ins Already Loaded") -foregroundcolor "Green"
}

If ($LASTEXITCODE -ne 0 ) {
	Write-Host ("Exchange Plug-ins and or Server Failed to Load: $LASTEXITCODE Retrying connection") -foregroundcolor "Red"
	$LASTEXITCODE = 0
	Get-PSSession | Where-Object {$_.computername -eq $ExchangeServer } | Remove-PSSession
	#Close and Reopen Session
	If ($([System.Net.Dns]::GetHostByName(($env:computerName))).hostname -eq $([System.Net.Dns]::GetHostByName(($ExchangeServer))).hostname) {
		Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010 -ErrorAction SilentlyContinue
		. $env:ExchangeInstallPath\bin\RemoteExchange.ps1
		Connect-ExchangeServer -auto -AllowClobber
	} else {
		$ERPSession = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$ExchangeServer/PowerShell/ -Authentication Kerberos
		Import-PSSession $ERPSession -AllowClobber
	}
	If ($LASTEXITCODE -ne 0 ) {
		throw "Exchange Plug-ins and or Server Failed to Load $LASTEXITCODE"
	}
}

#Set Defaults
$PrimaryEmailDomain = ((get-emailaddresspolicy | Where-Object { $_.Priority -Match "Lowest" } ).EnabledPrimarySMTPAddressTemplate).split('@')[-1]

##Functions
Function Write-Log {
    [CmdletBinding()]
    Param(
    [Parameter(Mandatory=$False)]
    [ValidateSet("INFO","WARN","ERROR","FATAL","DEBUG")]
    [String]
    $Level = "INFO",

	[Parameter(Mandatory=$False)]
    [switch]
    $NoConsoleOutput,

    [Parameter(Mandatory=$False)]
    [string]
    $foregroundcolor,
	
    [Parameter(Mandatory=$True)]
    [string]
    $Message,

    [Parameter(Mandatory=$False)]
    [string]
    $logfile
    )

    $Stamp = (Get-Date).toString("yyyy/MM/dd HH:mm:ss")
    $Line = "$Stamp $Level $Message"
    If($logfile) {
        Add-Content $logfile -Value $Line
    }
	If (!($NoConsoleOutput)) {
		If ($foregroundcolor) {
			Write-Host $Line -foregroundcolor $foregroundcolor
		} Else {
			Write-Output $Line
		}
	}
 
}
Function Get-FileName($initialDirectory)
{  
 [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") |
 Out-Null

 $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
 $OpenFileDialog.initialDirectory = $initialDirectory
 $OpenFileDialog.filter = "CSV files (*.CSV)| *.CSV|All files (*.*)|*.*"
 $OpenFileDialog.ShowDialog() | Out-Null
 $Logfile = $OpenFileDialog.filename + "_" + $StrDate + ".log" 
 $OpenFileDialog.filename
} #end function Get-FileName

#Validates strings
If (-Not $strArchiveHome.EndsWith("\")) { $strArchiveHome= $($strArchiveHome + "\")}
If (-Not $HomeDriveShare.EndsWith("\")) { $HomeDriveShare= $($HomeDriveShare + "\")}


## Start of Main script

#Import records to be changed.
If ($csv -eq $null -Or $csv -eq '') {
	$ObjCSV = Import-Csv  $(Get-FileName -initialDirectory $PSScriptRoot) 
} Else {
	If ( Test-Path $csv ) {
		$ObjCSV = Import-Csv  $csv
		$Logfile = $csv + "_" + $StrDate + ".log"
	} Else {
		$ObjCSV = Import-Csv  $(Get-FileName -initialDirectory $PSScriptRoot) 
	}
}


#7-Zip Set-up
if (!(test-path "$env:ProgramFiles\7-Zip\7z.exe")) {
	Write-Log -Level "FATAL" -logfile $Logfile -Message "$env:ProgramFiles\7-Zip\7z.exe needed"
	throw "$env:ProgramFiles\7-Zip\7z.exe needed"
}else{ 
	set-alias s7zip "$env:ProgramFiles\7-Zip\7z.exe"  
}
#DelProf2 Set-up
if (!(test-path "$env:ProgramFiles (x86)\SysinternalsSuite\DelProf2.exe")) {
	Write-Log -Level "FATAL" -logfile $Logfile -Message "$env:ProgramFiles (x86)\SysinternalsSuite\DelProf2.exe needed"
	throw "$env:ProgramFiles (x86)\SysinternalsSuite\DelProf2.exe needed"
}else{
	set-alias sdp2 "$env:ProgramFiles (x86)\SysinternalsSuite\DelProf2.exe"
}
#Start processing CSV file name
Foreach ($objline in $ObjCSV) {
	If ($objline.$csv_migrate -eq "Yes") {
		
		#Get Current user AD Object	
		$userSAM = $objline.$csv_currentSAMAccountName
		$ObjADUser = Get-ADUser -LDAPFilter "(sAMAccountName=$userSAM)" -ErrorAction SilentlyContinue -Properties DisplayName, EmailAddress, homeDirectory, homeDrive, cn, UserPrincipalName 
		$NewSAMAccountName = $objline.$csv_NewSAMAccountName
		$ObjADUserNetID = Get-ADUser -LDAPFilter "(sAMAccountName=$NewSAMAccountName)" -ErrorAction SilentlyContinue
		If ($ObjADUser.Name.Count ) { 
			$strDisplayName = $ObjADUser.DisplayName
			$strSamAccountName = $ObjADUser.SamAccountName
			$strUserPrincipalName = $ObjADUser.UserPrincipalName
			$strSN = $($objline.$csv_LastName)
			Write-Log -Message $("Processing User: " + $objline.$csv_FirstName + " " +  $objline.$csv_LastName)	-logfile $Logfile
			Write-Log -Message $("   Updating Active Directory") -logfile $Logfile -foregroundcolor "gray"
#############Move Variable Setup #########################################################################################################
			#Creates E-Mail Subject
			$strSubject = $($strCompanyName + " Username: " + $strSamAccountName + " Changed to NetID: " + $NewSAMAccountName)
			#Subject for E-Mails to Managers
			$ManagersSubject = $($strCompanyName + "Employee: " + $strDisplayName + "  Username: " + $strSamAccountName + " Changed to NetID: " + $NewSAMAccountName)
			#Creates E-Mail Body
			$strEMailBody = $("<b>" + $strDisplayName + "</b> " + $strCompanyName + " Windows username (<b><font color='red'>" +$strSamAccountName + "</font></b>) has been updated to New ID (<b><font color='green'>" + $NewSAMAccountName + "</font></b>). <br><br>Next time they log-on  please have  them use their <b><font color='blue'>" + $NewSAMAccountName + "</font></b> with their <b><font color='blue'> " + $strCompanyName + " current password</font></b>.<br>The default e-mail address has been changed from: " + $strEMail + " to:<b> " + $NewSAMAccountName + "@" + $domainNameFQDN + "</b> <br> Thank you, <br><img src='" + $strCompanyLogo + "' alt=Support>")
			$strEMailBodyOutofDomain = $("<b>" + $strDisplayName + "</b> " + $strCompanyName + " Windows username (<b><font color='red'>" +$strSamAccountName + "</font></b>) has been updated to (<b><font color='green'>" + $NewSAMAccountName + "</font></b>). <br><br>Next time they log-on please have  them use their <b><font color='blue'>" + $NewSAMAccountName + "</font></b> with their <b><font color='blue'> " + $strCompanyName + " current password</font></b>.<br> <br> Thank you, <br><img src='" + $strCompanyLogo + "' alt=Support>")
#############Move Variable Setup #########################################################################################################
			#Figures out which e-mail to use
			If (!([string]::IsNullOrEmpty($ObjADUser.EmailAddress))) {
				$strEMail = $ObjADUser.EmailAddress
			} Else {
				If (!([string]::IsNullOrEmpty($objline.$csv_EMail))) {
					$strEMail = $objline.$csv_EMail
				}
			}

			#Creates Body of e-mail		
			If (!([string]::IsNullOrEmpty($strEMail)) -And ($strEMail).contains($domainName)) {
				$strBody = $strEMailBody			
			} else {
				$strBody = $strEMailBodyOutofDomain					
			}

			#Update Users Account Info.
				If (!([string]::IsNullOrEmpty($objline.$csv_NewSAMAccountName))) {
					If (!($ObjADUserNetID) -And !([string]::IsNullOrEmpty($($objline.$csv_currentSAMAccountName)))) {				
						#check to see if homeDirectory is used.
						$strHomeDirectroy = (Get-ADUser -identity $($objline.$csv_currentSAMAccountName) -Properties homeDirectory -ErrorAction Ignore).homeDirectory.tostring().ToLower() | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						If (!([string]::IsNullOrEmpty($strHomeDirectroy))) {
							#Update Home Drive
							If ($strHomeDirectroy.contains($objline.$csv_currentSAMAccountName)) {
								Set-ADUser -identity $($objline.$csv_currentSAMAccountName) -HomeDirectory $($HomeDriveShare +  $($objline.$csv_NewSAMAccountName)) -HomeDrive "I:" | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							} else {
								Write-Log -logfile $Logfile -Message ("`t AD Home Drive Value: " + (Get-ADUser -identity $($objline.$csv_currentSAMAccountName) -Properties homeDirectory -ErrorAction Ignore).homeDirectory.tostring() + " " + $LastExitCode) -foregroundcolor "yellow"
							}
							#Verify Change						
							If ((Get-ADUser -identity $($objline.$csv_currentSAMAccountName) -Properties homeDirectory, homeDrive -ErrorAction Ignore).homeDirectory.tostring().ToLower().contains($objline.$csv_NewSAMAccountName)) {
								Write-Log -logfile $Logfile -Message ("`t AD Home Drive changed from: " + $strHomeDirectroy + " to: " + $($HomeDriveShare +  $($objline.$csv_NewSAMAccountName))) -foregroundcolor "green"
							} else {
								Write-Log -logfile $Logfile -Message ("`t AD Home Drive NOT changed from: " + $strHomeDirectroy + " to: " + $($HomeDriveShare +  $($objline.$csv_NewSAMAccountName)) + " " + $LastExitCode) -foregroundcolor "red"
							}
						}
						#Update User UserPrincipalName
						If ((Get-ADUser -identity $($objline.$csv_currentSAMAccountName) -ErrorAction SilentlyContinue -Properties UserPrincipalName).UserPrincipalName -eq $($objline.$csv_currentSAMAccountName + "`@" + $domainNameFQDN)) {
							Set-ADUser -identity $($objline.$csv_currentSAMAccountName) -UserPrincipalName $($objline.$csv_NewSAMAccountName + "`@" + $domainNameFQDN) | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							}
						$objtest = Get-ADUser -LDAPFilter "(sAMAccountName=$NewSAMAccountName)" -ErrorAction SilentlyContinue -Properties UserPrincipalName
						If ($objtest) {
							If ((Get-ADUser -LDAPFilter "(sAMAccountName=$NewSAMAccountName)" -ErrorAction SilentlyContinue -Properties UserPrincipalName ).UserPrincipalName -ne $($($objline.$csv_NewSAMAccountName) + "`@" + $domainNameFQDN)) {
								Set-ADUser -identity $($objline.$csv_NewSAMAccountName) -UserPrincipalName $($($objline.$csv_NewSAMAccountName) + "`@" + $domainNameFQDN) | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							}
						}
						#Verify Change
						If ((Get-ADUser -identity $($objline.$csv_currentSAMAccountName) -ErrorAction SilentlyContinue -Properties UserPrincipalName).UserPrincipalName -eq $($($objline.$csv_NewSAMAccountName) + "`@" + $domainNameFQDN)) {
							Write-Log -logfile $Logfile -Message ("`t UserPrincipalName changed from: " + $($($objline.$csv_currentSAMAccountName) + "`@" + $domainNameFQDN) + " to: " + $($($objline.$csv_NewSAMAccountName) + "`@" + $domainNameFQDN)) -foregroundcolor "green"
						}
						#Update User SamAccountName
						If ((Get-ADUser -identity $($objline.$csv_currentSAMAccountName)).SamAccountName -eq $($objline.$csv_currentSAMAccountName)) {
							Set-ADUser -identity $($objline.$csv_currentSAMAccountName) -SamAccountName $($objline.$csv_NewSAMAccountName) | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						}
						#Verify Change
						If ((Get-ADUser -identity $($objline.$csv_NewSAMAccountName)).SamAccountName -eq $($objline.$csv_NewSAMAccountName)) {
							Write-Log -logfile $Logfile -Message ("`t SamAccountName changed from: " + $($objline.$csv_currentSAMAccountName) + " to: " + $objline.$csv_NewSAMAccountName + ". . . Sending User E-Mail.") -foregroundcolor "green"
							#Send E-Mail about Change to user
							If (!([string]::IsNullOrEmpty($strEMail))) {
								 Send-MailMessage -From $FromSMTP -To $strEMail -Subject $strSubject -Body $strBody -BodyAsHtml  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							}			
							#Sends e-mail to support desk for our records
							Send-MailMessage -From $FromSMTP -To $FromSMTP -Subject $($TicketSubject + $strSubject) -Body $strBody -BodyAsHtml  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						} else {
							continue
						}
						
						$ObjADUser = Get-ADUser -identity $($objline.$csv_NewSAMAccountName) -Properties DisplayName, EmailAddress, homeDirectory, homeDrive, cn, UserPrincipalName
					} else {
					Write-Log -logfile $Logfile -Message ("`t Error New SAMAccountName " + $objline.$csv_NewSAMAccountName + " already exists in Domain " + ($ObjADUserNetID).Name.Count) -foregroundcolor "red" -Level "ERROR"
					continue
					}
				} else {
					Write-Log -logfile $Logfile -Message ("`t Error No New SAMAccountName") -foregroundcolor "red" -Level "ERROR"
					continue
				}
				
			Write-Host ("   Updating Home Drive")	-foregroundcolor "gray"
			#Rename Users Home Drive		
				If (Test-Path $($HomeDriveShare + $objline.$csv_currentSAMAccountName)) {
					
					If ( -Not (Test-Path $($HomeDriveShare + $objline.$csv_NewSAMAccountName))) {
						Rename-Item $($HomeDriveShare + $objline.$csv_currentSAMAccountName) $objline.$csv_NewSAMAccountName | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						Write-Log -logfile $Logfile -Message ("`t Renamed User's Home drive from: " + $($HomeDriveShare + $objline.$csv_currentSAMAccountName) + " to: " +  $($HomeDriveShare + $objline.$csv_NewSAMAccountName)) -foregroundcolor "green"
					} else {
						$A = start-process -wait -passthru -WindowStyle Hidden robocopy  -ArgumentList $(" /MIR " + $HomeDriveShare + $objline.$csv_currentSAMAccountName + " " + $HomeDriveShare + $objline.$csv_NewSAMAccountName + " /XF Thumbs.db /XF desktop.ini /XD WINDOWS /XD Music /XD Pictures /XD $RECYCLE.BIN /COPY:DAT /MIN:1 /R:3 /W:3 /MT:8" )  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						If ($A.ExitCode -eq 0 -Or $A.ExitCode -eq "") {
							Write-Log -logfile $Logfile -Message ("`t`t Synced Home Drive Successfully; Removing old Home Drive") -foregroundcolor "green"
							Remove-Item $($HomeDriveShare + $objline.$csv_currentSAMAccountName) -Force -Recurse | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						}
					}
				}

			#Update Users Last Name if Changed
				If (!([string]::IsNullOrEmpty($objline.$csv_UpdatedLastName))) {
					If ($strDisplayName -ne "" -And $strSN -ne "") {
						If ($ObjADUser.Name -ne $($strDisplayName.replace($strSN,$objline.$csv_UpdatedLastName ))) {
							Write-Log -logfile $Logfile -Message ("`tRenaming User's Display Name to: " + $($strDisplayName.replace($strSN,$objline.$csv_UpdatedLastName )))
							Set-ADUser -identity $($objline.$csv_currentSAMAccountName) -DisplayName $($strDisplayName.replace($strSN,$objline.$csv_UpdatedLastName )) | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							Rename-ADObject -identity $ObjADUser -NewName $($strDisplayName.replace($strSN,$objline.$csv_UpdatedLastName )) | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						}
					}	
					If ($strSN -ne $($objline.$csv_UpdatedLastName) ) {
						Set-ADUser -identity $($objline.$csv_currentSAMAccountName) -Surname $($objline.$csv_UpdatedLastName)  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
					}
					
				}
			#Update Users Manager
				If ((!($objline.$csv_ManagersSAMAccountName)) -And ($objline.$csv_ManagersSAMAccountName -ne "")) {
					Set-ADUser -identity $($objline.$csv_currentSAMAccountName) -Manager $(Get-ADUser -identity $($objline.$csv_ManagersSAMAccountName)) | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
					If ($LASTEXITCODE -eq 0) {
						Write-Log -logfile $Logfile -Message ("`t Updating " + $objline.$csv_currentSAMAccountName + " Manager: " + $(Get-ADUser -identity $($objline.$csv_ManagersSAMAccountName)).DisplayName) -foregroundcolor "green"
						#Send E-Mail about Change to Manager
						If ($(Get-ADUser -identity $($objline.$csv_ManagersSAMAccountName)).EmailAddress -ne "" ) {
							 Send-MailMessage -From $FromSMTP -To $($(Get-ADUser -identity $($objline.$csv_ManagersSAMAccountName)).EmailAddress) -Subject $ManagersSubject -Body $strBody -BodyAsHtml  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						}
					}
				}

			Write-Log -logfile $Logfile -Message ("   Updating Roaming Profile")	-foregroundcolor "gray"
			#Update Users roaming profiles
				Foreach ($strRomingProfile in $RomingProfiles) {
					If (-Not $strRomingProfile.EndsWith("\")) { $strRomingProfile= $($strRomingProfile + "\")}
					If (Test-Path $($strRomingProfile + $objline.$csv_currentSAMAccountName)) {
						Write-Log -logfile $Logfile -Message ("`tBacking up User's Roaming Profile: " + $($strRomingProfile + $objline.$csv_currentSAMAccountName))
						s7zip a -mx9 -sfx"$env:ProgramFiles\7-Zip\7z.sfx" -ssw -bd -t7z -mmt -ms=on  $('"' + $strArchiveHome + $objline.$csv_currentSAMAccountName + "_" + $StrDate + '.exe"') $('"' + $strRomingProfile + $objline.$csv_currentSAMAccountName + '"') | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						If ($LASTEXITCODE -eq 0) {
							Remove-Item $($strRomingProfile + $objline.$csv_currentSAMAccountName) -Force -Recurse  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							Write-Log -logfile $Logfile -Message ("`t`t Removing User's Roaming Profile: " + $($strRomingProfile + $objline.$csv_currentSAMAccountName)) -foregroundcolor "green"
						}
					}
					If (Test-Path $($strRomingProfile + $objline.$csv_currentSAMAccountName + "." + $domainName + ".V2")) {
						Write-Log -logfile $Logfile -Message ("`tBacking up User's Roaming Profile: " + $($strRomingProfile + $objline.$csv_currentSAMAccountName + "." + $domainName + ".V2"))
						s7zip a -mx9 -sfx"$env:ProgramFiles\7-Zip\7z.sfx" -ssw -bd -t7z -mmt -ms=on  $('"' + $strArchiveHome + $objline.$csv_currentSAMAccountName + "_" + $StrDate + '.exe"') $('"' + $strRomingProfile + $objline.$csv_currentSAMAccountName + "." + $domainName + '.V2"') | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						If ($LASTEXITCODE -eq 0) {
							Remove-Item $($strRomingProfile + $objline.$csv_currentSAMAccountName + "." + $domainName + '.V2') -Force -Recurse | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							Write-Log -logfile $Logfile -Message ("`t`t Removing User's Roaming Profile: " + $($strRomingProfile + $objline.$csv_currentSAMAccountName + "." + $domainName + ".V2")) -foregroundcolor "green"
						}
					}
				}
			#Update User e-mail addresses
			Write-Log -logfile $Logfile -Message ("   Updating Exchange")	-foregroundcolor "gray"

				#Update Exchange Alias and E-mail Addresses
				Switch ((Get-User -Identity $ObjADUser.DistinguishedName -ErrorAction SilentlyContinue).RecipientType)
				{
					"UserMailbox" {
						#Change Outgoing Address to new username
						# *** Exchange Policy does this after we change the Alias ***
						#Change Alias
						If ((Get-User -Identity $ObjADUser.DistinguishedName -ErrorAction SilentlyContinue).Alias -ne $($objline.$csv_NewSAMAccountName)) {
							Set-Mailbox -Identity $ObjADUser.DistinguishedName -Alias $objline.$csv_NewSAMAccountName  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							#Verify
							If ($LASTEXITCODE -eq 0) {
								Write-Log -logfile $Logfile -Message ("`t Mailbox Alias changed to: " + $objline.$csv_NewSAMAccountName )  -foregroundcolor "green"
							}
						}	
						# Added New Address
						(!((Get-Mailbox -Identity $ObjADUser.DistinguishedName).EmailAddresses -contains $($objline.$csv_NewSAMAccountName + "@" + $PrimaryEmailDomain)))
						(!((Get-Mailbox -Identity $ObjADUser.DistinguishedName).EmailAddresses -contains $($objline.$csv_currentSAMAccountName + "@" + $PrimaryEmailDomain)))
						
						If ((!((Get-Mailbox -Identity $ObjADUser.DistinguishedName).EmailAddresses -contains $($objline.$csv_NewSAMAccountName + "@" + $PrimaryEmailDomain))) -And (!((Get-Mailbox -Identity $ObjADUser.DistinguishedName).EmailAddresses -contains $($objline.$csv_currentSAMAccountName + "@" + $PrimaryEmailDomain)))) {
							Set-Mailbox -Identity $ObjADUser.DistinguishedName -EmailAddresses @{add=$($objline.$csv_NewSAMAccountName + "@" + $PrimaryEmailDomain),$($objline.$csv_currentSAMAccountName + "@" + $PrimaryEmailDomain)} | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
							#Verify
							If ($LASTEXITCODE -eq 0) {
								Write-Log -logfile $Logfile -Message ("`t Mailbox addresses added: " + $($objline.$csv_NewSAMAccountName + "@" + $PrimaryEmailDomain) + " , " + $($objline.$csv_currentSAMAccountName + "@" + $PrimaryEmailDomain))  -foregroundcolor "green"
							}
						}						
					}
					"MailUser" {
						#Update Alias for People in the GAL
						Set-User -Identity $ObjADUser.DistinguishedName -Alias $objline.$csv_NewSAMAccountName 	 | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
						If ($LASTEXITCODE -eq 0) {
							Write-Log -logfile $Logfile -Message ("`t Updated Defaults Mail User's Alias to: " + $objline.$csv_NewSAMAccountName)  -foregroundcolor "green"
						}
					}
				}

		} Else {
			Write-Log -logfile $Logfile -Message ("No AD User for : " + $objline.$csv_FirstName + " " +  $objline.$csv_LastName + "`t Username: " + $objline.$csv_currentSAMAccountName + " May have been migrated already.")  -foregroundcolor "red"
		}		
	}
}
#Clean Cached profiles on XenApp Servers
	Foreach ($XAServer in $XenAppServers) {
		#Set-up FQDN
		If ($XAServer.Contains($env:USERDNSDOMAIN)) {
			$XAServerFQDN = $XAServer
		} Else {
			$XAServerFQDN = $($XAServer + "." + $env:USERDNSDOMAIN)
		}
		#Run Delprof2
		 sdp2 /u /i /ed:"all users" /ed:default /ed:"default user" /ed:*service /ed:ctx_* /ed:public /ed:*AppPool /ed:*guest* /ed:Anon* /ed:s.* /c:\\$XAServerFQDN  | ? {$_ -ne 0x00} | Tee-Object -FilePath $Logfile -Append 
	
	}
