<#
.SYNOPSIS
    SystemEQ - System-wide Windows Audio Equalizer (Sub-Bass, Bass, Vocal, Low-Pass Filter).
.DESCRIPTION
    Native Windows WPF desktop application with real-time frequency response curve and
    zero-latency system-wide DSP powered by Equalizer APO. Works across Spotify, browsers,
    games, and all Windows apps on any enabled output device (speakers, Bluetooth earbuds,
    wired headphones, USB DACs, HDMI).
#>

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Single-instance check
$script:MutexName = 'Global\SystemEQ_DesktopApp_SingleInstance'
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$createdNew)
if (-not $createdNew) {
    exit
}

#region Paths, Config & Equalizer APO Discovery
$script:AppDir          = Join-Path $env:APPDATA 'SystemEQ'
$script:LegacyLivePath  = Join-Path $script:AppDir 'SystemEQ_Live.txt'
$script:LiveEqFileName  = 'SystemEQ_Live.txt'
$script:LiveEqPath      = Join-Path $script:AppDir $script:LiveEqFileName
$script:StatePath       = Join-Path $script:AppDir 'state.json'
$script:InvCulture  = [System.Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path $script:AppDir)) {
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
}

function Get-EqualizerApoInfo {
    $installDir = $null
    $configDir  = $null
    try {
        $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\EqualizerAPO' -ErrorAction SilentlyContinue
        if ($reg) {
            if ($reg.InstallPath) { $installDir = $reg.InstallPath }
            if ($reg.ConfigPath)  { $configDir  = $reg.ConfigPath }
        }
    } catch {}

    if (-not $installDir -and (Test-Path 'C:\Program Files\EqualizerAPO')) {
        $installDir = 'C:\Program Files\EqualizerAPO'
    }
    if (-not $configDir -and $installDir) {
        $candidate = Join-Path $installDir 'config'
        if (Test-Path $candidate) { $configDir = $candidate }
    }

    $configTxt = if ($configDir) { Join-Path $configDir 'config.txt' } else { $null }
    $selector  = $null
    if ($installDir) {
        $ds = Join-Path $installDir 'DeviceSelector.exe'
        $cf = Join-Path $installDir 'Configurator.exe'
        if (Test-Path $ds)     { $selector = $ds }
        elseif (Test-Path $cf) { $selector = $cf }
    }

    if ($configDir -and (Test-Path $configDir)) {
        $script:LiveEqPath = Join-Path $configDir $script:LiveEqFileName
    }

    $isLinked = $false
    if ($configTxt -and (Test-Path $configTxt)) {
        try {
            $lines = Get-Content -Path $configTxt -ErrorAction SilentlyContinue
            foreach ($ln in $lines) {
                if ($ln.Trim() -ieq "Include: $($script:LiveEqFileName)") {
                    $isLinked = $true
                    break
                }
            }
        } catch {}
    }

    return [PSCustomObject]@{
        Installed    = [bool]($installDir -and (Test-Path $installDir))
        InstallDir   = $installDir
        ConfigDir    = $configDir
        ConfigTxt    = $configTxt
        SelectorExe  = $selector
        IsLinked     = $isLinked
    }
}

$script:State = [PSCustomObject]@{
    Enabled      = $true
    SubDb        = 0.0
    BassDb       = 0.0
    VocalDb      = 0.0
    LpfEnabled   = $false
    LpfFreqHz    = 18000.0
    LpfSlope24   = $false
    AutoHeadroom = $true
    PreampDb     = 0.0
    CustomPreset = [PSCustomObject]@{
        SubDb      = 3.5
        BassDb     = 2.0
        VocalDb    = 1.5
        LpfEnabled = $false
        LpfFreqHz  = 18000.0
        LpfSlope24 = $false
    }
}

function Load-EqState {
    if (Test-Path $script:StatePath) {
        try {
            $s = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
            if ($null -ne $s.Enabled)      { $script:State.Enabled      = [bool]$s.Enabled }
            if ($null -ne $s.SubDb)        { $script:State.SubDb        = [double]$s.SubDb }
            if ($null -ne $s.BassDb)       { $script:State.BassDb       = [double]$s.BassDb }
            if ($null -ne $s.VocalDb)      { $script:State.VocalDb      = [double]$s.VocalDb }
            if ($null -ne $s.LpfEnabled)   { $script:State.LpfEnabled   = [bool]$s.LpfEnabled }
            if ($null -ne $s.LpfFreqHz)    { $script:State.LpfFreqHz    = [double]$s.LpfFreqHz }
            if ($null -ne $s.LpfSlope24)   { $script:State.LpfSlope24   = [bool]$s.LpfSlope24 }
            if ($null -ne $s.AutoHeadroom) { $script:State.AutoHeadroom = [bool]$s.AutoHeadroom }
            if ($null -ne $s.PreampDb)     { $script:State.PreampDb     = [double]$s.PreampDb }
            if ($null -ne $s.CustomPreset) { $script:State.CustomPreset = $s.CustomPreset }
        } catch {}
    }
}

function Save-EqState {
    try {
        $script:State | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StatePath -Encoding UTF8
    } catch {}
}

function Get-EffectivePreampDb {
    if (-not $script:State.Enabled) { return 0.0 }
    if ($script:State.AutoHeadroom) {
        $peak = [math]::Max(0.0, [math]::Max($script:State.SubDb, [math]::Max($script:State.BassDb, $script:State.VocalDb)))
        # Account for mild overlap when both Sub and Bass are boosted together
        if ($script:State.SubDb -gt 0 -and $script:State.BassDb -gt 0) {
            $peak = [math]::Max($peak, ($script:State.SubDb * 0.65) + ($script:State.BassDb * 0.65))
        }
        return [math]::Round(-$peak, 1)
    }
    return [math]::Round($script:State.PreampDb, 1)
}

function Write-LiveEqFile {
    $inv = $script:InvCulture
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Managed live by SystemEQ Desktop Controller')

    if ($script:State.Enabled) {
        $preamp = Get-EffectivePreampDb
        if ([math]::Abs($preamp) -ge 0.05) {
            $lines.Add(('Preamp: {0} dB' -f $preamp.ToString('F1', $inv)))
        }

        if ([math]::Abs($script:State.SubDb) -ge 0.05) {
            $lines.Add(('Filter: ON LSC Fc 45.0 Hz Gain {0} dB Q 0.707' -f $script:State.SubDb.ToString('F1', $inv)))
        }

        if ([math]::Abs($script:State.BassDb) -ge 0.05) {
            $lines.Add(('Filter: ON PK Fc 110.0 Hz Gain {0} dB Q 0.850' -f $script:State.BassDb.ToString('F1', $inv)))
        }

        if ([math]::Abs($script:State.VocalDb) -ge 0.05) {
            $lines.Add(('Filter: ON PK Fc 2500.0 Hz Gain {0} dB Q 0.900' -f $script:State.VocalDb.ToString('F1', $inv)))
        }

        if ($script:State.LpfEnabled -and $script:State.LpfFreqHz -lt 19950) {
            $fc = [math]::Max(120.0, [math]::Min(20000.0, $script:State.LpfFreqHz))
            $lines.Add(('Filter: ON LPQ Fc {0} Hz Q 0.707' -f $fc.ToString('F1', $inv)))
            if ($script:State.LpfSlope24) {
                $lines.Add(('Filter: ON LPQ Fc {0} Hz Q 0.707' -f $fc.ToString('F1', $inv)))
            }
        }
    } else {
        $lines.Add('# Master EQ Bypassed')
    }

    $content = ($lines -join "`r`n") + "`r`n"
    try {
        [System.IO.File]::WriteAllText($script:LiveEqPath, $content, [System.Text.Encoding]::ASCII)
    } catch {}
}

function Link-EqualizerApoConfig {
    $info = Get-EqualizerApoInfo
    if (-not $info.Installed -or -not $info.ConfigTxt -or -not $info.ConfigDir) {
        return $false
    }

    $targetLive = Join-Path $info.ConfigDir $script:LiveEqFileName
    $script:LiveEqPath = $targetLive
    $includeLine = "Include: $($script:LiveEqFileName)"

    # Test if both config.txt and SystemEQ_Live.txt are already writable without UAC
    $canWriteDirectly = $false
    try {
        if (-not (Test-Path $targetLive)) {
            [System.IO.File]::WriteAllText($targetLive, "# Managed live by SystemEQ`r`n", [System.Text.Encoding]::ASCII)
        } else {
            [System.IO.File]::AppendAllText($targetLive, "", [System.Text.Encoding]::ASCII)
        }
        $existingLines = if (Test-Path $info.ConfigTxt) { @(Get-Content -Path $info.ConfigTxt) } else { @() }
        $cleaned = @($existingLines | Where-Object {
            $t = $_.Trim()
            ($t -notlike '*AppData*SystemEQ_Live.txt*') -and ($t -ine $includeLine)
        })
        $cleaned += $includeLine
        [System.IO.File]::WriteAllText($info.ConfigTxt, (($cleaned -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
        $canWriteDirectly = $true
    } catch {
        $canWriteDirectly = $false
    }

    if ($canWriteDirectly) {
        return $true
    }

    # One-time UAC elevation to update config.txt and grant Users (Modify) + LOCAL SERVICE (Read) on SystemEQ_Live.txt
    $escCfg  = $info.ConfigTxt.Replace("'", "''")
    $escLive = $targetLive.Replace("'", "''")
    $escInc  = $includeLine.Replace("'", "''")
    $elevScript = @"
`$cfg = '$escCfg'
`$live = '$escLive'
`$inc = '$escInc'
if (-not (Test-Path `$live)) { [System.IO.File]::WriteAllText(`$live, "# Managed live by SystemEQ`r`n", [System.Text.Encoding]::ASCII) }
icacls "`$live" /grant "*S-1-5-32-545:(M)" /grant "*S-1-5-19:(R)" | Out-Null
`$lines = if (Test-Path `$cfg) { @(Get-Content -Path `$cfg) } else { @() }
`$cleaned = @(`$lines | Where-Object { (`$_.Trim() -notlike '*AppData*SystemEQ_Live.txt*') -and (`$_.Trim() -ine `$inc) })
`$cleaned += `$inc
[System.IO.File]::WriteAllText(`$cfg, ((`$cleaned -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($elevScript))
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -PassThru -Wait
        return ($proc.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Install-AppShortcuts {
    $vbsLauncher = Join-Path (Split-Path -Parent $PSCommandPath) 'Launch_SystemEQ.vbs'
    if (-not (Test-Path $vbsLauncher)) {
        $escapedScript = $PSCommandPath.Replace('"', '""')
        $vbsBody = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""$escapedScript""", 0, False
"@
        Set-Content -Path $vbsLauncher -Value $vbsBody -Encoding ASCII
    }

    $wsh = New-Object -ComObject WScript.Shell
    $targets = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SystemEQ.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'SystemEQ.lnk')
    )
    foreach ($lnkPath in $targets) {
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath       = 'wscript.exe'
        $sc.Arguments        = "`"$vbsLauncher`""
        $sc.WorkingDirectory = Split-Path -Parent $PSCommandPath
        $sc.Description      = 'SystemEQ - System-Wide Audio Equalizer (Sub, Bass, Vocal, LPF)'
        $sc.IconLocation     = 'mmsys.cpl,0'
        $sc.Save()
    }
}

Load-EqState
[void](Get-EqualizerApoInfo)
Write-LiveEqFile
#endregion

#region Frequency Response Math (Biquad Magnitude for Live EQ Graph)
function Get-BiquadGainDb {
    param(
        [string]$Type,
        [double]$FreqHz,
        [double]$Fc,
        [double]$GainDb,
        [double]$Q,
        [double]$Fs = 48000.0
    )
    $w0    = 2.0 * [math]::PI * $Fc / $Fs
    $cosW0 = [math]::Cos($w0)
    $sinW0 = [math]::Sin($w0)
    $alpha = $sinW0 / (2.0 * $Q)
    $A     = [math]::Pow(10.0, $GainDb / 40.0)

    switch ($Type) {
        'LSC' {
            $sq = 2.0 * [math]::Sqrt($A) * $alpha
            $b0 = $A * (($A + 1.0) - ($A - 1.0) * $cosW0 + $sq)
            $b1 = 2.0 * $A * (($A - 1.0) - ($A + 1.0) * $cosW0)
            $b2 = $A * (($A + 1.0) - ($A - 1.0) * $cosW0 - $sq)
            $a0 = ($A + 1.0) + ($A - 1.0) * $cosW0 + $sq
            $a1 = -2.0 * (($A - 1.0) + ($A + 1.0) * $cosW0)
            $a2 = ($A + 1.0) + ($A - 1.0) * $cosW0 - $sq
        }
        'PK' {
            $b0 = 1.0 + $alpha * $A
            $b1 = -2.0 * $cosW0
            $b2 = 1.0 - $alpha * $A
            $a0 = 1.0 + $alpha / $A
            $a1 = -2.0 * $cosW0
            $a2 = 1.0 - $alpha / $A
        }
        'LPQ' {
            $b0 = (1.0 - $cosW0) / 2.0
            $b1 = 1.0 - $cosW0
            $b2 = (1.0 - $cosW0) / 2.0
            $a0 = 1.0 + $alpha
            $a1 = -2.0 * $cosW0
            $a2 = 1.0 - $alpha
        }
        default { return 0.0 }
    }

    $b0 /= $a0; $b1 /= $a0; $b2 /= $a0
    $a1 /= $a0; $a2 /= $a0

    $w  = 2.0 * [math]::PI * $FreqHz / $Fs
    $c1 = [math]::Cos($w);     $s1 = [math]::Sin($w)
    $c2 = [math]::Cos(2 * $w); $s2 = [math]::Sin(2 * $w)

    $numRe = $b0 + $b1 * $c1 + $b2 * $c2
    $numIm = -$b1 * $s1 - $b2 * $s2
    $denRe = 1.0 + $a1 * $c1 + $a2 * $c2
    $denIm = -$a1 * $s1 - $a2 * $s2

    $magSq = ($numRe * $numRe + $numIm * $numIm) / [math]::Max(1e-12, ($denRe * $denRe + $denIm * $denIm))
    return 10.0 * [math]::Log10([math]::Max(1e-6, $magSq))
}
#endregion

#region WPF Studio UI (XAML)
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SystemEQ - Live Audio Equalizer"
        Width="600"
        Height="590"
        MinWidth="560"
        MinHeight="560"
        WindowStartupLocation="CenterScreen"
        Background="#0F1219"
        Foreground="#F1F5F9"
        FontFamily="Segoe UI">

    <Window.Resources>
        <Style x:Key="PillButton" TargetType="Button">
            <Setter Property="Background" Value="#1C2230"/>
            <Setter Property="Foreground" Value="#CBD5E1"/>
            <Setter Property="BorderBrush" Value="#2D3648"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="11,5"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#283144"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource PillButton}">
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="BorderBrush" Value="#3B82F6"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
    </Window.Resources>

    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="138"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Grid.Row="0" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="SystemEQ" FontSize="20" FontWeight="Bold" Foreground="#F8FAFC"/>
                    <Border x:Name="ApoBadge" CornerRadius="10" Background="#1E293B" Padding="8,2" Margin="10,2,0,0" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse x:Name="ApoDot" Width="7" Height="7" Fill="#F59E0B" Margin="0,0,5,0"/>
                            <TextBlock x:Name="ApoStatusText" Text="Checking APO..." FontSize="11" Foreground="#CBD5E1"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
                <TextBlock Text="System-wide audio DSP for Spotify, browsers &amp; all output devices"
                           FontSize="11.5" Foreground="#94A3B8" Margin="0,2,0,0"/>
            </StackPanel>

            <CheckBox x:Name="MasterPowerChk"
                      Grid.Column="1"
                      Content="EQ Active"
                      IsChecked="True"
                      Foreground="#22C55E"
                      FontWeight="SemiBold"
                      FontSize="13"
                      VerticalAlignment="Center"
                      Cursor="Hand"/>
        </Grid>

        <!-- Live Frequency Response Graph -->
        <Border Grid.Row="1"
                CornerRadius="12"
                Background="#151A24"
                BorderBrush="#252E40"
                BorderThickness="1"
                Padding="10,8"
                Margin="0,0,0,12">
            <Grid>
                <Canvas x:Name="EqCanvas" ClipToBounds="True"/>
                <TextBlock Text="+12 dB" FontSize="9.5" Foreground="#64748B" HorizontalAlignment="Left" VerticalAlignment="Top"/>
                <TextBlock Text="0 dB"   FontSize="9.5" Foreground="#64748B" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                <TextBlock Text="-12 dB" FontSize="9.5" Foreground="#64748B" HorizontalAlignment="Left" VerticalAlignment="Bottom"/>
                <TextBlock Text="20 Hz"  FontSize="9.5" Foreground="#64748B" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="34,0,0,0"/>
                <TextBlock Text="110 Hz" FontSize="9.5" Foreground="#64748B" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="145,0,0,0"/>
                <TextBlock Text="2.5 kHz" FontSize="9.5" Foreground="#64748B" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,145,0"/>
                <TextBlock Text="20 kHz" FontSize="9.5" Foreground="#64748B" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
            </Grid>
        </Border>

        <!-- Presets Bar -->
        <WrapPanel Grid.Row="2" Margin="0,0,0,12">
            <Button x:Name="PresetFlat"   Content="Flat"          Style="{StaticResource PillButton}" Margin="0,0,6,4"/>
            <Button x:Name="PresetSub"    Content="Deep Sub"      Style="{StaticResource PillButton}" Margin="0,0,6,4"/>
            <Button x:Name="PresetBass"   Content="Punchy Bass"   Style="{StaticResource PillButton}" Margin="0,0,6,4"/>
            <Button x:Name="PresetVocal"  Content="Vocal Boost"   Style="{StaticResource PillButton}" Margin="0,0,6,4"/>
            <Button x:Name="PresetLofi"   Content="Warm Lo-Fi"    Style="{StaticResource PillButton}" Margin="0,0,6,4"/>
            <Button x:Name="PresetCustom" Content="My Custom"     Style="{StaticResource PillButton}" Margin="0,0,6,4"/>
            <Button x:Name="SaveCustom"   Content="Save Custom"   Style="{StaticResource PillButton}" Margin="0,0,0,4" Foreground="#60A5FA"/>
        </WrapPanel>

        <!-- Main EQ Controls Card -->
        <Border Grid.Row="3"
                CornerRadius="12"
                Background="#151A24"
                BorderBrush="#252E40"
                BorderThickness="1"
                Padding="16,14"
                Margin="0,0,0,12">
            <StackPanel VerticalAlignment="Center">

                <!-- Sub-Bass (45 Hz Low-Shelf) -->
                <Grid Margin="0,0,0,14">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="122"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="64"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                        <TextBlock Text="Sub-Bass" FontSize="13" FontWeight="SemiBold" Foreground="#F8FAFC"/>
                        <TextBlock Text="45 Hz Low-Shelf" FontSize="10.5" Foreground="#64748B"/>
                    </StackPanel>
                    <Slider x:Name="SubSlider" Grid.Column="1" Minimum="-12" Maximum="12" Value="0"
                            TickFrequency="1" IsSnapToTickEnabled="False" VerticalAlignment="Center" Margin="8,0"/>
                    <TextBlock x:Name="SubValText" Grid.Column="2" Text="0.0 dB" FontSize="13" FontWeight="Bold"
                               Foreground="#38BDF8" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>

                <!-- Bass (110 Hz Peaking) -->
                <Grid Margin="0,0,0,14">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="122"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="64"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                        <TextBlock Text="Bass" FontSize="13" FontWeight="SemiBold" Foreground="#F8FAFC"/>
                        <TextBlock Text="110 Hz Punch" FontSize="10.5" Foreground="#64748B"/>
                    </StackPanel>
                    <Slider x:Name="BassSlider" Grid.Column="1" Minimum="-12" Maximum="12" Value="0"
                            TickFrequency="1" IsSnapToTickEnabled="False" VerticalAlignment="Center" Margin="8,0"/>
                    <TextBlock x:Name="BassValText" Grid.Column="2" Text="0.0 dB" FontSize="13" FontWeight="Bold"
                               Foreground="#818CF8" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>

                <!-- Vocal (2.5 kHz Peaking) -->
                <Grid Margin="0,0,0,16">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="122"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="64"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                        <TextBlock Text="Vocal" FontSize="13" FontWeight="SemiBold" Foreground="#F8FAFC"/>
                        <TextBlock Text="2.5 kHz Presence" FontSize="10.5" Foreground="#64748B"/>
                    </StackPanel>
                    <Slider x:Name="VocalSlider" Grid.Column="1" Minimum="-12" Maximum="12" Value="0"
                            TickFrequency="1" IsSnapToTickEnabled="False" VerticalAlignment="Center" Margin="8,0"/>
                    <TextBlock x:Name="VocalValText" Grid.Column="2" Text="0.0 dB" FontSize="13" FontWeight="Bold"
                               Foreground="#34D399" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>

                <Border Height="1" Background="#252E40" Margin="0,0,0,14"/>

                <!-- Low-Pass Filter Section -->
                <Grid Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="122"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="72"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" VerticalAlignment="Center">
                        <CheckBox x:Name="LpfEnableChk" Content="Low-Pass" FontSize="13" FontWeight="SemiBold"
                                  Foreground="#F8FAFC" Cursor="Hand"/>
                        <CheckBox x:Name="LpfSlopeChk" Content="24 dB/oct Steep" FontSize="10.5"
                                  Foreground="#94A3B8" Margin="0,3,0,0" Cursor="Hand"/>
                    </StackPanel>
                    <!-- Logarithmic slider: 0..1000 maps to 120 Hz .. 20000 Hz -->
                    <Slider x:Name="LpfSlider" Grid.Column="1" Minimum="0" Maximum="1000" Value="980"
                            VerticalAlignment="Center" Margin="8,0"/>
                    <TextBlock x:Name="LpfValText" Grid.Column="2" Text="OFF" FontSize="13" FontWeight="Bold"
                               Foreground="#F59E0B" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>

                <!-- Preamp / Anti-Clip Headroom -->
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="122"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="64"/>
                    </Grid.ColumnDefinitions>
                    <CheckBox x:Name="AutoHeadroomChk" Grid.Column="0" Content="Auto Anti-Clip" IsChecked="True"
                              FontSize="12" Foreground="#CBD5E1" VerticalAlignment="Center" Cursor="Hand"
                              ToolTip="Automatically lowers preamp when boosting bass/sub to prevent distortion"/>
                    <Slider x:Name="PreampSlider" Grid.Column="1" Minimum="-12" Maximum="6" Value="0"
                            VerticalAlignment="Center" Margin="8,0" IsEnabled="False"/>
                    <TextBlock x:Name="PreampValText" Grid.Column="2" Text="0.0 dB" FontSize="12" FontWeight="SemiBold"
                               Foreground="#94A3B8" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
            </StackPanel>
        </Border>

        <!-- Setup / Action Toolbar -->
        <Grid Grid.Row="4" Margin="0,0,0,6">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <Button x:Name="ApoActionBtn" Grid.Column="0" Content="Link to Equalizer APO"
                    Style="{StaticResource AccentButton}" HorizontalAlignment="Left"/>

            <Button x:Name="DevicesBtn" Grid.Column="1" Content="Select Devices"
                    Style="{StaticResource PillButton}" Margin="0,0,6,0"/>

            <Button x:Name="RestartAudioBtn" Grid.Column="2" Content="Restart Audio"
                    Style="{StaticResource PillButton}" Margin="0,0,6,0"
                    ToolTip="Restart Windows Audio service to apply newly selected devices without rebooting"/>

            <Button x:Name="ShortcutBtn" Grid.Column="3" Content="Add Start Menu"
                    Style="{StaticResource PillButton}"/>
        </Grid>

        <!-- Footer hint -->
        <TextBlock x:Name="FooterHintText" Grid.Row="5"
                   Text="Tip: Enable your speakers &amp; Bluetooth earbuds in 'Select Output Devices' once, then reboot."
                   FontSize="10.5" Foreground="#64748B" TextWrapping="Wrap"/>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [System.Windows.Markup.XamlReader]::Load($reader)

$script:ApoDot          = $script:Window.FindName('ApoDot')
$script:ApoStatusText   = $script:Window.FindName('ApoStatusText')
$script:MasterPowerChk  = $script:Window.FindName('MasterPowerChk')
$script:EqCanvas        = $script:Window.FindName('EqCanvas')

$script:SubSlider       = $script:Window.FindName('SubSlider')
$script:BassSlider      = $script:Window.FindName('BassSlider')
$script:VocalSlider     = $script:Window.FindName('VocalSlider')
$script:LpfEnableChk    = $script:Window.FindName('LpfEnableChk')
$script:LpfSlopeChk     = $script:Window.FindName('LpfSlopeChk')
$script:LpfSlider       = $script:Window.FindName('LpfSlider')
$script:AutoHeadroomChk = $script:Window.FindName('AutoHeadroomChk')
$script:PreampSlider    = $script:Window.FindName('PreampSlider')

$script:SubValText      = $script:Window.FindName('SubValText')
$script:BassValText     = $script:Window.FindName('BassValText')
$script:VocalValText    = $script:Window.FindName('VocalValText')
$script:LpfValText      = $script:Window.FindName('LpfValText')
$script:PreampValText   = $script:Window.FindName('PreampValText')

$script:PresetFlat      = $script:Window.FindName('PresetFlat')
$script:PresetSub       = $script:Window.FindName('PresetSub')
$script:PresetBass      = $script:Window.FindName('PresetBass')
$script:PresetVocal     = $script:Window.FindName('PresetVocal')
$script:PresetLofi      = $script:Window.FindName('PresetLofi')
$script:PresetCustom    = $script:Window.FindName('PresetCustom')
$script:SaveCustom      = $script:Window.FindName('SaveCustom')

$script:ApoActionBtn    = $script:Window.FindName('ApoActionBtn')
$script:DevicesBtn      = $script:Window.FindName('DevicesBtn')
$script:RestartAudioBtn = $script:Window.FindName('RestartAudioBtn')
$script:ShortcutBtn     = $script:Window.FindName('ShortcutBtn')
$script:FooterHintText  = $script:Window.FindName('FooterHintText')
#endregion

#region UI Sync, Curve Rendering & Live Write Throttling
$script:SuppressEvents = $false
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter

# Logarithmic mapping for LPF slider (0..1000 <-> 120 Hz .. 20000 Hz)
$script:LpfMinLog = [math]::Log10(120.0)
$script:LpfMaxLog = [math]::Log10(20000.0)

function Convert-SliderToLpfHz([double]$val) {
    $t = [math]::Max(0.0, [math]::Min(1.0, $val / 1000.0))
    return [math]::Pow(10.0, $script:LpfMinLog + $t * ($script:LpfMaxLog - $script:LpfMinLog))
}

function Convert-LpfHzToSlider([double]$hz) {
    $clamped = [math]::Max(120.0, [math]::Min(20000.0, $hz))
    return (([math]::Log10($clamped) - $script:LpfMinLog) / ($script:LpfMaxLog - $script:LpfMinLog)) * 1000.0
}

function Format-FreqLabel([double]$hz) {
    if ($hz -ge 1000.0) { return ('{0:F1} kHz' -f ($hz / 1000.0)) }
    return ('{0:F0} Hz' -f $hz)
}

function Format-DbLabel([double]$db) {
    $sign = if ($db -gt 0.05) { '+' } else { '' }
    return ('{0}{1:F1} dB' -f $sign, $db)
}

function Refresh-ApoStatusBadge {
    $info = Get-EqualizerApoInfo
    if (-not $info.Installed) {
        $script:ApoDot.Fill        = $script:BrushConverter.ConvertFromString('#EF4444')
        $script:ApoStatusText.Text = 'Equalizer APO Not Installed'
        $script:ApoActionBtn.Content = 'Download Equalizer APO'
        $script:DevicesBtn.IsEnabled = $false
    } elseif (-not $info.IsLinked) {
        $script:ApoDot.Fill        = $script:BrushConverter.ConvertFromString('#F59E0B')
        $script:ApoStatusText.Text = 'APO Installed (Not Linked)'
        $script:ApoActionBtn.Content = 'Link to Equalizer APO'
        $script:DevicesBtn.IsEnabled = [bool]$info.SelectorExe
    } else {
        $script:ApoDot.Fill        = $script:BrushConverter.ConvertFromString('#22C55E')
        $script:ApoStatusText.Text = 'APO Linked | Live DSP'
        $script:ApoActionBtn.Content = 'APO Linked'
        $script:DevicesBtn.IsEnabled = [bool]$info.SelectorExe
    }
}

function Render-EqCurve {
    $w = $script:EqCanvas.ActualWidth
    $h = $script:EqCanvas.ActualHeight
    if ($w -lt 40 -or $h -lt 40) { return }

    $script:EqCanvas.Children.Clear()

    # Horizontal 0 dB center grid line
    $midY = $h / 2.0
    $zeroLine = New-Object System.Windows.Shapes.Line
    $zeroLine.X1 = 0; $zeroLine.X2 = $w; $zeroLine.Y1 = $midY; $zeroLine.Y2 = $midY
    $zeroLine.Stroke = $script:BrushConverter.ConvertFromString('#2A3448')
    $zeroLine.StrokeThickness = 1
    [void]$script:EqCanvas.Children.Add($zeroLine)

    # Vertical reference lines (45 Hz, 110 Hz, 2500 Hz)
    $logMin = [math]::Log10(20.0)
    $logMax = [math]::Log10(20000.0)
    foreach ($fMark in @(45.0, 110.0, 2500.0)) {
        $xMark = (([math]::Log10($fMark) - $logMin) / ($logMax - $logMin)) * $w
        $vLine = New-Object System.Windows.Shapes.Line
        $vLine.X1 = $xMark; $vLine.X2 = $xMark; $vLine.Y1 = 0; $vLine.Y2 = $h
        $vLine.Stroke = $script:BrushConverter.ConvertFromString('#1E2636')
        $vLine.StrokeThickness = 1
        [void]$script:EqCanvas.Children.Add($vLine)
    }

    # Build frequency response polyline
    $poly = New-Object System.Windows.Shapes.Polyline
    $strokeHex = if ($script:State.Enabled) { '#38BDF8' } else { '#64748B' }
    $poly.Stroke = $script:BrushConverter.ConvertFromString($strokeHex)
    $poly.StrokeThickness = 2.2
    $poly.StrokeLineJoin = 'Round'

    $steps = 72
    $pts = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -le $steps; $i++) {
        $t = $i / [double]$steps
        $freq = [math]::Pow(10.0, $logMin + $t * ($logMax - $logMin))
        $db = 0.0
        if ($script:State.Enabled) {
            if ([math]::Abs($script:State.SubDb) -ge 0.05) {
                $db += Get-BiquadGainDb -Type 'LSC' -FreqHz $freq -Fc 45.0 -GainDb $script:State.SubDb -Q 0.707
            }
            if ([math]::Abs($script:State.BassDb) -ge 0.05) {
                $db += Get-BiquadGainDb -Type 'PK' -FreqHz $freq -Fc 110.0 -GainDb $script:State.BassDb -Q 0.850
            }
            if ([math]::Abs($script:State.VocalDb) -ge 0.05) {
                $db += Get-BiquadGainDb -Type 'PK' -FreqHz $freq -Fc 2500.0 -GainDb $script:State.VocalDb -Q 0.900
            }
            if ($script:State.LpfEnabled -and $script:State.LpfFreqHz -lt 19950) {
                $lpfGain = Get-BiquadGainDb -Type 'LPQ' -FreqHz $freq -Fc $script:State.LpfFreqHz -GainDb 0.0 -Q 0.707
                $db += $lpfGain
                if ($script:State.LpfSlope24) { $db += $lpfGain }
            }
        }
        $clampedDb = [math]::Max(-15.0, [math]::Min(15.0, $db))
        $px = $t * $w
        $py = $midY - ($clampedDb / 15.0) * ($h * 0.44)
        $pts.Add((New-Object System.Windows.Point($px, $py)))
    }
    $poly.Points = $pts
    [void]$script:EqCanvas.Children.Add($poly)
}

function Sync-ControlsFromState {
    $script:SuppressEvents = $true
    try {
        $script:MasterPowerChk.IsChecked  = $script:State.Enabled
        $script:SubSlider.Value           = $script:State.SubDb
        $script:BassSlider.Value          = $script:State.BassDb
        $script:VocalSlider.Value         = $script:State.VocalDb
        $script:LpfEnableChk.IsChecked    = $script:State.LpfEnabled
        $script:LpfSlopeChk.IsChecked     = $script:State.LpfSlope24
        $script:LpfSlider.Value           = Convert-LpfHzToSlider $script:State.LpfFreqHz
        $script:AutoHeadroomChk.IsChecked = $script:State.AutoHeadroom
        $script:PreampSlider.Value        = $script:State.PreampDb
        $script:PreampSlider.IsEnabled    = -not $script:State.AutoHeadroom
        $script:LpfSlider.IsEnabled       = $script:State.LpfEnabled
        $script:LpfSlopeChk.IsEnabled     = $script:State.LpfEnabled

        $script:SubValText.Text    = Format-DbLabel $script:State.SubDb
        $script:BassValText.Text   = Format-DbLabel $script:State.BassDb
        $script:VocalValText.Text  = Format-DbLabel $script:State.VocalDb
        $script:LpfValText.Text    = if ($script:State.LpfEnabled) { Format-FreqLabel $script:State.LpfFreqHz } else { 'OFF' }
        $script:PreampValText.Text = Format-DbLabel (Get-EffectivePreampDb)

        $script:MasterPowerChk.Foreground = if ($script:State.Enabled) {
            $script:BrushConverter.ConvertFromString('#22C55E')
        } else {
            $script:BrushConverter.ConvertFromString('#94A3B8')
        }
    } finally {
        $script:SuppressEvents = $false
    }
    Render-EqCurve
}

# 35ms debounce timer for smooth real-time disk writes while dragging sliders
$script:WriteTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WriteTimer.Interval = [TimeSpan]::FromMilliseconds(35)
$script:WriteTimer.Add_Tick({
    $script:WriteTimer.Stop()
    Write-LiveEqFile
    Save-EqState
})

function On-EqChanged {
    if ($script:SuppressEvents) { return }
    $script:State.Enabled      = [bool]$script:MasterPowerChk.IsChecked
    $script:State.SubDb        = [math]::Round($script:SubSlider.Value, 1)
    $script:State.BassDb       = [math]::Round($script:BassSlider.Value, 1)
    $script:State.VocalDb      = [math]::Round($script:VocalSlider.Value, 1)
    $script:State.LpfEnabled   = [bool]$script:LpfEnableChk.IsChecked
    $script:State.LpfSlope24   = [bool]$script:LpfSlopeChk.IsChecked
    $script:State.LpfFreqHz    = [math]::Round((Convert-SliderToLpfHz $script:LpfSlider.Value), 0)
    $script:State.AutoHeadroom = [bool]$script:AutoHeadroomChk.IsChecked
    $script:State.PreampDb     = [math]::Round($script:PreampSlider.Value, 1)

    $script:PreampSlider.IsEnabled = -not $script:State.AutoHeadroom
    $script:LpfSlider.IsEnabled    = $script:State.LpfEnabled
    $script:LpfSlopeChk.IsEnabled  = $script:State.LpfEnabled

    $script:SubValText.Text    = Format-DbLabel $script:State.SubDb
    $script:BassValText.Text   = Format-DbLabel $script:State.BassDb
    $script:VocalValText.Text  = Format-DbLabel $script:State.VocalDb
    $script:LpfValText.Text    = if ($script:State.LpfEnabled) { Format-FreqLabel $script:State.LpfFreqHz } else { 'OFF' }
    $script:PreampValText.Text = Format-DbLabel (Get-EffectivePreampDb)
    $script:MasterPowerChk.Foreground = if ($script:State.Enabled) {
        $script:BrushConverter.ConvertFromString('#22C55E')
    } else {
        $script:BrushConverter.ConvertFromString('#94A3B8')
    }

    Render-EqCurve
    $script:WriteTimer.Stop()
    $script:WriteTimer.Start()
}

function Apply-Preset {
    param([double]$Sub, [double]$Bass, [double]$Vocal, [bool]$LpfOn, [double]$LpfHz, [bool]$Steep)
    $script:State.Enabled    = $true
    $script:State.SubDb      = $Sub
    $script:State.BassDb     = $Bass
    $script:State.VocalDb    = $Vocal
    $script:State.LpfEnabled = $LpfOn
    $script:State.LpfFreqHz  = $LpfHz
    $script:State.LpfSlope24 = $Steep
    Sync-ControlsFromState
    Write-LiveEqFile
    Save-EqState
}
#endregion

#region Event Wiring
$script:SubSlider.Add_ValueChanged({ On-EqChanged })
$script:BassSlider.Add_ValueChanged({ On-EqChanged })
$script:VocalSlider.Add_ValueChanged({ On-EqChanged })
$script:LpfSlider.Add_ValueChanged({ On-EqChanged })
$script:PreampSlider.Add_ValueChanged({ On-EqChanged })

$script:MasterPowerChk.Add_Click({ On-EqChanged })
$script:LpfEnableChk.Add_Click({ On-EqChanged })
$script:LpfSlopeChk.Add_Click({ On-EqChanged })
$script:AutoHeadroomChk.Add_Click({ On-EqChanged })

$script:PresetFlat.Add_Click({  Apply-Preset 0.0  0.0  0.0  $false 18000.0 $false })
$script:PresetSub.Add_Click({   Apply-Preset 7.0  2.0  0.5  $false 18000.0 $false })
$script:PresetBass.Add_Click({  Apply-Preset 4.0  5.5  1.0  $false 18000.0 $false })
$script:PresetVocal.Add_Click({ Apply-Preset -1.0 -1.5 5.0  $false 18000.0 $false })
$script:PresetLofi.Add_Click({  Apply-Preset 3.0  2.5  -1.0 $true  3200.0  $false })
$script:PresetCustom.Add_Click({
    $c = $script:State.CustomPreset
    Apply-Preset ([double]$c.SubDb) ([double]$c.BassDb) ([double]$c.VocalDb) ([bool]$c.LpfEnabled) ([double]$c.LpfFreqHz) ([bool]$c.LpfSlope24)
})
$script:SaveCustom.Add_Click({
    $script:State.CustomPreset = [PSCustomObject]@{
        SubDb      = $script:State.SubDb
        BassDb     = $script:State.BassDb
        VocalDb    = $script:State.VocalDb
        LpfEnabled = $script:State.LpfEnabled
        LpfFreqHz  = $script:State.LpfFreqHz
        LpfSlope24 = $script:State.LpfSlope24
    }
    Save-EqState
    $script:FooterHintText.Text = 'Saved current Sub, Bass, Vocal & Low-Pass settings to "My Custom".'
})

$script:ApoActionBtn.Add_Click({
    $info = Get-EqualizerApoInfo
    if (-not $info.Installed) {
        Start-Process 'https://sourceforge.net/projects/equalizerapo/'
        $script:FooterHintText.Text = 'Opened Equalizer APO download page. Install it, select your audio devices, reboot, then click "Link to Equalizer APO".'
    } else {
        $ok = Link-EqualizerApoConfig
        Refresh-ApoStatusBadge
        if ($ok) {
            Write-LiveEqFile
            $script:FooterHintText.Text = 'Linked! SystemEQ is now live across Spotify, browsers, and all enabled output devices.'
        } else {
            $script:FooterHintText.Text = 'Could not link config.txt. Try approving the Windows permission prompt and clicking again.'
        }
    }
})

$script:DevicesBtn.Add_Click({
    $info = Get-EqualizerApoInfo
    if ($info.SelectorExe -and (Test-Path $info.SelectorExe)) {
        try {
            Start-Process -FilePath $info.SelectorExe -WorkingDirectory $info.InstallDir -Verb RunAs
            $script:FooterHintText.Text = 'Check your speakers/earbuds, click OK, then click "Restart Audio" (or reboot).'
        } catch {}
    }
})

$script:RestartAudioBtn.Add_Click({
    try {
        $script:FooterHintText.Text = 'Restarting Windows Audio service...'
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Restart-Service -Name Audiosrv -Force') -Verb RunAs -PassThru -Wait
        if ($proc.ExitCode -eq 0) {
            Write-LiveEqFile
            $script:FooterHintText.Text = 'Audio engine restarted! Play audio in Spotify/browser and drag a slider to test.'
        } else {
            $script:FooterHintText.Text = 'Could not restart Audio service. Try rebooting Windows once.'
        }
    } catch {
        $script:FooterHintText.Text = 'Audio restart cancelled.'
    }
})

$script:ShortcutBtn.Add_Click({
    try {
        Install-AppShortcuts
        $script:FooterHintText.Text = 'Added SystemEQ to your Start Menu and Desktop - you can now search "SystemEQ" in Windows to open it.'
    } catch {
        $script:FooterHintText.Text = 'Could not create shortcut: ' + $_.Exception.Message
    }
})

$script:EqCanvas.Add_SizeChanged({ Render-EqCurve })

$script:Window.Add_Loaded({
    $info = Get-EqualizerApoInfo
    if ($info.Installed -and -not $info.IsLinked) {
        [void](Link-EqualizerApoConfig)
    }
    Refresh-ApoStatusBadge
    Sync-ControlsFromState
    Write-LiveEqFile
})

$script:Window.Add_Closed({
    try { $script:WriteTimer.Stop() } catch {}
    Save-EqState
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch {}
        $script:Mutex.Dispose()
    }
})
#endregion

[void]$script:Window.ShowDialog()
