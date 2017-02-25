
class PluginManager {

    [hashtable]$Plugins = @{}
    [hashtable]$Commands = @{}
    hidden [string]$_PoshBotModuleDir
    [RoleManager]$RoleManager
    [StorageProvider]$_Storage
    [Logger]$Logger

    PluginManager([RoleManager]$RoleManager, [StorageProvider]$Storage, [Logger]$Logger, [string]$PoshBotModuleDir) {
        $this.RoleManager = $RoleManager
        $this._Storage = $Storage
        $this.Logger = $Logger
        $this._PoshBotModuleDir = $PoshBotModuleDir
        $this.Initialize()
    }

    # Initialize the plugin manager
    [void]Initialize() {
        $this.Logger.Info([LogMessage]::new('[PluginManager:Initialize] Initializing'))
        $this.LoadState()
        $this.LoadBuiltinPlugins()
    }

    [void]LoadState() {
        $this.Logger.Verbose([LogMessage]::new('[PluginManager:LoadState] Loading plugin state from storage'))

        $pluginsToLoad = $this._Storage.GetConfig('plugins')
        if ($pluginsToLoad) {
            $pluginsToLoad.GetEnumerator() | ForEach-Object {
                $pluginVersions = $_.Value.Keys
                foreach ($pluginVersion in $pluginVersions) {
                    $pluginName = $_.Value[$pluginVersion].Name
                    $manifestPath = $_.Value[$pluginVersion].ManifestPath
                    $this.CreatePluginFromModuleManifest($pluginName, $manifestPath, $true)
                }
            }
        }
    }

    [void]SaveState() {
        $this.Logger.Verbose([LogMessage]::new('[PluginManager:SaveState] Saving loaded plugin state to storage'))

        # Skip saving builtin plugin as it will always be loaded at initialization
        $pluginsToSave = @{}
        $this.Plugins.GetEnumerator() | Where {$_.Name -ne 'Builtin'} | ForEach-Object {
            $versions = @{}
            foreach ($versionKey in $_.Value.Keys) {
                $p = @{
                    Name = $_.Name
                    Version = $_.Value[$versionKey].Version
                    ManifestPath = $_.Value[$versionKey]._ManifestPath
                    Enabled = $_.Value[$versionKey].Enabled
                }
                $versions.Add($versionKey, $p)
            }
            $pluginsToSave.Add($_.Name, $versions)
        }
        $this._Storage.SaveConfig('plugins', $pluginsToSave)
    }

    # TODO
    # Given a PowerShell module definition, inspect it for commands etc,
    # create a plugin instance and load the plugin
    [void]InstallPlugin([string]$ManifestPath) {
        if (Test-Path -Path $ManifestPath) {
            $moduleName = (Get-Item -Path $ManifestPath).BaseName
            $this.CreatePluginFromModuleManifest($moduleName, $ManifestPath, $true)
        } else {
            Write-Error -Message "Module manifest path [$manifestPath] not found"
        }
    }

    # Add a plugin to the bot
    [void]AddPlugin([Plugin]$Plugin) {
        if (-not $this.Plugins.ContainsKey($Plugin.Name)) {
            $this.Logger.Info([LogMessage]::new("[PluginManager:AddPlugin] Attaching plugin [$($Plugin.Name)]"))

            $pluginVersion = @{
                ($Plugin.Version).ToString() = $Plugin
            }
            $this.Plugins.Add($Plugin.Name, $pluginVersion)

            # Register the plugins permission set with the role manager
            foreach ($permission in $Plugin.Permissions.GetEnumerator()) {
                $this.Logger.Info([LogMessage]::new("[PluginManager:AddPlugin] Adding permission [$($permission.Value.ToString())] to Role Manager"))
                $this.RoleManager.AddPermission($permission.Value)
            }
        } else {

            if (-not $this.Plugins[$Plugin.Name].ContainsKey($Plugin.Version)) {
                # Install a new plugin version
                $this.Logger.Info([LogMessage]::new("[PluginManager:AddPlugin] Attaching version [$($Plugin.Version)] of plugin [$($Plugin.Name)]"))

                $this.Plugins[$Plugin.Name].Add($Plugin.Version.ToString(), $Plugin)

                # Register the plugins permission set with the role manager
                foreach ($permission in $Plugin.Permissions.GetEnumerator()) {
                    $this.Logger.Info([LogMessage]::new("[PluginManager:AddPlugin] Adding permission [$($permission.Value.ToString())] to Role Manager"))
                    $this.RoleManager.AddPermission($permission.Value)
                }
            } else {
                throw [PluginException]::New("Plugin [$($Plugin.Name)] version [$($Plugin.Version)] is already loaded")
            }
        }

        # # Reload commands and role from all currently loading (and active) plugins
        $this.LoadCommands()

        $this.SaveState()
    }

    # Remove a plugin from the bot
    [void]RemovePlugin([Plugin]$Plugin) {
        if ($this.Plugins.ContainsKey($Plugin.Name)) {
            $pluginVersions = $this.Plugins[$Plugin.Name]
            if ($pluginVersions.Keys.Count -eq 1) {
                # Remove the permissions for this plugin from the role manaager
                # but only if this is the only version of the plugin loaded
                foreach ($permission in $Plugin.Permissions.GetEnumerator()) {
                    $this.Logger.Verbose([LogMessage]::new("[PluginManager:RemovePlugin] Removing permission [$($Permission.Value.ToString())]. No longer in use"))
                    $this.RoleManager.RemovePermission($Permission.Value)
                }
                $this.Logger.Info([LogMessage]::new("[PluginManager:RemovePlugin] Removing plugin [$($Plugin.Name)]"))
                $this.Plugins.Remove($Plugin.Name)
            } else {
                if ($pluginVersions.ContainsKey($Plugin.Version)) {
                    $this.Logger.Info([LogMessage]::new("[PluginManager:RemovePlugin] Removing plugin [$($Plugin.Name)] version [$($Plugin.Version)]"))
                    $pluginVersions.Remove($Plugin.Version)
                } else {
                    throw [PluginNotFoundException]::New("Plugin [$($Plugin.Name)] version [$($Plugin.Version)] is not loaded in bot")
                }
            }
        }

        # Reload commands from all currently loading (and active) plugins
        $this.LoadCommands()

        $this.SaveState()
    }

    # Activate a plugin
    [void]ActivatePlugin([string]$PluginName, [string]$Version) {
        if ($p = $this.Plugins[$PluginName]) {
            if ($pv = $p[$Version]) {
                $this.Logger.Info([LogMessage]::new("[PluginManager:ActivatePlugin] Activating plugin [$PluginName] version [$Version]"))
                $pv.Activate()

                # Reload commands from all currently loading (and active) plugins
                $this.LoadCommands()
                $this.SaveState()
            } else {
                throw [PluginNotFoundException]::New("Plugin [$PluginName] version [$Version] is not loaded in bot")
            }
        } else {
            throw [PluginNotFoundException]::New("Plugin [$PluginName] is not loaded in bot")
        }
    }

    # Activate a plugin
    [void]ActivatePlugin([Plugin]$Plugin) {
        $p = $this.Plugins[$Plugin.Name]
        if ($p) {
            if ($pv = $p[$Plugin.Version.ToString()]) {
                $this.Logger.Info([LogMessage]::new("[PluginManager:ActivatePlugin] Activating plugin [$($Plugin.Name)] version [$($Plugin.Version)]"))
                $pv.Activate()
            }
        } else {
            throw [PluginNotFoundException]::New("Plugin [$($Plugin.Name)] version [$($Plugin.Version)] is not loaded in bot")
        }

        # Reload commands from all currently loading (and active) plugins
        $this.LoadCommands()

        $this.SaveState()
    }

    # Deactivate a plugin
    [void]DeactivatePlugin([Plugin]$Plugin) {
        $p = $this.Plugins[$Plugin.Name]
        if ($p) {
            if ($pv = $p[$Plugin.Version.ToString()]) {
                $this.Logger.Info([LogMessage]::new("[PluginManager:DeactivatePlugin] Deactivating plugin [$($Plugin.Name)] version [$($Plugin.Version)]"))
                $pv.Deactivate()
            }
        } else {
            throw [PluginNotFoundException]::New("Plugin [$($Plugin.Name)] version [$($Plugin.Version)] is not loaded in bot")
        }

        # # Reload commands from all currently loading (and active) plugins
        $this.LoadCommands()

        $this.SaveState()
    }

    # Deactivate a plugin
    [void]DeactivatePlugin([string]$PluginName, [string]$Version) {
        if ($p = $this.Plugins[$PluginName]) {
            if ($pv = $p[$Version]) {
                $this.Logger.Info([LogMessage]::new("[PluginManager:DeactivatePlugin] Deactivating plugin [$PluginName)] version [$Version]"))
                $pv.Deactivate()

                # Reload commands from all currently loading (and active) plugins
                $this.LoadCommands()
                $this.SaveState()
            } else {
                throw [PluginNotFoundException]::New("Plugin [$PluginName] version [$Version] is not loaded in bot")
            }
        } else {
            throw [PluginNotFoundException]::New("Plugin [$PluginName] is not loaded in bot")
        }
    }

     # Match a parsed command to a command in one of the currently loaded plugins
    [PluginCommand]MatchCommand([ParsedCommand]$ParsedCommand) {

        # Check builtin commands first
        $builtinKey = $this.Plugins['Builtin'].Keys | Select -First 1
        $builtinPlugin = $this.Plugins['Builtin'][$builtinKey]
        foreach ($commandKey in $builtinPlugin.Commands.Keys) {
            $command = $builtinPlugin.Commands[$commandKey]
            if ($command.TriggerMatch($ParsedCommand)) {
                $this.Logger.Info([LogMessage]::new("[PluginManagerBot:MatchCommand] Matched parsed command [$($ParsedCommand.Plugin)`:$($ParsedCommand.Command)] to builtin command [Builtin:$commandKey]"))
                return [PluginCommand]::new($builtinPlugin, $command)
            }
        }

        # If parsed command is fully qualified with <plugin:command> syntax. Just look in that plugin
        if (($ParsedCommand.Plugin -ne [string]::Empty) -and ($ParsedCommand.Command -ne [string]::Empty)) {
            $plugin = $this.Plugins[$ParsedCommand.Plugin]
            if ($plugin) {

                # Just look in the latest version of the plugin.
                # This should be improved later to allow specifying a specific version to execute
                $latestVersionKey = $plugin.Keys | Sort -Descending | Select-Object -First 1

                foreach ($commandKey in $plugin[$latestVersionKey].Commands.Keys) {
                    $command = $plugin.Commands[$commandKey]
                    if ($command.TriggerMatch($ParsedCommand)) {
                        $this.Logger.Info([LogMessage]::new("[PluginManager:MatchCommand] Matched parsed command [$($ParsedCommand.Plugin)`:$($ParsedCommand.Command)] to plugin command [$($plugin.Name)`:$commandKey]"))
                        return [PluginCommand]::new($plugin, $command)
                    }
                }
                $this.Logger.Info([LogMessage]::new([LogSeverity]::Warning, "[PluginManager:MatchCommand] Unable to match parsed command [$($ParsedCommand.Plugin)`:$($ParsedCommand.Command)] to a command in plugin [$($plugin.Name)]"))
            } else {
                $this.Logger.Info([LogMessage]::new([LogSeverity]::Warning, "[PluginManager:MatchCommand] Unable to match parsed command [$($ParsedCommand.Plugin)`:$($ParsedCommand.Command)] to a plugin command"))
                return $null
            }
        } else {

            # Check all regular plugins/commands now
            foreach ($pluginKey in $this.Plugins.Keys) {
                $plugin = $this.Plugins[$pluginKey]

                # Just look in the latest version of the plugin.
                # This should be improved later to allow specifying a specific version to execute
                foreach ($pluginVersionKey in $plugin.Keys | Sort -Descending | Select-Object -Firs 1) {
                    $pluginVersion = $plugin[$pluginVersionKey]

                    foreach ($commandKey in $pluginVersion.Commands.Keys) {
                        $command = $pluginVersion.Commands[$commandKey]
                        if ($command.TriggerMatch($ParsedCommand)) {
                            $this.Logger.Info([LogMessage]::new("[PluginManager:MatchCommand] Matched parsed command [$($ParsedCommand.Plugin)`:$($ParsedCommand.Command)] to plugin command [$pluginKey`:$commandKey]"))
                            return [PluginCommand]::new($pluginVersion, $command)
                        }
                    }
                }
            }
        }

        $this.Logger.Info([LogMessage]::new([LogSeverity]::Warning, "[PluginManager:MatchCommand] Unable to match parsed command [$($ParsedCommand.Plugin)`:$($ParsedCommand.Command)] to a plugin command"))
        return $null
    }

    # Load in the available commands from all the loaded plugins
    [void]LoadCommands() {
        $allCommands = New-Object System.Collections.ArrayList
        foreach ($pluginKey in $this.Plugins.Keys) {
            $plugin = $this.Plugins[$pluginKey]

            foreach ($pluginVersionKey in $plugin.Keys | Sort -Descending | Select-Object -Firs 1) {
                $pluginVersion = $plugin[$pluginVersionKey]
                if ($pluginVersion.Enabled) {
                    foreach ($commandKey in $pluginVersion.Commands.Keys) {
                        $command =  $pluginVersion.Commands[$commandKey]
                        $fullyQualifiedCommandName = "$pluginKey`:$CommandKey"
                        $allCommands.Add($fullyQualifiedCommandName)
                        if (-not $this.Commands.ContainsKey($fullyQualifiedCommandName)) {
                            $this.Logger.Verbose([LogMessage]::new("[PluginManager:LoadCommands] Loading command [$fullyQualifiedCommandName]"))
                            $this.Commands.Add($fullyQualifiedCommandName, $command)
                        }
                    }
                }
            }
        }

        # Remove any commands that are not in any of the loaded (and active) plugins
        $remove = New-Object System.Collections.ArrayList
        foreach($c in $this.Commands.Keys) {
            if (-not $allCommands.Contains($c)) {
                $remove.Add($c)
            }
        }
        $remove | ForEach-Object {
            $this.Logger.Verbose([LogMessage]::new("[PluginManager:LoadCommands] Removing command [$_]. Plugin has either been removed or is deactivated."))
            $this.Commands.Remove($_)
        }
    }

    [void]CreatePluginFromModuleManifest([string]$ModuleName, [string]$ManifestPath, [bool]$AsJob = $true) {
        $manifest = Import-PowerShellDataFile -Path $ManifestPath -ErrorAction SilentlyContinue
        if ($manifest) {
            $plugin = [Plugin]::new()
            $plugin.Name = $ModuleName
            $plugin._ManifestPath = $ManifestPath
            if ($manifest.ModuleVersion) {
                $plugin.Version = $manifest.ModuleVersion
            } else {
                $plugin.Version = '0.0.0'
            }

            # Create new permissions from metadata in the module manifest
            $this.GetPermissionsFromModuleManifest($manifest) | ForEach-Object {
                $_.Plugin = $plugin.Name
                $plugin.AddPermission($_)
            }

            # Add the plugin so the roles can be registered with the role manager
            $this.AddPlugin($plugin)
            $this.Logger.Info([LogMessage]::new("[PluginManager:CreatePluginFromModuleManifest] Created new plugin [$($plugin.Name)]"))

            Import-Module -Name $manifestPath -Scope Local -Verbose:$false -WarningAction SilentlyContinue
            $moduleCommands = Microsoft.PowerShell.Core\Get-Command -Module $ModuleName -CommandType Cmdlet, Function, Workflow
            foreach ($command in $moduleCommands) {

                # Get the command help so we can pull information from it
                # to construct the bot command
                $cmdHelp = Get-Help -Name $command.Name

                # Get any command metadata that may be attached to the command
                # via the PoshBot.BotCommand extended attribute
                $metadata = $this.GetCommandMetadata($command)

                $this.Logger.Info([LogMessage]::new("[PluginManager:CreatePluginFromModuleManifest] Creating command [$($command.Name)] for new plugin [$($plugin.Name)]"))
                $cmd = [Command]::new()

                # Normally, bot commands only respond to normal messages received from the chat network
                # To respond to other message types/subtypes, metadata must be added to the function to
                # call out the exact message type/subtype the command is designed to respond to
                $trigger = [Trigger]::new('Command', $command.Name)
                $cmd.Trigger = $trigger

                # Set command properties based on metadata from module
                if ($metadata) {
                    if ($metadata.CommandName) {
                        $cmd.Name = $metadata.CommandName
                    } else {
                        $cmd.name = $command.Name
                    }

                    # Add any defined permissions to the command
                    if ($metadata.Permissions) {
                        foreach ($item in $metadata.Permissions) {
                            $fqPermission = "$($plugin.Name):$($item)"
                            if ($p = $plugin.GetPermission($fqPermission)) {
                                $cmd.AddPermission($p)
                            } else {
                                Write-Error -Message "Permission [$fqPermission] is not defined in the plugin module manifest. Command will not be added to plugin."
                                continue
                            }
                        }
                    }

                    $cmd.KeepHistory = $metadata.KeepHistory
                    $cmd.HideFromHelp = $metadata.HideFromHelp

                    # Set the trigger type
                    if ($metadata.TriggerType) {
                        switch ($metadata.TriggerType) {
                            'Comamnd' {
                                $cmd.Trigger.Type = [TriggerType]::Command
                            }
                            'Event' {
                                $cmd.Trigger.Type = [TriggerType]::Event
                            }
                            'Regex' {
                                $cmd.Trigger.Type = [TriggerType]::Regex
                                $cmd.Trigger.Trigger = $metadata.Regex
                            }
                        }
                    } else {
                        $cmd.Trigger.Type = [TriggerType]::Command
                    }

                    if ($metadata.MessageType) {
                        $cmd.Trigger.MessageType = $metadata.MessageType
                    }
                    if ($metadata.MessageSubtype) {
                        $cmd.Trigger.MessageSubtype = $metadata.MessageSubtype
                    }
                } else {
                    $cmd.Name = $command.Name
                    $cmd.Trigger = [Trigger]::new('Command', $command.Name)
                }

                $cmd.Description = $cmdHelp.Synopsis.Trim()
                $cmd.ManifestPath = $manifestPath
                $cmd.FunctionInfo = $command

                if ($cmdHelp.examples) {
                    foreach ($example in $cmdHelp.Examples.Example) {
                        $cmd.Usage += $example.code.Trim()
                    }
                }
                $cmd.ModuleCommand = "$ModuleName\$($command.Name)"
                $cmd.AsJob = $AsJob

                $plugin.AddCommand($cmd)
            }
            $this.LoadCommands()
            $this.SaveState()
        }
    }

    [PoshBot.BotCommand]GetCommandMetadata([System.Management.Automation.FunctionInfo]$Command) {
        $attrs = $Command.ScriptBlock.Attributes
        $botCmdAttr = $attrs | ForEach-Object {
            if ($_.TypeId.ToString() -eq 'PoshBot.BotCommand') {
                $_
            }
        }
        return $botCmdAttr
    }

    [Permission[]]GetPermissionsFromModuleManifest($Manifest) {
        $permissions = New-Object System.Collections.ArrayList
        foreach ($permission in $Manifest.PrivateData.Permissions) {
            if ($permission -is [string]) {
                $p = [Permission]::new($Permission)
                $permissions.Add($p)
            } elseIf ($permission -is [hashtable]) {
                $p = [Permission]::new($permission.Name)
                if ($permission.Description) {
                    $p.Description = $permission.Description
                }
                $permissions.Add($p)
            }
        }
        return $permissions
    }

    # Load in the built in plugins
    # These will be marked so that they DON't execute in a PowerShell job
    # as they need access to the bot internals
    [void]LoadBuiltinPlugins() {
        $this.Logger.Info([LogMessage]::new('[PluginManager:LoadBuiltinPlugins] Loading builtin plugins'))
        $builtinPlugin = Get-Item -Path "$($this._PoshBotModuleDir)/Plugins/Builtin"
        $moduleName = $builtinPlugin.BaseName
        $manifestPath = Join-Path -Path $builtinPlugin.FullName -ChildPath "$moduleName.psd1"
        $this.CreatePluginFromModuleManifest($moduleName, $manifestPath, $false)
    }
}