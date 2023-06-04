# AVD Power Management PowerShell script
A script for power management of your Azure Virtual Desktops based on resource tags to be run as an Azure Automation Runbook.

## Power policies
There are currently 4 different policys you can apply:
- Always: The VM should always be running
- InHours: The VM should be powered on at a specific time, then at the end of the time the server should be drained and powered off once nobody is logged in.
- InUse: The VM should be shutdown when nobody logged on (assumes using Power On Connect feature to turn VM on as required)
- InUseAndHours: The VM should be powered on at a specific time and powered off once nobody is logged in.

## Tags
The script uses the following tags (these can be configured if you don't like them):
- MaintenanceMode: If evaluates to true the server will be skipped.
- PowerOnPolicy: Needs to be set to 1 of the 4 above policies. Assumes "Always" if not set.
- StartTime: What time do you want the server powering on. 
- EndTime: What time do you want the server powering off when possible.
- StartDays: What days of the week do you want to manage the power. Can do ranges and/or comma seperated values. Some examples are "All", "Monday-Friday", "Fri-Sun, Wednesday"

## Permissions required
For this script to work the managed identity for the Azure Automation Runbook needs to have the "Desktop Virtualization Power On Off Contributor" role assigned to it for relevant resources.

## Timezones
Please note that Azure Automation Runbooks use UTC for the time. Either plan your times to work around this or you can set the timezone by ID. To see a list of available timezones open PowerShell locally on your computer and run:
```
Get-TimeZone -ListAvailable
```
You can search this by expanding the command to:
```
Get-TimeZone -ListAvailable | ? {$_.Id.ToLower().Contains('AUS')}
```

## Todo
A couple of things I have in mind are:
- Multithread processing the hosts
- Add support for a timezone tag on hosts so timezone can be set per host