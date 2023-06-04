Param(
	[Parameter(Mandatory=$true)] [String] $SubscriptionId,
	[Parameter(Mandatory=$true)] [String] $ResourceGroup,
	[Parameter(Mandatory=$true)] [String] $HostPool,
	[Int] $MinimumUptimeMins = 15,
	[String] $MaintenanceModeTag = "MaintenanceMode",
	[String] $PowerOnPolicyTag = "PowerOnPolicy",
	[String] $StartTimeTag = "StartTime",
	[String] $EndTimeTag = "EndTime",
	[String] $StartDaysTag = "StartDays",
	[String] $TimeZoneID = "UTC"
)

# Import our scoped AZ modules
Import-Module -Name Az.Accounts,Az.Compute,Az.DesktopVirtualization,Az.Resources

# Prep our Global variables
$Global:AzConn = $NULL
$Global:Subscription = $NULL

FUNCTION Connect-AzSubscriptionIdentity
{
	Param(
		[Parameter(Mandatory=$true)] [String] $SubscriptionId
	)

	"Connecting to Azure"
	$Global:AzConn = Connect-AzAccount -Identity
	"Connected, selecting subscription"
	$Global:Subscription = Select-AzSubscription -SubscriptionId $SubscriptionId
	"Ready"
}

FUNCTION Connect-AzSubscriptionServicePrincipal
{
	Param(
		[Parameter(Mandatory=$true)] [String] $SubscriptionId,
		[Parameter(Mandatory=$true)] [String] $CertificateThumbprint,
		[Parameter(Mandatory=$true)] [String] $ApplicationId,
		[Parameter(Mandatory=$true)] [String] $TenantId
	)

	"Connecting to Azure"
	$Global:AzConn = Connect-AzAccount -ServicePrincipal `
		-CertificateThumbprint $CertificateThumbprint `
		-ApplicationId $ApplicationId `
		-TenantId $TenantId
	"Connected, selecting subscription"
	$Global:Subscription = Select-AzSubscription -SubscriptionId $SubscriptionId
	"Ready"
}

FUNCTION Get-AzTagValue
{
	Param(
		[Parameter(Mandatory=$true)] $ResourceTags,
		[Parameter(Mandatory=$true)] [String] $Tag
	)
	
	$TagsDict = $ResourceTags.Properties.TagsProperty
	
	# Azure Tags are case insensitive even though they are stored with their original case so with dictionary keys which are case sensitive we have to do this the hard way
	FOREACH ($Key IN $TagsDict.Keys)
	{
		IF ($Key.ToLower() -eq $Tag.ToLower())
		{
			RETURN $TagsDict[$Key]
		}
	}
	
	RETURN $NULL
}

FUNCTION Get-AzAVDSHMaintenanceMode
{
	Param(
		[Parameter(Mandatory=$true)] $VMTags
	)

	# If we know what the tag is
	IF ($MaintenanceModeTag -ne "")
	{
		$MaintenanceMode = Get-AzTagValue -ResourceTags $VMTags -Tag $MaintenanceModeTag
		
		IF ($MaintenanceMode -ne $NULL)
		{
			$WaysToSayYes = @('yes', 'y', 'true', 't', 'enabled', 'on', '1')
			
			IF ($WaysToSayYes.Contains($MaintenanceMode.ToLower()))
			{
				RETURN $TRUE
			}
		}
	}

	RETURN $FALSE
}

FUNCTION Get-AzAVDSHPowerOnPolicy
{
	Param(
		[Parameter(Mandatory=$true)] $VMTags
	)
	
	$Result = "always"

	# If we know what the tag is
	IF ($PowerOnPolicyTag -ne "")
	{
		$PowerOnPolicy = Get-AzTagValue -ResourceTags $VMTags -Tag $PowerOnPolicyTag
		
		IF ($PowerOnPolicy -ne $NULL)
		{
			$PowerOnPolicies = @('always', 'inhours', 'inuse', 'inuseandhours')
			
			IF ($PowerOnPolicies.Contains($PowerOnPolicy.ToLower()))
			{
				RETURN $PowerOnPolicy.ToLower()
			}
		}
	}

	RETURN $Result
}

FUNCTION Get-AzAVDSHPowerOnTimes
{
	Param(
		[Parameter(Mandatory=$true)] $VMTags
	)
	
	$Result = @{
		'StartTime' = $NULL;
		'EndTime' = $NULL;
		'StartDays' = $NULL;
	}

	IF ($StartTimeTag -ne "" -AND $EndTimeTag -ne "" -AND $StartDaysTag -ne "")
	{
		$Result.StartTime = Get-AzTagValue -ResourceTags $VMTags -Tag $StartTimeTag
		$Result.EndTime = Get-AzTagValue -ResourceTags $VMTags -Tag $EndTimeTag
		$Result.StartDays = Get-AzTagValue -ResourceTags $VMTags -Tag $StartDaysTag
	}

	RETURN $Result
}

# A bit monolithic but this is a general purpose function
FUNCTION Test-InHours
{
	Param(
		[Parameter(Mandatory=$true)] [String] $StartTime,
		[Parameter(Mandatory=$true)] [String] $EndTime,
		[Parameter(Mandatory=$true)] [String] $StartDays,
		[DateTime] $Time = (Get-Date),
		[String] $TimeZoneID = ""
	)

	# Not using [System.DayOfWeek] because names need to be 3 characters long
	enum DaysEnum {
		sun = 0
		mon = 1
		tue = 2
		wed = 3
		thu = 4
		fri = 5
		sat = 6
	}
	
	# Factor in different timezones if required
	IF ($TimeZoneID -ne "")
	{
		$CurrentTZ = Get-TimeZone
		$TargetTZ = Get-TimeZone -id $TimeZoneID
		
		$Adjustment = ($TargetTZ.GetUTCOffset($Time)).TotalHours - ($CurrentTZ.GetUTCOffset($Time)).TotalHours
		
		$Time = $Time.AddHours($Adjustment)
	}

	$TimeTable = @{
		'StartTime' = $StartTime.Trim();
		'EndTime' = $EndTime.Trim();
		'Now' = $Time;
		'Days' = @(
			$FALSE,
			$FALSE,
			$FALSE,
			$FALSE,
			$FALSE,
			$FALSE,
			$FALSE
		)
	}

	# Process StartTime and EndTime
	FOREACH ($Key IN @('StartTime','EndTime'))
	{
		$Value = $TimeTable[$Key]

		# Check length
		IF ($Value.Length -gt 2)
		{
			$HourOffset = 0
			$AntePostMeridiem = $Value.Substring($Value.Length - 2).ToLower()
			$Numbers = $Value -Replace '[^0-9]',''

			# Check if using am/pm
			$ModHours = $FALSE
			IF ($AntePostMeridiem -eq 'am' -OR $AntePostMeridiem -eq 'pm')
			{
				$ModHours = $TRUE
				IF ($AntePostMeridiem -eq 'pm') { $HourOffset = 12 }
			}

			# Pad numbers for processing
			IF ($Numbers.Length -le 2) { $Numbers = $Numbers + "00" }
			$Numbers = $Numbers.PadLeft(4,'0')

			# Break into hours and minutes
			$Hours = [int]($Numbers.substring(0,2))
			$Minutes = [int]($Numbers.substring(2))

			# Factor in if using am/pm
			IF ($ModHours -eq $TRUE) { $Hours = ($Hours % 12) + $HourOffset }

			# Don't accept hours or minutes being out of bounds
			IF ($Hours -ge 24 -OR $Minutes -ge 60)
			{
				Throw (New-Object System.Exception("Test-InHours $($Key) value out of bounds"))
			}

			# Save our value as a DateTime object
			$Value = Get-Date -Hour $Hours -Minute $Minutes -Second 0 -Millisecond 0
		}
		ELSE
		{
			Throw (New-Object System.Exception("Test-InHours $($Key) too short"))
		}

		$TimeTable[$Key] = $Value
	}

	# Process our StartDays
	$DaysArray = $StartDays.ToLower().Split(',')
	FOR ($i = 0; $i -lt $DaysArray.Count; $i++)
	{
		$Day = $DaysArray[$i].Trim()

		IF ($Day -eq 'all' -OR $Day -eq '*')
		{
			$TimeTable['Days'] = @(
				$TRUE,
				$TRUE,
				$TRUE,
				$TRUE,
				$TRUE,
				$TRUE,
				$TRUE
			)
		}
		ELSE
		{
			$Day = $Day.Split('-')

			IF ($Day.Count -le 2)
			{
				$DayRange = @(-1, -1)

				FOR ($j = 0; $j -lt $Day.Count; $j++)
				{
					$Day[$j] = $Day[$j].Trim()

					# Must be 3 characters long for string
					IF ($Day[$j].Length -ge 3)
					{
						$CurrentDay = $Day[$j].SubString(0,3)
						$CurrentDay = [DaysEnum]::$CurrentDay

						IF ($CurrentDay -ne $NULL)
						{
							$DayRange[$j] = $CurrentDay.value__
						}
						ELSE
						{
							Throw (New-Object System.Exception("Test-InHours error with day (invalid text)"))
						}
					}
					# Must be 1 character long for integer
					ELSEIF ($Day[$j].Length -eq 1)
					{
						# Validate with regex
						IF ($Day[$j] -eq ($Day[$j] -Replace '[^0-6]',''))
						{
							$DayRange[$j] = [int]($Day[$j])
						}
						ELSE
						{
							Throw (New-Object System.Exception("Test-InHours error with day (invalid number)"))
						}
					}
					ELSE
					{
						Throw (New-Object System.Exception("Test-InHours error with day (invalid length)"))
					}
				}

				# If we only had 1 number
				IF ($DayRange[1] -eq -1)
					{ $DayRange[1] = $DayRange[0] }
				# If we wrap around
				ELSEIF ($DayRange[1] -lt $DayRange[0])
					{ $DayRange[1] = $DayRange[1] + 7 }

				# Update each day in our range
				FOR ($j = $DayRange[0]; $j -le $DayRange[1]; $j++)
				{
					$TimeTable.Days[($j % 7)] = $TRUE
				}
			}
			ELSE
			{
				Throw (New-Object System.Exception("Test-InHours error with day (too many hyphens)"))
			}
		}
	}

	$InsideWindow = $FALSE
	$TimeValue = (New-TimeSpan -Start $TimeTable.StartTime -End $TimeTable.Now).TotalSeconds

	# In the case timespan is same day
	IF ($TimeTable.EndTime -gt $TimeTable.StartTime)
	{
		$TimeWindow = (New-TimeSpan -Start $TimeTable.StartTime -End $TimeTable.EndTime).TotalSeconds

		IF ($TimeValue -gt 0 -AND $TimeValue -lt $TimeWindow)
		{
			$CheckStartDay = $TimeTable['Now'].DayOfWeek.ToString().SubString(0,3)
			$CheckStartDay = ([DaysEnum]::$CheckStartDay).Value__

			IF ($TimeTable.Days[$CheckStartDay] -eq $TRUE) { $InsideWindow = $TRUE }
		}
	}
	# In the case the timespan crosses over midnight
	ELSEIF ($TimeTable.EndTime -lt $TimeTable.StartTime)
	{
		# In the case of the timespan that started today
		IF ($TimeValue -gt 0)
		{
			$TimeWindow = (New-TimeSpan -Start $TimeTable.StartTime -End ($TimeTable.EndTime).AddDays(1)).TotalSeconds

			IF ($TimeValue -gt 0 -AND $TimeValue -lt $TimeWindow)
			{
				$CheckStartDay = $TimeTable['Now'].DayOfWeek.ToString().SubString(0,3)
				$CheckStartDay = ([DaysEnum]::$CheckStartDay).Value__

				IF ($TimeTable.Days[$CheckStartDay] -eq $TRUE) { $InsideWindow = $TRUE }
			}
		}
		# In the case of the timespan that started yesterday
		ELSEIF ($TimeValue -lt 0)
		{
			$TimeWindow = (New-TimeSpan -Start $TimeTable.StartTime.AddDays(-1) -End $TimeTable.EndTime).TotalSeconds
			$TimeValue = (New-TimeSpan -Start $TimeTable.StartTime.AddDays(-1) -End $TimeTable.Now).TotalSeconds

			IF ($TimeValue -gt 0 -AND $TimeValue -lt $TimeWindow)
			{
				$CheckStartDay = $TimeTable['Now'].AddDays(-1).DayOfWeek.ToString().SubString(0,3)
				$CheckStartDay = ([DaysEnum]::$CheckStartDay).Value__

				IF ($TimeTable.Days[$CheckStartDay] -eq $TRUE) { $InsideWindow = $TRUE }
			}
		}
		# In the case it is exactly our start time
		ELSE
		{
			$CheckStartDay = $TimeTable['Now'].DayOfWeek.ToString().SubString(0,3)
			$CheckStartDay = ([DaysEnum]::$CheckStartDay).Value__

			IF ($TimeTable.Days[$CheckStartDay] -eq $TRUE) { $InsideWindow = $TRUE }
		}
	}
	ELSE
	{
		Throw (New-Object System.Exception("Test-InHours StartTime and EndTime are the same"))
	}

	RETURN $InsideWindow
}

FUNCTION Get-AzAVDSHState
{
	Param(
		[Parameter(Mandatory=$true)] $VM
	)

	# Prep result
	$Result = @{
		'Uptime' = -1;
		'UsersLoggedIn' = $TRUE;
	}

	# Commands to run on VM
	$Script = @(
		"(New-Timespan -Start (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime -End (Get-Date)).TotalMinutes",
		"start-process -filepath `"query.exe`" -ArgumentList `"user`" -NoNewWindow -wait -RedirectStandardOutput .\query.log",
		"Get-Content .\query.log -Raw"
	)

	# Bundle commands into string
	$ScriptString = [String]::Join(';',$Script)
	
	# Run query
	"[$($VM.name)] - Running script on host"
	$VMquery = ($VM | Invoke-AzVMRunCommand  -CommandId 'RunPowerShellScript' -ScriptString $ScriptString)
	$VMmessages = $VMquery.value.message.split("`n")

	# Read uptime
	$Result['Uptime'] = [Double]::Parse($VMmessages[0])
	"[$($VM.name)] - Uptime is $($Result['Uptime']) minutes"
	
	# Read if users logged in
	IF ($VMmessages.count -eq 2 -AND $VMmessages[1].trim() -eq "No User exists for *")
	{
		"[$($VM.name)] - No users logged in"
		$Result['UsersLoggedIn'] = $FALSE
	}
	ELSE
	{
		"[$($VM.name)] - Users logged in"
	}
	
	RETURN $Result
}

FUNCTION Update-AzAVDVMState
{
	Param(
		[Parameter(Mandatory=$true)] $VM,
		[Parameter(Mandatory=$true)] $AVDSessionHostID,
		[Parameter(Mandatory=$true)] [String] $PowerOnPolicy,
		[Parameter(Mandatory=$true)] [Boolean] $InHours
	)

	IF ($PowerOnPolicy -eq 'always')
	{
		Update-AzAVDVMStateAlways -VM $VM -AVDSessionHostID $AVDSessionHostID -InHours $InHours
	}
	ELSEIF ($PowerOnPolicy -eq 'inhours')
	{
		Update-AzAVDVMStateInHours -VM $VM -AVDSessionHostID $AVDSessionHostID -InHours $InHours
	}
	ELSEIF ($PowerOnPolicy -eq 'inuse')
	{
		Update-AzAVDVMStateInUse -VM $VM -AVDSessionHostID $AVDSessionHostID -InHours $InHours
	}
	ELSEIF ($PowerOnPolicy -eq 'inuseandhours')
	{
		Update-AzAVDVMStateInUseAndHours -VM $VM -AVDSessionHostID $AVDSessionHostID -InHours $InHours
	}
}

FUNCTION Update-AzAVDVMStateAlways
{
	Param(
		[Parameter(Mandatory=$true)] $VM,
		[Parameter(Mandatory=$true)] $AVDSessionHostID,
		[Parameter(Mandatory=$true)] [Boolean] $InHours
	)
	
	"[$($VM.name)] - Processing with power policy: Always On"

	IF ($VM.PowerState -eq "VM deallocated")
	{
		"[$($VM.name)] - Deallocated, now starting"
		$VMStart = ($VM | Start-AzVM)
		"[$($VM.name)] - Start status: $($VMStart.status)"
	}
	ELSEIF ($VM.PowerState -eq "VM stopped")
	{
		"[$($VM.name)] - Stopped, now starting"
		$VMStart = ($VM | Start-AzVM)
		"[$($VM.name)] - Start status: $($VMStart.status)"
	}
	ELSEIF ($VM.PowerState -eq "VM running")
	{
		$VMState = Get-AzAVDSHState -VM $VM

		"[$($VM.name)] - Running, been up $($VMState.Uptime) minutes"
	}
	ELSE
	{
		"[$($VM.name)] - Unknown state"
	}

	Update-AzWvdSessionHost -InputObject $AVDSessionHostID -AllowNewSession:$true | Out-Null
	"[$($VM.name)] - Ensured draining off"

}

FUNCTION Update-AzAVDVMStateInHours
{
	Param(
		[Parameter(Mandatory=$true)] $VM,
		[Parameter(Mandatory=$true)] $AVDSessionHostID,
		[Parameter(Mandatory=$true)] [Boolean] $InHours
	)
	
	"[$($VM.name)] - Processing with power policy: During work hours"
	
	IF ($InHours)
	{
		"[$($VM.name)] - Session host is in work hours"

		IF ($VM.PowerState -eq "VM deallocated")
		{
			"[$($VM.name)] - Deallocated, now starting"
			$VMStart = ($VM | Start-AzVM)
			"[$($VM.name)] - Start status: $($VMStart.Status)"
		}
		ELSEIF ($VM.PowerState -eq "VM stopped")
		{
			"[$($VM.name)] - Stopped, now starting"
			$VMStart = ($VM | Start-AzVM)
			"[$($VM.name)] - Start status: $($VMStart.Status)"
		}
		ELSEIF ($VM.PowerState -eq "VM running")
		{
			$VMState = Get-AzAVDSHState -VM $VM

			"[$($VM.name)] - Running, been up $($VMState.Uptime) minutes"
		}
		ELSE
		{
			"[$($VM.name)] - Unknown state"
		}

		Update-AzWvdSessionHost -InputObject $AVDSessionHostID -AllowNewSession:$true | Out-Null
		"[$($VM.name)] - Ensured draining off"

	}
	ELSE
	{
		"[$($VM.name)] - Session host is out of work hours"
		
		Update-AzWvdSessionHost -InputObject $AVDSessionHostID -AllowNewSession:$false | Out-Null
		"[$($VM.name)] - Ensured draining on"

		IF ($VM.PowerState -eq "VM deallocated")
		{
			"[$($VM.name)] - Deallocated"
		}
		ELSEIF ($VM.PowerState -eq "VM stopped")
		{
			"[$($VM.name)] - Stopped, deallocating"
			$VMDealloc = ($VM | Stop-AzVM -Force)
			"[$($VM.name)] - Deallocation status: $($VMDealloc.Status)"
		}
		ELSEIF ($VM.PowerState -eq "VM running")
		{
			$VMState = Get-AzAVDSHState -VM $VM
			
			"[$($VM.name)] - Running, been up $($VMState.Uptime) minutes"
			
			IF ($VMState.Uptime -ge $MinimumUptimeMins)
			{
				IF ($VMState.UsersLoggedIn)
				{
					"[$($VM.name)] - Users logged in"
				}
				ELSE
				{
					"[$($VM.name)] - No users logged in, shutting down and deallocating"
					$VMDealloc = ($VM | Stop-AzVM -Force)
					"[$($VM.name)] - Deallocation status: $($VMDealloc.Status)"
				}
			}
			ELSE
			{
				"[$($VM.name)] - Skipping as has not been up $($MinimumUptimeMins) minutes yet"
			}
		}
		ELSE
		{
			"[$($VM.name)] - Unknown state"
		}
	}
}

FUNCTION Update-AzAVDVMStateInUse
{
	Param(
		[Parameter(Mandatory=$true)] $VM,
		[Parameter(Mandatory=$true)] $AVDSessionHostID,
		[Parameter(Mandatory=$true)] [Boolean] $InHours
	)
	
	"[$($VM.name)] - Processing with power policy: When users logged on"

	IF ($VM.PowerState -eq "VM deallocated")
	{
		"[$($VM.name)] - Deallocated"
	}
	ELSEIF ($VM.PowerState -eq "VM stopped")
	{
		"[$($VM.name)] - Stopped, deallocating"
		$VMDealloc = ($VM | Stop-AzVM -Force)
		"[$($VM.name)] - Deallocation status: $($VMDealloc.Status)"
	}
	ELSEIF ($VM.PowerState -eq "VM running")
	{
		$VMState = Get-AzAVDSHState -VM $VM
		
		"[$($VM.name)] - Running, been up $($VMState.Uptime) minutes"
		
		IF ($VMState.Uptime -ge $MinimumUptimeMins)
		{
			IF ($VMState.UsersLoggedIn)
			{
				"[$($VM.name)] - Users logged in"
			}
			ELSE
			{
				"[$($VM.name)] - No users logged in"

				Update-AzWvdSessionHost -InputObject $AVDSessionHostID -AllowNewSession:$false | Out-Null
				"[$($VM.name)] - Temporarily draining"

				"[$($VM.name)] - Shutting down and deallocating"
				$VMDealloc = ($VM | Stop-AzVM -Force)
				"[$($VM.name)] - Deallocation status: $($VMDealloc.Status)"
			}
		}
		ELSE
		{
			"[$($VM.name)] - Skipping as has not been up $($MinimumUptimeMins) minutes yet"
		}
	}
	ELSE
	{
		"[$($VM.name)] - Unknown state"
	}
	
	Update-AzWvdSessionHost -InputObject $AVDSessionHostID -AllowNewSession:$true | Out-Null
	"[$($VM.name)] - Ensured draining off"
}

FUNCTION Update-AzAVDVMStateInUseAndHours
{
	Param(
		[Parameter(Mandatory=$true)] $VM,
		[Parameter(Mandatory=$true)] $AVDSessionHostID,
		[Parameter(Mandatory=$true)] [Boolean] $InHours
	)
	
	"[$($VM.name)] - Processing with power policy: During work hours or when users logged on"

	IF ($InHours)
	{
		"[$($VM.name)] - Session host is in work hours"

		IF ($VM.PowerState -eq "VM deallocated")
		{
			"[$($VM.name)] - Deallocated, now starting"
			$VMStart = ($VM | Start-AzVM)
			"[$($VM.name)] - Start status: $($VMStart.Status)"
		}
		ELSEIF ($VM.PowerState -eq "VM stopped")
		{
			"[$($VM.name)] - Stopped, now starting"
			$VMStart = ($VM | Start-AzVM)
			"[$($VM.name)] - Start status: $($VMStart.Status)"
		}
		ELSEIF ($VM.PowerState -eq "VM running")
		{
			$VMState = Get-AzAVDSHState -VM $VM

			"[$($VM.name)] - Running, been up $($VMState.Uptime) minutes"
		}
		ELSE
		{
			"[$($VM.name)] - Unknown state"
		}

	}
	ELSE
	{
		"[$($VM.name)] - Session host is out of work hours"

		IF ($VM.PowerState -eq "VM deallocated")
		{
			"[$($VM.name)] - Deallocated"
		}
		ELSEIF ($VM.PowerState -eq "VM stopped")
		{
			"[$($VM.name)] - Stopped, deallocating"
			$VMDealloc = ($VM | Stop-AzVM -Force)
			"[$($VM.name)] - Deallocation status: $($VMDealloc.Status)"
		}
		ELSEIF ($VM.PowerState -eq "VM running")
		{
			$VMState = Get-AzAVDSHState -VM $VM
			
			"[$($VM.name)] - Running, been up $($VMState.Uptime) minutes"
			
			IF ($VMState.Uptime -ge $MinimumUptimeMins)
			{
				IF ($VMState.UsersLoggedIn)
				{
					"[$($VM.name)] - Users logged in"
				}
				ELSE
				{
					"[$($VM.name)] - No users logged in"

					Update-AzWvdSessionHost -InputObject $AVDSessionHostID -AllowNewSession:$false | Out-Null
					"[$($VM.name)] - Temporarily draining"

					"[$($VM.name)] - Shutting down and deallocating"
					$VMDealloc = ($VM | Stop-AzVM -Force)
					"[$($VM.name)] - Deallocation status: $($VMDealloc.Status)"
				}
			}
			ELSE
			{
				"[$($VM.name)] - Skipping as has not been up $($MinimumUptimeMins) minutes yet"
			}
		}
		ELSE
		{
			"[$($VM.name)] - Unknown state"
		}
	}
	
	Update-AzWvdSessionHost -InputObject $AVDSessionHostID -AllowNewSession:$true | Out-Null
	
	"[$($VM.name)] - Ensured draining off"
}

FUNCTION Main
{
	Param(
		[Parameter(Mandatory=$true)] [String] $SubscriptionId,
		[Parameter(Mandatory=$true)] [String] $ResourceGroup,
		[Parameter(Mandatory=$true)] [String] $HostPool,
		[Parameter(Mandatory=$true)] [Int] $MinimumUptimeMins,
		[String] $MaintenanceModeTag = "",
		[String] $PowerOnPolicyTag = "",
		[String] $StartTimeTag = "",
		[String] $EndTimeTag = "",
		[String] $StartDaysTag = "",
		[String] $TimeZoneID = ""
	)
	
	# Connect to Azure Powershell
	Connect-AzSubscriptionIdentity -SubscriptionId $SubscriptionId
	
	"Getting AVD Hosts"
	$AVDSessionHosts = Get-AzWvdSessionHost -HostPoolName $HostPool -ResourceGroupName $ResourceGroup

	"Host Count: $($AVDSessionHosts.count)"
	
	# For each host
	FOREACH ($AVDSessionHost in $AVDSessionHosts)
	{
		# Get our VM
		$VM = Get-AZVM -ResourceId $AVDSessionHost.VirtualMachineId -Status
		
		"[$($VM.name)] - $($VM.PowerState)"
		
		# Get our VM's tags
		$VMTags = Get-AzTag -ResourceId $VM.Id
		
		# Check if session host is in Maintenance Mode
		IF ((Get-AzAVDSHMaintenanceMode -VMTags $VMTags) -ne $TRUE)
		{
			# Get our power schedule information if available
			$PowerOnPolicy = Get-AzAVDSHPowerOnPolicy -VMTags $VMTags
			$PowerOnTimes = Get-AzAVDSHPowerOnTimes -VMTags $VMTags

			# Try process whether we are in hours or not, assuming that we are
			$InHours = $TRUE
			TRY
			{
				IF ($PowerOnTimes.StartDays -ne $NULL -AND $PowerOnTimes.StartTime -ne $NULL -AND $PowerOnTimes.EndTime -ne $NULL)
				{
					$InHours = Test-InHours -StartDays $PowerOnTimes.StartDays -StartTime $PowerOnTimes.StartTime -EndTime $PowerOnTimes.EndTime -TimeZoneID $TimeZoneID
				}
			}
			CATCH
			{
				"[$($VM.name)] - $($_.Exception)"
			}
			
			# Work around for
			# Update-AzWvdSessionHost needs '/subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.DesktopVirtualization/hostPools/{hostPoolName}/sessionHosts/{sessionHostName}'
			# Get-AzWvdSessionHost gives '/subscriptions/{subscriptionId}/resourcegroups/{resourceGroupName}/providers/Microsoft.DesktopVirtualization/hostpools/{hostPoolName}/sessionhosts/{sessionHostName}'
			$AVDName = $AVDSessionHost.Name.Split('/')
			$AVDObjectID = "/subscriptions/$($SubscriptionId)/resourceGroups/$($ResourceGroup)/providers/Microsoft.DesktopVirtualization/hostPools/$($AVDName[0])/sessionHosts/$($AVDName[1])"

			# Update the power state based on Power On Policy 
			Update-AzAVDVMState -VM $VM -AVDSessionHostID $AVDObjectID -InHours $InHours -PowerOnPolicy $PowerOnPolicy
		}
		ELSE
		{
			# Skip if it is
			"[$($VM.name)] - Maintenance mode tag evaluates to TRUE"
		}
	}
}

TRY
{
	Main `
		-ResourceGroup $ResourceGroup `
		-SubscriptionId $SubscriptionId `
		-HostPool $HostPool `
		-MinimumUptimeMins $MinimumUptimeMins `
		-MaintenanceModeTag $MaintenanceModeTag `
		-PowerOnPolicyTag $PowerOnPolicyTag `
		-StartTimeTag $StartTimeTag `
		-EndTimeTag $EndTimeTag `
		-StartDaysTag $StartDaysTag `
		-TimeZoneID $TimeZoneID
}
CATCH
{
	"$($_.Exception)"
	throw $_.Exception
}