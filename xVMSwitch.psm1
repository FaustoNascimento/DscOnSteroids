enum Ensure
{
    Absent
    Present
}

enum SwitchType
{
    External
    Internal
    Private
}

enum MinimumBandwidthMode
{
    None
    Default
    Weight
    Absolute
}

enum AllowDisruptiveAction
{
    Never
    IfNeeeded
    OnlyIfUnused
}

enum ConfigurationMode
{
    ApplyOnly
    ApplyAndMonitor
    ApplyAndAutoCorrect
}

enum TrackingMethod
{
    Guid
    Name
}

# TODO
# Localized Data
# Probably changing remaining boolean properties to [Nullable[Boolean]]
# TIDY UP CODE!!
[DscResource()]
class xVMSwitch
{
    [DscProperty(Key)]
    [ValidateNotNullOrEmpty()]
    [System.String]$Name
    
    [DscProperty()]
    [Ensure]$Ensure = [Ensure]::Present
    
    [DscProperty()]
    [SwitchType]$SwitchType
    
    [DscProperty()]
    [ValidateNotNullOrEmpty()]
    [System.String]$NetAdapterName
    
    [DscProperty()]
    [System.Nullable[System.Boolean]]$AllowManagementOS
    
    [DscProperty()]
    [System.Boolean]$IovEnabled
    
    [DscProperty()]
    [MinimumBandwidthMode]$MinimumBandwidthMode
    
    [DscProperty()]
    [ValidateNotNullOrEmpty()]
    [System.String]$Notes
    
    [DscProperty()]
    [System.Int64]$DefaultFlowMinimumBandwidthAbsolute
    
    [DscProperty()]
    [System.Int64]$DefaultFlowMinimumBandwidthWeight
    
    [DscProperty()]
    [AllowDisruptiveAction]$AllowDisruptiveAction = 'OnlyIfUnused'
    
    [DscProperty()]
    [System.Boolean]$AllowNameDrift
    
    [DscProperty()]
    [TrackingMethod]$TrackingMethod = 'Guid'
    
    [DscProperty(NotConfigurable)]
    [System.String]$SwitchUniqueId
    
    [DscProperty(NotConfigurable)]
    [System.UInt32]$ReferencedVMs
    
    [DscProperty()]
    [ConfigurationMode]$ConfigurationMode
    
    [DscProperty()]
    [System.UInt32]$ConfigurationModeFrequencyMins
    
    # 'Private' (aka hidden) fields follow camel case notation and declared as hidden
    hidden [System.Boolean] $hasRun
    hidden [System.DateTime] $lastExecution
    hidden [System.DateTime] $startExecution
    hidden [System.String[]] $setOperations
    hidden [System.String] $actualName
    hidden [System.String] $configFile
    hidden [System.Management.Automation.PSObject] $localizedData # Not implemented
    
    xVMSwitch()
    {
        # Get start time
        $this.startExecution = [DateTime]::Now
        
        # Attempt to load localized data, if it fails, it will use the default localized data hardcoded on the script
        Import-LocalizedData -BindingVariable $script:LocalizedData -ErrorAction Ignore # Not implemented
    }
    
    [xVMSwitch] Get()
    {
        $configuration = $this.GetConfiguration()
        
        foreach ($variableName in ($configuration | Get-Member -MemberType NoteProperty).Name)
        {
            $this.$variableName = $configuration.$variableName
        }
        
        return this;
    }
    
    [System.Boolean] Test()
    {
        Write-Verbose "Starting Test()"
        # ValidateParameters() doesn't have a return value. If the validation fails it throws a terminating error 
        # and we simply don't catch it, so it gets thrown back to the caller (LCM in this case)
        $this.ValidateParameters()
        
        $this.LoadConfiguration()
        
        # If it should not run, return $true so LCM does not call Set().
        if (-not $this.ShouldRun())
        {
            return $true
        }
        
        $this.setOperations = $this.TestConfiguration()

        $this.SaveConfiguration('Test')
        
        # Set to apply and monitor, not apply and correct so don't do anything else now.
        if ($this.ConfigurationMode -eq [ConfigurationMode]::ApplyAndMonitor)
        {
            Write-Verbose "Set to ApplyAndMonitor so will prevent Set() from being called."
            return $true
        }
        
        return (-not $this.setOperations)
    }
    
    [void] Set()
    {
        Write-Verbose "Starting Set()"
        $this.LoadConfiguration()
        
        foreach ($setOperation in $this.setOperations)
        {
            Write-Verbose "Processing operationg $setOperation"
            switch -regex ($setOperation)
            {
                '^(Delete|Create|Rename)Object$' { $this.$setOperation(); break }
                '^Set'                           { $this.SetObjectProperty($setOperation, 'Set') }
            }
        }
        
        # Even though calling SetObjectProperty() once per SetProperty is slower and more taxing, it does give much greater flexibility.
        # You can find more information regarding my choice and why it provides more flexibility on www.faustonascimento.com
        
        $this.SaveConfiguration('Set')
    }
    
    [void] SetObjectProperty([System.String]$operationName, [System.String]$keyword)
    {
        $propertyName = $operationName.SubString($keyword.Length)
        Write-Verbose "Preparing to set property $propertyName"
        
        $cmdletParameters = @{ $propertyName = $this.$propertyName }
        Set-VMSwitch -Name $($this.actualName) -ErrorAction Stop @cmdletParameters
    }
    
    [void] RenameObject()
    {
        Write-Verbose "Renaming switch $($this.actualName) to $($this.Name)"
        Rename-VMSwitch -Name $this.actualName -NewName $this.Name -ErrorAction Stop
    }
    
    [void] DeleteObject()
    {
        Write-Verbose "Deelting object with name $($this.actualName)"
        Remove-VMSwitch -Name $this.actualName -ErrorAction Stop
    }
    
    [void] CreateObject()
    {
        Write-Verbose "Preparing to create switch with name $($this.parameterName)"
        $cmdletParameters = @{ }
        
        # List of potential parameters that can be passed to New-VMSwitch
        $propertyNames = @('SwitchType', 'NetAdapterName', 'AllowManagementOS', 'MinimumBandwidthMode', 'Notes')
        
        foreach ($propertyName in $propertyNames)
        {
            if ($this.$propertyName)
            {
                Write-Verbose "Adding parameter $propertyName to list of parameters to splat"
                $cmdletParameters.$propertyName = $this.$propertyName
            }
        }
        
        New-VMSwitch -Name $($this.Name) -ErrorAction Stop @cmdletParameters
    }
    
    # Very simple function that confirms if the configuration for this resource should be run
    # Has *nothing* specific to this particular resource, can be easily exported to other modules so long as the variables it relies on exist
    [System.Boolean] ShouldRun()
    {
        Write-Verbose "Determinating if Test() should continue based on ConfigurationMode and ConfigurationModeFrequencyMins values"
        
        # If set to only ApplyOnce and already ran, exit
        if ($this.ConfigurationMode -eq [ConfigurationMode]::ApplyOnly -and $this.hasRun)
        {
            Write-Verbose "Set to apply only (apply once) but have already run this configuration item, will not continue"
            return $false
        }
        
        # If the ConfigurationModeFrequencyMins is higher than 0 and there is a lastExecution (i.e., not running for first time)
        # And the amount of minutes since it last ran is lower than how often is can run, return false
        if ($this.ConfigurationModeFrequencyMins -and $this.lastExecution -and ([int] ($this.startExecution - $this.lastRunTime).TotalMinutes) -lt $this.ConfigurationModeFrequencyMins)
        {
            Write-Verbose "Set to only run once every $($this.ConfigurationModeFrequencyMins) minutes, but last ran $([int] ($this.startExecution - $this.lastRunTime).TotalMinutes) minutes ago, will not continue"
            return $false
        }
        
        Write-Verbose "Configuration should proceed, continuing with it"
        return $true
    }
    
    # I find that failing on the very first parameter that is invalid is counter intuitive.
    # If the caller had 10 parameters and all were wrong, it would take 10 tries to fix it as only one error would be output per call
    # So I think it is better to perform *all* parameter validations. These tests have no impact on how long it takes to run or CPU load
    [void] ValidateParameters()
    {
        Write-Verbose "Validating Parameters"
        $results = @()

        if ($this.SwitchType -and $this.SwitchType -ne [SwitchType]::External)
        {
            if ($this.NetAdapterName)
            {
                $results += 'NetAdapterName can only be set on External switch types.'
            }
            
            if ($this.AllowManagementOS)
            {
                $results += 'AllowManagementOS can only be set on External switch types.'
            }
            
            if ($this.IovEnabled)
            {
                $results += 'IovEnabled can only be set on External switch types.'
            }
        }
        else #If SwitchType -eq 'External' -or -not SwitchType
        {
            if (-not $this.NetAdapterName)
            {
                $results += 'For external switch type, NetAdapterName must be specified.'
            }
            else
            {
                $netAdapter = Get-NetAdapter -Name $this.NetAdapterName -ErrorAction SilentlyContinue
                
                if (!$netAdapter)
                {
                    $results += "No network adapter with name $this.NetAdapterName exists."
                }
            }
        }
        
        # Weird if statement, but the only way I could find at 5am to ensure that the property MinmumBandwidthMode remains an optional field
        if (-not $this.MinimumBandwidthMode -and $this.MinimumBandwidthMode -ne [MinimumBandwidthMode]::Absolute -and $this.MinimumBandwidthMode -ne [MinimumBandwidthMode]::Default -and $this.DefaultFlowMinimumBandwidthAbsolute)
        {
            $results += 'DefaultFlowMinimumBandwidthAbsolute can only be set on switches with Absolute bandwidth reservation modes.'
        }
        
        if ($this.MinimumBandwidthMode -ne [MinimumBandwidthMode]::Width -and $this.DefaultFlowMinimumBandwidthWeight)
        {
            $results += 'DefaultFlowMinimumBandwidthWeight can only be set on switches with weight bandwidth reservation modes.'
        }
        
        if ($this.TrackingMethod -ne [TrackingMethod]::Guid -and $this.AllowNameDrift)
        {
            $results += 'AllowNameDrift can only be set to $true if TrackingMethod is Guid'
        }
        
        if ($results)
        {
            $results.foreach({ Write-Warning $_ })
			$errorRecord = New-ErrorRecord -ErrorMessage "Failed to validate parameters for switch $($this.Name)" -ErrorCategory 'InvalidArgument'
            throw $errorRecord
        }
    }
    
    # Function that returns a PSObject containing the current configuration
    # Used by both TestConfiguration() and Get()
    [System.Management.Automation.PSObject] GetConfiguration()
    {
        Write-Verbose "Retrieving switch configuration"
        
        $results = @{ }
        
        if ($this.SwitchUniqueId -and $this.TrackingMethod -eq [TrackingMethod]::Guid)
        {
            Write-Verbose "Retrieving switch based on Id = $($this.SwitchUniqueId)"
            $switch = Get-VMSwitch -Id $this.SwitchUniqueId -ErrorAction SilentlyContinue
        }
        else
        {
            Write-Verbose "Retrieving switch based on Name = $($this.Name)"
            $switch = Get-VMSwitch -Name $this.Name -ErrorAction SilentlyContinue
            
            if ($switch.Count -gt 1)
            {
                $errorRecord = New-ErrorRecord -ErrorMessage "Multiple switches with name $($this.Name) found, this is only supported in this resource if TrackingMethod is set to Guid and the Guid is known" -ErrorCategory 'InvalidData'
                throw $errorRecord
            }
        }
        
        # Invert if to simplify reading since the else clause is much bigger
        if (-not $switch)
        {
            Write-Verbose "Switch not found"
            $results.Ensure = [Ensure]::Absent
        }
        else
        {
            Write-Verbose "Found Switch"
            # Preserve the Switch Unique Id
            $this.SwitchUniqueId = $switch.Id
            
            $results.Ensure = [Ensure]::Present
            $results.Name = $switch.Name
            $results.SwitchType = $switch.SwitchType
            $results.NetAdapterName = if ($switch.SwitchType -eq [SwitchType]::External) { (Get-NetAdapter -InterfaceDescription $switch.NetAdapterInterfaceDescription -ErrorAction SilentlyContinue).Name }
            $results.AllowManagementOS = $switch.AllowManagementOS
            $results.IovEnabled = $switch.IovEnabled
            $results.MinimumBandwidthMode = $switch.MinimumBandwidthMode
            $results.Notes = $switch.Notes
            $results.DefaultFlowMinimumBandwidthAbsolute = $switch.DefaultFlowMinimumBandwidthAbsolute
            $results.DefaultFlowMinimumBandwidthWeight = $switch.DefaultFlowMinimumBandwidthWeight
            $results.SwitchUniqueId = $switch.Id
            $results.ReferencedVMs = (Get-VMNetworkAdapter *).Where({ $_.SwitchName -eq $switch.Name }).Count
        }
        
        return (New-Object -TypeName PSObject -Property $results)
    }
    
    # We have a single function that oversees all tests. This way the Test() method never has to change.
    # Is it worth having this on a module of its own? Same for the other functions currently inside the class?
    # Worth checking at some point
    [System.String[]] TestConfiguration()
    {
        Write-Verbose "Testing configuration for switch $($this.Name)"
        
        $results = @()
        $switchBeingCreated = $false
        $actualConfiguration = $this.GetConfiguration()
        
        if ($this.Ensure -ne $actualConfiguration.Ensure)
        {
            # If we want to ensure it's absent return now, all other tests are only applicable when Ensure = Present
            if ($this.Ensure -eq [Ensure]::Absent)
            {
                Write-Verbose "Switch exists but Ensure is set to Absent, will delete switch"
                return 'DeleteObject'
            }
            
            Write-Verbose "Switch does not exist, but ensure is set to Present. Will create switch"
            $results += 'CreateObject'
            $switchBeingCreated = $true
        }
        
        Write-Verbose "Discovered real switch name is $($actualConfiguration.Name)"
        $this.actualName = $actualConfiguration.Name
        
        # If we're not allowed to perform disruptive operations, there's no point even checking these
        if ($this.AllowDisruptiveAction -eq [AllowDisruptiveAction]::IfNeeded -or ($this.AllowDisruptiveAction -eq [AllowDisruptiveAction]::OnlyIfUnused -and $actualConfiguration.ReferencedVMs -eq 0))
        {
            # If IovEnabled or is not in the correct state, we need to recreate the switch
            if (($this.IovEnabled -ne $actualConfiguration.IovEnabled) -and -not $switchBeingCreated)
            {
                Write-Verbose "IovEnabled is set to $($actualConfiguration.IovEnabled) but it should be set to $($this.IovEnabled). Will need to recreate switch"
                # Recreating a switch is effectively a delete and a create...
                $results += 'DeleteObject'
                $results += 'CreateObject'
                
                $switchBeingCreated = $true
            }
            
            # If MinimumBandwidthMode is not in the correct state, we need to recreate the switch
            if ($this.MinimumBandwidthMode -and $this.MinimumBandwidthMode -ne $actualConfiguration.MinimumBandwidthMode -and ($this.MinimumBandwidthMode -ne [MinimumBandwidthMode]::Default -and $actualConfiguration.MinimumBandwidthMode -ne 'Absolute') -and -not $switchBeingCreated)
            {
                Write-Verbose "MinimumBandwidthMode is set to $($actualConfiguration.MinimumBandwidthMode) but should be set to $($this.MinimumBandwidthMode). Will need to recreate switch."
                $results += 'DeleteObject'
                $results += 'CreateObject'
                
                $switchBeingCreated = $true
            }
            
            # Properties inside this if are set at switch creation so no need to re-check them if the switch is already being created
            if ($switchBeingCreated -eq $false)
            {
                if ($this.SwitchType -and $this.SwitchType -ne $actualConfiguration.SwitchType -and $this.SwitchType -ne [SwitchType]::External)
                {
                    Write-Verbose "SwitchType is currently set to $($actualConfiguration.SwitchType) but should be set to $($this.SwitchType), changing it"
                    $results += 'SetSwitchType'
                }
                
                # We only want to monitor the NetAdapterName for drift if the SwitchType is specified (and set to External, but this is controlled by the parameter validation)
                if ($this.NetAdapterName -and $this.SwitchType -and $this.NetAdapterName -ne $actualConfiguration.NetAdapterName)
                {
                    Write-Verbose "NetAdapterName is currently set to $($actualConfiguration.NetAdapterName) but should be set to $($this.NetAdapterName), changing it"
                    $results += 'SetNetAdapterName'
                }
                
                if ($this.AllowManagementOS -ne $null -and $this.AllowManagementOS -ne $actualConfiguration.AllowManagementOs)
                {
                    Write-Verbose "AllowManagementOS is currently set to $($actualConfiguration.AllowManagementOS) but should be set to $($this.AllowManagementOS), changing it"
                    $results += 'SetAllowManagementOS'
                }
            }
        }
        else
        {
            Write-Verbose "Skipping disruptive tests as we're not allowed to perform disruptive actions. AllowDisruptiveAction = '$($this.AllowDisruptiveAction), ReferencedVMs = '$($this.ReferencedVMs)'"
        }
        
        # The notes can be set at switch creation, but they are not a disruptable operation, so it's set outside the if above
        if ($this.Notes -and $this.Notes -ne $actualConfiguration.Notes -and -not $switchBeingCreated)
        {
            Write-Verbose "Notes does not have the correct value, setting it"
            $results += 'SetNotes'
        }
        
        # If name has drifted and we don't allow name drift, set it back
        if ($this.Name -ne $actualConfiguration.Name -and -not $this.AllowNameDrift -and -not $switchBeingCreated)
        {
            Write-Verbose "Switch does not have the correct name, changing it"
            $results += 'RenameObject'
        }
        
        if ($this.DefaultFlowMinimumBandwidthAbsolute -and $this.DefaultFlowMinimumBandwidthAbsolute -ne $actualConfiguration.DefaultFlowMinimumBandwidthAbsolute)
        {
            Write-Verbose "DefaultFlowMinimumBandwidthAbsolute does not have the correct value, setting it"
            $results += 'SetDefaultFlowMinimumBandwidthAbsolute'
        }
        
        if ($this.DefaultFlowMinimumBandwidthWeight -and $this.DefaultFlowMinimumBandwidthWeight -ne $actualConfiguration.DefaultFlowMinimumBandwidthWeight)
        {
            Write-Verbose "SetDefaultFlowMinimumBandwidthWeight does not have the correct value, setting it"
            $results += 'SetDefaultFlowMinimumBandwidthWeight'
        }

        return $results
    }
    
    [void] SaveConfiguration([System.String] $caller)
    {
        Write-Verbose "Saving configuration for caller $caller"
        
        $outputXML = @{ }
        $outputXML.SwitchUniqueId = $this.SwitchUniqueId
        
        # Whether there are set operations or not defines whether the Set() gets called, and we only want to save the variables below if there's a set still being called.
        if ($caller -eq 'Test' -and $this.setOperations)
        {
            $outputXML.actualName = $this.actualName
            $outputXML.setOperations = $this.setOperations
            $outputXML.lastExecution = $this.startExecution

        }
        else
        {
            $outputXML.lastExecution = $this.startExecution
        }
        
        $directoryName = [System.IO.FileInfo]::New($this.configFile).DirectoryName

        if (-not (Test-Path $directoryName))
        {
            New-Item $directoryName -ItemType Directory -Force
        }

        Export-Clixml -InputObject $outputXML -Path $this.configFile
    }
    
    [void] LoadConfiguration()
    {
        Write-Verbose 'Loading configuration'
        
        # Calculate what the path for the config file should be
        $resourceName = [System.IO.Path]::GetFileNameWithoutExtension($PSScriptRoot)
        $this.configFile = "$env:APPDATA\DSC\$resourceName\$($this.Name).xml"

        if (-not (Test-Path $this.configFile))
        {
            Write-Verbose "Config file '$($this.configFile)' not found, running for first time for switch '$($this.Name)'"
            $this.hasRun = $false
        }
        else
        {
            Write-Verbose "Found config file '$($this.configFile)' for switch '$($this.Name)' - importing variables"
            $inputXML = Import-Clixml $this.ConfigFile
            
            foreach ($key in $inputXML.Keys)
            {
                Write-Verbose "Assining value '$($inputXML.$key)' to variable '$key'"
                $this.$key = $inputXML.$key
            }
        }
    }
}

#region Helper Functions
function New-ErrorRecord
{
    [CmdletBinding(DefaultParameterSetName = 'ErrorMessageSet')]
    param
        (
        [Parameter(ValueFromPipeline = $true, Position = 0, ParameterSetName = 'ErrorMessageSet')]
        [String]$ErrorMessage,
        [Parameter(ValueFromPipeline = $true, Position = 0, ParameterSetName = 'ExceptionSet')]
        [System.Exception]$Exception,
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 1, ParameterSetName = 'ErrorMessageSet')]
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 1, ParameterSetName = 'ExceptionSet')]
        [System.Management.Automation.ErrorCategory]$ErrorCategory = [System.Management.Automation.ErrorCategory]::NotSpecified,
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 2, ParameterSetName = 'ErrorMessageSet')]
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 2, ParameterSetName = 'ExceptionSet')]
        [String]$ErrorId,
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 3, ParameterSetName = 'ErrorMessageSet')]
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 3, ParameterSetName = 'ExceptionSet')]
        [Object]$TargetObject
    )
    
    if (!$Exception)
    {
        $Exception = New-Object System.Exception $ErrorMessage
    }
    
    # Function does not belong to class so does not have a localized string. The idea if for helper functions in the future to be on their own module, just didn't do it as of yet.
	Write-Verbose "Creating new error record with the following information: ErrorMessage = '$($Exception.Message)'; ErrorId = '$ErrorId'; ErrorCategory = '$ErrorCategory'"
	New-Object System.Management.Automation.ErrorRecord $Exception, $ErrorId, $ErrorCategory, $TargetObject
}
#endregion