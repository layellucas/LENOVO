﻿$CustomerId = "" # Log Analytics Workspace ID
$SharedKey = '' # Log Analytics Workspace Primary Key
$LogType = "Lenovo_Report" # Custom log to create in lo Analytics
$TimeStampField = "" # let to blank
#*******************************************************************************

# Log analytics functions
# More info there: https://docs.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}

# Create the function to create and post the request
# More info there: https://docs.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode
}

$SerialNumber = $((Get-WmiObject -Class Win32_BIOS).SerialNumber).Trim()
$CurrentOS = $((Get-WmiObject -Class Win32_OperatingSystem).Caption).Trim()

$WMI_computersystem = gwmi win32_computersystem
$Manufacturer = $WMI_computersystem.manufacturer
If($Manufacturer -ne "LENOVO")
	{
		write-output "Poste non Lenovo"	
		EXIT 0	
	}
Else
	{		
		$Get_Current_Model_MTM = ($WMI_computersystem.Model).Substring(0,4)
		$Get_Current_Model_FamilyName = $WMI_computersystem.SystemFamily.split(" ")[1]			
		$Script:currentuser = $WMI_computersystem | select -ExpandProperty username
		$Script:process = get-process logonui -ea silentlycontinue
		If($currentuser -and $process)
			{							
				$Session_Locked = $True
			}
		Else
			{							
				$Session_Locked = $False
			}		
	
		$LZ4_DLL_Path = "$env:TEMP\LZ4.dll"
		$DLL_Download_Success = $False
		If(!(test-path $LZ4_DLL_Path))
			{
				$LZ4_DLL = "https://stagrtdwpprddevices.blob.core.windows.net/biosmgmt/LZ4.dll"
				Try
					{
						Invoke-WebRequest -Uri $LZ4_DLL -OutFile "$LZ4_DLL_Path" -UseBasicParsing	
						$DLL_Download_Success = $True		
					}
				Catch
					{		
						$Script:Script_Status = "Error"
						$Script:BIOS_UpToDate = ""
						$Script:BIOS_New_Version = ""	
						$Script:BIOSDaysOld = 0										
						$Script:Exit_Status = 0
					}	
			}
		Else
			{
				$DLL_Download_Success = $True		
			}

			
		If($DLL_Download_Success -eq $True)
			{
				[System.Reflection.Assembly]::LoadFrom("$LZ4_DLL_Path") | Out-Null

				Function Decode-WithLZ4 ($Content,$originalLength)
				{
					$Bytes =[Convert]::FromBase64String($Content)
					$OutArray = [LZ4.LZ4Codec]::Decode($Bytes,0, $Bytes.Length,$originalLength)
					$rawString  = [System.Text.Encoding]::UTF8.GetString($OutArray)
					return $rawString
				}

				Class Lenovo{
					Static hidden [String]$_vendorName = "Lenovo"
					hidden [Object[]] $_deviceCatalog
					hidden [Object[]] $_deviceImgCatalog  
					
					Lenovo()
					{
						$this._deviceCatalog = [Lenovo]::GetDevicesCatalog()
						$this._deviceImgCatalog = $null
					}

					Static hidden [Object[]] GetDevicesCatalog()
					{
						$result = Invoke-WebRequest -UseBasicParsing -Uri "https://pcsupport.lenovo.com/us/en/api/v4/mse/getAllProducts?productId=" -Headers @{#
						"Accept"="application/json, text/javascript, */*; q=0.01"
						  "Referer"="https://pcsupport.lenovo.com/us/en/"
						  "X-CSRF-Token"="2yukcKMb1CvgPuIK9t04C6"
						  "User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36"
						  "X-Requested-With"="XMLHttpRequest"
                          "ClientId" = "YOURCLIENTID"
						}


						$JSON = ($result.Content | ConvertFrom-Json)
						$rawString = Decode-WithLZ4 -Content $JSON.content -originalLength $JSON.originLength 
						$jsonObject = ($rawString | ConvertFrom-Json)

						return $jsonObject
					}

					[Object[]]FindModel($userInputModel)
					{
						$SearchResultFormatted = @()
						$userSearchResult = $this._deviceCatalog.Where({($_.Name -match $userInputModel) -and ($_.Type -eq "Product.SubSeries")})	
						foreach($obj in $userSearchResult){
							$SearchResultFormatted += [PSCustomObject]@{
								Name=$obj.Name;
								Guid=$obj.ProductGuid;
								Path=$obj.Id;
								Image=$obj.Image
							} 
						}
						return $SearchResultFormatted
					}

					hidden [Object[]] GetModelWebResponse($modelGUID)
					{
						$DownloadURL = "http://supportapi.lenovo.com/V2.5/content?Product=$($modelGUID)&Type=Driver"#						
						$SelectedModelwebReq = Invoke-WebRequest -UseBasicParsing -Uri $DownloadURL -Headers @{
                            "ClientId" = "YOURCLIENTID"
						}
                        $SelectedModelWebResponse = ($SelectedModelwebReq.Content | ConvertFrom-Json)  

                        $ids = ""
                        foreach ($item in $SelectedModelWebResponse) {
                            $ids += "ID="+$item.ID+"&"#
                        }
                        $ids = $ids.Substring(0,$ids.Length-1)# 

                        $DownloadURL2 = "http://supportapi.lenovo.com/V2.5/content?"+$ids#
                        $SelectedDriversReq = Invoke-WebRequest -UseBasicParsing -Uri $DownloadURL2 -Headers @{#
                            "ClientId" = "YOURCLIENTID"
						}
                        $SelectedDriversResponse = ($SelectedDriversReq.Content | ConvertFrom-Json)  #
						return $SelectedDriversResponse
					}

					hidden [Object[]]GetAllSupportedOS($webresponse)
					{
						
						$AllOSKeys = [Array]$webresponse.body.OperatingSystems #
						$operatingSystemObj= $AllOSKeys | Foreach { [PSCustomObject]@{ Name = $_; Value = $_}}

						return $operatingSystemObj
					}
					
					hidden [Object[]]LoadDriversFromWebResponse($webresponse)
					{
						$DownloadItemsRaw = ($webresponse | Select-Object -Property ID,Title,Released,Categories,Files,OperatingSystems)#
						$DownloadItemsObj = [Collections.ArrayList]@()

						ForEach ($item in $DownloadItemsRaw | Where{$_.Title -notmatch "SCCM Package"})
						{
							[Array]$ExeFiles = $item.Files | Where-Object {($_.Type -notmatch "TXT")} 
							$current = [PSCustomObject]@{
								Title=$item.Title;
								Category=$item.Categories;
								OperatingSystems=$item.OperatingSystems;
                                Date=$item.Released;
                                ID=$item.ID;
								
								Files= [Array]($ExeFiles |  ForEach-Object {  
									if($_){
										[PSCustomObject]@{
											IsSelected=$false;
											ID=$_.Url.Split('/')[-1].ToUpper().Split('.')[0];
											Name=$_.Name;
											Size=$_.Size;
											Type=$_.Type;
											Version=$_.Version
											URL=$_.URL;
											Priority=$_.Priority;
											Date=Get-date($item.Released) -format MM/dd/yyyy;
										}
									}
								})										
							}
							$DownloadItemsObj.Add($current) | Out-Null
						}
						return $DownloadItemsObj
					}
				}

				$Model_Found = $False
				$Script:Get_Current_Model_MTM = ((gwmi win32_computersystem).Model).Substring(0,4)
				$Script:Get_Current_Model_FamilyName = (gwmi win32_computersystem).SystemFamily.split(" ")[1]
				
				$BIOS_Version = Get-ciminstance -class win32_bios
				$Current_BIOS_Version = $BIOS_Version.SMBIOSBIOSVersion
				$Current_BIOS_Version_ID = $Current_BIOS_Version.Split("(")[0]				
				
				$BIOS_release_date = (gwmi win32_bios | select *).ReleaseDate								
				$Format_BIOS_release_date = [DateTime]::new((([wmi]"").ConvertToDateTime($BIOS_release_date)).Ticks, 'Local').ToUniversalTime()	

				$Get_Current_Date = get-date
				$Diff_CurrentBIOS_and_Today = $Get_Current_Date - $Format_BIOS_release_date
				$Diff_Today_CurrentBIOS = $Diff_CurrentBIOS_and_Today.Days					
												
				$BIOS_Maj_Version = $BIOS_Version.SystemBiosMajorVersion 
				$BIOS_Min_Version = $BIOS_Version.SystemBiosMinorVersion 
				$Script:Get_Current_BIOS_Version = "$BIOS_Maj_Version.$BIOS_Min_Version"
				$RunspaceScopeVendor = [Lenovo]::new()
				
				$Search_Model = $RunspaceScopeVendor.FindModel("$Get_Current_Model_MTM")
				$Get_GUID = $Search_Model.Guid 
				If($Get_GUID -eq $null)
					{
						$Search_Model = $RunspaceScopeVendor.FindModel("$Get_Current_Model_FamilyName")	
						$Get_GUID = $Search_Model.Guid 		
						If($Get_GUID -eq $null)
							{
								$Script_Status = "Error"
								$BIOS_UpToDate = ""
								$BIOS_New_Version = ""	
								$Get_Converted_BIOS_Date = 0
								$BIOSDaysOld = 0									
								$Exit_Status = 0	
							}		
						Else
							{
								$Model_Found = $True
							}	
					}
				Else
					{
						$Model_Found = $True
					}
									
				If($Model_Found -eq $True)
					{						
						$Get_GUID = $Search_Model.Guid 
						$wbrsp 	= $RunspaceScopeVendor.GetModelWebResponse("$Get_GUID")
						$OSCatalog = $RunspaceScopeVendor.GetAllSupportedOS($wbrsp) 
						$DriversModeldatas 	= $RunspaceScopeVendor.LoadDriversFromWebResponse($wbrsp) 
						$DriversModelDatasForOsType = [Array]($DriversModeldatas | Where-Object {($_.OperatingSystems -contains 'Windows 10 (64-bit)' )} )

						$Get_BIOS_Update = $DriversModelDatasForOsType | Where {($_.Title -like "*BIOS Update*")}
                        #$Get_BIOS_Update = $DownloadItemsObj | Where {($_.Title -like "*BIOS Update*")}
						$BIOS_Update_Title = $Get_BIOS_Update.Title						
						$Get_BIOS_Update = $Get_BIOS_Update.files  | Where {$_.Type -eq "EXE"}
						
						If(($Get_BIOS_Update.Count) -gt 1)
							{
								$Get_BIOS_Update = $Get_BIOS_Update[1]
							}	
						$Get_New_BIOS_Version = $Get_BIOS_Update.version
						$Get_New_BIOS_ID = $Get_BIOS_Update.ID
						If($BIOS_Update_Title -like "*ThinkPad*")
							{
								If($Get_New_BIOS_Version -like "*/*")
									{
										$Get_New_BIOS_Version = $Get_New_BIOS_Version.split("/")[0]									
									}
								$Get_New_BIOS_Date = $Get_BIOS_Update.Date
								$Get_Converted_BIOS_Date = [Datetime]::ParseExact($Get_New_BIOS_Date, 'MM/dd/yyyy', $null)							
								
								$Is_BIOS_NotUptoDate = ($Get_Current_BIOS_Version -lt $Get_New_BIOS_Version)
								If($Is_BIOS_NotUptoDate -eq $null)
									{
										$Script:Script_Status = "Error"
										$Script:BIOS_UpToDate = ""
										$Script:BIOS_New_Version = $Get_New_BIOS_Version	
										$Script:BIOSDaysOld = 0										
										$Script:Exit_Status = 0
									}
								ElseIf($Is_BIOS_NotUptoDate -eq $True)
									{
										$BIOSDaysOld = ($Get_Converted_BIOS_Date - $Format_BIOS_release_date).Days								

										$Script:Script_Status = "Success"															
										$Script:BIOS_UpToDate = "No"
										$Script:BIOS_New_Version = $Get_New_BIOS_Version			
										$Script:Exit_Status = 1		
									}
								Else
									{
										$Script:Script_Status = "Success"							
										$Script:BIOS_UpToDate = "Yes"
										$Script:BIOS_New_Version = $Get_New_BIOS_Version			
										$Script:Exit_Status = 0	
									}							
							}
						Else
							{
								If($Get_New_BIOS_Version -ne $Current_BIOS_Version_ID)
									{
										$Get_New_BIOS_Date = $Get_BIOS_Update.Date
										$Get_Converted_BIOS_Date = [Datetime]::ParseExact($Get_New_BIOS_Date, 'MM/dd/yyyy', $null)	
										If($Get_Converted_BIOS_Date - $Format_BIOS_release_date)
											{
												$BIOSDaysOld = ($Get_Converted_BIOS_Date - $Format_BIOS_release_date).Days								

												$Script:Script_Status = "Success"															
												$Script:BIOS_UpToDate = "No"
												$Script:BIOS_New_Version = $Get_New_BIOS_Version			
												$Script:Exit_Status = 1													
											}
										Else
											{
												$Script:Script_Status = "Success"							
												$Script:BIOS_UpToDate = "Yes"
												$Script:BIOS_New_Version = $Get_New_BIOS_Version			
												$Script:Exit_Status = 0												
											}
									}								
							}


					}	
			}
	}


If($BIOSDaysOld -ge 1 -and $BIOSDaysOld -lt 180)
	{
		$Diff_Delay = "1_180"
	}	
ElseIf($BIOSDaysOld -ge 180 -and $BIOSDaysOld -lt 365)
	{
		$Diff_Delay = "180_365"
	}
ElseIf($BIOSDaysOld -ge 365 -and $BIOSDaysOld -lt 730)
	{
		$Diff_Delay = "365_730"
	}
ElseIf($BIOSDaysOld -ge 730)
	{
		$Diff_Delay = "730_More"
	}		

$Current_User_Profile = Get-ChildItem Registry::\HKEY_USERS | Where-Object { Test-Path "$($_.pspath)\Volatile Environment" } | ForEach-Object { (Get-ItemProperty "$($_.pspath)\Volatile Environment").USERPROFILE }
$Username = $Current_User_Profile.split("\")[2]	

$BIOS_Ver_Model = "$Get_Current_BIOS_Version ($Get_Current_Model_FamilyName)"

$Chassis = (Get-CimInstance -ClassName Win32_SystemEnclosure).ChassisTypes
$Device_Chassis = [string]$chassis
If($Chassis -eq 9 -or $Chassis -eq 10 -or $Chassis -eq 14 -or $Chassis -eq 8 -or $Chassis -eq 11 -or $Chassis -eq 12 -or $Chassis -eq 18 -or $Chassis -eq 21 -or $Chassis -eq 31 -or $Chassis -eq 32) 
	{
		$Chassis_Type = "Laptop"
	}
else 
	{
		$Chassis_Type = "Desktop"
	}
	
$BIOSConfiguration = (Get-WmiObject -Class Lenovo_BiosSetting -Namespace root\wmi | Where-Object { $_.CurrentSetting -ne ""} ).CurrentSetting

#WARRANTY
$WarrantyUrl = "http://supportapi.lenovo.com/V2.5/Warranty?Serial=$($SerialNumber)"
$WarrantyWebReq = Invoke-WebRequest -UseBasicParsing -Uri $WarrantyUrl -Headers @{
    "ClientId" = "YOURCLIENTID"
}
$WarrantyWebResponse = ($WarrantyWebReq.Content | ConvertFrom-Json)
If($WarrantyWebResponse -notlike "*Serial Not Found*") {
    $WarrantyWebResponse.Warranty | where {$_.name -eq "3Y On-site, 9X5"} | foreach {
        $DateWarranty = Get-date($_.End) -format dd-MM-yyyy
        $DateWarrantyYear = Get-date($_.End) -format yyyy

        If((Get-date -format dd-MM-yyyy) -lt $DateWarranty){
            $WarrantyStatus = "Active"
        }
        Else {
           $WarrantyStatus = "Expiree"
        } 
    }
}
Else {
    $WarrantyStatus = "Machine non trouvee"
}

#BATTERY
$CommercialVantage = (Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq "E046963F.LenovoSettingsforEnterprise" })
if ($null -eq $CommercialVantage) {
}
Else {
    $Battery = Get-CimInstance -Namespace root/Lenovo -ClassName Lenovo_Battery -errorAction silentlycontinue
    if ($null -eq $Battery) {
    }
	Else {
		$BatteryHealth = $Battery.BatteryHealth	
	}
	$Odometer = Get-CimInstance -Namespace root/Lenovo -ClassName Lenovo_Odometer -errorAction silentlycontinue
    if ($null -eq $Odometer) {
    }
	Else {
		$BatteryCycles = $Odometer.Battery_Cycles
		$CPU_Uptime =  [math]::Floor($Odometer.CPU_Uptime / 24)
		$Shock_Events =  $Odometer.Shock_Events
		$Thermal_events =  $Odometer.Thermal_events
	}
        
}

#Updates LENOVO
$LenovoUpdates = Get-CimInstance -Namespace root/Lenovo -ClassName Lenovo_Updates -errorAction silentlycontinue
if ($null -eq $LenovoUpdates) {
}
Else{
	$Properties = foreach ($Update in $LenovoUpdates) {
        [PSCustomObject]@{
            Hostname      = $env:COMPUTERNAME
            MTM           = $Get_Current_Model_MTM
            Product       = $WMI_computersystem.SystemFamily
            SerialNumber  = $SerialNumber	
            PackageID     = $Update.PackageID
            Severity      = $Update.Severity
            Status        = $Update.Status
            Title         = $Update.Title
            Version       = $Update.Version
        }
    }
	
	$UpdateStatusJson = $Properties | ConvertTo-Json
        $params1 = @{
            CustomerId = $customerId
            SharedKey  = $sharedKey
            Body       = ([System.Text.Encoding]::UTF8.GetBytes($UpdateStatusJson))
            LogType    = $logType 
        }

        $logResponse1 = Post-LogAnalyticsData @params1
}

#Updates Windows
$PNPSigned_Drivers = gwmi Win32_PnPSignedDriver | where {($_.manufacturer -ne "microsoft") -and ($_.driverprovidername -ne "microsoft") -and`
($_.DeviceName -ne $null)} | select-object @{Label="ComputerName";Expression={$_.PSComputerName}},`
@{Label="ModelFamilyName";Expression={$WMI_computersystem.SystemFamily}},`
@{Label="ModelMTM";Expression={$Get_Current_Model_MTM}},`
@{Label="DriverName";Expression={$_.DeviceName}},DriverVersion,`
@{Label="DriverDate";Expression={$_.ConvertToDateTime($_.DriverDate)}},`
@{Label="WindowsDriverStatus";Expression={"OK"}},`
@{Label="SerialNumber";Expression={$SerialNumber}},`
DeviceClass, DeviceID, manufacturer 

$Drivers_Json = $PNPSigned_Drivers | ConvertTo-Json

$params2 = @{
            CustomerId = $customerId
            SharedKey  = $sharedKey
            Body       = ([System.Text.Encoding]::UTF8.GetBytes($Drivers_Json))
            LogType    = $logType 
        }
$LogResponse2 = Post-LogAnalyticsData @params2	

$LastScanUpdates = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\WOW6432Node\Lenovo\System Update" -Name LastCheckForUpdatesDateTime -errorAction silentlycontinue
if ($null -eq $LastScanUpdates) {
}
Else{
	If((Get-date($LastScanUpdates)) -ge ((Get-date).AddDays(-20))) {
		$LastScanTemps = "OK"
	}
	Else {
		$LastScanTemps = "KO"
	}
	$DateUpdates = (Get-date($LastScanUpdates) -Format yyyy-MM-dd)
}

$se = "HKLM:\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General"
if(test-path -LiteralPath $se){
	$AdminCommandLine = Get-ItemPropertyvalue $se -Name "AdminCommandLine"
}
Else {
    $AdminCommandLine = "NULL"
}

# Creating the object to send to Log Analytics custom logs
$Properties = [Ordered] @{
    "ScriptStatus"            = $Script_Status
    "BIOSUpToDate"            = $BIOS_UpToDate
    "ComputerName"            = $env:computername
    "UserName"                = $username
    "SerialNumber"            = $SerialNumber	
    "CurrentOS"            	  = $CurrentOS		
    "ModelMTM"                = $Get_Current_Model_MTM
    "ModelFamilyName"         = $Get_Current_Model_FamilyName
	"BIOSCurrentVersion"      = $Get_Current_BIOS_Version	
	"BIOSCurrentVersionFull"  = $Current_BIOS_Version
	"BIOSVersionModel"        = $BIOS_Ver_Model	
	"CurrentBIOSDate" 	      = $Format_BIOS_release_date
	"BIOSNewVersion"          = $BIOS_New_Version
	"BIOSNewDate"             = $Get_Converted_BIOS_Date	
	"GetNewBIOSID"            = $Get_New_BIOS_ID		
	"NotUpdatedSince"         = $BIOSDaysOld		
	"DateDiffDelay"           = $Diff_Delay	
	"BIOSDaysOld"             = $BIOSDaysOld	
	"DiffTodayCurrentBIOS"    = $Diff_Today_CurrentBIOS	
	"ChassisDevice"    	      = $Device_Chassis				
	"ChassisType"    		  = $Chassis_Type
	"BIOSConfiguration"		  = $BIOSConfiguration
	"WarrantyDate"			  = $DateWarranty
	"WarrantyYear"			  = $DateWarrantyYear
    "WarrantyStatus"          = $WarrantyStatus
	"BatteryCycles"			  = $BatteryCycles
	"CPU_Uptime"			  =	$CPU_Uptime
	"Shock_Events"			  =	$Shock_Events
	"Thermal_Events"		  =	$Thermal_events
	"BatteryHealth"			  = $BatteryHealth
	"LastScan"			      = $DateUpdates
	"LastScanTemps"			  = $LastScanTemps
	"AdminCommandLine"		  = $AdminCommandLine
}


$BIOSUpdateResult = New-Object -TypeName "PSObject" -Property $Properties

$BIOSUpdateResultJson = $BIOSUpdateResult | ConvertTo-Json
$params = @{
    CustomerId = $customerId
    SharedKey  = $sharedKey
    Body       = ([System.Text.Encoding]::UTF8.GetBytes($BIOSUpdateResultJson))
    LogType    = $LogType 
}
$LogResponse = Post-LogAnalyticsData @params
	
If($Exit_Status -eq 1)
	{
		EXIT 1
	}
Else
	{
		EXIT 0
	}		