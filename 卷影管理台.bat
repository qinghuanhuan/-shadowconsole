@echo off
rem VSS Shadow Console - single-file distribution (auto-extract & hidden launch)
rem Embedded PS1 snapshot: 2026-08-13 20:17
setlocal
set "PSRUN=%TEMP%\shadowconsole\vss_console_run.ps1"
rem Tell embedded PS1 where the real (bat) file is, so config writes back to this bat itself
set "VSS_SELF=%~f0"
if not exist "%TEMP%\shadowconsole" mkdir "%TEMP%\shadowconsole"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$s=[IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8);$a='__'+'VSS_PS1_BEGIN__';$b='__'+'VSS_PS1_END__';$i=$s.IndexOf($a)+$a.Length;$j=$s.IndexOf($b,$i);$p='%~f0';$body='$script:VssSelfFile = '''+$p+''';'+[char]13+[char]10+$s.Substring($i,$j-$i);[IO.File]::WriteAllText($env:TEMP+'\shadowconsole\vss_console_run.ps1',$body,[Text.UTF8Encoding]::new($true))"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PSRUN%"
rem 注意: 不删除临时文件(UAC 提权重启的进程延迟几秒才读它, 删了会竞态致 GUI 不启动);
rem 固定路径 %TEMP%\shadowconsole\vss_console_run.ps1, 每次启动重新提取覆盖
endlocal
exit /b
__VSS_PS1_BEGIN__<#
  卷影管理台 VSS Shadow Console
  用法: powershell -ExecutionPolicy Bypass -File VSS-Console.ps1   或双击 启动管理台.cmd
  仅两种模式: 管理员(提权自举) / 只读(提权被拒或非管理员)
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Drawing

# 隐藏 PowerShell 控制台窗口: GUI 由 PS 进程承载无法退出,只能隐藏窗口
# (cmd 启动已用 -WindowStyle Hidden, 此处兜底覆盖"直接右键 PowerShell 运行"场景)
try {
  if (-not ('ConsoleHider' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleHider {
  [DllImport("kernel32.dll")]
  public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
  }
  $hw = [ConsoleHider]::GetConsoleWindow()
  if ($hw -ne [IntPtr]::Zero) { [void][ConsoleHider]::ShowWindow($hw, 0) }
} catch {}

$script:VssAdmin  = Join-Path $env:SystemRoot 'System32\vssadmin.exe'
$script:Diskshadow = Join-Path $env:SystemRoot 'System32\diskshadow.exe'
$g = Get-Command vssadmin.exe -ErrorAction SilentlyContinue
if ($g) { $script:VssAdmin = $g.Source }
$g = Get-Command diskshadow.exe -ErrorAction SilentlyContinue
if ($g) { $script:Diskshadow = $g.Source }
$g = $null
$script:AppName = '卷影管理台'
$script:Log = New-Object System.Collections.Generic.List[object]
$script:FilterLetter = $null
$script:CanAct = $false
$script:ConfirmFrame = $null
$script:ResizeFrame = $null
$script:ConfirmResult = $false
$script:ResizeResult = $null
$script:ElevationDenied = $false
$script:InvCulture = [Globalization.CultureInfo]::InvariantCulture

$script:ThemeLight = @{
  C_Bg='#F3F5F8'; C_Panel='#FFFFFF'; C_Border='#DDE1E8'; C_Divider='#ECF0F4'
  C_Ink='#1B212B'; C_Sub='#5B6472'; C_Faint='#929BA8'
  C_Accent='#2F6BF4'; C_AccentHover='#1D5AE0'; C_AccentDown='#174CBF'
  C_AccentSoft='#EAF1FE'; C_AccentSoftHover='#DDE9FD'; C_OnAccent='#FFFFFF'
  C_Danger='#D64545'; C_DangerHover='#C03939'; C_DangerDown='#A93333'; C_DangerSoft='#FBEFEF'
  C_Success='#1E9E5A'; C_SuccessSoft='#EBF7F1'
  C_Warn='#B7791F'; C_WarnSoft='#FBF3E3'
  C_SurfaceHover='#F7F9FC'; C_Overlay='#66000000'; C_ScrollThumb='#D0D5DC'
}
$script:ThemeDark = @{
  C_Bg='#14161A'; C_Panel='#1D2026'; C_Border='#2E333C'; C_Divider='#262B33'
  C_Ink='#F2F4F8'; C_Sub='#9AA3B2'; C_Faint='#67707F'
  C_Accent='#5B8DF6'; C_AccentHover='#7AA6FF'; C_AccentDown='#4E7DDE'
  C_AccentSoft='#1C2A4A'; C_AccentSoftHover='#24375F'; C_OnAccent='#FFFFFF'
  C_Danger='#F26D6D'; C_DangerHover='#FF8080'; C_DangerDown='#E14F4F'; C_DangerSoft='#3A2222'
  C_Success='#3FBF75'; C_SuccessSoft='#1D352A'
  C_Warn='#E5B23C'; C_WarnSoft='#39301C'
  C_SurfaceHover='#232730'; C_Overlay='#B4000000'; C_ScrollThumb='#3A404B'
}
# 配置修改自身(内嵌于脚本尾部配置区), 零外部文件; bat 分发由 bat 设置 VSS_SELF
$script:ThemeMode = 'System'
$script:WriterStates = @{ 1='稳定'; 2='等待冻结'; 3='等待解冻'; 4='解冻后待命'; 5='失败'; 6='冻结失败'; 7='释放失败'; 8='解冻失败' }

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# 若在 PowerShell ISE / VS Code 集成终端等 GUI 宿主中直接运行,先切换到控制台版 powershell.exe
# (ISE 的 powershell_ise.exe 不支持 -ExecutionPolicy/-File 参数,且 WPF 消息循环在 ISE runspace 内不工作)
$hostName = ''
try { $hostName = $Host.Name } catch {}
$hostExe = (Get-Process -Id $PID).Path
$guiHost = ($hostName -match 'ISE|Visual Studio Code Host' -or $hostExe -match 'powershell_ise\.exe|pwsh_ise\.exe|Code\.exe')
if ($guiHost) {
  try {
    $consoleExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $consoleExe)) { $consoleExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if ($consoleExe) {
      Start-Process -FilePath $consoleExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"") | Out-Null
      exit 0
    }
  } catch {}
}
# 非管理员 → 尝试提权重启(UAC); 用户拒绝 → 只读模式
if (-not $script:IsAdmin) {
  try {
    Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"") -Verb RunAs | Out-Null
    exit 0
  } catch { $script:ElevationDenied = $true }
}
if ($script:IsAdmin) { $script:CanAct = $true }

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="卷影管理台 · VSS Shadow Console" Width="1180" Height="780" MinWidth="980" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource C_Bg}" ShowInTaskbar="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="C_Bg" Color="#F3F5F8"/>
    <SolidColorBrush x:Key="C_Panel" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="C_Border" Color="#DDE1E8"/>
    <SolidColorBrush x:Key="C_Divider" Color="#ECF0F4"/>
    <SolidColorBrush x:Key="C_Ink" Color="#1B212B"/>
    <SolidColorBrush x:Key="C_Sub" Color="#5B6472"/>
    <SolidColorBrush x:Key="C_Faint" Color="#929BA8"/>
    <SolidColorBrush x:Key="C_Accent" Color="#2F6BF4"/>
    <SolidColorBrush x:Key="C_AccentHover" Color="#1D5AE0"/>
    <SolidColorBrush x:Key="C_AccentDown" Color="#174CBF"/>
    <SolidColorBrush x:Key="C_AccentSoft" Color="#EAF1FE"/>
    <SolidColorBrush x:Key="C_AccentSoftHover" Color="#DDE9FD"/>
    <SolidColorBrush x:Key="C_OnAccent" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="C_Danger" Color="#D64545"/>
    <SolidColorBrush x:Key="C_DangerHover" Color="#C03939"/>
    <SolidColorBrush x:Key="C_DangerDown" Color="#A93333"/>
    <SolidColorBrush x:Key="C_DangerSoft" Color="#FBEFEF"/>
    <SolidColorBrush x:Key="C_Success" Color="#1E9E5A"/>
    <SolidColorBrush x:Key="C_SuccessSoft" Color="#EBF7F1"/>
    <SolidColorBrush x:Key="C_Warn" Color="#B7791F"/>
    <SolidColorBrush x:Key="C_WarnSoft" Color="#FBF3E3"/>
    <SolidColorBrush x:Key="C_SurfaceHover" Color="#F7F9FC"/>
    <SolidColorBrush x:Key="C_Overlay" Color="#66000000"/>
    <SolidColorBrush x:Key="C_ScrollThumb" Color="#D0D5DC"/>

    <!-- 统一滚动条:透明轨道 + 圆角拇指(跟随主题 C_ScrollThumb/C_Sub/C_Faint), 隐藏翻页按钮 -->
    <Style x:Key="st_scrollPageButton" TargetType="RepeatButton">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="st_scrollThumb" TargetType="Thumb">
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="bd" Background="{DynamicResource C_ScrollThumb}" CornerRadius="3" Margin="2,1"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource C_Sub}"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource C_Faint}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource st_scrollPageButton}"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource st_scrollPageButton}"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource st_scrollThumb}"/>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Vertical">
                <Setter Property="Width" Value="10"/>
              </Trigger>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter Property="Height" Value="10"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_icon" TargetType="Path">
      <Setter Property="Stroke" Value="{DynamicResource C_Sub}"/>
      <Setter Property="StrokeThickness" Value="1.5"/>
      <Setter Property="StrokeStartLineCap" Value="Square"/>
      <Setter Property="StrokeEndLineCap" Value="Square"/>
      <Setter Property="StrokeLineJoin" Value="Miter"/>
      <Setter Property="Fill" Value="{x:Null}"/>
    </Style>
    <Style x:Key="st_iconAccent" TargetType="Path" BasedOn="{StaticResource st_icon}">
      <Setter Property="Stroke" Value="{DynamicResource C_Accent}"/>
    </Style>

    <Style x:Key="st_btnPrimary" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource C_OnAccent}"/>
      <Setter Property="Background" Value="{DynamicResource C_Accent}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Accent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentHover}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_AccentHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentDown}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_AccentDown}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoft}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_AccentSoft}"/><Setter Property="Foreground" Value="{DynamicResource C_Faint}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_btnSecondary" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_SurfaceHover}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_Accent}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoft}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource C_Faint}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_Divider}"/><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_Bg}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_btnDanger" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Background" Value="{DynamicResource C_Danger}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Danger}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_DangerHover}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_DangerHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_DangerDown}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_DangerDown}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_DangerSoft}"/><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_DangerSoft}"/><Setter Property="Foreground" Value="{DynamicResource C_Faint}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_btnGhost" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource C_Sub}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoft}"/><Setter Property="Foreground" Value="{DynamicResource C_Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource C_Faint}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_btnLinkDanger" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource C_Danger}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Padding" Value="6,0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_DangerSoft}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource C_Faint}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_btnIcon" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Width" Value="32"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoft}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoftHover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_nav" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource C_Sub}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_SurfaceHover}"/><Setter Property="Foreground" Value="{DynamicResource C_Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_chip" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource C_AccentSoft}"/>
      <Setter Property="Padding" Value="7,2"/>
      <Setter Property="Height" Value="20"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="st_chipText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource C_Accent}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="st_input" TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="Padding" Value="6,2"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush" Value="{DynamicResource C_Accent}"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <!-- 关闭触摸交互(桌面鼠标工具): 触摸平移/操作/长按/轻拂/触摸反馈 -->
      <Setter Property="ScrollViewer.PanningMode" Value="None"/>
      <Setter Property="IsManipulationEnabled" Value="False"/>
      <Setter Property="Stylus.IsPressAndHoldEnabled" Value="False"/>
      <Setter Property="Stylus.IsFlicksEnabled" Value="False"/>
      <Setter Property="Stylus.IsTapFeedbackEnabled" Value="False"/>
      <Setter Property="Stylus.IsTouchFeedbackEnabled" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource C_Faint}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_inputMono" TargetType="TextBox" BasedOn="{StaticResource st_input}">
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style x:Key="st_console" TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <!-- 关闭触摸交互(桌面鼠标工具) -->
      <Setter Property="ScrollViewer.PanningMode" Value="None"/>
      <Setter Property="IsManipulationEnabled" Value="False"/>
      <Setter Property="Stylus.IsPressAndHoldEnabled" Value="False"/>
      <Setter Property="Stylus.IsFlicksEnabled" Value="False"/>
      <Setter Property="Stylus.IsTapFeedbackEnabled" Value="False"/>
      <Setter Property="Stylus.IsTouchFeedbackEnabled" Value="False"/>
    </Style>

    <Style x:Key="st_pageTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="st_mono" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Sub}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="st_list" TargetType="ListView">
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
      <!-- 关闭全部原生触摸交互(桌面鼠标工具不优化触屏): 触摸平移/操作/长按/轻拂/触摸反馈 —
           避免 WPF 触摸输入管道干扰鼠标操作流畅性 -->
      <Setter Property="ScrollViewer.PanningMode" Value="None"/>
      <Setter Property="IsManipulationEnabled" Value="False"/>
      <Setter Property="Stylus.IsPressAndHoldEnabled" Value="False"/>
      <Setter Property="Stylus.IsFlicksEnabled" Value="False"/>
      <Setter Property="Stylus.IsTapFeedbackEnabled" Value="False"/>
      <Setter Property="Stylus.IsTouchFeedbackEnabled" Value="False"/>
    </Style>

    <Style x:Key="st_listItem" TargetType="ListViewItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <!-- 高亮分离: 背景(Border)与内容(GridViewRowPresenter)分层 — 内容层独立位图缓存,
                 选中/悬停变化只重绘背景纯色层, 文字内容直接叠加缓存位图, 不重新光栅化(解决选中行不跟手) -->
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderThickness="0,0,0,1" BorderBrush="{DynamicResource C_Divider}">
              <GridViewRowPresenter Content="{TemplateBinding Content}" Columns="{TemplateBinding GridView.ColumnCollection}" VerticalAlignment="Center" Margin="8,0,8,0">
                <GridViewRowPresenter.CacheMode>
                  <BitmapCache EnableClearType="False"/>
                </GridViewRowPresenter.CacheMode>
              </GridViewRowPresenter>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_SurfaceHover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoft}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_listHeader" TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="{DynamicResource C_Bg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding" Value="10,0,10,0"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Sub}"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <!-- 碎片化位图缓存: 列头缓存为位图(固定不滚动), 悬停/排序箭头变化时自动重建 -->
      <Setter Property="CacheMode">
        <Setter.Value>
          <BitmapCache EnableClearType="False"/>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
                <Thumb x:Name="PART_HeaderGripper" Grid.Column="1" Width="5" Margin="-1,0,0,0" Cursor="SizeWE">
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="Transparent">
                        <Rectangle Width="1" Fill="{DynamicResource C_Border}" HorizontalAlignment="Right" Margin="0,4,0,4"/>
                      </Border>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource C_SurfaceHover}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12"/>
      <!-- 碎片化位图缓存: 卷卡片渲染缓存为位图, 选中高亮/数据变化时重建 -->
      <Setter Property="CacheMode">
        <Setter.Value>
          <BitmapCache EnableClearType="False"/>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_radio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>

    <Style x:Key="st_combo" TargetType="ComboBox">
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Padding" Value="6,2"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <ContentPresenter x:Name="contentPresenter" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" IsHitTestVisible="False" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                  <Path Grid.Column="1" Data="M3,5.2 L9,5.2 L6,8.4 Z" Fill="{DynamicResource C_Sub}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                </Grid>
              </Border>
              <!-- 关键:覆盖整个区域的 ToggleButton,负责鼠标点击开合下拉(IsChecked <-> IsDropDownOpen 双向绑定),缺失则点击无反应 -->
              <ToggleButton ClickMode="Press" Focusable="False" FocusVisualStyle="{x:Null}" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}" Margin="0,1,0,0" SnapsToDevicePixels="True">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_Accent}"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_Accent}"/></Trigger>
              <Trigger Property="IsDropDownOpen" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource C_Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource C_Faint}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="st_comboItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoft}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_AccentSoft}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="48"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="28"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,0,1">
      <Grid Margin="14,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Path Width="16" Height="16" Data="M4.5,7 L13,7 L13,15.5 L4.5,15.5 Z" Stroke="{DynamicResource C_Accent}" StrokeThickness="1.5" StrokeLineJoin="Miter"/>
          <Path Width="16" Height="16" Data="M2,2 L10.5,2 L10.5,10.5 L2,10.5 Z" Fill="{DynamicResource C_Accent}" Margin="-7,0,9,0"/>
          <StackPanel>
            <TextBlock Text="卷影管理台" FontSize="16" FontWeight="SemiBold" Foreground="{DynamicResource C_Ink}" LineHeight="20"/>
            <TextBlock Text="VSS SHADOW CONSOLE" FontSize="9.5" Foreground="{DynamicResource C_Faint}" LineHeight="12"/>
          </StackPanel>
        </StackPanel>
        <!-- 异步任务状态指示器: 后台任务执行时显示在标题右侧, 不阻塞界面 -->
        <StackPanel x:Name="spnStatus" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0" Visibility="Collapsed">
          <Border x:Name="spnDot" Width="10" Height="10" BorderBrush="{DynamicResource C_Accent}" BorderThickness="1.5" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform><RotateTransform x:Name="spinMini" Angle="0"/></Border.RenderTransform>
          </Border>
          <TextBlock x:Name="txtStatus" FontSize="11.5" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center" Margin="8,0,0,0" TextTrimming="CharacterEllipsis" MaxWidth="420"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="btnTheme" Style="{StaticResource st_btnIcon}" ToolTip="切换明暗主题">
            <Path x:Name="iconTheme" Width="15" Height="15" Style="{StaticResource st_icon}" Data="M9.6,2 A5.6,5.6 0 1 0 14,9.2 A4.4,4.4 0 1 1 9.6,2 Z"/>
          </Button>
          <Button x:Name="btnRefresh" Style="{StaticResource st_btnIcon}" ToolTip="刷新 (F5)" Margin="4,0,0,0">
            <Path Width="15" Height="15" Style="{StaticResource st_icon}" Data="M14.9,2.6 L14.9,6.5 L11,6.5 M0.6,12.9 L0.6,9 L4.5,9 M2.3,5.8 A5.8,5.8 0 0 1 11.9,3.6 L14.9,6.5 M0.7,9 L3.7,11.9 A5.8,5.8 0 0 0 13.2,9.7"/>
          </Button>
        </StackPanel>
      </Grid>
    </Border>

    <Border x:Name="bannerNoAdmin" Grid.Row="1" Background="{DynamicResource C_WarnSoft}" BorderBrush="{DynamicResource C_Warn}" BorderThickness="0,0,0,1" Visibility="Collapsed">
      <Grid Margin="14,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <Path Width="14" Height="14" Style="{StaticResource st_icon}" Data="M8,2 L14.6,14 L1.4,14 Z" Stroke="{DynamicResource C_Warn}" Margin="0,0,8,0"/>
          <TextBlock x:Name="txtBanner" Foreground="{DynamicResource C_Warn}" FontSize="12.5" VerticalAlignment="Center" Text="未检测到管理员权限,当前为只读模式,操作按钮已禁用。"/>
        </StackPanel>
        <Button x:Name="btnRelaunch" Grid.Column="1" Content="以管理员身份重新启动" Style="{StaticResource st_btnSecondary}" Height="26" Padding="12,0"/>
      </Grid>
    </Border>

    <Grid Grid.Row="2" x:Name="mainGrid">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="196" MinWidth="150" MaxWidth="340"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,1,0">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel>
            <Button x:Name="navShadows" Style="{StaticResource st_nav}">
              <StackPanel Orientation="Horizontal">
                <Path Width="15" Height="15" Data="M5,7 L13.5,7 L13.5,15.5 L5,15.5 Z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.5" StrokeLineJoin="Miter"/>
                <Path Width="15" Height="15" Data="M2.5,2.5 L11,2.5 L11,11 L2.5,11 Z" Fill="{DynamicResource C_Accent}" Margin="-8,0,7,0"/>
                <TextBlock Text="卷影副本" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="navStorage" Style="{StaticResource st_nav}">
              <StackPanel Orientation="Horizontal">
                <Path Width="15" Height="15" Style="{StaticResource st_icon}" Data="M2,2.5 L14,2.5 L14,13.5 L2,13.5 Z M4.5,10.8 L6.5,10.8 L6.5,13 L4.5,13 Z M7.5,7.8 L9.5,7.8 L9.5,13 L7.5,13 Z M10.5,4.8 L12.5,4.8 L12.5,13 L10.5,13 Z"/>
                <TextBlock Text="存储配额" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="navDiskShadow" Style="{StaticResource st_nav}">
              <StackPanel Orientation="Horizontal">
                <Path Width="15" Height="15" Style="{StaticResource st_icon}" Data="M3,1.5 L11,1.5 L13.5,4 L13.5,14.5 L3,14.5 Z M3,1.5 L3,4 L13.5,4 M7,7 L11,7 M7,9.5 L11,9.5 M7,12 L11,12"/>
                <TextBlock Text="计划任务" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="navLog" Style="{StaticResource st_nav}">
              <StackPanel Orientation="Horizontal">
                <Path Width="15" Height="15" Style="{StaticResource st_icon}" Data="M2,4.2 L14,4.2 M2,8 L14,8 M2,11.8 L14,11.8"/>
                <TextBlock Text="命令日志" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
            <Button x:Name="navSysInfo" Style="{StaticResource st_nav}">
              <StackPanel Orientation="Horizontal">
                <Path Width="15" Height="15" Style="{StaticResource st_icon}" Data="M7.8,1.8 L13.2,7.2 L13.2,13.8 L2.4,13.8 L2.4,7.2 Z M5,5.5 L10.6,5.5 M5,8.5 L10.6,8.5 M5,11.5 L8.5,11.5"/>
                <TextBlock Text="系统信息" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
          </StackPanel>

          <Border Grid.Row="2" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="10">
            <StackPanel>
              <TextBlock Text="写时复制 COPY-ON-WRITE" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource C_Faint}"/>
              <TextBlock Text="VSS 卷影在首次写入时才复制数据块,创建近乎瞬时,空间按需占用。" FontSize="11.5" Foreground="{DynamicResource C_Sub}" TextWrapping="Wrap" Margin="0,5,0,4"/>
              <Button x:Name="btnDocs" Style="{StaticResource st_btnGhost}" Height="20" Padding="0" HorizontalContentAlignment="Left">
                <TextBlock Text="Microsoft 文档 →" FontSize="11.5" Foreground="{DynamicResource C_Accent}" TextDecorations="Underline"/>
              </Button>
            </StackPanel>
          </Border>
        </Grid>
      </Border>
      <GridSplitter x:Name="splitNav" Grid.Column="1" Width="5" HorizontalAlignment="Center" VerticalAlignment="Stretch" Background="Transparent" ShowsPreview="False" Cursor="SizeWE" ToolTip="拖拽调整左侧宽度">
        <GridSplitter.Style>
          <Style TargetType="GridSplitter">
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="GridSplitter">
                  <Border Background="Transparent">
                    <Rectangle Width="1" Fill="{DynamicResource C_Border}" HorizontalAlignment="Center"/>
                  </Border>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </GridSplitter.Style>
      </GridSplitter>
<Grid Grid.Column="2" Margin="20,16,20,12">
        <Grid x:Name="pageShadows">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="220" MinHeight="120" MaxHeight="400"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="卷影副本" Style="{StaticResource st_pageTitle}"/>
              <Border x:Name="chipFilter" Style="{StaticResource st_chip}" Margin="10,0,0,0" Visibility="Collapsed" Cursor="Hand" ToolTip="点击取消筛选">
                <TextBlock x:Name="txtFilter" Style="{StaticResource st_chipText}"/>
              </Border>
              <Border x:Name="chipBrowse" Style="{StaticResource st_chip}" Margin="8,0,0,0" Visibility="Collapsed" Cursor="Hand" ToolTip="打开卷影浏览">
                <TextBlock x:Name="txtBrowse" Style="{StaticResource st_chipText}"/>
              </Border>
            </StackPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
              <Button x:Name="btnShadowCreate" Content="创建卷影" Style="{StaticResource st_btnPrimary}" IsEnabled="False"/>
              <Button x:Name="btnShadowOldest" Content="删除最旧" Style="{StaticResource st_btnSecondary}" Margin="8,0,0,0" IsEnabled="False"/>
              <Button x:Name="btnShadowAll" Content="全部删除" Style="{StaticResource st_btnDanger}" Margin="8,0,0,0" IsEnabled="False"/>
            </StackPanel>
          </Grid>

          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <ItemsControl x:Name="cardHost">
              <ItemsControl.ItemsPanel>
                <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
              </ItemsControl.ItemsPanel>
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border x:Name="card" Width="236" Margin="0,0,10,10" Cursor="Hand">
                    <Border.Style>
                      <Style TargetType="Border" BasedOn="{StaticResource st_card}">
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding Active}" Value="True">
                            <Setter Property="BorderBrush" Value="{DynamicResource C_Accent}"/>
                            <Setter Property="BorderThickness" Value="2"/>
                          </DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </Border.Style>
                    <Grid>
                      <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                      </Grid.RowDefinitions>
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="{Binding Letter}" FontSize="22" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI" Foreground="{DynamicResource C_Ink}"/>
                        <Border Grid.Column="1" Style="{StaticResource st_chip}" HorizontalAlignment="Right">
                          <TextBlock Text="{Binding ShadowCountText}" Style="{StaticResource st_chipText}"/>
                        </Border>
                      </Grid>
                      <TextBlock Grid.Row="1" Text="{Binding Label}" Foreground="{DynamicResource C_Sub}" FontSize="12.5" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
                      <TextBlock Grid.Row="2" Text="{Binding SpaceText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource C_Faint}" Margin="0,2,0,0"/>
                      <Grid Grid.Row="3" Margin="0,9,0,9">
                        <Border Height="6" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
                          <Grid>
                            <Grid.ColumnDefinitions>
                              <ColumnDefinition Width="{Binding BarUsed}"/>
                              <ColumnDefinition Width="{Binding BarFree}"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Height="4" Background="{DynamicResource C_Accent}" VerticalAlignment="Bottom"/>
                          </Grid>
                        </Border>
                      </Grid>
                      <Grid Grid.Row="4">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="{Binding NewestText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                          <Button Name="btnCardCreate" Content="创建卷影" Style="{StaticResource st_btnPrimary}" Height="26" Padding="10,0" FontSize="12" IsEnabled="{Binding CanAct}" Tag="{Binding Letter}"/>
                          <Button Name="btnCardQuota" Content="配额" Style="{StaticResource st_btnSecondary}" Height="26" Padding="10,0" FontSize="12" Margin="6,0,0,0" IsEnabled="{Binding CanAct}" Tag="{Binding Letter}"/>
                        </StackPanel>
                      </Grid>
                    </Grid>
                  </Border>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>

          <GridSplitter x:Name="splitCard" Grid.Row="2" Height="5" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="Transparent" Cursor="SizeNS" ToolTip="拖拽调整卡片/列表高度">
            <GridSplitter.Style>
              <Style TargetType="GridSplitter">
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="GridSplitter">
                      <Border Background="Transparent">
                        <Rectangle Height="1" Fill="{DynamicResource C_Border}" VerticalAlignment="Center"/>
                      </Border>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </GridSplitter.Style>
          </GridSplitter>

          <Grid Grid.Row="3">
            <ListView x:Name="lstShadows" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}">
              <ListView.ContextMenu>
                <ContextMenu>
                  <MenuItem x:Name="miBrowseOpen" Header="打开浏览"/>
                  <MenuItem x:Name="miBrowseCopy" Header="复制设备路径"/>
                </ContextMenu>
              </ListView.ContextMenu>
              <ListView.View>
                <GridView>
                  <GridView.ColumnHeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                  </GridView.ColumnHeaderContainerStyle>
                  <GridViewColumn Header="创建时间" Width="128">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding CreatedText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="卷" Width="46">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Letter}" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="阴影 ID" Width="250">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTipService.InitialShowDelay="1200" ToolTipService.BetweenShowDelay="0"><TextBlock.ToolTip><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}"/></TextBlock.ToolTip></TextBlock></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="设备对象" Width="280">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Device}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTipService.InitialShowDelay="1200" ToolTipService.BetweenShowDelay="0"><TextBlock.ToolTip><TextBlock Text="{Binding Device}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}"/></TextBlock.ToolTip></TextBlock></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="属性" Width="170">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding TypeText}" FontSize="12" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="操作" Width="70">
                    <GridViewColumn.CellTemplate>
                      <DataTemplate>
                        <Button Name="btnShadowDelete" Content="删除" Style="{StaticResource st_btnLinkDanger}" IsEnabled="{Binding CanAct}" Tag="{Binding Id}"/>
                      </DataTemplate>
                    </GridViewColumn.CellTemplate>
                  </GridViewColumn>
                </GridView>
              </ListView.View>
            </ListView>
            <StackPanel x:Name="emptyShadows" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <Path Width="34" Height="34" Data="M10,16 L26,16 L26,32 L10,32 Z" Stroke="{DynamicResource C_Border}" StrokeThickness="1.5"/>
                <Path Width="34" Height="34" Data="M4,4 L20,4 L20,20 L4,20 Z" Fill="{DynamicResource C_AccentSoft}" Margin="-18,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="txtEmptyTitle" Text="尚无卷影副本" FontSize="14" FontWeight="SemiBold" Foreground="{DynamicResource C_Sub}" HorizontalAlignment="Center" Margin="0,12,0,4"/>
              <TextBlock x:Name="txtEmptySub" Text="点击卷卡片上的 创建卷影,写时复制会在数秒内完成快照。" FontSize="12" Foreground="{DynamicResource C_Faint}" HorizontalAlignment="Center"/>
            </StackPanel>
          </Grid>
        </Grid>
<Grid x:Name="pageStorage" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="存储配额" Style="{StaticResource st_pageTitle}"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="btnStorageResize" Content="调整配额…" Style="{StaticResource st_btnSecondary}" IsEnabled="False"/>
            </StackPanel>
          </Grid>
          <ListView x:Name="lstStorage" Grid.Row="1" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}">
            <ListView.View>
              <GridView>
                <GridView.ColumnHeaderContainerStyle>
                  <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                </GridView.ColumnHeaderContainerStyle>
                <GridViewColumn Header="卷" Width="46">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Letter}" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="已用空间" Width="110">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding UsedText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="已分配" Width="110">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding AllocText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="上限" Width="120">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding MaxText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="占用比例" Width="230">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Width="130" Height="6" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
                          <Grid>
                            <Grid.ColumnDefinitions>
                              <ColumnDefinition Width="{Binding BarUsed}"/>
                              <ColumnDefinition Width="{Binding BarFree}"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Height="4" Background="{DynamicResource C_Accent}" VerticalAlignment="Bottom"/>
                          </Grid>
                        </Border>
                        <TextBlock Text="{Binding PctText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="存储位置" Width="90">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding DiffLetter}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="操作" Width="70">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <Button Name="btnStorageAdjust" Content="调整" Style="{StaticResource st_btnGhost}" Height="24" IsEnabled="{Binding CanAct}"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
          <Border Grid.Row="2" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="10,6" Margin="0,10,0,0">
            <TextBlock Text="vssadmin resize shadowstorage /for=C: /on=C: /maxsize=10GB    ·    UNBOUNDED 表示自动上限" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}"/>
          </Border>
        </Grid>

        <Grid x:Name="pageDiskShadow" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="定时卷影 · 计划任务" Style="{StaticResource st_pageTitle}"/>
            <TextBlock x:Name="txtSchedHint" Grid.Column="1" Text="创建定时卷影副本计划任务,由 Windows 计划任务在指定时间自动执行" FontSize="11" Foreground="{DynamicResource C_Faint}" VerticalAlignment="Center" Margin="160,4,0,0"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="btnSchedRefresh" Content="刷新" Style="{StaticResource st_btnGhost}"/>
            </StackPanel>
          </Grid>
          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="330"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="30"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,0,1">
                  <TextBlock Text="任务列表" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource C_Sub}" Margin="10,0"/>
                </Border>
                <ListView x:Name="lstSchedTasks" Grid.Row="1" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}" ScrollViewer.HorizontalScrollBarVisibility="Auto">
                  <ListView.View>
                    <GridView>
                      <GridView.ColumnHeaderContainerStyle>
                        <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                      </GridView.ColumnHeaderContainerStyle>
                      <GridViewColumn Header="任务" Width="130">
                        <GridViewColumn.CellTemplate>
                          <DataTemplate>
                            <StackPanel Orientation="Horizontal">
                              <Border Width="7" Height="7" Background="{Binding StateBrush}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                              <TextBlock Text="{Binding TaskName}" FontSize="12" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                            </StackPanel>
                          </DataTemplate>
                        </GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="计划" Width="130">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding PlanText}" FontSize="11.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding PlanText}" ToolTipService.InitialShowDelay="1200" ToolTipService.BetweenShowDelay="0"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="状态" Width="60">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding StateText}" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="上次运行" Width="120">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding LastRunText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding LastRunText}" ToolTipService.InitialShowDelay="1200" ToolTipService.BetweenShowDelay="0"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="上次结果" Width="90">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding ResultText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding ResultHint}" ToolTipService.InitialShowDelay="1200" ToolTipService.BetweenShowDelay="0" Foreground="{Binding ResultBrush}"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="下次运行" Width="120">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding NextRunText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding NextRunText}" ToolTipService.InitialShowDelay="1200" ToolTipService.BetweenShowDelay="0"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                    </GridView>
                  </ListView.View>
                </ListView>
              </Grid>
            </Border>
            <Border Grid.Column="2" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
              <Grid Margin="16">
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <TextBlock x:Name="txtSchedTitle" Text="选择或新建一个计划任务" FontSize="14" FontWeight="SemiBold" Foreground="{DynamicResource C_Ink}"/>
                <TextBlock x:Name="txtSchedDesc" Grid.Row="1" FontSize="11.5" Foreground="{DynamicResource C_Sub}" TextWrapping="Wrap" Margin="0,6,0,0" Text="定时为所选卷创建卷影副本,旧卷影由系统存储配额自动管理。"/>
                <Grid Grid.Row="2" Margin="0,14,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="64"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="64"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="目标卷" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                  <ComboBox x:Name="cboSchedLetter" Grid.Column="1" Style="{StaticResource st_combo}" ItemContainerStyle="{StaticResource st_comboItem}" IsEditable="False"/>
                  <TextBlock Grid.Column="2" Text="计划类型" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}" Margin="10,0,0,0"/>
                  <ComboBox x:Name="cboSchedType" Grid.Column="3" Style="{StaticResource st_combo}" ItemContainerStyle="{StaticResource st_comboItem}" IsEditable="False"/>
                </Grid>
                <Grid Grid.Row="3" Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="64"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="txtSchedTimeLabel" Text="执行时间" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                  <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <TextBox x:Name="txtSchedTime" Style="{StaticResource st_inputMono}" Text="09:00" ToolTip="多个时间点用逗号分隔,如 09:00,14:00,18:00"/>
                    <StackPanel x:Name="spnFreq" Orientation="Horizontal" Visibility="Collapsed">
                      <TextBlock Text="每隔" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBox x:Name="txtSchedFreq" Style="{StaticResource st_inputMono}" Width="56" Margin="6,0" Text="5" ToolTip="重复间隔"/>
                      <TextBlock x:Name="txtSchedFreqUnit" Text="分钟" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBlock x:Name="txtSchedFreqHint" Text="(全天循环)" VerticalAlignment="Center" FontSize="11" Foreground="{DynamicResource C_Faint}" Margin="8,0,0,0"/>
                    </StackPanel>
                  </StackPanel>
                </Grid>
                <Grid Grid.Row="4" Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="64"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="txtSchedPlanLabel" Text="计划参数" VerticalAlignment="Top" FontSize="12.5" Foreground="{DynamicResource C_Sub}" Margin="0,5,0,0"/>
                  <StackPanel Grid.Column="1">
                    <WrapPanel x:Name="wpanWeek" Visibility="Collapsed">
                      <Border x:Name="chipMon" Style="{StaticResource st_chip}" Margin="0,0,6,6" Cursor="Hand"><TextBlock Text="周一" Style="{StaticResource st_chipText}"/></Border>
                      <Border x:Name="chipTue" Style="{StaticResource st_chip}" Margin="0,0,6,6" Cursor="Hand"><TextBlock Text="周二" Style="{StaticResource st_chipText}"/></Border>
                      <Border x:Name="chipWed" Style="{StaticResource st_chip}" Margin="0,0,6,6" Cursor="Hand"><TextBlock Text="周三" Style="{StaticResource st_chipText}"/></Border>
                      <Border x:Name="chipThu" Style="{StaticResource st_chip}" Margin="0,0,6,6" Cursor="Hand"><TextBlock Text="周四" Style="{StaticResource st_chipText}"/></Border>
                      <Border x:Name="chipFri" Style="{StaticResource st_chip}" Margin="0,0,6,6" Cursor="Hand"><TextBlock Text="周五" Style="{StaticResource st_chipText}"/></Border>
                      <Border x:Name="chipSat" Style="{StaticResource st_chip}" Margin="0,0,6,6" Cursor="Hand"><TextBlock Text="周六" Style="{StaticResource st_chipText}"/></Border>
                      <Border x:Name="chipSun" Style="{StaticResource st_chip}" Margin="0,0,0,6" Cursor="Hand"><TextBlock Text="周日" Style="{StaticResource st_chipText}"/></Border>
                    </WrapPanel>
                    <StackPanel x:Name="spnDaily" Orientation="Horizontal" Visibility="Collapsed">
                      <TextBlock Text="每隔" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBox x:Name="txtSchedInterval" Style="{StaticResource st_inputMono}" Width="56" Margin="6,0" Text="1" ToolTip="高频任务的重复间隔"/>
                      <TextBlock x:Name="txtSchedIntervalUnit" Text="天" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBlock x:Name="txtSchedIntervalHint" Text="(0 表示每天)" VerticalAlignment="Center" FontSize="11" Foreground="{DynamicResource C_Faint}" Margin="8,0,0,0"/>
                    </StackPanel>
                    <StackPanel x:Name="spnMonthly" Orientation="Horizontal" Visibility="Collapsed">
                      <TextBlock Text="每月" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBox x:Name="txtSchedMonthDay" Style="{StaticResource st_inputMono}" Width="56" Margin="6,0" Text="1" ToolTip="每月的几号运行,1-31; 31 表示每月最后一天"/>
                      <TextBlock Text="号" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBlock Text="(31 表示最后一天)" VerticalAlignment="Center" FontSize="11" Foreground="{DynamicResource C_Faint}" Margin="8,0,0,0"/>
                    </StackPanel>
                  </StackPanel>
                </Grid>
                <Grid Grid.Row="5" Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="64"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="任务名称" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                  <TextBox x:Name="txtSchedName" Grid.Column="1" Style="{StaticResource st_input}" Text=""/>
                </Grid>
                <Grid Grid.Row="6" Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="64"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="任务描述" VerticalAlignment="Top" FontSize="12.5" Foreground="{DynamicResource C_Sub}" Margin="0,5,0,0"/>
                  <TextBox x:Name="txtSchedComment" Grid.Column="1" Style="{StaticResource st_input}" Text="" Height="52" TextWrapping="Wrap" VerticalContentAlignment="Top" AcceptsReturn="True"/>
                </Grid>
                <Grid Grid.Row="7" Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="64"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="高级设置" VerticalAlignment="Top" FontSize="12.5" Foreground="{DynamicResource C_Sub}" Margin="0,5,0,0"/>
                  <StackPanel Grid.Column="1">
                    <CheckBox x:Name="chkSchedSawa" Content="错过计划时间后尽快补运行 (StartWhenAvailable)" FontSize="12" Foreground="{DynamicResource C_Ink}" IsChecked="True"/>
                    <TextBlock Text="任务以 SYSTEM 权限运行,无需手动提权。创建/修改后立即生效。" FontSize="11" Foreground="{DynamicResource C_Faint}" TextWrapping="Wrap" Margin="0,6,0,0"/>
                  </StackPanel>
                </Grid>
                <Border Grid.Row="8" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="10,8" Margin="0,12,0,0">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="上次运行" FontSize="11" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center"/>
                      <TextBlock x:Name="txtSchedLastRun" Text="—" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}" Margin="6,0,16,0" VerticalAlignment="Center"/>
                      <TextBlock Text="上次结果" FontSize="11" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center"/>
                      <TextBlock x:Name="txtSchedLastResult" Text="—" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}" Margin="6,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Grid.Column="2" Text="下次运行" FontSize="11" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtSchedNextRun" Grid.Column="2" Text="—" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}" Margin="6,0,0,0" VerticalAlignment="Center" HorizontalAlignment="Right"/>
                  </Grid>
                </Border>
                <StackPanel Grid.Row="9" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,12,0,0">
                  <Button x:Name="btnSchedNew" Content="新建任务" Style="{StaticResource st_btnPrimary}"/>
                  <Button x:Name="btnSchedExport" Content="导出 XML" Style="{StaticResource st_btnGhost}" Margin="8,0,0,0" ToolTip="导出任务定义到 XML 文件"/>
                  <Button x:Name="btnSchedRunNow" Content="立即运行" Style="{StaticResource st_btnSecondary}" Margin="8,0,0,0"/>
                  <Button x:Name="btnSchedToggle" Content="启用/禁用" Style="{StaticResource st_btnSecondary}" Margin="8,0,0,0"/>
                  <Button x:Name="btnSchedDelete" Content="删除任务" Style="{StaticResource st_btnDanger}" Margin="8,0,0,0"/>
                  <Button x:Name="btnSchedSave" Content="保存任务" Style="{StaticResource st_btnPrimary}" Margin="8,0,0,0"/>
                </StackPanel>
              </Grid>
            </Border>
          </Grid>
          <Border Grid.Row="2" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="10,6" Margin="0,10,0,0">
            <TextBlock Text="原理:每个任务调用 Win32_ShadowCopy.Create 创建 ClientAccessible 卷影,旧卷影由系统存储配额自动淘汰。任务注册在 任务计划程序 → ShadowConsole 目录下。" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}"/>
          </Border>
        </Grid>
<Grid x:Name="pageLog" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="命令日志" Style="{StaticResource st_pageTitle}"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="btnLogCopy" Content="复制输出" Style="{StaticResource st_btnSecondary}"/>
              <Button x:Name="btnLogClear" Content="清空" Style="{StaticResource st_btnGhost}" Margin="8,0,0,0"/>
            </StackPanel>
          </Grid>
          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="420"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <ListView x:Name="lstLog" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}">
              <ListView.View>
                <GridView>
                  <GridView.ColumnHeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                  </GridView.ColumnHeaderContainerStyle>
                  <GridViewColumn Header="时间" Width="96">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding TimeText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="工具" Width="78">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Tool}" FontFamily="Cascadia Mono, Consolas" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="命令" Width="NaN">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Args}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="退出码" Width="56">
                    <GridViewColumn.CellTemplate>
                      <DataTemplate>
                        <TextBlock Text="{Binding ExitText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" FontWeight="SemiBold" Foreground="{Binding CodeBrush}" VerticalAlignment="Center"/>
                      </DataTemplate>
                    </GridViewColumn.CellTemplate>
                  </GridViewColumn>
                </GridView>
              </ListView.View>
            </ListView>
            <Border Grid.Column="2" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="30"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,0,1">
                  <TextBlock Text="原始输出" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource C_Sub}" Margin="10,0"/>
                </Border>
                <TextBox x:Name="txtLogDetail" Grid.Row="1" Style="{StaticResource st_console}" BorderThickness="0"/>
              </Grid>
            </Border>
          </Grid>
        </Grid>

        <Grid x:Name="pageSysInfo" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="2*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="3*"/>
            <RowDefinition Height="150"/>
          </Grid.RowDefinitions>
          <TextBlock Text="系统信息" Style="{StaticResource st_pageTitle}" Margin="0,0,0,10"/>
          <!-- 提供程序 -->
          <Border Grid.Row="1" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="30"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,0,1">
                <TextBlock Text="提供程序 Providers" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource C_Sub}" Margin="10,0"/>
              </Border>
              <ListView x:Name="lstProviders" Grid.Row="1" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}">
                <ListView.View>
                  <GridView>
                    <GridView.ColumnHeaderContainerStyle>
                      <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                    </GridView.ColumnHeaderContainerStyle>
                    <GridViewColumn Header="名称" Width="330">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" FontSize="12.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="类型" Width="90">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate>
                          <StackPanel Orientation="Horizontal">
                            <Border Width="6" Height="6" Background="{Binding TypeBrush}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                            <TextBlock Text="{Binding TypeText}" FontSize="12" VerticalAlignment="Center"/>
                          </StackPanel>
                        </DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="版本" Width="90">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Version}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="提供程序 ID" Width="260">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="CLSID" Width="240">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Clsid}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                  </GridView>
                </ListView.View>
              </ListView>
            </Grid>
          </Border>
          <Border Grid.Row="2" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="10,6" Margin="0,8,0,0">
            <TextBlock Text="类型:系统 = volsnap.sys 内置   软件 = 第三方软件提供程序   硬件 = 存储阵列提供程序" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}"/>
          </Border>
          <!-- 编写器 -->
          <Grid Grid.Row="3" Margin="0,14,0,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="编写器 Writers" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource C_Ink}" VerticalAlignment="Center"/>
            <TextBlock x:Name="txtWritersSummary" Grid.Column="1" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center" Margin="12,0,0,0"/>
          </Grid>
          <ListView x:Name="lstWriters" Grid.Row="4" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}">
            <ListView.View>
              <GridView>
                <GridView.ColumnHeaderContainerStyle>
                  <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                </GridView.ColumnHeaderContainerStyle>
                <GridViewColumn Header="状态" Width="130">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal">
                        <Border Width="7" Height="7" Background="{Binding StateBrush}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding StateText}" FontSize="12" VerticalAlignment="Center" FontWeight="SemiBold"/>
                      </StackPanel>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="写入程序" Width="230">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" FontSize="12.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="写入程序 ID" Width="230">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="实例 ID" Width="230">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Instance}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="上次错误" Width="NaN">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding LastError}" FontSize="12" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
          <Border Grid.Row="5" Margin="0,8,0,0" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="30"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,0,1">
                <TextBlock Text="原始输出" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource C_Sub}" Margin="10,0"/>
              </Border>
              <TextBox x:Name="txtWriterDetail" Grid.Row="1" Style="{StaticResource st_console}" BorderThickness="0"/>
            </Grid>
          </Border>
        </Grid>
      </Grid>
    </Grid>
    <!-- 数据更新提示层: 后台任务运行期间窗口正中显示 70% 透明(Opacity 0.3)超大加粗黑体文字。
         垂直 StackPanel 整体居中(无写死坐标, 窗口任意尺寸均居中);
         主体"等待更新中"在上固定不动, 小方块动画在其正下方(txtHintDots 固定宽度 —
         点 0→3 变化不改变 StackPanel 尺寸, 避免每次变化触发全窗口布局重算导致 UI 卡顿) -->
    <Grid x:Name="grdUpdateHint" Grid.RowSpan="4" IsHitTestVisible="False" Visibility="Collapsed">
      <StackPanel Orientation="Vertical" HorizontalAlignment="Center" VerticalAlignment="Center">
        <TextBlock x:Name="txtHintMain" Text="等待更新中" FontSize="102" FontWeight="Bold" FontFamily="SimHei, Microsoft YaHei"
                   Foreground="{DynamicResource C_Ink}" Opacity="0.3" HorizontalAlignment="Center"/>
        <TextBlock x:Name="txtHintDots" Text="" FontSize="36" FontWeight="Bold" FontFamily="SimHei, Microsoft YaHei"
                   Foreground="{DynamicResource C_Ink}" Opacity="0.3" Width="150"
                   HorizontalAlignment="Center" Margin="0,6,0,0"/>
      </StackPanel>
    </Grid>
    <Border Grid.Row="3" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,1,0,0">
      <Grid Margin="14,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <Border x:Name="dotVss" Width="7" Height="7" Background="{DynamicResource C_Faint}" VerticalAlignment="Center"/>
          <TextBlock x:Name="txtVss" FontSize="11.5" Foreground="{DynamicResource C_Sub}" Margin="7,0,0,0" VerticalAlignment="Center" Text="VSS 服务: 检测中…"/>
        </StackPanel>
        <TextBlock x:Name="txtLastRefresh" Grid.Column="1" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Faint}" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <TextBlock x:Name="txtSku" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Faint}" VerticalAlignment="Center"/>
          <Border Width="1" Height="12" Background="{DynamicResource C_Border}" Margin="12,0"/>
          <Border x:Name="dotAdmin" Width="7" Height="7" Background="{DynamicResource C_Success}" VerticalAlignment="Center"/>
          <TextBlock x:Name="txtAdmin" FontSize="11.5" Foreground="{DynamicResource C_Sub}" Margin="7,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid x:Name="grdConfirm" Grid.RowSpan="4" Background="{DynamicResource C_Overlay}" Visibility="Collapsed">
      <Border Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Width="400" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Grid Margin="22">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="txtConfirmTitle" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource C_Ink}"/>
          <TextBlock x:Name="txtConfirmMsg" Grid.Row="1" FontSize="12.5" Foreground="{DynamicResource C_Sub}" TextWrapping="Wrap" Margin="0,8,0,0"/>
          <Border Grid.Row="2" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="8,5" Margin="0,12,0,0">
            <TextBlock x:Name="txtConfirmCmd" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource C_Ink}" TextWrapping="Wrap"/>
          </Border>
          <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnConfirmCancel" Content="取消" Style="{StaticResource st_btnSecondary}" Width="90"/>
            <Button x:Name="btnConfirmOK" Content="确认" Style="{StaticResource st_btnPrimary}" Width="90" Margin="8,0,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <Grid x:Name="grdResize" Grid.RowSpan="4" Background="{DynamicResource C_Overlay}" Visibility="Collapsed">
      <Border Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Width="420" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Grid Margin="22">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="txtResizeTitle" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource C_Ink}"/>
          <Border Grid.Row="1" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="8,5" Margin="0,10,0,0">
            <TextBlock x:Name="txtResizeCur" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource C_Sub}" TextWrapping="Wrap"/>
          </Border>
          <StackPanel Grid.Row="2" Margin="0,14,0,0">
            <RadioButton x:Name="rbResizeAuto" GroupName="rz" Content="自动上限 (UNBOUNDED,由系统决定)" Style="{StaticResource st_radio}"/>
            <RadioButton x:Name="rbResizeCustom" GroupName="rz" Content="指定上限" Style="{StaticResource st_radio}" Margin="0,10,0,0"/>
            <Grid Margin="24,8,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="txtResizeGB" Style="{StaticResource st_inputMono}"/>
              <TextBlock Grid.Column="1" Text="GB" FontFamily="Cascadia Mono, Consolas" FontSize="12" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center" Margin="8,0,0,0"/>
            </Grid>
          </StackPanel>
          <TextBlock Grid.Row="3" FontSize="11.5" Foreground="{DynamicResource C_Faint}" TextWrapping="Wrap" Margin="0,12,0,0" Text="上限只约束新写入的差异数据,已有卷影不受影响。建议至少保留最近两周。"/>
          <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnResizeCancel" Content="取消" Style="{StaticResource st_btnSecondary}" Width="90"/>
            <Button x:Name="btnResizeOK" Content="应用" Style="{StaticResource st_btnPrimary}" Width="90" Margin="8,0,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <StackPanel x:Name="toastHost" Grid.RowSpan="4" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,16,44" IsHitTestVisible="False"/>
  </Grid>
</Window>
'@
function Get-N {
  param([string]$name)
  $el = $window.FindName($name)
  if (-not $el) { throw "界面元素 '$name' 不存在" }
  return $el
}

function Set-Theme {
  param([string]$Mode)
  $script:ThemeMode = $Mode
  $eff = $Mode
  if ($eff -eq 'System') {
    $light = 1
    try { $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme } catch {}
    $eff = if ($light -eq 1) { 'Light' } else { 'Dark' }
  }
  $tokens = if ($eff -eq 'Dark') { $script:ThemeDark } else { $script:ThemeLight }
  foreach ($k in $tokens.Keys) {
    try {
      if ($window.Resources.Contains($k)) { $window.Resources.Remove($k) | Out-Null }
      $window.Resources.Add($k, (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($tokens[$k])))) | Out-Null
    } catch {
      throw "主题资源 '$k' = '$($tokens[$k])' 应用失败: $($_.Exception.Message)"
    }
  }
  $script:ThemeIsDark = ($eff -eq 'Dark')
  $icon = Get-N 'iconTheme'
  if ($script:ThemeIsDark) {
    $icon.Data = [System.Windows.Media.Geometry]::Parse('M8,3 A5,5 0 1 0 8,13 A5,5 0 1 0 8,3 Z M8,1 V2.4 M8,13.6 V15 M1,8 H2.4 M13.6,8 H15 M3.4,3.4 L4.4,4.4 M11.6,11.6 L12.6,12.6 M12.6,3.4 L11.6,4.4 M4.4,11.6 L3.4,12.6')
  } else {
    $icon.Data = [System.Windows.Media.Geometry]::Parse('M9.6,2 A5.6,5.6 0 1 0 14,9.2 A4.4,4.4 0 1 1 9.6,2 Z')
  }
  # 主题切换后立即刷新导航选中高亮(Set-Nav 用资源引用跟随,此处再显式重设一次,不依赖资源通知异步派发)
  try { Set-Nav $script:NavIndex } catch {}
}

function Show-Toast {
  param([string]$Message, [string]$Type = 'ok')
  $host2 = Get-N 'toastHost'
  $accent = $window.Resources['C_Success']
  if ($Type -eq 'warn') { $accent = $window.Resources['C_Warn'] }
  elseif ($Type -eq 'err') { $accent = $window.Resources['C_Danger'] }
  $border = New-Object System.Windows.Controls.Border
  $border.Background = $window.Resources['C_Panel']
  $border.BorderBrush = $window.Resources['C_Border']
  $border.BorderThickness = New-Object System.Windows.Thickness(1)
  $border.Margin = New-Object System.Windows.Thickness(0,6,0,0)
  $border.HorizontalAlignment = 'Right'
  $grid = New-Object System.Windows.Controls.Grid
  $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $col = New-Object System.Windows.Controls.ColumnDefinition
  $col.Width = New-Object System.Windows.GridLength(3)
  $grid.ColumnDefinitions.Add($col)
  $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $bar = New-Object System.Windows.Controls.Border
  $bar.Background = $accent
  $bar.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
  $grid.Children.Add($bar)
  $txt = New-Object System.Windows.Controls.TextBlock
  $txt.Text = $Message
  $txt.Foreground = $window.Resources['C_Ink']
  $txt.FontSize = 12.5
  $txt.Margin = New-Object System.Windows.Thickness(12,9,14,9)
  $txt.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
  $grid.Children.Add($txt)
  $border.Child = $grid
  $host2.Children.Add($border)
  while ($host2.Children.Count -gt 4) { $host2.Children.RemoveAt(0) }
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromSeconds(4)
  $timer.add_Tick({
    $timer.Stop()
    if ($host2.Children.Contains($border)) { $host2.Children.Remove($border) }
  }.GetNewClosure())
  $timer.Start()
}

# 旋转动画只启动一次(任务泵 100ms tick 会反复调 Start-Spin, 每次重建 DoubleAnimation+BeginAnimation
# 会持续占用 UI 线程导致右键菜单/操作卡顿) — 动画已在运行则跳过
$script:SpinRunning = $false
function Start-Spin {
  if ($script:SpinRunning) { return }
  $script:SpinRunning = $true
  $spin = Get-N 'spinMini'
  $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 360, [TimeSpan]::FromSeconds(1.2))
  $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  try { $spin.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim) } catch {}
}

function Stop-Spin {
  $script:SpinRunning = $false
  try { (Get-N 'spinMini').BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null) } catch {}
}

# 数据更新提示层: 后台任务运行期间在窗口正中显示 70% 透明超大加粗黑体"等待更新中"
# 主体文字固定不动, 正下方小方块(■)依次出现再消失循环(打字机效果, 220ms/帧)
$script:HintTimer = $null
$script:HintIdx = 0
$script:HintDots = @('', '■', '■■', '■■■', '■■', '■')
function Start-UpdateHint {
  try {
    $g = Get-N 'grdUpdateHint'
    if ($g.Visibility -ne 'Visible') {
      $g.Visibility = 'Visible'
      (Get-N 'txtHintDots').Text = ''
      $script:HintIdx = 0
    }
    if (-not $script:HintTimer) {
      $t = New-Object System.Windows.Threading.DispatcherTimer
      $t.Interval = [TimeSpan]::FromMilliseconds(220)
      $t.add_Tick({
        $script:HintIdx = ($script:HintIdx + 1) % $script:HintDots.Count
        try { (Get-N 'txtHintDots').Text = $script:HintDots[$script:HintIdx] } catch {}
      })
      $t.Start()
      $script:HintTimer = $t
    }
  } catch {}
}
function Stop-UpdateHint {
  try {
    if ($script:HintTimer) { $script:HintTimer.Stop(); $script:HintTimer = $null }
    (Get-N 'grdUpdateHint').Visibility = 'Collapsed'
  } catch {}
}

# 左上角状态指示器: 由任务队列驱动(Add-Task/Pump-Tasks 每 tick 调用), 显示运行任务名/耗时/队列数
# 文本更新 500ms 节流(每 5 tick 才刷新文本/读进度文件), 避免 100ms tick 高频改文本触发布局重算
$script:StatusTickCount = 0
function Update-StatusIndicator {
  try {
    $spn = Get-N 'spnStatus'
    $runCount = if ($script:TaskRunning) { $script:TaskRunning.Count } else { 0 }
    $queCount = if ($script:TaskQueue) { $script:TaskQueue.Count } else { 0 }
    if ($runCount -eq 0 -and $queCount -eq 0) {
      if ($spn.Visibility -ne 'Collapsed') { $spn.Visibility = 'Collapsed' }
      Stop-Spin
      Stop-UpdateHint
      return
    }
    if ($spn.Visibility -ne 'Visible') {
      $spn.Visibility = 'Visible'
      $script:StatusTickCount = 0
    }
    # 提示层(等待更新中...)只在存在"非 Quiet"任务时显示 — Quiet 任务(如打开卷影浏览)不弹大提示打断交互
    $anyVisible = $false
    foreach ($t in $script:TaskRunning.Values) { if (-not $t.Quiet) { $anyVisible = $true; break } }
    if (-not $anyVisible) { foreach ($t in $script:TaskQueue) { if (-not $t.Quiet) { $anyVisible = $true; break } } }
    if ($anyVisible) { Start-UpdateHint } else { Stop-UpdateHint }
    # 节流: 每 5 tick(≈500ms)更新一次文本; 可见性/动画即时
    $script:StatusTickCount++
    if (($script:StatusTickCount % 5) -ne 1) { return }
    $txt = ''
    if ($runCount -gt 0) {
      # 取最早开始的任务作为主显示(最早=最先入队)
      $first = $null
      foreach ($t in $script:TaskRunning.Values) {
        if (-not $first -or $t.StartTime -lt $first.StartTime) { $first = $t }
      }
      if ($first) {
        $txt = $first.Name
        $sec = [string]::Format($script:InvCulture, '{0:0.0}s', ((Get-Date) - $first.StartTime).TotalSeconds)
        $txt += (' · ' + $sec)
        if ($runCount -gt 1) { $txt += (' · +' + ($runCount - 1)) }
        # 刷新任务显示当前查询阶段(事件驱动进度文件)
        if ($first.IsRefresh) {
          $line = Read-ProgressLine
          if ($line) {
            $p = $line -split '\|'
            if ($p.Count -ge 3) { $txt += (' · ' + $p[1] + ' ' + $p[2]) }
          }
        }
      }
    }
    if ($queCount -gt 0) { $txt += (' · 排队 ' + $queCount) }
    (Get-N 'txtStatus').Text = $txt
    Start-Spin
  } catch {}
}

$script:ProgressFile = Join-Path $env:TEMP 'shadowconsole\refresh_progress.log'
$script:ProgLine = 0

function Read-ProgressLine {
  $pf = $script:ProgressFile
  if (-not (Test-Path -LiteralPath $pf)) { return $null }
  $lines = $null
  try { $lines = @(Get-Content -LiteralPath $pf -ErrorAction Stop) } catch { return $null }
  if ($lines.Count -le $script:ProgLine) { return $null }
  $script:ProgLine = $lines.Count
  return $lines[$lines.Count - 1]
}

function Get-SettingsValues {
  $vals = @{
    Theme = $script:ThemeMode
    WLeft = $window.Left
    WTop = $window.Top
    WW = $window.Width
    WH = $window.Height
    NavPage = [int]$script:NavIndex
  }
  try {
    $mg = $window.FindName('mainGrid')
    if ($mg) { $vals.NavW = $mg.ColumnDefinitions[0].ActualWidth }
  } catch {}
  try {
    $ps = $window.FindName('pageShadows')
    if ($ps) { $vals.CardH = $ps.RowDefinitions[1].ActualHeight }
  } catch {}
  # 表格列宽(所有 ListView 的 GridView 列, 表头去掉排序箭头)
  try {
    $colW = @{}
    foreach ($ln in @('lstShadows','lstStorage','lstProviders','lstWriters','lstSchedTasks','lstLog')) {
      $lv = $window.FindName($ln)
      if (-not $lv -or -not $lv.View) { continue }
      foreach ($col in $lv.View.Columns) {
        $h = ($col.Header.ToString() -replace '\s*[▲▼]\s*$','').Trim()
        if ($h) { $colW[$ln + ':' + $h] = [double]$col.Width }
      }
    }
    if ($colW.Count -gt 0) { $vals.ColWidths = $colW }
  } catch {}
  # 表格排序状态(列表名 → 排序列/方向)
  try {
    $sort = @{}
    foreach ($ln in $script:SortOrig.Keys) {
      foreach ($pair in $script:SortOrig[$ln].GetEnumerator()) {
        $raw = $pair.Value
        $d = $script:SortState[$ln + ':' + $raw]
        if ($d) { $sort[$ln] = @{ Col = $raw; Dir = $d } }
      }
    }
    if ($sort.Count -gt 0) { $vals.SortState = $sort }
  } catch {}
  # 表格列顺序(列表名 → 列头数组, 按当前显示顺序)
  try {
    $colO = @{}
    foreach ($ln in @('lstShadows','lstStorage','lstProviders','lstWriters','lstSchedTasks','lstLog')) {
      $lv = $window.FindName($ln)
      if (-not $lv -or -not $lv.View) { continue }
      $hdrs = New-Object System.Collections.Generic.List[string]
      foreach ($col in $lv.View.Columns) {
        $h = ($col.Header.ToString() -replace '\s*[▲▼]\s*$','').Trim()
        if ($h) { $hdrs.Add($h) }
      }
      if ($hdrs.Count -gt 0) { $colO[$ln] = @($hdrs) }
    }
    if ($colO.Count -gt 0) { $vals.ColOrder = $colO }
  } catch {}
  return $vals
}

# 防抖保存:事件触发后 3 秒无新变化才真正写文件(拖动窗口/分割条是连续事件,避免频繁写盘)
function Schedule-SettingsSave {
  if (-not $script:SettingsTimer) {
    $script:SettingsTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SettingsTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:SettingsTimer.add_Tick({
      $script:SettingsTimer.Stop()
      try { Save-Settings (Get-SettingsValues) } catch {}
    })
  }
  $script:SettingsTimer.Stop()
  $script:SettingsTimer.Start()
}

# === 配置修改自身(零外部文件): 配置区内嵌在脚本/bat 尾部, 保存时重写自身 ===
# 脚本文件自身路径: bat 提取时在临时 ps1 头部注入 $script:VssSelfFile(硬编码 bat 路径, 不依赖环境变量继承, 提权进程也可靠);
# 兜底 $env:VSS_SELF; ps1 直接运行时用 $PSCommandPath
function Get-SelfPath {
  if ($script:VssSelfFile) { return $script:VssSelfFile }
  if ($env:VSS_SELF) { return $env:VSS_SELF }
  return $PSCommandPath
}
# 读取配置区原始文本(含 # 前缀), 不存在返回 $null
function Read-SettingsRaw {
  try {
    $self = Get-SelfPath
    if (-not (Test-Path -LiteralPath $self)) { return $null }
    $content = [IO.File]::ReadAllText($self)
    # 标记用拼接构造: 本函数内不得出现完整标记串, 否则 IndexOf 会误匹配到函数自身
    $marker = '#=' + '==CONFIG-BEGIN==='
    $endMark = '#=' + '==CONFIG-END==='
    $s = $content.IndexOf($marker)
    $e = $content.IndexOf($endMark)
    if ($s -lt 0 -or $e -le $s) { return $null }
    $raw = $content.Substring($s + $marker.Length, $e - $s - $marker.Length).Trim()
    # 去掉每行 # 前缀
    return ($raw -split "`r?`n" | ForEach-Object { $_.TrimStart() } | Where-Object { $_ -and $_ -ne '#' } | ForEach-Object { $_.TrimStart('#').TrimStart() }) -join "`n"
  } catch { return $null }
}
# 把 JSON 写入自身配置区(保持原文件 BOM, 失败抛异常)
function Write-SettingsRaw {
  param([string]$Json)
  $self = Get-SelfPath
  $content = [IO.File]::ReadAllText($self)
  $marker = '#=' + '==CONFIG-BEGIN==='
  $endMark = '#=' + '==CONFIG-END==='
  $s = $content.IndexOf($marker)
  $e = $content.IndexOf($endMark)
  if ($s -lt 0 -or $e -le $s) { throw '配置区标记不存在,无法写入自身' }
  # ReadAllText 会把 BOM 解码成 \uFEFF 字符, 先剥离避免写回时双重 BOM
  $hasBom = ($content.Length -ge 1 -and $content[0] -eq [char]0xFEFF)
  if ($hasBom) { $content = $content.Substring(1); $s--; $e-- }
  $head = $content.Substring(0, $s + $marker.Length)
  $tail = $content.Substring($e)
  $enc = if ($hasBom) { New-Object Text.UTF8Encoding $true } else { New-Object Text.UTF8Encoding $false }
  # JSON 单行 + # 前缀(保证整行是合法 PS 注释/bat 中 exit 后不解析)
  $line = '#' + ($Json -replace "`r?`n", '')
  [IO.File]::WriteAllText($self, ($head + "`r`n" + $line + "`r`n" + $tail), $enc)
}

function Save-Settings {
  param([hashtable]$Values)
  $data = @{}
  try {
    $cur = Read-SettingsRaw
    if ($cur) {
      $existing = $cur | ConvertFrom-Json -ErrorAction Stop
      if ($existing) {
        foreach ($prop in $existing.PSObject.Properties) { $data[$prop.Name] = $prop.Value }
      }
    }
  } catch {}
  foreach ($k in $Values.Keys) { $data[$k] = $Values[$k] }
  try {
    $json = $data | ConvertTo-Json -Compress
    Write-SettingsRaw -Json $json
    try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\runpath.log'), ('[cfg-save ' + (Get-Date -Format 'HH:mm:ss.fff') + '] OK self=' + (Get-SelfPath) + ' keys=' + ($data.Keys -join ',')) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
  } catch {
    try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[settings save ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString()) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
  }
}

function Load-Settings {
  try {
    $raw = Read-SettingsRaw
    if ($raw) {
      $obj = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($obj) {
        try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\runpath.log'), ('[cfg-load ' + (Get-Date -Format 'HH:mm:ss.fff') + '] self=' + (Get-SelfPath) + ' keys=' + ($obj.PSObject.Properties.Name -join ',')) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
        return $obj
      }
    }
  } catch {}
  return $null
}

function Format-Size {
  param([double]$Bytes)
  $inv = [Globalization.CultureInfo]::InvariantCulture
  if ($Bytes -ge 1TB) { return [string]::Format($inv, '{0:0.0} TB', ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return [string]::Format($inv, '{0:0.0} GB', ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return [string]::Format($inv, '{0:0.0} MB', ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return [string]::Format($inv, '{0:0.0} KB', ($Bytes / 1KB)) }
  return [string]::Format($inv, '{0} B', $Bytes)
}
function Invoke-ToolBg {
  param([string]$Exe, [string]$ArgStr, [int]$TimeoutSec = 120)
  $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
  $psi.Arguments = $ArgStr
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $oemCp = 0
  try { $oemCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage } catch {}
  if ($oemCp -le 0) { $oemCp = 437 }
  try { $oemEnc = [System.Text.Encoding]::GetEncoding($oemCp) } catch { $oemEnc = $null }
  if ($oemEnc) { $psi.StandardOutputEncoding = $oemEnc; $psi.StandardErrorEncoding = $oemEnc }
  else {
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::Default } catch {}
    try { $psi.StandardErrorEncoding = [System.Text.Encoding]::Default } catch {}
  }
  $p = [System.Diagnostics.Process]::new()
  $p.StartInfo = $psi
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try { $p.Start() | Out-Null } catch { return [pscustomobject]@{ ExitCode = -100; Output = $_.Exception.Message; Duration = 0; TimedOut = $false } }
  # 关键:stderr 异步读 + stdout 同步 ReadToEnd,避免两个同步 ReadToEnd 缓冲区互填死锁;且不用 ReadToEndAsync 的 GetAwaiter(在 PowerShell 后台 runspace 中 TAP 上下文可能挂起)
  $errTask = $p.StandardError.ReadToEndAsync()
  $out = ''
  try { $out = $p.StandardOutput.ReadToEnd() } catch {}
  $finished = $p.WaitForExit($TimeoutSec * 1000)
  if (-not $finished) { try { $p.Kill() } catch {}; $p.WaitForExit() }
  $err = ''
  try { $err = $errTask.Result } catch {}
  $sw.Stop()
  $text = ($out.TrimEnd() + "`r`n" + $err.TrimEnd()).Trim()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $text.TrimEnd(); Duration = $sw.Elapsed.TotalSeconds; TimedOut = (-not $finished) }
}

function Invoke-WmiCreateShadow {
  param([string]$Letter)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $vol = $Letter.TrimEnd('\') + '\'
    $r = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = $vol; Context = 'ClientAccessible' } -ErrorAction Stop
    $sw.Stop()
    if ($r.ReturnValue -eq 0) {
      return [pscustomobject]@{ ExitCode = 0; Output = ('已创建卷影副本 {0}' -f $r.ShadowID); Duration = $sw.Elapsed.TotalSeconds }
    }
    $map = @{
      1 = '拒绝访问:需要管理员权限'
      2 = '参数无效'
      3 = '未找到指定卷'
      4 = '该卷不支持卷影副本'
      5 = '不支持的卷影上下文'
      6 = '存储空间不足'
      7 = '卷正被使用'
      8 = '已达到卷影副本数量上限'
      9 = '另一个卷影操作正在进行'
      10 = '卷影提供程序拒绝了操作'
      11 = '卷影提供程序未注册'
      12 = '卷影提供程序失败'
      13 = '未知错误'
    }
    $msg = if ($map.ContainsKey([int]$r.ReturnValue)) { $map[[int]$r.ReturnValue] } else { ('WMI 返回代码 {0}' -f $r.ReturnValue) }
    return [pscustomobject]@{ ExitCode = -200 - [int]$r.ReturnValue; Output = $msg; Duration = $sw.Elapsed.TotalSeconds }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{ ExitCode = -100; Output = $_.Exception.Message; Duration = $sw.Elapsed.TotalSeconds }
  }
}

function Invoke-SystemTool {
  param([string]$Tool, [string[]]$ArgList, [string]$Label, [ScriptBlock]$OnDone = $null, [int]$TimeoutSec = 180)
  if (-not $OnDone) { $OnDone = { param($e) } }
  $exe = if ($Tool -eq 'vssadmin') { $script:VssAdmin } else { $script:Diskshadow }
  $argStr = (($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } }) -join ' ')
  $entry = [pscustomobject]@{
    Time = Get-Date; Tool = $Tool; Args = $argStr; ExitCode = 0; Duration = 0
    Output = ''; Running = $true
  }
  $script:Log.Add($entry) | Out-Null
  Update-LogView
  if ($Tool -eq 'wmi') {
    $body = $script:WmiBody
    $wargs = @($ArgList[0])
  } else {
    $body = $script:ToolBody
    $wargs = @($exe, $argStr, $TimeoutSec)
  }
  # 闭包捕获 $entry/$OnDone: 并发多个工具任务时互不干扰(不再用脚本级单例 ToolEntryRef/ToolOnDone)
  Add-Task -Name $Label -Body $body -ArgList $wargs -OnDone {
    param($ok, $res, $err)
    if (-not $ok) {
      $entry.ExitCode = -101
      $entry.Running = $false
      $entry.Output = ('后台执行失败: ' + $err)
    } else {
      $entry.ExitCode = $res.ExitCode
      $entry.Duration = $res.Duration
      $entry.Output = $res.Output
      $entry.Running = $false
    }
    try {
      Update-LogView
      & $OnDone $entry
    } catch {
      try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[cmd ui ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString()) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
    }
  }.GetNewClosure()
}

function Parse-Writers {
  param([string]$Raw)
  $list = New-Object System.Collections.Generic.List[object]
  $cur = $null
  foreach ($rawLine in ($Raw -split "`r?`n")) {
    $t = $rawLine.Trim()
    if ($t.Length -eq 0) { continue }
    $m = [regex]::Match($t, '^(?:Writer\s+name|写入程序名)\s*:\s*''?(.*?)''?\s*$')
    if ($m.Success) {
      if ($cur) { $list.Add($cur) }
      $cur = [pscustomobject]@{ Name = $m.Groups[1].Value.Trim(); Id = ''; Instance = ''; State = 0; StateText = ''; LastError = ''; Raw = $t }
      continue
    }
    if (-not $cur) { continue }
    $cur.Raw += "`n" + $t
    $m = [regex]::Match($t, '^(?:Writer\s+Id|写入程序\s*ID)\s*:\s*(\{[\w-]+\})')
    if ($m.Success) { $cur.Id = $m.Groups[1].Value; continue }
    $m = [regex]::Match($t, '^(?:Writer\s+Instance\s+Id|写入程序实例\s*ID)\s*:\s*(\{[\w-]+\})')
    if ($m.Success) { $cur.Instance = $m.Groups[1].Value; continue }
    $m = [regex]::Match($t, '^(?:State|状态)\s*:\s*\[(\d)\]')
    if ($m.Success) {
      $cur.State = [int]$m.Groups[1].Value
      $cur.StateText = if ($script:WriterStates.ContainsKey($cur.State)) { $script:WriterStates[$cur.State] } else { ('状态 {0}' -f $cur.State) }
      continue
    }
    $m = [regex]::Match($t, '^(?:Last\s+error|上一个错误)\s*:\s*(.*)$')
    if ($m.Success) {
      $err = $m.Groups[1].Value.Trim()
      if ($err -match '^(No error|没有错误|无错误)$') { $err = '无错误' }
      $cur.LastError = $err
      continue
    }
  }
  if ($cur) { $list.Add($cur) }
for ($i = 0; $i -lt $list.Count; $i++) {
    $w = $list[$i]
    $brush = $script:Brush_Success
    if ($w.State -ge 5) { $brush = $script:Brush_Danger }
    elseif ($w.State -ge 2) { $brush = $script:Brush_Warn }
    $w | Add-Member -NotePropertyName StateBrush -NotePropertyValue $brush -Force
  }
  return ,$list
}

function Get-RealCache {
  $qLog = New-Object System.Collections.Generic.List[object]
  $progFile = Join-Path $env:TEMP 'shadowconsole\refresh_progress.log'
  try { [IO.Directory]::CreateDirectory((Split-Path $progFile)) | Out-Null } catch {}
  # 查询日志:每条记录 工具/参数/退出码/耗时/输出,同时写进度文件供 UI 事件驱动显示当前阶段
  $logQ = { param($tool, $argStr, $exit, $dur, $out)
    $qLog.Add([pscustomobject]@{ Time = Get-Date; Tool = $tool; Args = $argStr; ExitCode = $exit; Duration = $dur; Output = $out; Running = $false }) | Out-Null
    try { [IO.File]::AppendAllText($script:SProg, ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}|{1}|{2}', (Get-Date -Format 'HH:mm:ss'), $tool, $argStr) + "`r`n"), (New-Object Text.UTF8Encoding $true)) } catch {}
  }
  $runWmi = { param($cls, $filter)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rows = if ($filter) { @(Get-CimInstance $cls -Filter $filter -ErrorAction SilentlyContinue) } else { @(Get-CimInstance $cls -ErrorAction SilentlyContinue) }
    $sw.Stop()
    & $logQ 'WMI' $cls 0 $sw.Elapsed.TotalSeconds ('查询到 {0} 条记录' -f $rows.Count)
    return $rows
  }
  $script:SProg = $progFile
  $vols = @(& $runWmi 'Win32_Volume')
  $volMap = @{}
  foreach ($v in $vols) {
    foreach ($k in @($v.VolumeName, $v.DeviceID)) {
      if ($k) { $volMap[$k.TrimEnd('\')] = $v }
    }
  }
  $letterOf = {
    param($vol)
    foreach ($k in @($vol.VolumeName, $vol.DeviceID, $vol.Volume)) {
      if ($k -and $volMap.ContainsKey($k.TrimEnd('\'))) {
        $dl = $volMap[$k.TrimEnd('\')].DriveLetter
        if ($dl) { return $dl.TrimEnd('\') }
      }
    }
    return $null
  }
  $shadows = @(& $runWmi 'Win32_ShadowCopy')
  $storages = @(& $runWmi 'Win32_ShadowStorage')
  $providers = @(& $runWmi 'Win32_ShadowProvider')
  $disks = @(& $runWmi 'Win32_LogicalDisk' 'DriveType=3')

  $shadowRows = New-Object System.Collections.Generic.List[object]
  foreach ($s in $shadows) {
    $letter = & $letterOf $s
    if (-not $letter) { $letter = $s.VolumeName }
    $flags = New-Object System.Collections.Generic.List[string]
    if ($s.Persistent) { $flags.Add('持久') } else { $flags.Add('临时') }
    if ($s.Differential) { $flags.Add('差量') }
    if ($s.NoAutoRelease) { $flags.Add('不自动释放') }
    if ($s.NoWriters) { $flags.Add('无编写器') }
    $created = $null
    try {
      # Get-CimInstance 返回 InstallDate 为 Kind=Local 的 [datetime];老式 WMI 给字符串(ToDateTime 后 ToString 也是本地显示)
      if ($s.InstallDate -is [datetime]) { $created = $s.InstallDate }
      elseif ($s.InstallDate) { $created = [Management.ManagementDateTimeConverter]::ToDateTime([string]$s.InstallDate) }
    } catch {}
    $shadowRows.Add([pscustomobject]@{
      CreatedText = if ($created) { $created.ToString('yyyy/MM/dd HH:mm:ss') } else { '-' }
      GmtStamp = if ($created) { $created.ToUniversalTime().ToString('yyyy.MM.dd-HH.mm.ss') } else { '' }
      Letter = $letter.TrimEnd('\')
      Id = $s.ID.ToUpper()
      Device = $s.DeviceObject
      TypeText = ($flags -join ' · ')
      CanAct = $script:CanAct
    }) | Out-Null
  }

  $storageRows = New-Object System.Collections.Generic.List[object]
  $storageByLetter = @{}
  foreach ($st in $storages) {
    $letter = & $letterOf $st.Volume
    if (-not $letter) { continue }
    $letter = $letter.TrimEnd('\')
    if (-not $storageByLetter.ContainsKey($letter)) { $storageByLetter[$letter] = $st }
  }
  # 所有固定磁盘都生成配额行(有存储关联的填实际值,无的显示"未设置"),保证配额页不遗漏无快照的卷
  foreach ($d in $disks) {
    $letter = $d.DeviceID.TrimEnd('\')
    $st = $storageByLetter[$letter]
    if ($st) {
      $diffLetter = & $letterOf $st.DiffVolume
      if (-not $diffLetter) { $diffLetter = $letter }
      $maxUnbounded = ($st.MaxSpace -eq [uint64]::MaxValue)
      # 配额进度:有上限 = 卷影占用/配额;UNBOUNDED = 卷影占用/(该卷空闲空间+卷影占用)
      if ($maxUnbounded) {
        $freeSpace = if ($null -ne $d.FreeSpace -and [uint64]$d.FreeSpace -ge 0) { [uint64]$d.FreeSpace } else { 0 }
        $pct = if (($st.UsedSpace + $freeSpace) -gt 0) { [double]$st.UsedSpace / ($st.UsedSpace + $freeSpace) * 100 } else { 0 }
      } else {
        $pct = if ($st.MaxSpace -gt 0) { [double]$st.UsedSpace / $st.MaxSpace * 100 } else { 0 }
      }
      $storageRows.Add([pscustomobject]@{
        Letter = $letter
        UsedText = Format-Size $st.UsedSpace
        AllocText = Format-Size $st.AllocatedSpace
        MaxText = if ($maxUnbounded) { 'UNBOUNDED' } else { Format-Size $st.MaxSpace }
        Pct = $pct
        PctText = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}%', $pct)
        BarUsed = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', $pct)
        BarFree = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', ([Math]::Max(100 - $pct, 0)))
        DiffLetter = $diffLetter.TrimEnd('\')
        MaxBytes = $st.MaxSpace
        HasStorage = $true
        CanAct = $script:CanAct
      }) | Out-Null
    } else {
      $storageRows.Add([pscustomobject]@{
        Letter = $letter
        UsedText = '—'
        AllocText = '—'
        MaxText = '未设置'
        Pct = 0
        PctText = '—'
        DiffLetter = $letter
        MaxBytes = [uint64]0
        HasStorage = $false
        CanAct = $script:CanAct
      }) | Out-Null
    }
  }

$providerRows = New-Object System.Collections.Generic.List[object]
  foreach ($p in $providers) {
    $typeText = switch ($p.Type) { 1 { '系统' } 2 { '软件' } 3 { '硬件' } default { '未知' } }
    $typeBrush = switch ($p.Type) { 1 { $script:Brush_Accent } 2 { $script:Brush_Success } 3 { $script:Brush_Warn } default { $script:Brush_Faint } }
    $providerRows.Add([pscustomobject]@{
      Name = $p.Name; TypeText = $typeText; TypeBrush = $typeBrush
      Version = $p.Version; Id = $p.ID.ToUpper(); Clsid = $p.CLSID.ToUpper()
    }) | Out-Null
  }

  $cards = New-Object System.Collections.Generic.List[object]
  foreach ($d in $disks) {
    $letter = $d.DeviceID.TrimEnd('\')
    $sc = @($shadowRows | Where-Object { $_.Letter -eq $letter })
    $newest = $null
    foreach ($s in $sc) {
      $t = [datetime]::MinValue
      if ([datetime]::TryParseExact($s.CreatedText, 'yyyy/MM/dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { $newest = $t }
    }
    $stRow = $storageRows | Where-Object { $_.Letter -eq $letter } | Select-Object -First 1
    $pctUsed = if ($d.Size -gt 0) { ($d.Size - $d.FreeSpace) / $d.Size * 100 } else { 0 }
    $cards.Add([pscustomobject]@{
      Letter = $letter
      Label = if ($d.VolumeName) { $d.VolumeName } else { '本地磁盘' }
      SpaceText = ('可用 {0} / 共 {1}' -f (Format-Size $d.FreeSpace), (Format-Size $d.Size))
      PctUsed = [double]$pctUsed
      BarUsed = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', $pctUsed)
      BarFree = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', ([Math]::Max(100 - $pctUsed, 0)))
      ShadowCountText = ('{0} 个卷影' -f $sc.Count)
      NewestText = if ($newest) { ('最新 {0}' -f $newest.ToString('MM/dd HH:mm')) } else { '无卷影副本' }
      Active = $false
      CanAct = $script:CanAct
    }) | Out-Null
  }

$writersRaw = ''
  try {
    $wtool = Invoke-ToolBg -Exe $script:VssAdmin -ArgStr 'list writers' -TimeoutSec 120
    if ($wtool) { & $logQ 'vssadmin' 'list writers' $wtool.ExitCode $wtool.Duration $wtool.Output; $writersRaw = $wtool.Output }
  } catch {}
  $writers = Parse-Writers $writersRaw
  $vssState = 'unknown'
  $vssStart = ''
  $scExe = Join-Path $env:SystemRoot 'System32\sc.exe'
  try {
    $q = Invoke-ToolBg -Exe $scExe -ArgStr 'query VSS' -TimeoutSec 15
    if ($q) {
      & $logQ 'sc' 'query VSS' $q.ExitCode $q.Duration $q.Output
      $m = [regex]::Match($q.Output, 'STATE\s*:\s*(\d+)\s*(\w+)')
      if ($m.Success) { $vssState = $m.Groups[2].Value }
    }
  } catch {}
  try {
    $qc = Invoke-ToolBg -Exe $scExe -ArgStr 'qc VSS' -TimeoutSec 15
    if ($qc) {
      & $logQ 'sc' 'qc VSS' $qc.ExitCode $qc.Duration $qc.Output
      $m2 = [regex]::Match($qc.Output, 'START_TYPE\s*:\s*(\d+)\s*(\w+)')
      if ($m2.Success) {
        $code = [int]$m2.Groups[1].Value
        $vssStart = if ($code -eq 4) { 'Disabled' } elseif ($code -eq 2) { 'Auto' } else { 'Manual' }
      }
    }
  } catch {}

  return @{
    Cards = $cards; Shadows = $shadowRows; Storage = $storageRows
    Providers = $providerRows; Writers = $writers; WritersRaw = $writersRaw
    VssRunning = ($vssState -eq 'RUNNING'); VssState = $vssState; VssStart = $vssStart
    Queries = $qLog
    Time = Get-Date
  }
}

function Update-ShadowsView {
  $cache = $script:Cache
  if (-not $cache) { return }
  foreach ($card in $cache.Cards) { $card.Active = ($script:FilterLetter -and $card.Letter -eq $script:FilterLetter) }
  # 强制重建容器:pscustomobject 无 INotifyPropertyChanged,且 ItemsSource 同引用时 WPF 不刷新,必须置 null 再赋值让 DataTrigger 重新评估 Active
  $cardHost = Get-N 'cardHost'
  $cardHost.ItemsSource = $null
  $cardHost.ItemsSource = $cache.Cards
  if ($script:FilterLetter) { $rows = [System.Collections.Generic.List[object]]::new(); foreach ($sh in $cache.Shadows) { if ($sh.Letter -eq $script:FilterLetter) { $rows.Add($sh) } } } else { $rows = $cache.Shadows }
  (Get-N 'lstShadows').ItemsSource = $rows
  (Get-N 'emptyShadows').Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
  if ($rows.Count -eq 0) {
    if ($script:CanAct) {
      (Get-N 'txtEmptyTitle').Text = '尚无卷影副本'
      (Get-N 'txtEmptySub').Text = '点击卷卡片上的 创建卷影,写时复制会在数秒内完成快照。'
    } else {
      (Get-N 'txtEmptyTitle').Text = '需要管理员权限'
      (Get-N 'txtEmptySub').Text = '点击左上角"以管理员身份重新启动"后,可查看并创建卷影副本。'
    }
  }
  $chip = Get-N 'chipFilter'
  $chip.Visibility = if ($script:FilterLetter) { 'Visible' } else { 'Collapsed' }
  if ($script:FilterLetter) { (Get-N 'txtFilter').Text = ('选中{0}：取消' -f $script:FilterLetter) }
  $enabled = [bool]$script:FilterLetter
  (Get-N 'btnShadowCreate').IsEnabled = $enabled -and $script:CanAct
  (Get-N 'btnShadowOldest').IsEnabled = $enabled -and $script:CanAct
  (Get-N 'btnShadowAll').IsEnabled = $enabled -and $script:CanAct
  try { Apply-SavedSort } catch {}
}

function Update-OtherViews {
  $cache = $script:Cache
  if (-not $cache) { return }
  (Get-N 'lstStorage').ItemsSource = $cache.Storage
  (Get-N 'lstProviders').ItemsSource = $cache.Providers
  (Get-N 'lstWriters').ItemsSource = $cache.Writers
  if ($cache.Writers) {
    $stable = @($cache.Writers | Where-Object { $_.State -eq 1 }).Count
    $fail = @($cache.Writers | Where-Object { $_.State -ge 5 }).Count
    $wait = @($cache.Writers | Where-Object { $_.State -ge 2 -and $_.State -le 4 }).Count
    (Get-N 'txtWritersSummary').Text = ('{0} 个写入程序 · {1} 稳定 · {2} 等待 · {3} 失败' -f $cache.Writers.Count, $stable, $wait, $fail)
  } else {
    (Get-N 'txtWritersSummary').Text = '0 个写入程序'
  }
  $dot = Get-N 'dotVss'
  if ($cache.VssRunning) {
    $dot.Background = $window.Resources['C_Success']
    (Get-N 'txtVss').Text = 'VSS 服务: 运行中'
  } elseif ($cache.VssStart -eq 'Disabled') {
    $dot.Background = $window.Resources['C_Danger']
    (Get-N 'txtVss').Text = 'VSS 服务: 已禁用,卷影不可用'
  } elseif ($cache.VssState -eq 'STOPPED') {
    $dot.Background = $window.Resources['C_Faint']
    (Get-N 'txtVss').Text = 'VSS 服务: 就绪(按需启动)'
  } else {
    $dot.Background = $window.Resources['C_Faint']
    (Get-N 'txtVss').Text = 'VSS 服务: 状态检测中'
  }
  (Get-N 'txtLastRefresh').Text = ('上次刷新 {0}' -f $cache.Time.ToString('HH:mm:ss'))
  try { Apply-SavedSort } catch {}
}

# 后台 body 构建: 缓存函数 AST(只解析一次主脚本, 3 个 body 复用), 避免每次启动重复 ParseFile 3500 行
$script:BgBodyFns = $null
function Get-BgBody {
  param([string[]]$Functions, [string]$Epilogue)
  if (-not $script:BgBodyFns) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
    $script:BgBodyFns = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  }
  $all = $script:BgBodyFns
  $sb = New-Object System.Text.StringBuilder
  foreach ($n in $Functions) {
    $f = $all | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if ($f) { [void]$sb.AppendLine($f.Extent.Text) }
  }
  [void]$sb.AppendLine($Epilogue)
  return $sb.ToString()
}

# ===== 异步任务队列: 所有耗时操作入队后台执行, 不阻塞 UI; 最多并发 $script:TaskMaxRun 个; 刷新任务自动合并 =====
$script:TaskQueue = New-Object System.Collections.Generic.List[object]
$script:TaskRunning = @{}
$script:TaskSeq = 0
$script:TaskMaxRun = 2
$script:PendingRefresh = $false
$script:BgPump = $null

# 入队一个后台任务; -IsRefresh 表示系统状态刷新(队列/运行中已有刷新则跳过合并, 返回 $false)
function Add-Task {
  param([string]$Name, [string]$Body, [ScriptBlock]$OnDone, [object[]]$ArgList = @(), [switch]$IsRefresh, [switch]$Quiet)
  if ($IsRefresh) {
    foreach ($t in $script:TaskQueue) { if ($t.IsRefresh) { return $false } }
    foreach ($k in $script:TaskRunning.Keys) { if ($script:TaskRunning[$k].IsRefresh) { return $false } }
  }
  $script:TaskSeq++
  $task = [pscustomobject]@{
    Seq = $script:TaskSeq; Name = $Name; Body = $Body; ArgList = $ArgList
    OnDone = $OnDone; IsRefresh = [bool]$IsRefresh; Quiet = [bool]$Quiet
    PS = $null; Async = $null; StartTime = $null
  }
  $script:TaskQueue.Add($task)
  Start-TaskPump
  return $true
}

function Start-TaskPump {
  if (-not $script:BgPump) {
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(100)
    $t.add_Tick({ Pump-Tasks })
    $t.Start()
    $script:BgPump = $t
  }
}

function Pump-Tasks {
  # 1. 收集并处理已完成的任务(OnDone 在 UI 线程串行执行, 天然安全)
  $finished = New-Object System.Collections.Generic.List[object]
  foreach ($k in $script:TaskRunning.Keys) {
    $t = $script:TaskRunning[$k]
    if ($t.Async -and $t.Async.IsCompleted) { $finished.Add($t) }
  }
  foreach ($t in $finished) {
    $script:TaskRunning.Remove($t.Seq)
    $res = $null; $err = ''; $ok = $false
    try {
      $out = $t.PS.EndInvoke($t.Async)
      if ($out -and $out.Count -gt 0) { $res = $out[$out.Count - 1] }
      $ok = $true
    } catch {
      $err = $_.Exception.Message
      try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString()) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
    } finally {
      try { $t.PS.Dispose() } catch {}
    }
    if ($t.OnDone) {
      try { & $t.OnDone $ok $res $err } catch {
        try {
          $rt = if ($null -eq $res) { 'null' } elseif ($res -is [System.Collections.IDictionary]) { 'hashtable:' + (($res.Keys) -join ',') } else { $res.GetType().FullName }
          [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[od ' + (Get-Date -Format 'HH:mm:ss.fff') + ' task=' + $t.Name + ' ok=' + $ok + ' res=' + $rt + ' err=[' + $err + ']] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | ')) + "`r`n", (New-Object Text.UTF8Encoding $true))
        } catch {}
      }
    }
  }
  # 2. 从队列启动新任务直到并发上限
  while ($script:TaskRunning.Count -lt $script:TaskMaxRun -and $script:TaskQueue.Count -gt 0) {
    $task = $script:TaskQueue[0]
    $script:TaskQueue.RemoveAt(0)
    try {
      $ps = [System.Management.Automation.PowerShell]::Create()
      [void]$ps.AddScript($task.Body)
      foreach ($a in $task.ArgList) { [void]$ps.AddArgument($a) }
      $async = $ps.BeginInvoke()
      $task.PS = $ps; $task.Async = $async; $task.StartTime = Get-Date
      $script:TaskRunning[$task.Seq] = $task
    } catch {
      # 启动失败: 直接回调 OnDone 报告错误, 避免任务卡死
      try { if ($task.OnDone) { & $task.OnDone $false $null $_.Exception.Message } } catch {}
      try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[task start ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString()) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
    }
  }
  # 3. 空则停泵(避免 100ms 空转); 更新状态指示器
  if ($script:TaskRunning.Count -eq 0 -and $script:TaskQueue.Count -eq 0) {
    if ($script:BgPump) { try { $script:BgPump.Stop() } catch {}; $script:BgPump = $null }
  }
  Update-StatusIndicator
}

function Refresh-All {
  # 更新主题画刷(刷新任务后台使用; 每次调用幂等刷新)
  try {
    $script:Brush_Accent = $window.Resources['C_Accent']
    $script:Brush_Success = $window.Resources['C_Success']
    $script:Brush_Warn = $window.Resources['C_Warn']
    $script:Brush_Danger = $window.Resources['C_Danger']
    $script:Brush_Faint = $window.Resources['C_Faint']
  } catch {}
  $added = Add-Task -IsRefresh -Name '正在读取系统状态' -Body $script:BgBody -ArgList @($script:CanAct, $script:VssAdmin, $script:Brush_Accent, $script:Brush_Success, $script:Brush_Warn, $script:Brush_Danger, $script:Brush_Faint) -OnDone {
    param($ok, $res, $err)
    if ($ok -and $res) {
      $script:Cache = $res
      # 各视图更新独立 try: 单个视图失败不影响其他视图与下次刷新
      try {
        if ($res.Queries) {
          foreach ($qq in $res.Queries) { $script:Log.Add($qq) | Out-Null }
          Update-LogView
        }
      } catch {
        try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[view log ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | ')) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
      }
      try { Update-ShadowsView } catch {
        try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[view shadows ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | ')) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
      }
      try { Update-OtherViews } catch {
        try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\taskerr.log'), ('[view other ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | ')) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
      }
    } else {
      $script:Cache = $null
      $script:CacheError = $err
      try {
        (Get-N 'dotVss').Background = $window.Resources['C_Danger']
        (Get-N 'txtVss').Text = 'VSS 服务: 读取失败'
        (Get-N 'txtLastRefresh').Text = ('上次刷新 失败: ' + $err)
      } catch {}
      Show-Toast -Message ('读取系统状态失败: ' + $err) -Type 'err'
    }
    # 若刷新期间有新请求被合并跳过, 补刷一次保证视图最新(如写操作恰在刷新读完后完成)
    if ($script:PendingRefresh) {
      $script:PendingRefresh = $false
      try { Refresh-All } catch {}
    }
  }
  if ($added) {
    # 事件驱动进度:清空进度文件,后台每完成一个查询阶段追加一行,指示器读取后实时显示
    try { [IO.Directory]::CreateDirectory((Split-Path -Parent $script:ProgressFile)) | Out-Null } catch {}
    try { [IO.File]::WriteAllText($script:ProgressFile, '') } catch {}
    $script:ProgLine = 0
  } else {
    # 已有刷新在运行/排队 → 标记待补刷(当前刷新完成后自动再刷一次)
    $script:PendingRefresh = $true
  }
}

function Update-LogView {
  while ($script:Log.Count -gt 500) { $script:Log.RemoveAt(0) }
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($e in $script:Log) {
    $items.Add([pscustomobject]@{
      TimeText = $e.Time.ToString('HH:mm:ss')
      Tool = $e.Tool
      Args = $e.Args
      ExitText = if ($e.Running) { '…' } else { [string]$e.ExitCode }
      CodeBrush = if ($e.Running) { $window.Resources['C_Faint'] } elseif ($e.ExitCode -eq 0) { $window.Resources['C_Success'] } else { $window.Resources['C_Danger'] }
    }) | Out-Null
  }
  $list = Get-N 'lstLog'
  $list.ItemsSource = $items
  if ($items.Count -gt 0) {
    $list.SelectedIndex = $items.Count - 1
    $list.ScrollIntoView($items[$items.Count - 1])
  }
  try { Apply-SavedSort } catch {}
}

function Set-Nav {
  param([int]$Index)
  $script:NavIndex = $Index
  for ($i = 0; $i -lt $script:NavNames.Count; $i++) {
    $btn = Get-N $script:NavNames[$i]
    $page = Get-N $script:PageNames[$i]
    if ($i -eq $Index) {
      $page.Visibility = 'Visible'
      $btn.Background = $window.Resources['C_AccentSoft']
      $btn.Foreground = $window.Resources['C_Accent']
    } else {
      $page.Visibility = 'Collapsed'
      $btn.Background = 'Transparent'
      $btn.Foreground = $window.Resources['C_Sub']
    }
  }
  try { Schedule-SettingsSave } catch {}
}

function Show-Confirm {
  param([string]$Title, [string]$Message, [string]$Cmd, [switch]$Danger)
  (Get-N 'txtConfirmTitle').Text = $Title
  (Get-N 'txtConfirmMsg').Text = $Message
  (Get-N 'txtConfirmCmd').Text = $Cmd
  (Get-N 'txtConfirmCmd').Visibility = if ($Cmd) { 'Visible' } else { 'Collapsed' }
  $ok = Get-N 'btnConfirmOK'
  $ok.Style = if ($Danger) { $window.FindResource('st_btnDanger') } else { $window.FindResource('st_btnPrimary') }
  $script:ConfirmResult = $false
  (Get-N 'grdConfirm').Visibility = 'Visible'
  $frame = [System.Windows.Threading.DispatcherFrame]::new()
  $script:ConfirmFrame = $frame
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)
  return $script:ConfirmResult
}

function Show-ResizeDialog {
  param([string]$Letter, [string]$CurText, [uint64]$CurBytes)
  (Get-N 'txtResizeTitle').Text = ('调整存储配额 · {0}' -f $Letter)
  (Get-N 'txtResizeCur').Text = '当前: ' + $CurText
  $isUnbounded = ($CurBytes -eq [uint64]::MaxValue -or $CurBytes -eq 0)
  (Get-N 'rbResizeAuto').IsChecked = $isUnbounded
  (Get-N 'rbResizeCustom').IsChecked = -not $isUnbounded
  (Get-N 'txtResizeGB').Text = if ($isUnbounded) { '' } else { [string]::Format($script:InvCulture, '{0:0}', ($CurBytes / 1GB)) }
  $script:ResizeResult = $null
  (Get-N 'grdResize').Visibility = 'Visible'
  $frame = [System.Windows.Threading.DispatcherFrame]::new()
  $script:ResizeFrame = $frame
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)
  return $script:ResizeResult
}

function Test-GBInput {
  param([string]$Text)
  $n = 0.0
  if ([double]::TryParse($Text, [ref]$n)) { return ($n -gt 0) }
  return $false
}

function Invoke-CreateShadow {
  param([string]$Letter)
  if (-not $script:CanAct -or -not $Letter) { return }
  $letter = $Letter.TrimEnd('\')
  if (Show-Confirm -Title ('创建卷影 · ' + $letter) -Message '写时复制会在数秒内创建一份当前时点的卷影,期间卷的读写不受影响。' -Cmd ('Win32_ShadowCopy.Create(Volume="' + $letter + ':\", Context="ClientAccessible")')) {
    Invoke-SystemTool -Tool 'wmi' -ArgList @($letter) -Label '正在创建卷影' -OnDone {
      param($e)
      if ($e.ExitCode -eq 0) {
        Show-Toast -Message ('已创建 {0} 卷影副本' -f $letter)
        Refresh-All
      } else {
        Show-Toast -Message ('创建失败: ' + $e.Output) -Type 'err'
      }
    }.GetNewClosure()
  }
}

function Open-ShadowBrowser {
  param($Shadow)
  if (-not $Shadow) { return }
  $letter = $Shadow.Letter
  $gmt = $Shadow.GmtStamp
  if (-not $letter -or -not $gmt) {
    Show-Toast -Message '该卷影缺少浏览所需信息' -Type 'warn'
    return
  }
  # Windows 标准卷影访问路径:\\localhost\X$\@GMT-YYYY.MM.DD-HH.MM.SS (UTC)
  $uncPath = '\\localhost\' + $letter.TrimEnd(':') + '$\@GMT-' + $gmt
  $share = '\\localhost\' + $letter.TrimEnd(':') + '$'
  # 后台队列执行(任务队列 runspace 环境完整, UI 零阻塞):
  # ①确认/建立共享连接(系统级 net use, 捕获输出便于诊断) ②验证 @GMT 卷影路径可解析
  #   (仅"可访问"类型快照支持资源管理器浏览) ③explorer 打开; 任一步失败回传明确提示
  $body = @'
$share = $args[0]
$unc = $args[1]
try {
  $connected = $false
  try { $connected = [System.IO.Directory]::Exists($share) } catch {}
  if (-not $connected) {
    $diag = $null
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = (Join-Path $env:SystemRoot 'System32\net.exe')
      $psi.Arguments = 'use ' + $share + ' /persistent:no'
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $o = $p.StandardOutput.ReadToEnd()
      $er = $p.StandardError.ReadToEnd()
      $p.WaitForExit(8000) | Out-Null
      $diag = ('net use exit=' + $p.ExitCode + ' [' + $o.Trim() + ']' + $(if ($er.Trim()) { ' [' + $er.Trim() + ']' } else { '' }))
      if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    } catch { $diag = 'net use 异常: ' + $_.Exception.Message }
    try { $connected = [System.IO.Directory]::Exists($share) } catch {}
    if (-not $connected) {
      return ('无法连接共享 ' + $share + $(if ($diag) { ' — ' + $diag } else { '' }))
    }
  }
  $ok = $false
  try { $ok = [System.IO.Directory]::Exists($unc) } catch {}
  if (-not $ok) {
    return ('卷影路径不可访问 ' + $unc + ' — 该快照可能不支持资源管理器浏览(仅"可访问"类型快照可浏览)')
  }
  try {
    $e = New-Object System.Diagnostics.ProcessStartInfo
    $e.FileName = 'explorer.exe'
    $e.Arguments = $unc
    $e.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($e) | Out-Null
    return 'OK'
  } catch { return ('打开资源管理器失败: ' + $_.Exception.Message) }
} catch { return ('打开卷影异常: ' + $_.Exception.Message) }
'@
  Add-Task -Name '正在打开卷影' -Body $body -ArgList @($share, $uncPath) -Quiet -OnDone {
    param($ok, $res, $err)
    if ($res -and $res -ne 'OK') { Show-Toast -Message $res -Type 'warn' }
  }
}

function Invoke-DeleteShadow {
  param([string]$Id)
  if (-not $script:CanAct -or -not $Id) { return }
if (Show-Confirm -Title '删除卷影副本' -Message '将删除指定的卷影副本并释放对应差异存储空间。' -Cmd ('vssadmin delete shadows /shadow=' + $Id + ' /quiet') -Danger) {
    Invoke-SystemTool -Tool 'vssadmin' -ArgList @('delete', 'shadows', ('/shadow=' + $Id), '/quiet') -Label '正在删除卷影' -OnDone {
      param($e)
      if ($e.ExitCode -eq 0) {
        Show-Toast '已删除卷影副本'
        Refresh-All
      } else {
        Show-Toast -Message ('删除失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
      }
    }.GetNewClosure()
  }
}

function Invoke-ResizeFor {
  param([string]$Letter)
  if (-not $script:CanAct -or -not $Letter) { return }
  $row = @($script:Cache.Storage | Where-Object { $_.Letter -eq $Letter } | Select-Object -First 1)
  if (-not $row) { Show-Toast -Message '该卷没有存储配额记录' -Type 'warn'; return }
  $hasStorage = [bool]$row.HasStorage
  $curText = if ($hasStorage) { ('已用 {0} / 上限 {1}' -f $row.UsedText, $row.MaxText) } else { '尚未设置存储配额' }
  $result = Show-ResizeDialog -Letter $Letter -CurText $curText -CurBytes $row.MaxBytes
  if (-not $result) { return }
  # 首次设置(无存储关联)用 create,已有用 resize;DiffLetter 解析失败时用卷自身兜底
  $op = if ($hasStorage) { 'resize' } else { 'create' }
  $diff = if ($row.DiffLetter -and $row.DiffLetter -ne '—') { $row.DiffLetter } else { $Letter }
  $resizeArgs = @($op, 'shadowstorage', ('/for=' + $Letter), ('/on=' + $diff))
  if ($result.Mode -eq 'auto') { $resizeArgs += '/maxsize=UNBOUNDED' } else { $resizeArgs += [string]::Format($script:InvCulture, '/maxsize={0:0}GB', $result.GB) }
  Invoke-SystemTool -Tool 'vssadmin' -ArgList $resizeArgs -Label ('正在调整配额 · ' + $Letter) -OnDone {
    param($e)
    if ($e.ExitCode -eq 0) {
      Show-Toast -Message ('已设置 {0} 存储配额' -f $Letter)
      Refresh-All
    } else {
      Show-Toast -Message ('调整失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
    }
  }.GetNewClosure()
}

function Invoke-DeleteOldest {
  param([string]$Letter)
  if (-not $script:CanAct -or -not $Letter) { return }
if (Show-Confirm -Title ('删除最旧卷影 · ' + $Letter) -Message '将删除该卷最早的卷影副本,用于释放差异存储空间。' -Cmd ('vssadmin delete shadows /for=' + $Letter + ' /oldest /quiet') -Danger) {
    Invoke-SystemTool -Tool 'vssadmin' -ArgList @('delete', 'shadows', ('/for=' + $Letter), '/oldest', '/quiet') -Label '正在删除最旧卷影' -OnDone {
      param($e)
      if ($e.ExitCode -eq 0) {
        Show-Toast '已删除最旧卷影'
        Refresh-All
      } else {
        Show-Toast -Message ('删除失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
      }
    }.GetNewClosure()
  }
}

function Invoke-DeleteAll {
  param([string]$Letter)
  if (-not $script:CanAct -or -not $Letter) { return }
if (Show-Confirm -Title ('全部删除 · ' + $Letter) -Message '将删除该卷的全部卷影副本并释放全部差异存储空间。此操作不可撤销!' -Cmd ('vssadmin delete shadows /for=' + $Letter + ' /all /quiet') -Danger) {
    Invoke-SystemTool -Tool 'vssadmin' -ArgList @('delete', 'shadows', ('/for=' + $Letter), '/all', '/quiet') -Label '正在删除全部卷影' -OnDone {
      param($e)
      if ($e.ExitCode -eq 0) {
        Show-Toast '已删除全部卷影'
        Refresh-All
      } else {
        Show-Toast -Message ('删除失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
      }
    }.GetNewClosure()
  }
}

try {
  $window = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
} catch {
  $detail = $_.Exception.InnerException.Message
  throw "窗口 XAML 解析失败: $detail"
}
if (-not $window) { throw '窗口对象未能创建' }

$script:NavNames = @('navShadows','navStorage','navDiskShadow','navLog','navSysInfo')
$script:PageNames = @('pageShadows','pageStorage','pageDiskShadow','pageLog','pageSysInfo')

for ($i = 0; $i -lt $script:NavNames.Count; $i++) {
  $btn = Get-N $script:NavNames[$i]
  $btn.Tag = $i
  $btn.add_Click([System.Windows.RoutedEventHandler]{ Set-Nav ([int]$this.Tag) })
}

try {

Set-Nav 0
(Get-N 'btnRefresh').add_Click({ Refresh-All })
(Get-N 'btnDocs').add_Click({ Start-Process 'https://learn.microsoft.com/zh-cn/windows-server/storage/file-server/volume-shadow-copy-service' })
(Get-N 'btnRelaunch').add_Click({
  $hostExe = (Get-Process -Id $PID).Path
  Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") -Verb RunAs | Out-Null
  $window.Close()
})
(Get-N 'btnTheme').add_Click({
  # 两态循环(Light/Dark 互切): System 先解析为系统实际主题, 避免 System(亮)=Light 视觉重复
  # 导致"白切黑要点两次"(原循环 System→Light→Dark→System 在系统为亮色时 System 与 Light 视觉相同, 中间那一次点击无变化)
  $eff = $script:ThemeMode
  if ($eff -eq 'System') {
    $light = 1
    try { $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme } catch {}
    $eff = if ($light -eq 1) { 'Light' } else { 'Dark' }
  }
  Set-Theme $(if ($eff -eq 'Dark') { 'Light' } else { 'Dark' })
  try { Save-Settings @{ Theme = $script:ThemeMode } } catch {}
})
(Get-N 'chipFilter').add_MouseLeftButtonUp({
  $script:FilterLetter = $null
  Update-ShadowsView
})
(Get-N 'btnShadowCreate').add_Click({ if ($script:FilterLetter) { Invoke-CreateShadow $script:FilterLetter } })
(Get-N 'btnShadowOldest').add_Click({ if ($script:FilterLetter) { Invoke-DeleteOldest $script:FilterLetter } })
(Get-N 'btnShadowAll').add_Click({ if ($script:FilterLetter) { Invoke-DeleteAll $script:FilterLetter } })
(Get-N 'btnStorageResize').add_Click({
  $sel = (Get-N 'lstStorage').SelectedItem
  if ($sel) { Invoke-ResizeFor $sel.Letter }
})
(Get-N 'btnLogCopy').add_Click({
  $txt = (Get-N 'txtLogDetail').Text
  if ($txt) { [System.Windows.Clipboard]::SetText($txt); Show-Toast '已复制到剪贴板' }
})
(Get-N 'btnLogClear').add_Click({
  $script:Log.Clear()
  Update-LogView
  (Get-N 'txtLogDetail').Text = ''
})

$script:SchedPrefix = 'ShadowConsole-'
$script:SchedEditing = $null

# 用 Get-ScheduledTask 读取任务(结构化对象,无 CSV 解析问题; schtasks CSV 输出格式不规范导致回读失败)
function Get-SchedTasks {
  $list = New-Object System.Collections.Generic.List[object]
  $dbgLog = Join-Path $env:TEMP 'shadowconsole\sched_query.log'
  try {
    $ts = @(Get-ScheduledTask -TaskPath '\ShadowConsole\' -ErrorAction SilentlyContinue)
    try { [IO.File]::AppendAllText($dbgLog, ('[{0}] Get-ScheduledTask returned {1} tasks' -f (Get-Date -Format 'HH:mm:ss.fff'), $ts.Count) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
    foreach ($t in $ts) {
      try {
        $taskName = $t.TaskName
        # 运行信息(上次/下次/结果)可能读取失败,单独容错
        $lastRun = ''; $nextRun = ''; $lastRes = ''
        try {
          $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\ShadowConsole\' -ErrorAction SilentlyContinue
          if ($info) {
            $lastRun = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('yyyy/MM/dd HH:mm:ss') } else { '' }
            $nextRun = if ($info.NextRunTime -and $info.NextRunTime.Year -gt 2000) { $info.NextRunTime.ToString('yyyy/MM/dd HH:mm:ss') } else { '' }
            $lastRes = '0x{0:x}' -f $info.LastTaskResult
          }
        } catch {}
        $enabled = ($t.State -in @('Ready','Running','Queued'))
        # 从 Actions[0].Arguments 解析参数(结构化字符串,无 CSV 引号问题)
        $cmd = ''
        if ($t.Actions -and $t.Actions[0]) { $cmd = [string]$t.Actions[0].Arguments }
        $letter = ''; $times = @(); $type = 'day'; $interval = 1; $week = @(); $monthDay = 1; $sawa = $true; $comment = ''
        if ($cmd -match '-L\s+"?(\w:)"?') { $letter = $Matches[1] }
        elseif ($cmd -match 'L=(\w:)') { $letter = $Matches[1] }
        if ($cmd -match '-T\s+"?([0-9:, ]*)"?') { $times = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        elseif ($cmd -match 'T=(\d{1,2}:\d{2})') { $times = @($Matches[1]) }
        if ($cmd -match '-TYPE\s+(\w+)') { $type = $Matches[1] }
        if ($cmd -match '-INT\s+(\d+)') { $interval = [int]$Matches[1] }
        if ($cmd -match '-W\s+"?([0-9,]+)"?') { $week = @($Matches[1] -split ',' | ForEach-Object { [int]$_.Trim() } | Where-Object { $_ -gt 0 }) }
        if ($cmd -match '-MD\s+(\d+)') { $monthDay = [int]$Matches[1] }
        if ($cmd -match '-SAWA\s+(\d)') { $sawa = ($Matches[1] -eq '1') }
        if ($type -notin @('minute','hour') -and $times.Count -eq 0) { $times = @('09:00') }
        $timeText = $times -join ','
        $planText = Get-SchedPlanText -Type $type -Times $times -Interval $interval -Week $week -MonthDay $monthDay
        $resInfo = Get-TaskResultInfo $lastRes
        $list.Add([pscustomobject]@{
          TaskName = $taskName
          Letter = $letter
          TimeText = $timeText
          Type = $type
          Interval = $interval
          Week = $week
          MonthDay = $monthDay
          Sawa = $sawa
          Comment = $comment
          Enabled = $enabled
          StateText = if ($enabled) { '已启用' } else { '已禁用' }
          StateBrush = if ($enabled) { $window.Resources['C_Success'] } else { $window.Resources['C_Faint'] }
          PlanText = $planText
          LastRunText = if ($lastRun) { $lastRun } else { '—' }
          NextRunText = if ($nextRun) { $nextRun } else { '—' }
          ResultText = $resInfo.Text
          ResultHint = $resInfo.Hint
          ResultBrush = $resInfo.Brush
        }) | Out-Null
        try { [IO.File]::AppendAllText($dbgLog, ('    -> parsed: ' + $taskName + ' letter=' + $letter + ' times=' + $timeText + ' type=' + $type) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
      } catch {
        try { [IO.File]::AppendAllText($dbgLog, ('    task EXCEPTION: ' + $_.Exception.Message) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
      }
    }
  } catch {
    try { [IO.File]::AppendAllText($dbgLog, ('    EXCEPTION: ' + $_.Exception.Message) + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch {}
  }
  # 关键:强制返回数组,防 PowerShell 单元素自动展开成 PSCustomObject 导致 ItemsSource 绑定失败
  return ,$list
}

# 运行结果码翻译
function Get-TaskResultInfo {
  param([string]$Code)
  $code = ($code -replace '\s','').ToLower()
  $brush = $window.Resources['C_Sub']
  $text = $code; $hint = $code
  if (-not $code) { $text = '—'; $hint = '从未运行' }
  elseif ($code -eq '0x0') { $text = '0x0 成功'; $hint = '上次运行成功完成'; $brush = $window.Resources['C_Success'] }
  elseif ($code -eq '0x41303') { $text = '0x41303 未运行'; $hint = '任务尚未运行过'; $brush = $window.Resources['C_Faint'] }
  elseif ($code -eq '0x41301') { $text = '0x41301 已禁用'; $hint = '任务被禁用时未运行'; $brush = $window.Resources['C_Faint'] }
  elseif ($code -eq '0x41300') { $text = '0x41300 运行中'; $hint = '任务当前正在运行'; $brush = $window.Resources['C_Warn'] }
  elseif ($code -eq '0x1') { $text = '0x1 一般错误'; $hint = '发生未指定的错误'; $brush = $window.Resources['C_Danger'] }
  elseif ($code -eq '0x80070002') { $text = '0x80070002 找不到文件'; $hint = '命令或脚本路径不存在'; $brush = $window.Resources['C_Danger'] }
  elseif ($code -eq '0x800710e0') { $text = '0x800710E0 拒绝请求'; $hint = '操作被拒绝(可能因权限)'; $brush = $window.Resources['C_Danger'] }
  elseif ($code -eq '0x8004131f') { $text = '0x8004131F 未就绪'; $hint = '任务未准备好运行'; $brush = $window.Resources['C_Warn'] }
  elseif ($code -match '^0x') { $text = $code; $hint = '未知结果码,可查看任务计划程序事件日志'; $brush = $window.Resources['C_Warn'] }
  return [pscustomobject]@{ Text = $text; Hint = $hint; Brush = $brush }
}

# 计划描述文本
function Get-SchedPlanText {
  param([string]$Type, [string[]]$Times, [int]$Interval, [int[]]$Week, [int]$MonthDay)
  $timeText = ($Times -join ',')
  $wdNames = @('','周一','周二','周三','周四','周五','周六','周日')
  switch ($Type) {
    'minute' {
      $iv = if ($Interval -lt 1) { 1 } else { $Interval }
      return ('每 ' + $iv + ' 分钟')
    }
    'hour' {
      $iv = if ($Interval -lt 1) { 1 } else { $Interval }
      return ('每 ' + $iv + ' 小时')
    }
    'week' {
      $sel = @($Week | Sort-Object | ForEach-Object { if ($_ -ge 1 -and $_ -le 7) { $wdNames[$_] } })
      if ($sel.Count -eq 7) { $d = '每天' }
      elseif ($sel.Count -eq 5 -and ($Week -contains 1) -and ($Week -contains 2) -and ($Week -contains 3) -and ($Week -contains 4) -and ($Week -contains 5)) { $d = '工作日' }
      else { $d = ($sel -join ',') }
      return ('每周 ' + $d + ' ' + $timeText)
    }
    'month' {
      $dd = if ($MonthDay -ge 31) { '最后一天' } else { ([string]$MonthDay + '日') }
      return ('每月 ' + $dd + ' ' + $timeText)
    }
    default {
      if ($Interval -gt 1) { return ('每 ' + $Interval + ' 天 ' + $timeText) }
      return ('每天 ' + $timeText)
    }
  }
}

# 生成计划触发器 XML(多时间点 → 多个 CalendarTrigger; 分钟/小时 → ScheduleByDay + Repetition 全天循环)
# 注意 schema 子元素顺序: StartBoundary → Enabled → Repetition → ScheduleByX (Repetition 必须在 Schedule 之前,否则报 "unexpected node")
function Get-SchedTriggersXml {
  param([string]$Type, [string[]]$Times, [int]$Interval, [int[]]$Week, [int]$MonthDay)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('<Triggers>')
  if ($Type -eq 'minute' -or $Type -eq 'hour') {
    # 全天循环:每天 00:00 触发一次,并重复直到禁用
    $rep = if ($Type -eq 'minute') { ('PT' + $Interval + 'M') } else { ('PT' + $Interval + 'H') }
    [void]$sb.Append('<CalendarTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary><Enabled>true</Enabled>')
    [void]$sb.Append('<Repetition><Interval>' + $rep + '</Interval><Duration>P1D</Duration><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>')
    [void]$sb.Append('<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>')
    [void]$sb.Append('</CalendarTrigger>')
    [void]$sb.Append('</Triggers>')
    return $sb.ToString()
  }
  foreach ($t in $Times) {
    [void]$sb.Append('<CalendarTrigger><StartBoundary>2026-01-01T' + $t + ':00</StartBoundary><Enabled>true</Enabled>')
    switch ($Type) {
      'week' {
        [void]$sb.Append('<ScheduleByWeek><WeeksInterval>1</WeeksInterval><DaysOfWeek>')
        $xmlDays = @('','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
        foreach ($d in ($Week | Sort-Object)) {
          if ($d -ge 1 -and $d -le 7) { [void]$sb.Append('<' + $xmlDays[$d] + '/>') }
        }
        [void]$sb.Append('</DaysOfWeek></ScheduleByWeek>')
      }
      'month' {
        # 每月最后一天用 <Day>Last</Day>(官方规范: Day 值为 1-31 或 "Last"); LastDayOfMonth 元素不合法
        if ($MonthDay -ge 31) { [void]$sb.Append('<ScheduleByMonth><Days><Day>Last</Day></Days></ScheduleByMonth>') }
        else { [void]$sb.Append('<ScheduleByMonth><Days><Day>' + $MonthDay + '</Day></Days></ScheduleByMonth>') }
      }
      default {
        $iv = if ($Interval -lt 1) { 1 } else { $Interval }
        [void]$sb.Append('<ScheduleByDay><DaysInterval>' + $iv + '</DaysInterval></ScheduleByDay>')
      }
    }
    [void]$sb.Append('</CalendarTrigger>')
  }
  [void]$sb.Append('</Triggers>')
  return $sb.ToString()
}

# 周几 chips 状态刷新 / 计划类型 UI 切换
function Set-WeekChips {
  param([int[]]$Sel)
  $names = @('chipMon','chipTue','chipWed','chipThu','chipFri','chipSat','chipSun')
  for ($i = 0; $i -lt 7; $i++) {
    $on = $Sel -contains ($i + 1)
    $bd = Get-N $names[$i]
    $txt = $bd.Child
    if ($on) {
      $bd.Background = $window.Resources['C_AccentSoft']
      $txt.Foreground = $window.Resources['C_Accent']
    } else {
      $bd.Background = $window.Resources['C_Panel']
      $txt.Foreground = $window.Resources['C_Sub']
    }
  }
}
function Set-SchedTypeUI {
  param([string]$Type)
  $isFreq = ($Type -eq 'minute' -or $Type -eq 'hour')
  # 计划参数区(周几/每月天数)
  (Get-N 'wpanWeek').Visibility = if ($Type -eq 'week') { 'Visible' } else { 'Collapsed' }
  (Get-N 'spnMonthly').Visibility = if ($Type -eq 'month') { 'Visible' } else { 'Collapsed' }
  # 每天 → 天数间隔(独立行)
  (Get-N 'spnDaily').Visibility = if ($Type -eq 'day') { 'Visible' } else { 'Collapsed' }
  # 执行时间 ↔ 重复间隔(同一位置切换)
  (Get-N 'txtSchedTime').Visibility = if ($isFreq) { 'Collapsed' } else { 'Visible' }
  (Get-N 'spnFreq').Visibility = if ($isFreq) { 'Visible' } else { 'Collapsed' }
  (Get-N 'txtSchedTimeLabel').Text = if ($isFreq) { '重复间隔' } else { '执行时间' }
  if ($Type -eq 'minute') { (Get-N 'txtSchedFreqUnit').Text = '分钟' }
  elseif ($Type -eq 'hour') { (Get-N 'txtSchedFreqUnit').Text = '小时' }
}

function Get-SchedScript {
  param([string]$Letter)
  # 只创建卷影,不清理(卷影由存储配额自动管理, 系统会按配额上限自动淘汰最旧卷影)
  $body = @'
$L = '{LETTER}'
try {
  $r = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = ($L + '\'); Context = 'ClientAccessible' } -ErrorAction Stop
  if ($r.ReturnValue -eq 0) { 'created: ' + $r.ShadowID }
  else { 'create failed: ' + $r.ReturnValue; exit 1 }
} catch { $_.Exception.Message; exit 1 }
'@
  return $body.Replace('{LETTER}', $Letter)
}

function Update-SchedView {
  $tasks = Get-SchedTasks
  $lst = Get-N 'lstSchedTasks'
  $lst.ItemsSource = $null
  $lst.ItemsSource = $tasks
  $cbo = Get-N 'cboSchedLetter'
  if ($cbo.Items.Count -eq 0) {
    $disks = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    foreach ($d in $disks) { [void]$cbo.Items.Add($d.Name.TrimEnd('\')) }
    if ($cbo.Items.Count -eq 0) { [void]$cbo.Items.Add('C:') }
    $cbo.SelectedIndex = 0
  }
  $cboType = Get-N 'cboSchedType'
  if ($cboType.Items.Count -eq 0) {
    [void]$cboType.Items.Add('按分钟循环')
    [void]$cboType.Items.Add('按小时循环')
    [void]$cboType.Items.Add('每天')
    [void]$cboType.Items.Add('每周')
    [void]$cboType.Items.Add('每月')
  }
  if ($cboType.SelectedIndex -lt 0) { $cboType.SelectedIndex = 2 }
  if ($tasks.Count -gt 0) {
    $lst.SelectedIndex = 0
    # 显式填充详情并刷新按钮(不依赖 SelectionChanged 事件派发)
    try {
      $script:SchedEditing = $lst.SelectedItem
      Show-SchedDetail $lst.SelectedItem
    } catch {}
  }
  try { Update-SchedActionBtns } catch {}
  try { Apply-SavedSort } catch {}
}

function Show-SchedDetail {
  param($sel)
  $txtLast = Get-N 'txtSchedLastRun'
  $txtRes = Get-N 'txtSchedLastResult'
  $txtNext = Get-N 'txtSchedNextRun'
  if (-not $sel) {
    (Get-N 'txtSchedTitle').Text = '选择或新建一个计划任务'
    (Get-N 'txtSchedName').Text = ''
    (Get-N 'txtSchedTime').Text = '09:00'
    (Get-N 'txtSchedComment').Text = ''
    (Get-N 'txtSchedInterval').Text = '1'
    (Get-N 'txtSchedFreq').Text = '5'
    (Get-N 'txtSchedMonthDay').Text = '1'
    (Get-N 'chkSchedSawa').IsChecked = $true
    (Get-N 'txtSchedDesc').Text = '定时为所选卷创建卷影副本,旧卷影由系统存储配额自动管理。'
    $txtLast.Text = '—'; $txtRes.Text = '—'; $txtNext.Text = '—'
    try { Update-SchedActionBtns } catch {}
    return
  }
  (Get-N 'txtSchedTitle').Text = ('任务: ' + $sel.TaskName)
  (Get-N 'txtSchedName').Text = $sel.TaskName
  (Get-N 'txtSchedTime').Text = $sel.TimeText
  (Get-N 'txtSchedComment').Text = $sel.Comment
  $selTimes = @($sel.TimeText -split ',' | Where-Object { $_ })
  $plan = Get-SchedPlanText -Type $sel.Type -Times $selTimes -Interval $sel.Interval -Week $sel.Week -MonthDay $sel.MonthDay
  (Get-N 'txtSchedDesc').Text = ($plan + ' · 目标卷 ' + $(if($sel.Letter){$sel.Letter}else{'未知'}))
  # 运行信息
  $txtLast.Text = $sel.LastRunText
  $txtRes.Text = $sel.ResultText
  $txtNext.Text = $sel.NextRunText
  # 目标卷回显
  $cbo = Get-N 'cboSchedLetter'
  for ($i = 0; $i -lt $cbo.Items.Count; $i++) { if ($cbo.Items[$i] -eq $sel.Letter) { $cbo.SelectedIndex = $i; break } }
  # 计划类型回显
  $cboType = Get-N 'cboSchedType'
  $typeIdx = @{ 'minute' = 0; 'hour' = 1; 'day' = 2; 'week' = 3; 'month' = 4 }
  if ($typeIdx.ContainsKey($sel.Type)) { $cboType.SelectedIndex = $typeIdx[$sel.Type] } else { $cboType.SelectedIndex = 2 }
  (Get-N 'txtSchedInterval').Text = [string]$sel.Interval
  (Get-N 'txtSchedFreq').Text = [string]$sel.Interval
  (Get-N 'txtSchedMonthDay').Text = [string]$sel.MonthDay
  (Get-N 'chkSchedSawa').IsChecked = $sel.Sawa
  Set-SchedTypeUI $sel.Type
  if ($sel.Type -eq 'week') {
    $script:SchedWeekSel = @($sel.Week | Where-Object { $_ -ge 1 -and $_ -le 7 })
    Set-WeekChips $script:SchedWeekSel
  }
}


function Save-SchedTask {
  if (-not $script:CanAct) { Show-Toast -Message '只读模式无法保存任务' -Type 'warn'; return }
  $letter = (Get-N 'cboSchedLetter').SelectedItem
  $timeRaw = (Get-N 'txtSchedTime').Text.Trim()
  $name = (Get-N 'txtSchedName').Text.Trim()
  $comment = (Get-N 'txtSchedComment').Text.Trim()
  $typeIdx = (Get-N 'cboSchedType').SelectedIndex
  if ($typeIdx -lt 0 -or $typeIdx -gt 4) { $typeIdx = 2 }
  $type = @('minute','hour','day','week','month')[$typeIdx]
  if (-not $letter) { Show-Toast -Message '请选择目标卷' -Type 'warn'; return }
  # 时间校验(仅 day/week/month 需要; 分钟/小时全天循环不需要时间点)
  $times = @()
  if ($type -eq 'day' -or $type -eq 'week' -or $type -eq 'month') {
    $times = @($timeRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($times.Count -eq 0) { Show-Toast -Message '请填写执行时间' -Type 'warn'; return }
    foreach ($t in $times) {
      if ($t -notmatch '^(\d{1,2}):(\d{2})$') { Show-Toast -Message ('时间格式应为 HH:mm: ' + $t) -Type 'warn'; return }
      $hh = [int]$Matches[1]; $mm = [int]$Matches[2]
      if ($hh -gt 23 -or $mm -gt 59) { Show-Toast -Message ('时间无效: ' + $t) -Type 'warn'; return }
    }
  }
  # 计划参数
  $interval = 1; $week = @(1..7); $monthDay = 1
  if ($type -eq 'minute') {
    if ((Get-N 'txtSchedFreq').Text.Trim() -match '^\d+$') { $interval = [int](Get-N 'txtSchedFreq').Text.Trim() }
    if ($interval -lt 1) { $interval = 1 }
    if ($interval -gt 60) { $interval = 60 }
  }
  elseif ($type -eq 'hour') {
    if ((Get-N 'txtSchedFreq').Text.Trim() -match '^\d+$') { $interval = [int](Get-N 'txtSchedFreq').Text.Trim() }
    if ($interval -lt 1) { $interval = 1 }
    if ($interval -gt 24) { $interval = 24 }
  }
  elseif ($type -eq 'day') {
    if ((Get-N 'txtSchedInterval').Text.Trim() -match '^\d+$') { $interval = [int](Get-N 'txtSchedInterval').Text.Trim() }
    if ($interval -lt 1) { $interval = 1 }
    if ($interval -gt 365) { $interval = 365 }
  }
  elseif ($type -eq 'week') {
    $week = @($script:SchedWeekSel | Where-Object { $_ -ge 1 -and $_ -le 7 } | Sort-Object)
    if ($week.Count -eq 0) { Show-Toast -Message '请至少选择一个星期' -Type 'warn'; return }
  }
  elseif ($type -eq 'month') {
    if ((Get-N 'txtSchedMonthDay').Text.Trim() -match '^\d+$') { $monthDay = [int](Get-N 'txtSchedMonthDay').Text.Trim() }
    if ($monthDay -lt 1) { $monthDay = 1 }
    if ($monthDay -gt 31) { $monthDay = 31 }
  }
  $sawa = ((Get-N 'chkSchedSawa').IsChecked -eq $true)
  $sawaStr = if ($sawa) { 'true' } else { 'false' }
  # 名称处理
  if (-not $name) { $name = $script:SchedPrefix + $letter.TrimEnd(':') }
  elseif ($name -notmatch $script:SchedPrefix) { $name = $script:SchedPrefix + $name }
  $name = $name -replace '[\\/:*?"<>|]','_'
  $taskName = $name.Replace($script:SchedPrefix,'')
  $fullName = '\ShadowConsole\' + $taskName
  # 编辑改名的旧任务清理
  $editing = $script:SchedEditing
  if ($editing -and $editing.TaskName -and $editing.TaskName -ne $taskName) {
    $null = & schtasks.exe /Delete /TN ('\ShadowConsole\' + $editing.TaskName) /F 2>&1
  }
  $scriptText = Get-SchedScript -Letter $letter
  $dir = Join-Path $env:TEMP 'shadowconsole'
  try { [IO.Directory]::CreateDirectory($dir) | Out-Null } catch {}
  $scriptFile = Join-Path $dir ('sched_' + $taskName + '.ps1')
  try { [IO.File]::WriteAllText($scriptFile, $scriptText, (New-Object Text.UTF8Encoding $true)) } catch { Show-Toast -Message '写入脚本失败' -Type 'err'; return }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  # 参数编码到命令行,供查询还原(编辑回显); XML 特殊字符转义(描述/注释含 & < > 会致 XML 解析失败)
  $argTail = (' -L "' + $letter + '" -T "' + ($times -join ',') + '" -TYPE ' + $type + ' -INT ' + $interval + ' -W "' + ($week -join ',') + '" -MD ' + $monthDay + ' -SAWA ' + $(if($sawa){'1'}else{'0'}))
  $trigXml = Get-SchedTriggersXml -Type $type -Times $times -Interval $interval -Week $week -MonthDay $monthDay
  $planDesc = (Get-SchedPlanText -Type $type -Times $times -Interval $interval -Week $week -MonthDay $monthDay)
  $schedDesc = ('ShadowConsole 定时卷影任务 (' + $planDesc + ' · ' + $letter + ')')
  # 用户描述并入 Description(RegistrationInfo 无 Comment 元素, 带 <Comment> 会报 SCHED_E_UNEXPECTEDNODE 0x80041316)
  $fullDesc = if ($comment) { ($comment + ' | ' + $schedDesc) } else { $schedDesc }
  # 用任务 XML 创建(避免 schtasks /TR 命令行的引号解析问题,支持含空格路径)
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$([Security.SecurityElement]::Escape($fullDesc))</Description>
  </RegistrationInfo>
  $trigXml
  <Principals>
    <Principal id="Author">
      <RunLevel>HighestAvailable</RunLevel>
      <UserId>SYSTEM</UserId>
      <LogonType>Password</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>$sawaStr</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$scriptFile"$argTail</Arguments>
    </Exec>
  </Actions>
</Task>
"@
  $xmlFile = Join-Path $dir ('sched_' + $taskName + '.xml')
  try { [IO.File]::WriteAllText($xmlFile, $xml, [Text.Encoding]::Unicode) } catch { Show-Toast -Message '写入任务 XML 失败' -Type 'err'; return }
  try {
    $result = & schtasks.exe /Create /TN $fullName /XML $xmlFile /F 2>&1
    if ($LASTEXITCODE -eq 0) {
      Show-Toast -Message ('已保存计划任务 ' + $taskName)
      Update-SchedView
      $script:SchedEditing = $null
    } else {
      # 详细错误:写日志文件 + toast 展示完整信息(用户要求具体错误)
      $errText = ($result | Out-String).Trim()
      try {
        $errLog = Join-Path $env:TEMP 'shadowconsole\sched_err.log'
        [IO.File]::AppendAllText($errLog, ('[{0}] save {1} FAILED:`n{2}`nXML file: {3}`n----`n' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $fullName, $errText, $xmlFile), (New-Object Text.UTF8Encoding $true))
      } catch {}
      Show-Toast -Message ('保存失败: ' + $errText) -Type 'err'
    }
  } catch { Show-Toast -Message ('保存异常: ' + $_.Exception.Message) -Type 'err' }
}

# 周几 chips 点击切换
$script:SchedWeekSel = @(1..7)
$chipNames = @('chipMon','chipTue','chipWed','chipThu','chipFri','chipSat','chipSun')
for ($i = 0; $i -lt $chipNames.Count; $i++) {
  $day = $i + 1
  $chip = Get-N $chipNames[$i]
  $chip.add_MouseLeftButtonUp({
    $d = $day
    if ($script:SchedWeekSel -contains $d) { $script:SchedWeekSel = @($script:SchedWeekSel | Where-Object { $_ -ne $d }) }
    else { $script:SchedWeekSel = @($script:SchedWeekSel + $d | Sort-Object) }
    Set-WeekChips $script:SchedWeekSel
  }.GetNewClosure())
}
(Get-N 'cboSchedType').add_SelectionChanged({
  $idx = (Get-N 'cboSchedType').SelectedIndex
  if ($idx -lt 0 -or $idx -gt 4) { $idx = 2 }
  $type = @('minute','hour','day','week','month')[$idx]
  Set-SchedTypeUI $type
})

# 按钮组显隐:选中任务 → 显示 保存/导出/运行/启用/删除,隐藏 新建;未选中 → 只显示 新建
function Update-SchedActionBtns {
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  $hasSel = ($null -ne $sel)
  $canWrite = [bool]$script:CanAct
  (Get-N 'btnSchedNew').Visibility = if ($hasSel) { 'Collapsed' } else { 'Visible' }
  (Get-N 'btnSchedSave').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  (Get-N 'btnSchedExport').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  (Get-N 'btnSchedRunNow').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  (Get-N 'btnSchedToggle').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  (Get-N 'btnSchedDelete').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  # 只读模式: 写操作按钮禁用(新建/保存/运行/启用/删除), 导出为只读保留
  (Get-N 'btnSchedNew').IsEnabled = $canWrite
  (Get-N 'btnSchedSave').IsEnabled = $canWrite
  (Get-N 'btnSchedRunNow').IsEnabled = $canWrite
  (Get-N 'btnSchedToggle').IsEnabled = $canWrite
  (Get-N 'btnSchedDelete').IsEnabled = $canWrite
  (Get-N 'btnSchedExport').IsEnabled = $true
}
(Get-N 'btnSchedRefresh').add_Click({ Update-SchedView })
# 选中任务 → 填充详情; 取消选中 → 清空表单(新建模式)
(Get-N 'lstSchedTasks').add_SelectionChanged({
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  if ($sel) {
    $script:SchedEditing = $sel
    Show-SchedDetail $sel
  } else {
    $script:SchedEditing = $null
    Show-SchedDetail $null
  }
  Update-SchedActionBtns
})
# 再次点击已选中项 → 取消选中(用 MouseLeftButtonDown:选中在 Down 阶段完成,Up 时刚点的项已是选中态会误判)
(Get-N 'lstSchedTasks').add_PreviewMouseLeftButtonDown({
  $src = $_.OriginalSource
  $item = [System.Windows.Controls.ItemsControl]::ContainerFromElement((Get-N 'lstSchedTasks'), $src)
  if ($item -is [System.Windows.Controls.ListViewItem]) {
    $sel = (Get-N 'lstSchedTasks').SelectedItem
    if ($sel -and $item.IsSelected) {
      (Get-N 'lstSchedTasks').SelectedIndex = -1
      $_.Handled = $true
    }
  }
})
# 新建:未选中态下保存(创建新任务); 保存:选中态下保存(更新现有任务)
(Get-N 'btnSchedNew').add_Click({
  $script:SchedEditing = $null
  Save-SchedTask
})
(Get-N 'btnSchedSave').add_Click({ Save-SchedTask })
(Get-N 'btnSchedRunNow').add_Click({
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  if (-not $sel) { Show-Toast -Message '请先选择任务' -Type 'warn'; return }
  if (-not $script:CanAct) { Show-Toast -Message '只读模式无法触发任务' -Type 'warn'; return }
  $fullName = '\ShadowConsole\' + $sel.TaskName
  try {
    $result = & schtasks.exe /Run /TN $fullName 2>&1
    if ($LASTEXITCODE -eq 0) { Show-Toast -Message ('已触发任务 ' + $sel.TaskName); Update-SchedView } else { Show-Toast -Message ('触发失败: ' + ($result -join ' ')) -Type 'err' }
  } catch { Show-Toast -Message ('触发异常: ' + $_.Exception.Message) -Type 'err' }
})
(Get-N 'btnSchedToggle').add_Click({
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  if (-not $sel) { Show-Toast -Message '请先选择任务' -Type 'warn'; return }
  if (-not $script:CanAct) { Show-Toast -Message '只读模式无法启用/禁用任务' -Type 'warn'; return }
  $fullName = '\ShadowConsole\' + $sel.TaskName
  $action = if ($sel.Enabled) { '/DISABLE' } else { '/ENABLE' }
  try {
    $result = & schtasks.exe /Change $action /TN $fullName 2>&1
    if ($LASTEXITCODE -eq 0) { Show-Toast -Message ('已' + $(if($sel.Enabled){'禁用'}else{'启用'}) + '任务 ' + $sel.TaskName); Update-SchedView } else { Show-Toast -Message ('操作失败: ' + ($result -join ' ')) -Type 'err' }
  } catch { Show-Toast -Message ('操作异常: ' + $_.Exception.Message) -Type 'err' }
})
(Get-N 'btnSchedDelete').add_Click({
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  if (-not $sel) { Show-Toast -Message '请先选择任务' -Type 'warn'; return }
  if (-not $script:CanAct) { Show-Toast -Message '只读模式无法删除任务' -Type 'warn'; return }
  $fullName = '\ShadowConsole\' + $sel.TaskName
  if (-not (Show-Confirm -Title '删除计划任务' -Message ('将删除计划任务 ' + $sel.TaskName + ',其已创建的卷影副本不受影响。') -Cmd ('schtasks /Delete /TN ' + $fullName + ' /F') -Danger)) { return }
  try {
    $result = & schtasks.exe /Delete /TN $fullName /F 2>&1
    if ($LASTEXITCODE -eq 0) { Show-Toast -Message ('已删除任务 ' + $sel.TaskName); Update-SchedView; Show-SchedDetail $null } else { Show-Toast -Message ('删除失败: ' + ($result -join ' ')) -Type 'err' }
  } catch { Show-Toast -Message ('删除异常: ' + $_.Exception.Message) -Type 'err' }
})
(Get-N 'btnSchedExport').add_Click({
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  if (-not $sel) { Show-Toast -Message '请先选择任务' -Type 'warn'; return }
  $fullName = '\ShadowConsole\' + $sel.TaskName
  $dlg = New-Object Microsoft.Win32.SaveFileDialog
  $dlg.Title = '导出任务定义'
  $dlg.Filter = '任务定义 (*.xml)|*.xml'
  $dlg.FileName = $sel.TaskName + '.xml'
  if ($dlg.ShowDialog() -eq $true) {
    $out = & schtasks.exe /Query /TN $fullName /XML ONE 2>&1
    if ($LASTEXITCODE -eq 0 -and $out) {
      try {
        [IO.File]::WriteAllText($dlg.FileName, ($out -join "`r`n"), (New-Object Text.UTF8Encoding $true))
        Show-Toast -Message ('已导出任务 ' + $sel.TaskName)
      } catch { Show-Toast -Message ('导出失败: ' + $_.Exception.Message) -Type 'err' }
    } else { Show-Toast -Message ('导出失败: ' + ($out -join ' ')) -Type 'err' }
  }
})


(Get-N 'btnConfirmCancel').add_Click({
  $script:ConfirmResult = $false
  (Get-N 'grdConfirm').Visibility = 'Collapsed'
  if ($script:ConfirmFrame) { $script:ConfirmFrame.Continue = $false; $script:ConfirmFrame = $null }
})
(Get-N 'btnConfirmOK').add_Click({
  $script:ConfirmResult = $true
  (Get-N 'grdConfirm').Visibility = 'Collapsed'
  if ($script:ConfirmFrame) { $script:ConfirmFrame.Continue = $false; $script:ConfirmFrame = $null }
})
(Get-N 'btnResizeCancel').add_Click({
  $script:ResizeResult = $null
  (Get-N 'grdResize').Visibility = 'Collapsed'
  if ($script:ResizeFrame) { $script:ResizeFrame.Continue = $false; $script:ResizeFrame = $null }
})
(Get-N 'btnResizeOK').add_Click({
  $auto = ((Get-N 'rbResizeAuto').IsChecked -eq $true)
  $result = $null
  if ($auto) { $result = [pscustomobject]@{ Mode = 'auto'; GB = 0 } }
  else {
    $gb = (Get-N 'txtResizeGB').Text
    if (-not (Test-GBInput $gb)) { Show-Toast -Message '请输入有效的 GB 数值' -Type 'warn'; return }
    $result = [pscustomobject]@{ Mode = 'custom'; GB = [double]$gb }
  }
  $script:ResizeResult = $result
  (Get-N 'grdResize').Visibility = 'Collapsed'
  if ($script:ResizeFrame) { $script:ResizeFrame.Continue = $false; $script:ResizeFrame = $null }
})

(Get-N 'lstLog').add_SelectionChanged({
  $sel = $null
  $idx = (Get-N 'lstLog').SelectedIndex
  if ($idx -ge 0 -and $idx -lt $script:Log.Count) { $sel = $script:Log[$idx] }
  (Get-N 'txtLogDetail').Text = if ($sel) {
    ('PS> ' + $sel.Tool + ' ' + $sel.Args + "`r`n" + '退出码: ' + $sel.ExitCode + ' · 耗时: ' + [string]::Format($script:InvCulture, '{0:0.00}s', $sel.Duration) + "`r`n`r`n" + $sel.Output)
  } else { '' }
})
(Get-N 'lstWriters').add_SelectionChanged({
  $sel = (Get-N 'lstWriters').SelectedItem
  (Get-N 'txtWriterDetail').Text = if ($sel) { $sel.Raw } else { '' }
})
(Get-N 'lstStorage').add_SelectionChanged({
  $sel = (Get-N 'lstStorage').SelectedItem
  (Get-N 'btnStorageResize').IsEnabled = [bool]$sel -and $script:CanAct
})

function Find-Up {
  param($node, [string]$TargetName, [Type]$TargetType)
  while ($node) {
    if ($TargetName -and $node -is [System.Windows.FrameworkElement] -and $node.Name -eq $TargetName) { return $node }
    if ($TargetType -and $node -is $TargetType) { return $node }
    $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
  }
  return $null
}

(Get-N 'cardHost').AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
  $src = $_.OriginalSource -as [System.Windows.DependencyObject]
  if (-not $src) { return }
  $btn = Find-Up $src $null ([System.Windows.Controls.Button])
  if ($btn) {
    $_.Handled = $true
    $letter = $btn.Tag
    if ($btn.Name -eq 'btnCardCreate') { Invoke-CreateShadow $letter }
    elseif ($btn.Name -eq 'btnCardQuota') { Invoke-ResizeFor $letter }
  }
})
(Get-N 'cardHost').add_PreviewMouseLeftButtonUp({
  $src = $_.OriginalSource -as [System.Windows.DependencyObject]
  if (-not $src) { return }
  if (Find-Up $src $null ([System.Windows.Controls.Button])) { return }
  $card = Find-Up $src 'card' $null
  if ($card) {
    $_.Handled = $true
    $data = $card.DataContext
    if ($data -and $data.Letter) {
      if ($script:FilterLetter -eq $data.Letter) { $script:FilterLetter = $null } else { $script:FilterLetter = $data.Letter }
      Update-ShadowsView
    }
  }
})
(Get-N 'lstShadows').AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
  $src = $_.OriginalSource -as [System.Windows.DependencyObject]
  if (-not $src) { return }
  $btn = Find-Up $src $null ([System.Windows.Controls.Button])
  if ($btn -and $btn.Name -eq 'btnShadowDelete') {
    $_.Handled = $true
    Invoke-DeleteShadow $btn.Tag
  }
})
# 卷影列表:双击打开浏览
(Get-N 'lstShadows').add_MouseDoubleClick({
  $sel = (Get-N 'lstShadows').SelectedItem
  if ($sel) { Open-ShadowBrowser $sel }
})
# 卷影列表:右键菜单
(Get-N 'miBrowseOpen').add_Click({
  $sel = (Get-N 'lstShadows').SelectedItem
  if ($sel) { Open-ShadowBrowser $sel }
})
(Get-N 'miBrowseCopy').add_Click({
  $sel = (Get-N 'lstShadows').SelectedItem
  if ($sel -and $sel.Device) {
    [System.Windows.Clipboard]::SetText($sel.Device)
    Show-Toast '已复制设备路径到剪贴板'
  }
})
# 通用表头排序:给 ListView 绑定点击表头排序(需要按钮式列头,改用路由事件监听)
$script:SortState = @{}
$script:SortOrig = @{}
$script:SortPropMap = @{
    'lstShadows:创建时间' = 'CreatedText'; 'lstShadows:卷' = 'Letter'; 'lstShadows:阴影 ID' = 'Id'; 'lstShadows:设备对象' = 'Device'; 'lstShadows:属性' = 'TypeText'
    'lstStorage:卷' = 'Letter'; 'lstStorage:已用空间' = 'UsedText'; 'lstStorage:已分配' = 'AllocText'; 'lstStorage:上限' = 'MaxText'; 'lstStorage:存储位置' = 'DiffLetter'
    'lstProviders:名称' = 'Name'; 'lstProviders:类型' = 'TypeText'; 'lstProviders:版本' = 'Version'; 'lstProviders:提供程序 ID' = 'Id'; 'lstProviders:CLSID' = 'Clsid'
    'lstWriters:状态' = 'StateText'; 'lstWriters:写入程序' = 'Name'
    'lstLog:时间' = 'TimeText'; 'lstLog:工具' = 'Tool'; 'lstLog:命令' = 'Args'; 'lstLog:退出码' = 'ExitText'
    'lstSchedTasks:任务' = 'TaskName'; 'lstSchedTasks:计划' = 'PlanText'; 'lstSchedTasks:状态' = 'StateText'; 'lstSchedTasks:上次运行' = 'LastRunText'; 'lstSchedTasks:上次结果' = 'ResultText'; 'lstSchedTasks:下次运行' = 'NextRunText'
  }
function Add-ListSort {
  param([System.Windows.Controls.ListView]$ListView)
  $ListView.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    $h = $_.OriginalSource -as [System.Windows.Controls.GridViewColumnHeader]
    if (-not $h -or $h.Role -eq [System.Windows.Controls.GridViewColumnHeaderRole]::Padding) { return }
    $col = $h.Column
    if (-not $col) { return }
    $list = $_.Source
    # 原始 header(去掉可能已加的箭头)
    $rawHeader = $col.Header.ToString() -replace '\s*[▲▼]\s*$',''
    $key = $list.Name + ':' + $rawHeader
    $prop = $script:SortPropMap[$key]
    if (-not $prop) { return }
    # 重置该列表所有表头箭头
    if ($script:SortOrig.ContainsKey($list.Name)) {
      foreach ($pair in $script:SortOrig[$list.Name].GetEnumerator()) {
        try { $pair.Key.Header = $pair.Value } catch {}
      }
    }
    if (-not $script:SortState.ContainsKey($key)) { $script:SortState[$key] = 'Asc' }
    $dir = $script:SortState[$key]
    $script:SortState[$key] = if ($dir -eq 'Asc') { 'Desc' } else { 'Asc' }
    $dir = $script:SortState[$key]
    # 记录并显示箭头
    if (-not $script:SortOrig.ContainsKey($list.Name)) { $script:SortOrig[$list.Name] = @{} }
    $script:SortOrig[$list.Name][$col] = $rawHeader
    $col.Header = if ($dir -eq 'Asc') { ($rawHeader + ' ▲') } else { ($rawHeader + ' ▼') }
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list.ItemsSource)
    if (-not $view) { return }
    $view.SortDescriptions.Clear()
    $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($prop, $(if($dir -eq 'Asc'){[System.ComponentModel.ListSortDirection]::Ascending}else{[System.ComponentModel.ListSortDirection]::Descending}))))
    $view.Refresh()
    # 排序是明确点击动作, 状态仅经此代码变化 -> 直接防抖保存
    try { Schedule-SettingsSave } catch {}
  })
}
# 从配置恢复表格列宽(启动时调用, 列对象在 XAML 解析后即存在)
function Apply-SavedColWidths {
  if (-not $script:SavedColWidths) { return }
  foreach ($prop in $script:SavedColWidths.PSObject.Properties) {
    $key = $prop.Name
    try { $w = [double]$prop.Value } catch { continue }
    $idx = $key.IndexOf(':')
    if ($idx -le 0) { continue }
    $listName = $key.Substring(0, $idx)
    $header = $key.Substring($idx + 1)
    try {
      $lv = $window.FindName($listName)
      if (-not $lv -or -not $lv.View) { continue }
      foreach ($c in $lv.View.Columns) {
        if (($c.Header.ToString() -replace '\s*[▲▼]\s*$','').Trim() -eq $header) {
          # NaN = 自动宽度(双击自动列宽 / XAML 自动填充列): 恢复自动模式; 具体值且合理才设固定宽度
          if ([double]::IsNaN($w)) { $c.Width = [double]::NaN }
          elseif ($w -gt 16) { $c.Width = $w }
          break
        }
      }
    } catch {}
  }
}
# 从配置恢复表格排序(每次列表数据刷新后调用, ItemsSource 更换会丢失默认视图排序)
function Apply-SavedSort {
  if (-not $script:SavedSortState) { return }
  foreach ($prop in $script:SavedSortState.PSObject.Properties) {
    $listName = $prop.Name
    $info = $prop.Value
    if (-not $info -or -not $info.Col) { continue }
    $dataProp = $script:SortPropMap[$listName + ':' + $info.Col]
    if (-not $dataProp) { continue }
    try {
      $lv = $window.FindName($listName)
      if (-not $lv -or -not $lv.View) { continue }
      $col = $null
      foreach ($c in $lv.View.Columns) {
        if (($c.Header.ToString() -replace '\s*[▲▼]\s*$','').Trim() -eq $info.Col) { $col = $c; break }
      }
      if (-not $col) { continue }
      # 重置该列表所有旧表头箭头, 再设置排序列
      if ($script:SortOrig.ContainsKey($listName)) {
        foreach ($pair in $script:SortOrig[$listName].GetEnumerator()) {
          try { $pair.Key.Header = $pair.Value } catch {}
        }
      } else { $script:SortOrig[$listName] = @{} }
      $dir = if ($info.Dir -eq 'Asc') { 'Asc' } else { 'Desc' }
      $key = $listName + ':' + $info.Col
      $script:SortState[$key] = $dir
      $script:SortOrig[$listName][$col] = $info.Col
      $col.Header = if ($dir -eq 'Asc') { ($info.Col + ' ▲') } else { ($info.Col + ' ▼') }
      $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($lv.ItemsSource)
      if ($view) {
        $view.SortDescriptions.Clear()
        $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($dataProp, $(if($dir -eq 'Asc'){[System.ComponentModel.ListSortDirection]::Ascending}else{[System.ComponentModel.ListSortDirection]::Descending}))))
        $view.Refresh()
      }
    } catch {}
  }
}
# 从配置恢复表格列顺序(拖动表头换列后的顺序; 启动时在列宽恢复前调用)
function Apply-SavedColOrder {
  if (-not $script:SavedColOrder) { return }
  foreach ($prop in $script:SavedColOrder.PSObject.Properties) {
    $listName = $prop.Name
    $order = @($prop.Value)
    if ($order.Count -lt 2) { continue }
    try {
      $lv = $window.FindName($listName)
      if (-not $lv -or -not $lv.View) { continue }
      $cols = $lv.View.Columns
      # 表头(strip 箭头) → 列对象
      $map = @{}
      foreach ($c in $cols) {
        $h = ($c.Header.ToString() -replace '\s*[▲▼]\s*$','').Trim()
        if ($h -and -not $map.ContainsKey($h)) { $map[$h] = $c }
      }
      # 按保存顺序排列, 未出现在保存列表中的列(新列)追加到末尾
      $ordered = New-Object System.Collections.Generic.List[object]
      foreach ($h in $order) {
        if ($map.ContainsKey($h)) { $ordered.Add($map[$h]) }
      }
      foreach ($c in @($cols)) {
        if (-not $ordered.Contains($c)) { $ordered.Add($c) }
      }
      if ($ordered.Count -ne $cols.Count) { continue }
      # 重排 GridViewColumnCollection
      for ($i = $cols.Count - 1; $i -ge 0; $i--) { $cols.RemoveAt($i) }
      foreach ($c in $ordered) { [void]$cols.Add($c) }
    } catch {}
  }
}
Add-ListSort (Get-N 'lstShadows')
Add-ListSort (Get-N 'lstStorage')
Add-ListSort (Get-N 'lstProviders')
Add-ListSort (Get-N 'lstWriters')
Add-ListSort (Get-N 'lstLog')
Add-ListSort (Get-N 'lstSchedTasks')
# 表格状态(列宽/排序/列顺序)持久化: 事件驱动监听"落地值本身"的变化, 不轮询不监听拖动过程事件——
# 列宽: DependencyPropertyDescriptor 监听 GridViewColumn.Width 依赖属性(拖动/双击自动列宽/代码设置都触发)
# 列顺序: GridViewColumnCollection(ObservableCollection) 的 CollectionChanged
# 排序: Add-ListSort 点击处理器内已直接 Schedule-SettingsSave
foreach ($lvName in @('lstShadows','lstStorage','lstProviders','lstWriters','lstSchedTasks','lstLog')) {
  try {
    $lv = Get-N $lvName
    if (-not $lv -or -not $lv.View) { continue }
    $dpd = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
      [System.Windows.Controls.GridViewColumn]::WidthProperty,
      [System.Windows.Controls.GridViewColumn])
    foreach ($col in $lv.View.Columns) {
      try { $dpd.AddValueChanged($col, { Schedule-SettingsSave }) } catch {}
    }
    # 列顺序变化(拖动表头换列)
    try { $lv.View.Columns.add_CollectionChanged({ Schedule-SettingsSave }) } catch {}
  } catch {}
}
# 卷影列表选中 -> 显示/更新"打开卷影"chip
function Update-BrowseChip {
  $sel = (Get-N 'lstShadows').SelectedItem
  $chip = Get-N 'chipBrowse'
  if ($sel -and $sel.Letter -and $sel.CreatedText) {
    (Get-N 'txtBrowse').Text = ('选中卷影{0}{1} · 打开' -f $sel.Letter, $sel.CreatedText)
    $chip.Visibility = 'Visible'
  } else {
    $chip.Visibility = 'Collapsed'
  }
}
(Get-N 'lstShadows').add_SelectionChanged({ Update-BrowseChip })
(Get-N 'chipBrowse').add_MouseLeftButtonUp({
  $sel = (Get-N 'lstShadows').SelectedItem
  if ($sel) { Open-ShadowBrowser $sel }
})
(Get-N 'lstStorage').AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
  $src = $_.OriginalSource -as [System.Windows.DependencyObject]
  if (-not $src) { return }
  $btn = Find-Up $src $null ([System.Windows.Controls.Button])
  if ($btn -and $btn.Name -eq 'btnStorageAdjust') {
    $_.Handled = $true
    $data = $btn.DataContext
    if ($data) { Invoke-ResizeFor $data.Letter }
  }
})

$window.add_PreviewKeyDown({
  if ($_.Key -eq [System.Windows.Input.Key]::F5) { Refresh-All; $_.Handled = $true }
})
$window.add_Closed({
  try { Save-Settings (Get-SettingsValues) } catch {}
  try { if ($script:SettingsTimer) { $script:SettingsTimer.Stop() } } catch {}
  try { if ($script:BgPump) { $script:BgPump.Stop() } } catch {}
})
# 事件驱动保存:窗口尺寸/位置/分割条变化时 3 秒防抖保存一次
$window.add_SizeChanged({ Schedule-SettingsSave })
$window.add_LocationChanged({ Schedule-SettingsSave })
try {
  $sn = $window.FindName('splitNav')
  if ($sn) { $sn.add_DragCompleted({ Schedule-SettingsSave }) }
} catch {}
try {
  $sc = $window.FindName('splitCard')
  if ($sc) { $sc.add_DragCompleted({ Schedule-SettingsSave }) }
} catch {}

$mode = 'System'
$script:Settings = Load-Settings
$script:SavedColWidths = if ($script:Settings) { $script:Settings.ColWidths } else { $null }
$script:SavedSortState = if ($script:Settings) { $script:Settings.SortState } else { $null }
$script:SavedColOrder = if ($script:Settings) { $script:Settings.ColOrder } else { $null }
if ($script:Settings -and $script:Settings.Theme) { $mode = [string]$script:Settings.Theme }
if (-not $mode) { $mode = 'System' }
Set-Theme $mode

try {
  if ($script:Settings) {
    $p = $script:Settings
    if ($null -ne $p.WW -and $null -ne $p.WH -and [double]$p.WW -gt 0 -and [double]$p.WH -gt 0) { $window.Width = [double]$p.WW; $window.Height = [double]$p.WH }
    if ($null -ne $p.WLeft -and $null -ne $p.WTop) {
      $window.WindowStartupLocation = 'Manual'
      $window.Left = [double]$p.WLeft
      $window.Top = [double]$p.WTop
    }
    # 恢复分割比例:左侧导航栏宽度 / 卷影页卡片区高度
    try {
      $mg = $window.FindName('mainGrid')
      if ($mg -and $null -ne $p.NavW -and [double]$p.NavW -gt 0) { $mg.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new([double]$p.NavW) }
    } catch {}
    try {
      $ps = $window.FindName('pageShadows')
      if ($ps -and $null -ne $p.CardH -and [double]$p.CardH -gt 0) { $ps.RowDefinitions[1].Height = [System.Windows.GridLength]::new([double]$p.CardH) }
    } catch {}
    # 恢复上次导航页
    try {
      if ($null -ne $p.NavPage -and [int]$p.NavPage -ge 0 -and [int]$p.NavPage -lt $script:NavNames.Count) { Set-Nav ([int]$p.NavPage) }
    } catch {}
  }
} catch {}
# 恢复表格列顺序(先排顺序, 列宽按表头匹配不受顺序影响)与列宽
try { Apply-SavedColOrder } catch {}
try { Apply-SavedColWidths } catch {}

$skuParts = @()
try {
  $v = & $script:VssAdmin 2>&1 | Select-Object -First 1 | Out-String
  if ($v -match '([\d]+\.[\d]+)') { $skuParts += ('vssadmin ' + $Matches[1]) }
} catch {}
try {
  $ds = & $script:Diskshadow 2>&1 | Select-Object -First 1 | Out-String
  if ($ds -match '([\d]+\.[\d]+)') { $skuParts += ('diskshadow ' + $Matches[1]) }
} catch {}
try {
  $osv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber
  $skuParts += ('Win ' + $osv)
} catch {}
(Get-N 'txtSku').Text = ($skuParts -join ' · ')
try { Update-SchedView } catch {}
if ($script:ElevationDenied) { (Get-N 'bannerNoAdmin').Visibility = 'Visible' }
if ($script:CanAct) {
  (Get-N 'dotAdmin').Background = $window.Resources['C_Success']
  (Get-N 'txtAdmin').Text = '已提权'
} else {
  (Get-N 'dotAdmin').Background = $window.Resources['C_Warn']
  (Get-N 'txtAdmin').Text = '只读模式'
}

# ===== 程序图标: 淡雅双层方块+时钟(对应 logo.svg, 代码绘制零资源, 任意尺寸自适应) =====
# 意象: 写时复制 — 底层卷(深蓝方块) + 卷影副本(主蓝方块叠层) + 白色时钟=快照时间点
# 配色: 底层 #5A7FD6 / 顶层 #7BA3F0 / 描边 #3B5AA0 / 纹路 #8CA9E8 / 高光 #E1EAFB / 时钟 #274E8E
function New-ConsoleIconBmp {
  param([int]$Size)
  $k = $Size / 512.0
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 59, 90, 160), [Math]::Max(1.0, [double](3 * $k)))
  $brushLow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 90, 127, 214))
  $brushTop = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 123, 163, 240))
  $brushStripe = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 140, 169, 232))
  $brushHl = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 225, 234, 251))
  $brushInk = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 39, 78, 142))
  try {
    # 底层方块(原始卷)
    $g.FillRectangle($brushLow, (84 * $k), (108 * $k), (340 * $k), (340 * $k))
    $g.DrawRectangle($pen, (84 * $k), (108 * $k), (340 * $k), (340 * $k))
    # 底层卷数据纹路(仅大尺寸可见)
    if ($Size -ge 48) {
      $g.FillRectangle($brushStripe, (108 * $k), (160 * $k), (292 * $k), (8 * $k))
      $g.FillRectangle($brushStripe, (108 * $k), (184 * $k), (292 * $k), (8 * $k))
    }
    # 顶层方块(卷影副本)
    $g.FillRectangle($brushTop, (156 * $k), (76 * $k), (340 * $k), (340 * $k))
    $g.DrawRectangle($pen, (156 * $k), (76 * $k), (340 * $k), (340 * $k))
    # 顶层左上高光条(扁平色块)
    $g.FillRectangle($brushHl, (172 * $k), (94 * $k), (308 * $k), (24 * $k))
    # 时钟(快照时间点; 小尺寸只画圆+两针保证清晰)
    $cx = 326 * $k; $cy = 246 * $k
    if ($Size -ge 24) {
      $ckPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 39, 78, 142), [Math]::Max(1.0, [double](9 * $k)))
      $g.DrawEllipse($ckPen, ($cx - 80 * $k), ($cy - 80 * $k), (160 * $k), (160 * $k))
      $g.DrawLine($ckPen, $cx, $cy, $cx, (200 * $k))
      $g.DrawLine($ckPen, $cx, $cy, (384 * $k), (260 * $k))
      $g.FillEllipse($brushInk, ($cx - 10 * $k), ($cy - 10 * $k), (20 * $k), (20 * $k))
    } else {
      # 16px: 简化圆环 + 两针
      $ckPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 39, 78, 142), [Math]::Max(1.0, [double](8 * $k)))
      $g.DrawEllipse($ckPen, ($cx - 6 * $k), ($cy - 6 * $k), (12 * $k), (12 * $k))
      $g.DrawLine($ckPen, $cx, $cy, $cx, ($cy - 3 * $k))
    }
  } finally {
    $pen.Dispose(); $brushLow.Dispose(); $brushTop.Dispose()
    $brushStripe.Dispose(); $brushHl.Dispose(); $brushInk.Dispose()
    $g.Dispose()
  }
  return $bmp
}
# 设置窗口与任务栏图标
$iconBmp = New-ConsoleIconBmp 32
try {
  $hIcon = $iconBmp.GetHicon()
  $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($hIcon, [System.Windows.Int32Rect]::new(0, 0, 32, 32), [System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(32, 32))
} catch {}
$iconBmp.Dispose()

$runLog = Join-Path $env:TEMP 'shadowconsole\runpath.log'
# 日志保留策略: 每个日志文件保留最近 500 行(启动时截断, 与命令日志一致) —
# 按时间清理不适用: 天天使用则日志永不过期, 空间照样膨胀
try {
  $scDir = Join-Path $env:TEMP 'shadowconsole'
  if (Test-Path -LiteralPath $scDir) {
    Get-ChildItem -LiteralPath $scDir -Filter '*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $lines = [IO.File]::ReadAllLines($_.FullName)
        if ($lines.Count -gt 500) {
          [IO.File]::WriteAllLines($_.FullName, $lines[($lines.Count - 500)..($lines.Count - 1)], (New-Object Text.UTF8Encoding $false))
        }
      } catch {}
    }
  }
} catch {}
[IO.File]::AppendAllText($runLog, ('apartment: ' + [System.Threading.Thread]::CurrentThread.ApartmentState) + "`r`n", (New-Object System.Text.UTF8Encoding $true))
$pre = [System.Windows.Application]::Current
[IO.File]::AppendAllText($runLog, ('pre-Current: ' + $(if ($pre) { 'YES ' + $pre.GetType().FullName } else { 'NO' })) + "`r`n", (New-Object System.Text.UTF8Encoding $true))
$app = New-Object System.Windows.Application
$app.MainWindow = $window
$script:MainDispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
# 降低 GC 暂停(鼠标滑动/悬停等交互持续产生小对象分配 → 堆涨到阈值后周期性 Gen2 压缩回收,
# 每 ~2s 暂停 UI 线程几十 ms = "滑动流畅但周期性卡一下"的根源):
# SustainedLowLatency 延迟 Gen2 压缩避免阻塞(会话短, 内存增长可接受)
try { [System.Runtime.GCSettings]::LatencyMode = [System.Runtime.GCLatencyMode]::SustainedLowLatency } catch {}
# 位图缓存(持久化位图): 内容区渲染结果缓存为位图, 任务运行期间点动画/旋转动画/状态文本变化时,
# 内容区直接叠加缓存位图而非实时矢量重渲染(用户建议) — 数据刷新时缓存自动失效重建
try {
  $bc = New-Object System.Windows.Media.BitmapCache(1.0)
  $bc.EnableClearType = $false
  $mainGrid.CacheMode = $bc
} catch {}
$script:BgBody = Get-BgBody -Functions @('Format-Size','Invoke-ToolBg','Parse-Writers','Get-RealCache') -Epilogue @'
$script:CanAct = $args[0]
$script:VssAdmin = $args[1]
$script:Brush_Accent = $args[2]
$script:Brush_Success = $args[3]
$script:Brush_Warn = $args[4]
$script:Brush_Danger = $args[5]
$script:Brush_Faint = $args[6]
$result = Get-RealCache
$result
'@
$script:ToolBody = Get-BgBody -Functions @('Invoke-ToolBg') -Epilogue @'
$r = Invoke-ToolBg -Exe $args[0] -ArgStr $args[1] -TimeoutSec $args[2]
$r
'@
$script:WmiBody = Get-BgBody -Functions @('Invoke-WmiCreateShadow') -Epilogue @'
$r = Invoke-WmiCreateShadow -Letter $args[0]
$r
'@

$window.add_Loaded({
  # UI 线程卡顿监测(诊断用): 200ms 看门狗, 若 UI 线程被阻塞导致 tick 间隔 >400ms 则记录到
  # %TEMP%\shadowconsole\stutter.log(时间+阻塞时长) — 用于定位"整个 UI 周期卡 1s"是 UI 线程忙
  # 还是渲染/系统问题; 定位后移除
  $script:WdLast = $null
  $watchDog = New-Object System.Windows.Threading.DispatcherTimer
  $watchDog.Interval = [TimeSpan]::FromMilliseconds(200)
  $watchDog.add_Tick({
    try {
      $now = [DateTime]::Now
      if ($script:WdLast) {
        $gap = ($now - $script:WdLast).TotalMilliseconds
        if ($gap -gt 400) {
          [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\stutter.log'), ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] UI阻塞 ' + [int]$gap + 'ms') + "`r`n", (New-Object Text.UTF8Encoding $true))
        }
      }
      $script:WdLast = $now
    } catch {}
  })
  $watchDog.Start()
  # 关闭全部原生触摸交互(桌面鼠标工具, 不优化触屏): 触摸管道可能干扰鼠标操作流畅性
  try {
    [System.Windows.Input.Stylus]::SetIsPressAndHoldEnabled($window, $false)
    [System.Windows.Input.Stylus]::SetIsFlicksEnabled($window, $false)
    [System.Windows.Input.Stylus]::SetIsTapFeedbackEnabled($window, $false)
    [System.Windows.Input.Stylus]::SetIsTouchFeedbackEnabled($window, $false)
  } catch {}
  # 只读模式(提权被拒)也加载数据: 查询是只读操作, 仅操作按钮被 CanAct 禁用
  try { Refresh-All }
  catch {
    try {
      [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\tickerr2.log'), ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' @line ' + $_.InvocationInfo.ScriptLineNumber + ' :: ' + $_.InvocationInfo.Line.Trim()) + "`r`n", (New-Object System.Text.UTF8Encoding $true))
    } catch {}
  }
  # 空闲预热: PS 5.1 脚本块首次执行才编译(实测二次执行快 ~24x), 提前调用幂等函数编译常用链,
  # 消除用户首次操作(切页/计划任务页/按钮)的卡顿; 数据未就绪时这些函数安全跳过/幂等
  $warmTimer = New-Object System.Windows.Threading.DispatcherTimer
  $warmTimer.Interval = [TimeSpan]::FromSeconds(1)
  $warmTimer.add_Tick({
    param($s, $e)
    # 用事件参数 $s(=timer 自身)停止: PS 事件处理器执行时动态作用域不含 Loaded 局部变量,
    # 若写 $warmTimer.Stop() 会得到 null→异常被吞→timer 永不停止→1s 无限循环(每 tick 同步执行
    # Update-SchedView→Get-ScheduledTask 700-1300ms 阻塞 UI 线程=周期性整 UI 卡顿根因, 已定位)
    try { $s.Stop() } catch {}
    try {
      # 纯函数(无副作用)
      $null = Format-Size 0
      $null = Get-TaskResultInfo '0x0'
      $null = Get-SchedPlanText 'day' @('09:00') 1 @(1..7) 1
    } catch {}
    # 幂等 UI 刷新(编译视图/计划任务操作链)
    try { Update-SchedView } catch {}
    try { Update-SchedActionBtns } catch {}
    try { Update-LogView } catch {}
    try { Set-Nav $script:NavIndex } catch {}
    # 选中行触发链(首次点击选中行会编译 PS 处理器, 预热消除首击卡顿)
    try { Update-BrowseChip } catch {}
  })
  $warmTimer.Start()
})
$app.add_DispatcherUnhandledException({
  param($s, $e)
  try {
    [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\disptex.log'), ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $e.Exception.ToString()) + "`r`n`r`n", (New-Object System.Text.UTF8Encoding $true))
    $e.Handled = $true
  } catch {}
})
try {
  [IO.File]::AppendAllText($runLog, ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] Run before' + "`r`n"), (New-Object System.Text.UTF8Encoding $true))
  $null = $app.Run($window)
  [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\runpath.log'), ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] direct OK' + "`r`n"), (New-Object System.Text.UTF8Encoding $true))
} catch {
  [IO.File]::AppendAllText($runLog, ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] direct FAILED - ' + $_.Exception.Message) + "`r`n", (New-Object System.Text.UTF8Encoding $true))
  $ex = $_.Exception
  $n = 0
  while ($ex -and $n -lt 8) { [IO.File]::AppendAllText($runLog, ('  L' + $n + ' [' + $ex.GetType().FullName + '] ' + $ex.Message) + "`r`n", (New-Object System.Text.UTF8Encoding $true)); $ex = $ex.InnerException; $n++ }
  $mi = [System.Windows.Application].GetMethod('Run', [Type[]]@([System.Windows.Window]))
  $null = $mi.Invoke($app, @([System.Windows.Window]$window))
  [IO.File]::AppendAllText((Join-Path $env:TEMP 'shadowconsole\runpath.log'), 'reflection OK' + "`r`n", (New-Object System.Text.UTF8Encoding $true))
}
} catch {
  $err = $_.Exception
  $parts = @()
  while ($err) { $parts += $err.Message; $err = $err.InnerException }
  $state = ('   state: window=' + $(if ($window) { $window.GetType().FullName } else { 'NULL' }) + ' app=' + $(if ($app) { $app.GetType().FullName } else { 'NULL' }) + ' runEx=' + $_.Exception.GetType().FullName)
  $msg = '初始化失败: ' + ($parts -join ' ← ') + $state
  $msg += "`r`n   stacktrace: " + $_.Exception.StackTrace
  try {
    $crashDir = Join-Path $env:TEMP 'shadowconsole'
    [IO.Directory]::CreateDirectory($crashDir) | Out-Null
    $crashFile = Join-Path $crashDir 'crash.log'
    $where = ('   at line {0} | {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    $stack = '   stack: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | ')
    [IO.File]::AppendAllText($crashFile, ('{0}  {1}{2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, $where, $stack) + "`r`n", (New-Object System.Text.UTF8Encoding $true))
  } catch {}
  try {
    $mb = [System.Windows.MessageBox]::Show($msg, $script:AppName, 'OK', 'Error')
  } catch {}
}
#===CONFIG-BEGIN===
#{"WLeft":434.40000000000003,"NavW":196,"ColWidths":{"lstSchedTasks:状态":60,"lstShadows:操作":70,"lstShadows:创建时间":128,"lstShadows:属性":170,"lstWriters:写入程序 ID":230,"lstSchedTasks:下次运行":120,"lstProviders:提供程序 ID":260,"lstLog:工具":78,"lstProviders:名称":330,"lstSchedTasks:上次结果":90,"lstLog:时间":96,"lstWriters:上次错误":NaN,"lstShadows:卷":46,"lstProviders:CLSID":240,"lstLog:命令":NaN,"lstStorage:卷":46,"lstStorage:上限":120,"lstSchedTasks:上次运行":120,"lstStorage:已分配":110,"lstSchedTasks:计划":130,"lstSchedTasks:任务":130,"lstWriters:实例 ID":230,"lstStorage:已用空间":110,"lstShadows:阴影 ID":250,"lstStorage:存储位置":90,"lstWriters:写入程序":230,"lstProviders:版本":90,"lstProviders:类型":90,"lstStorage:占用比例":230,"lstLog:退出码":56,"lstShadows:设备对象":280,"lstWriters:状态":130,"lstStorage:操作":70},"WW":1180,"WTop":226.4,"Theme":"System","CardH":220,"WH":780,"ColOrder":{"lstStorage":["卷","已用空间","已分配","上限","占用比例","存储位置","操作"],"lstLog":["时间","工具","命令","退出码"],"lstShadows":["创建时间","卷","阴影 ID","设备对象","属性","操作"],"lstProviders":["名称","类型","版本","提供程序 ID","CLSID"],"lstWriters":["状态","写入程序","写入程序 ID","实例 ID","上次错误"],"lstSchedTasks":["任务","计划","状态","上次运行","上次结果","下次运行"]},"NavPage":0}
#===CONFIG-END===

__VSS_PS1_END__