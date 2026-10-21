@echo off
rem VSS Shadow Console - single-file distribution (auto-extract & hidden launch)
rem Embedded PS1 snapshot: 2026-08-19 21:55
setlocal
set "PSRUN=%TEMP%\shadowconsole\vss_console_run.ps1"
rem Tell embedded PS1 where the real (bat) file is, so config writes back to this bat itself
set "VSS_SELF=%~f0"
rem ==== /debug: 让诊断日志落盘到 %TEMP%\shadowconsole\*.log ====
rem 默认不落盘: 诊断日志只写内存, 退出即消失(兑现"无残留")。
rem 带 /debug 启动, 或在界面「命令日志」页勾选「日志落盘」, 才会把日志写到磁盘。
rem (VSS_DEBUG 由本 bat 继承给提权子进程; PS1 侧同时认 $args 里的 /debug)
set "VSS_DEBUG="
rem ⚠ 不要用 shift 解析参数: 本 bat 后面要用 %~f0(自身路径)注入 PS1, shift 会把 %0 一起挪走,
rem   导致提取脚本时按 "/debug" 当文件名去找 → 整个程序起不来。改用 for 遍历, 不动 %0。
rem ⚠ 也不用 for %%A in (%*): %* 展开不加引号, 参数里有 & | > 会被 cmd 当成命令分隔符。
rem   逐个带引号展开(%~1..%~9)才安全。
for %%A in ("%~1" "%~2" "%~3" "%~4" "%~5" "%~6" "%~7" "%~8" "%~9") do (
  if /I "%%~A"=="/debug" set "VSS_DEBUG=1"
  if /I "%%~A"=="-debug" set "VSS_DEBUG=1"
  if /I "%%~A"=="--debug" set "VSS_DEBUG=1"
)
if not exist "%TEMP%\shadowconsole" mkdir "%TEMP%\shadowconsole"
rem 提取前清理上次残留(崩溃/异常退出遗留的旧脚本), 保证 %TEMP% 无历史残留
if exist "%PSRUN%" del /q "%PSRUN%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$s=[IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8);$a='__'+'VSS_PS1_BEGIN__';$b='__'+'VSS_PS1_END__';$i=$s.IndexOf($a)+$a.Length;$j=$s.IndexOf($b,$i);$p='%~f0';$body='$script:VssSelfFile = '''+$p+''';'+[char]13+[char]10+$s.Substring($i,$j-$i);[IO.File]::WriteAllText($env:TEMP+'\shadowconsole\vss_console_run.ps1',$body,[Text.UTF8Encoding]::new($true))"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PSRUN%"
rem 注意: 正常退出时 ps1 会自清理临时脚本; 提权场景由提权进程清理(主进程发起 RunAs 后即退出, 不删);
rem 崩溃残留由下次启动时上面的 del 清掉; 固定路径每次启动重新提取覆盖
rem 日志: 默认只写内存(不落盘); /debug 或界面开关打开时才写 %TEMP%\shadowconsole\*.log,
rem       关闭开关时 ps1 会立即清理一次已落盘的日志(系统不会清理 %TEMP%, 不清会变陈年垃圾)
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
$script:Schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
$g = Get-Command vssadmin.exe -ErrorAction SilentlyContinue
if ($g) { $script:VssAdmin = $g.Source }
$g = Get-Command diskshadow.exe -ErrorAction SilentlyContinue
if ($g) { $script:Diskshadow = $g.Source }
$g = Get-Command schtasks.exe -ErrorAction SilentlyContinue
if ($g) { $script:Schtasks = $g.Source }
$g = $null
$script:AppName = '卷影管理台'
$script:Log = New-Object System.Collections.Generic.List[object]

# ===== 诊断日志: 默认只写内存, 不落盘 =====
# 默认只进内存环形缓冲(每文件 500 行), 退出即消失; 加 /debug 或勾选「日志落盘」才写
# %TEMP%\shadowconsole\*.log(%TEMP% 系统不会清, 故关掉开关时立即清一次)。
$script:LogDir     = Join-Path $env:TEMP 'shadowconsole'
$script:MemLogs    = @{}           # 名称 → List[string](内存环形缓冲)
$script:MemLogMax  = 500
$script:DebugMode  = (($env:VSS_DEBUG -eq '1') -or (@($args) -contains '/debug'))
$script:LogDisk    = [bool]$script:DebugMode   # 生效中的落盘状态
$script:LogDiskPref = $false                  # 设置里保存的偏好(不含 /debug 这一次性覆盖)

# 诊断日志写入: ① 内存环形缓冲(默认唯一去处) ② 落盘(仅 /debug 或「日志落盘」开关打开时)
function Write-Diag {
  param([string]$Name, [string]$Text)
  if (-not $Name) { $Name = 'diag' }
  $line = [string]$Text
  try {
    $buf = $script:MemLogs[$Name]
    if (-not $buf) { $buf = New-Object System.Collections.Generic.List[string]; $script:MemLogs[$Name] = $buf }
    $buf.Add($line) | Out-Null
    while ($buf.Count -gt $script:MemLogMax) { $buf.RemoveAt(0) }
  } catch {}
  if ($script:LogDisk) {
    try {
      [IO.Directory]::CreateDirectory($script:LogDir) | Out-Null
      [IO.File]::AppendAllText((Join-Path $script:LogDir ($Name + '.log')), ($line + "`r`n"), (New-Object Text.UTF8Encoding $true))
    } catch {}
  }
}

# 清理已落盘的诊断日志(关掉「日志落盘」时执行一次; 启动时未开启落盘也执行一次)
# 只删本程序留下的 *.log 与 sched_*.xml; 计划任务要用的 sched_*.ps1 必须留(删了任务就跑不起来)
function Clear-DiskLogs {
  $dir = $script:LogDir
  $n = 0
  try {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
      if (($f.Name -like '*.log') -or ($f.Name -like 'sched_*.xml')) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch {}
      }
    }
  } catch {}
  return $n
}

# 「日志落盘」开关的统一处理: 切换生效状态 + 保存设置 + 关闭时立即清理一次已落盘的日志
function Set-LogDisk {
  param([bool]$On)
  $script:LogDisk = $On
  $script:LogDiskPref = $On
  try { Save-Settings @{ LogDisk = $On } } catch {}
  if ($On) {
    Write-Diag 'runpath' ('[logdisk ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ON -> ' + $script:LogDir)
    try { Show-Toast -Message ('日志落盘已开启: ' + $script:LogDir + '\*.log') } catch {}
  } else {
    # 关掉开关: 立即清理一次 —— %TEMP% 系统不会主动清, 不清就成陈年垃圾
    $n = 0
    try { $n = Clear-DiskLogs } catch {}
    try { Show-Toast -Message ('日志落盘已关闭, 已清理 ' + $n + ' 个日志文件') } catch {}
  }
}

# 落盘日志保留策略: 每个文件只留最近 500 行(按时间清理不适用, 天天用就永不过期)
function Truncate-DiskLogs {
  try {
    if (-not (Test-Path -LiteralPath $script:LogDir)) { return }
    Get-ChildItem -LiteralPath $script:LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $lines = [IO.File]::ReadAllLines($_.FullName)
        if ($lines.Count -gt 500) {
          [IO.File]::WriteAllLines($_.FullName, $lines[($lines.Count - 500)..($lines.Count - 1)], (New-Object Text.UTF8Encoding $false))
        }
      } catch {}
    }
  } catch {}
}

# 把内存里的诊断日志拼成一段文本(界面「诊断日志」按钮用)
function Get-DiagDump {
  $sb = New-Object System.Text.StringBuilder
  try {
    foreach ($k in @($script:MemLogs.Keys | Sort-Object)) {
      $buf = $script:MemLogs[$k]
      [void]$sb.AppendLine(('===== ' + $k + '  (' + $buf.Count + ' 行) ====='))
      foreach ($l in $buf) { [void]$sb.AppendLine($l) }
      [void]$sb.AppendLine('')
    }
  } catch {}
  if ($sb.Length -eq 0) { return '(内存里没有任何诊断日志)' }
  return $sb.ToString()
}

$script:FilterLetter = $null
$script:FilterDisplay = $null
# 定时任务「目标卷」下拉的并行映射: 与 ComboBox 显示字符串按下标一一对应
# (自定义 ComboBox 模板不生效 DisplayMemberPath, 放对象会渲染成 @{Key=..; Display=..})
$script:SchedVolKeys = @()
$script:SchedVolNames = @()
$script:CanAct = $false
$script:ConfirmFrame = $null
$script:ResizeFrame = $null
$script:ConfirmResult = $false
$script:ResizeResult = $null
$script:ElevationDenied = $false
$script:InvCulture = [Globalization.CultureInfo]::InvariantCulture

# ===== 写操作/刷新任务调度: 串行队列(FIFO) =====
# 不串行的后果(实测): 连点"创建卷影"会并发发起多个 WMI Create → 后到者撞上 VSS
# "另一个卷影操作正在进行"(返回码 9, 日志 ExitCode -209), 结果错乱。
$script:JobQueue = New-Object System.Collections.Generic.List[object]
$script:JobCurrent = $null
$script:JobSeq = 0
$script:JobLog = New-Object System.Collections.Generic.List[object]
$script:JobPump = $null
$script:JobClosing = $false
$script:BgPump = $null          # 后台任务(runspace)泵, 只负责采集数据, 由 Pump-Tasks 驱动

# ===== 主题色: 全项目唯一的配色来源 =====
# 这两张表就是明/暗主题的全部 27 个 C_* 键(Set-Theme 在窗口显示前写进 $window.Resources,
# XAML 一律用 {DynamicResource C_xxx} 引用) —— 改配色只改这里, 不存在两处漂移。
$script:ThemeLight = @{
  C_Bg='#F3F5F8'; C_Panel='#FFFFFF'; C_Border='#DDE1E8'; C_Divider='#ECF0F4'
  C_Ink='#1B212B'; C_Sub='#5B6472'; C_Faint='#929BA8'
  C_Accent='#2F6BF4'; C_AccentHover='#1D5AE0'; C_AccentDown='#174CBF'
  C_AccentSoft='#EAF1FE'; C_AccentSoftHover='#DDE9FD'; C_OnAccent='#FFFFFF'
  C_Danger='#D64545'; C_DangerHover='#C03939'; C_DangerDown='#A93333'; C_DangerSoft='#FBEFEF'
  C_Success='#1E9E5A'
  C_Warn='#B7791F'; C_WarnSoft='#FBF3E3'
  C_SurfaceHover='#F7F9FC'; C_Overlay='#66000000'; C_ScrollThumb='#D0D5DC'
  C_RowGray='#EAEEF3'; C_RowRed='#FBECEC'
# 组间分割线: 取滚动条拇指色 —— 用户要求"线条颜色和边上滚动用的进度条一样"。
# 演进: #ECF0F4(看不见) → #B6C0CE(用户说看不出) → #9AA8BB(太抢眼) → #D0D5DC(当前)。
# ⚠ "线看不见"的真正根因不是颜色, 而是 SeparatorBrush 恒为 null(见 C# 注释)。
  C_SepLine='#D0D5DC'
}
$script:ThemeDark = @{
  C_Bg='#14161A'; C_Panel='#1D2026'; C_Border='#2E333C'; C_Divider='#262B33'
  C_Ink='#F2F4F8'; C_Sub='#9AA3B2'; C_Faint='#67707F'
  C_Accent='#5B8DF6'; C_AccentHover='#7AA6FF'; C_AccentDown='#4E7DDE'
  C_AccentSoft='#1C2A4A'; C_AccentSoftHover='#24375F'; C_OnAccent='#FFFFFF'
  C_Danger='#F26D6D'; C_DangerHover='#FF8080'; C_DangerDown='#E14F4F'; C_DangerSoft='#3A2222'
  C_Success='#3FBF75'
  C_Warn='#E5B23C'; C_WarnSoft='#39301C'
  C_SurfaceHover='#232730'; C_Overlay='#B4000000'; C_ScrollThumb='#3A404B'
  C_RowGray='#30353F'; C_RowRed='#3A2D30'
  # 深色主题同样对齐滚动条拇指色 C_ScrollThumb='#3A404B'
  C_SepLine='#3A404B'
}
# 配置修改自身(内嵌于脚本尾部配置区), 零外部文件; bat 分发由 bat 设置 VSS_SELF
$script:ThemeMode = 'System'
# ⚠ 后台 runspace 里的函数读不到 $script: 变量, 常量一律写在函数体内(见 Get-BgBody)

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# ISE / VSCode 等 GUI 宿主里跑不了 WPF 消息循环 → 换控制台版 powershell.exe 重启
$hostName = ''
try { $hostName = $Host.Name } catch {}
$hostExe = (Get-Process -Id $PID).Path
$guiHost = ($hostName -match 'ISE|Visual Studio Code Host' -or $hostExe -match 'powershell_ise\.exe|pwsh_ise\.exe|Code\.exe')
if ($guiHost) {
  try {
    $consoleExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $consoleExe)) { $consoleExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
    if ($consoleExe) {
      $guiArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"")
      if ($script:DebugMode) { $guiArgs += '/debug' }
      Start-Process -FilePath $consoleExe -ArgumentList $guiArgs | Out-Null
      exit 0
    }
  } catch {}
}
# 非管理员 → 尝试提权重启(UAC); 用户拒绝 → 只读模式
if (-not $script:IsAdmin) {
  try {
    $elevArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"")
    # /debug 跟随提权重启: 环境变量 VSS_DEBUG 本就会继承, 这里再显式带一次作双保险
    if ($script:DebugMode) { $elevArgs += '/debug' }
    Start-Process -FilePath $hostExe -ArgumentList $elevArgs -Verb RunAs | Out-Null
    exit 0
  } catch { $script:ElevationDenied = $true }
}
if ($script:IsAdmin) { $script:CanAct = $true }

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="卷影管理台 · VSS Shadow Console" Width="1020" Height="885" MinWidth="720" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource C_Bg}" ShowInTaskbar="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        FlowDirection="LeftToRight"
        TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Window.Resources>
<!-- 主题色不在这里定义: 27 个 C_* 键只存在于 PS 的 $script:ThemeLight/ThemeDark 两张表。 -->

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
              <Track x:Name="PART_Track">
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
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="True"/>
              </Trigger>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter Property="Height" Value="10"/>
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
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
    <!-- ===== 按钮体系 =====
         外观骨架全项目共用一套(tpl_btn): 边框 + 居中内容。各变体只声明自己的配色/尺寸/字重。
         悬停/按下/禁用态一律放在**样式级** Style.Triggers(改 Button 自身属性), 模板用 TemplateBinding 跟随。
         为什么不放模板里: 模板触发器直接改内层 Border 的 Background, 会盖过样式层的 Background ——
         于是"半透明灰态按钮"一悬停就跳成亮蓝(见 st_cardCreate 的说明)。
         ⚠ 样式级触发器里不要写 Padding: 模板没有绑定 Padding, 写了也不生效(纯误导)。 -->
    <ControlTemplate x:Key="tpl_btn" TargetType="Button">
      <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </ControlTemplate>
    <Style x:Key="st_btn" TargetType="Button">
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template" Value="{StaticResource tpl_btn}"/>
    </Style>

    <Style x:Key="st_btnPrimary" TargetType="Button" BasedOn="{StaticResource st_btn}">
      <Setter Property="Foreground" Value="{DynamicResource C_OnAccent}"/>
      <Setter Property="Background" Value="{DynamicResource C_Accent}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Accent}"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_AccentHover}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_AccentHover}"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_AccentDown}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_AccentDown}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Background" Value="{DynamicResource C_AccentSoft}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_AccentSoft}"/>
          <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- 卡片"创建卷影"按钮: 卷尚不能创建(不能自存差异区且未设外部存储)时整体半透明呈灰态但保持可点击,
         点击引导到配额窗口设置存储位置; 设置完成后恢复主题色。
         用 Opacity 而不是换背景色: 换色只能改"静止态", 悬停/按下时样式级触发器仍会盖回主题色,
         出现"灰态一悬停就跳亮蓝"; Opacity 统一淡化, 悬停表现一致且文字对比度正常 -->
    <Style x:Key="st_cardCreate" TargetType="Button" BasedOn="{StaticResource st_btnPrimary}">
      <Style.Triggers>
        <DataTrigger Binding="{Binding CreateReady}" Value="False">
          <Setter Property="Opacity" Value="0.45"/>
        </DataTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="st_btnSecondary" TargetType="Button" BasedOn="{StaticResource st_btn}">
      <Setter Property="Foreground" Value="{DynamicResource C_Ink}"/>
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontSize" Value="13"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_SurfaceHover}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_Accent}"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_AccentSoft}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_Accent}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_Divider}"/>
          <Setter Property="Background" Value="{DynamicResource C_Bg}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="st_btnDanger" TargetType="Button" BasedOn="{StaticResource st_btn}">
      <Setter Property="Foreground" Value="{DynamicResource C_OnAccent}"/>
      <Setter Property="Background" Value="{DynamicResource C_Danger}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Danger}"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_DangerHover}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_DangerHover}"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_DangerDown}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_DangerDown}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Background" Value="{DynamicResource C_DangerSoft}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource C_DangerSoft}"/>
          <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="st_btnGhost" TargetType="Button" BasedOn="{StaticResource st_btn}">
      <Setter Property="Foreground" Value="{DynamicResource C_Sub}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_AccentSoft}"/>
          <Setter Property="Foreground" Value="{DynamicResource C_Accent}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="st_btnLinkDanger" TargetType="Button" BasedOn="{StaticResource st_btn}">
      <Setter Property="Foreground" Value="{DynamicResource C_Danger}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="FontSize" Value="12"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_DangerSoft}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="st_btnIcon" TargetType="Button" BasedOn="{StaticResource st_btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Width" Value="32"/>
      <Setter Property="Height" Value="30"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_AccentSoft}"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="{DynamicResource C_AccentSoftHover}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- 导航项: 不需要描边且内容左对齐(与上面那套居中骨架不同, 故单独一份模板) -->
    <Style x:Key="st_nav" TargetType="Button" BasedOn="{StaticResource st_btn}">
      <Setter Property="Foreground" Value="{DynamicResource C_Sub}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource C_SurfaceHover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Foreground" Value="{DynamicResource C_Accent}"/>
        </Trigger>
      </Style.Triggers>
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
<!-- 关闭触摸交互(桌面鼠标工具, 不优化触屏) -->
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
<!-- 高亮分离: 背景层与内容层分开 —— 选中/悬停只重绘背景纯色层, 文字用缓存位图叠加 -->
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

<!-- ★ 卡片边框"四边等粗"三件套(别单独删任何一个):
     ① BorderThickness=1.6 → 125% 缩放下恰为 2.0 物理px, 四边恒等粗(用 1 则亚像素取整后有的边 1px);
     ② SnapsToDevicePixels=True → 根节点上的是可继承属性, 经 ItemsControl→ContentPresenter→
        DataTemplate 后不保证仍生效, 故卡片自身显式再设一次;
     ③ 常态与选中态都是 2 物理px, 选中只靠颜色变蓝区分。
     ⚠ 别给 st_card 加 CacheMode=BitmapCache: 它按"首次布局 RenderSize"缓存位图, 边框厚度
       一变就超出缓存被裁(实测蓝框左边只画出下半段)。 -->
    <Style x:Key="st_card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource C_Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
      <Setter Property="BorderThickness" Value="1.6"/>
      <Setter Property="Padding" Value="12"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
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
        <StackPanel x:Name="spnStatus" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0" Visibility="Collapsed">
          <Border x:Name="spnDot" Width="10" Height="10" BorderBrush="{DynamicResource C_Accent}" BorderThickness="1.5" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform><RotateTransform x:Name="spinMini" Angle="0"/></Border.RenderTransform>
          </Border>
          <TextBlock x:Name="txtStatus" FontSize="11.5" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center" Margin="8,0,0,0" TextTrimming="CharacterEllipsis" MaxWidth="420"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="btnTheme" Style="{StaticResource st_btnIcon}" ToolTipService.InitialShowDelay="100" ToolTip="切换明暗主题">
            <Path x:Name="iconTheme" Width="15" Height="15" Style="{StaticResource st_icon}" Data="M9.6,2 A5.6,5.6 0 1 0 14,9.2 A4.4,4.4 0 1 1 9.6,2 Z"/>
          </Button>
          <Button x:Name="btnRefresh" Style="{StaticResource st_btnIcon}" ToolTipService.InitialShowDelay="100" ToolTip="刷新 (F5)" Margin="4,0,0,0">
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
        <ColumnDefinition Width="196" MinWidth="110" MaxWidth="340"/>
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
      <GridSplitter x:Name="splitNav" Grid.Column="1" Width="5" HorizontalAlignment="Center" VerticalAlignment="Stretch" Background="Transparent" ShowsPreview="False" Cursor="SizeWE" ResizeBehavior="PreviousAndNext" ResizeDirection="Columns" ToolTipService.InitialShowDelay="100" ToolTip="拖拽调整左侧宽度">
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
<!-- 卡片区 : 卷影列表 = 2 : 1(列表占 1/3)。这两行**不给 Min/Max** —— 一行带 Min/Max 会
     完全退出星号分配, 余量被另一行独吞。列表下限另由 RowDefinitions[3].MinHeight 常驻补齐。 -->
            <RowDefinition Height="2*"/>
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
              <Border x:Name="chipFilter" Style="{StaticResource st_chip}" Margin="10,0,0,0" Visibility="Collapsed" Cursor="Hand" ToolTipService.InitialShowDelay="100" ToolTip="点击取消筛选">
                <TextBlock x:Name="txtFilter" Style="{StaticResource st_chipText}"/>
              </Border>
              <Border x:Name="chipBrowse" Style="{StaticResource st_chip}" Margin="8,0,0,0" Visibility="Collapsed" Cursor="Hand" ToolTipService.InitialShowDelay="100" ToolTip="打开卷影浏览">
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
<!-- 所有卡片共用**同一套 Margin**(硬约束): 面板按 colIdx × 列宽定位, 列宽 = 卡片宽 + 外距;
     任何一张卡多出左距, 右缘就会捅进下一列。⚠ 不要再往 DataTemplate/DataTrigger 里塞 Margin 差异。 -->
<!-- 卡片不定宽: 宽度由 CardPanel 按"标准 3 列"分配(夹在 190~320), 缩放到下限才降列数 -->
<!-- Tag={Binding Group} 供面板读分组号(PSObject 的 NoteProperty 反射取不到) -->
                  <Border x:Name="card" MinWidth="190" MaxWidth="320" Tag="{Binding Group}" Cursor="Hand">
                    <Border.Style>
                      <Style TargetType="Border" BasedOn="{StaticResource st_card}">
                        <Setter Property="Margin" Value="0,0,10,10"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding Active}" Value="True">
                            <Setter Property="BorderBrush" Value="{DynamicResource C_Accent}"/>
<!-- ★ 选中框厚度 1.6 不是 2: 125% 缩放下 1.6*1.25=2.0 物理px 恰为整数, 四边恒等粗
     (用 2 → 2.5 物理px, 亚像素取整后右边只剩 1px)。⚠ 换缩放比(150%)时此值要重算: 目标 = 2/缩放比。 -->
                            <Setter Property="BorderThickness" Value="1.6"/>
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
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="{Binding DisplayLetter}" FontSize="22" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI" Foreground="{DynamicResource C_Ink}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTipService.InitialShowDelay="100" ToolTip="{Binding TipText}"/>
                        <Border Grid.Column="1" Style="{StaticResource st_chip}" Margin="8,0,0,0">
                          <TextBlock Text="{Binding ShadowCountText}" Style="{StaticResource st_chipText}"/>
                        </Border>
                      </Grid>
                      <Grid Grid.Row="1" Margin="0,4,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="{Binding Label}" Foreground="{DynamicResource C_Sub}" FontSize="12.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="1" Text="{Binding FsText}" Foreground="{DynamicResource C_Faint}" FontSize="11.5" FontFamily="Cascadia Mono, Consolas" Margin="8,0,0,0" VerticalAlignment="Center"/>
                      </Grid>
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
                          <Button Name="btnCardCreate" Content="创建卷影" Height="26" Padding="10,0" FontSize="12" IsEnabled="{Binding CanCreate}" Tag="{Binding Letter}" ToolTipService.InitialShowDelay="100" ToolTipService.ShowOnDisabled="True" ToolTip="{Binding FsTip}">
                            <Button.Style>
                              <Style TargetType="Button" BasedOn="{StaticResource st_cardCreate}">
                                <Style.Triggers>
                                  <DataTrigger Binding="{Binding CreateGrayed}" Value="True">
                                    <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
                                    <Setter Property="Opacity" Value="0.6"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
                                  </DataTrigger>
                                </Style.Triggers>
                              </Style>
                            </Button.Style>
                          </Button>
                          <Button Name="btnCardQuota" Content="配额" Height="26" Padding="10,0" FontSize="12" Margin="6,0,0,0" IsEnabled="{Binding CanCreate}" Tag="{Binding Letter}" ToolTipService.InitialShowDelay="100" ToolTipService.ShowOnDisabled="True" ToolTip="{Binding QuotaTip}">
                            <Button.Style>
                              <Style TargetType="Button" BasedOn="{StaticResource st_btnSecondary}">
                                <Style.Triggers>
                                  <DataTrigger Binding="{Binding QuotaGrayed}" Value="True">
                                    <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
                                    <Setter Property="Opacity" Value="0.6"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource C_Border}"/>
                                  </DataTrigger>
                                </Style.Triggers>
                              </Style>
                            </Button.Style>
                          </Button>
                        </StackPanel>
                      </Grid>
                    </Grid>
                  </Border>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>

<!-- ResizeBehavior/ResizeDirection 必须显式给: 该行是 Height="Auto" 且只放分割条, 自动判定找不到可改的行, 整条拖不动 -->
          <GridSplitter x:Name="splitCard" Grid.Row="2" Height="5" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="Transparent" Cursor="SizeNS" ResizeBehavior="PreviousAndNext" ResizeDirection="Rows" ToolTipService.InitialShowDelay="100" ToolTip="拖拽调整卡片/列表高度">
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
                  <GridViewColumn Header="创建时间" Width="130">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding CreatedText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="卷" Width="45">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding LetterDisplay}" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="阴影 ID" Width="165">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTipService.InitialShowDelay="100" ToolTipService.BetweenShowDelay="0"><TextBlock.ToolTip><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}"/></TextBlock.ToolTip></TextBlock></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="设备对象" Width="135">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Device}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTipService.InitialShowDelay="100" ToolTipService.BetweenShowDelay="0"><TextBlock.ToolTip><TextBlock Text="{Binding Device}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}"/></TextBlock.ToolTip></TextBlock></DataTemplate></GridViewColumn.CellTemplate>
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
          <ListView x:Name="lstStorage" Grid.Row="1" Style="{StaticResource st_list}">
            <ListView.ItemContainerStyle>
              <Style TargetType="ListViewItem" BasedOn="{StaticResource st_listItem}">
                <!-- 行底色: nosetup=该卷不能在本卷存差异区且未设置保存位置(淡红); noshadow=从未创建过卷影副本(淡灰) -->
                <Style.Triggers>
                  <DataTrigger Binding="{Binding RowState}" Value="nosetup"><Setter Property="Background" Value="{DynamicResource C_RowRed}"/></DataTrigger>
                  <DataTrigger Binding="{Binding RowState}" Value="noshadow"><Setter Property="Background" Value="{DynamicResource C_RowGray}"/></DataTrigger>
                </Style.Triggers>
            </Style>
          </ListView.ItemContainerStyle>
          <ListView.GroupStyle>
            <GroupStyle>
              <GroupStyle.HeaderTemplate>
                <DataTemplate>
                  <Rectangle Height="1" Fill="{DynamicResource C_Border}" Margin="0,5,0,5" SnapsToDevicePixels="True" UseLayoutRounding="True"/>
                </DataTemplate>
              </GroupStyle.HeaderTemplate>
            </GroupStyle>
          </ListView.GroupStyle>
          <ListView.View>
              <GridView>
                <GridView.ColumnHeaderContainerStyle>
                  <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                </GridView.ColumnHeaderContainerStyle>
                <GridViewColumn Header="卷" Width="55">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding LetterDisplay}" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="卷标" Width="95">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding LabelText}" FontSize="12" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="文件系统" Width="80">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding FsText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource C_Faint}" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="已用空间" Width="NaN">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding UsedText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="已分配" Width="NaN">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding AllocText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="上限" Width="NaN">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding MaxText}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="占用比例" Width="165">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <Grid VerticalAlignment="Center">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Border Height="6" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" HorizontalAlignment="Stretch">
                          <Grid>
                            <Grid.ColumnDefinitions>
                              <ColumnDefinition Width="{Binding BarUsed}"/>
                              <ColumnDefinition Width="{Binding BarFree}"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Height="4" Background="{DynamicResource C_Accent}" VerticalAlignment="Bottom"/>
                          </Grid>
                        </Border>
                        <TextBlock Grid.Column="1" Text="{Binding PctText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" Margin="8,0,0,0"/>
                      </Grid>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="存储位置" Width="70">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding DiffDisplay}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="操作" Width="70">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <Button Name="btnStorageAdjust" Content="调整" Height="24" IsEnabled="{Binding CanAct}" ToolTipService.InitialShowDelay="100" ToolTipService.ShowOnDisabled="True" ToolTip="{Binding QuotaTip}">
                        <Button.Style>
                          <Style TargetType="Button" BasedOn="{StaticResource st_btnGhost}">
                            <Style.Triggers>
                              <DataTrigger Binding="{Binding QuotaGrayed}" Value="True">
                                <Setter Property="Foreground" Value="{DynamicResource C_Faint}"/>
                                <Setter Property="Opacity" Value="0.6"/>
                              </DataTrigger>
                            </Style.Triggers>
                          </Style>
                        </Button.Style>
                      </Button>
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
            <Grid.RowDefinitions>
              <RowDefinition Height="*" MinHeight="150" MaxHeight="240"/>
              <RowDefinition Height="10"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="30"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,0,1">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="任务列表" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource C_Sub}" Margin="10,0" VerticalAlignment="Center"/>
                    <Button x:Name="btnSchedNew" Grid.Column="1" Content="新增任务" Style="{StaticResource st_btnPrimary}" Height="22" Padding="10,0" FontSize="11.5" Margin="0,0,8,0" VerticalAlignment="Center" ToolTipService.InitialShowDelay="100" ToolTip="清空表单,新建一个计划任务"/>
                  </Grid>
                </Border>
                <ListView x:Name="lstSchedTasks" Grid.Row="1" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}" ScrollViewer.HorizontalScrollBarVisibility="Auto">
                  <ListView.View>
                    <GridView>
                      <GridView.ColumnHeaderContainerStyle>
                        <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                      </GridView.ColumnHeaderContainerStyle>
                      <GridViewColumn Header="任务" Width="210">
                        <GridViewColumn.CellTemplate>
                          <DataTemplate>
                            <StackPanel Orientation="Horizontal">
                              <Border Width="7" Height="7" Background="{Binding StateBrush}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                              <TextBlock Text="{Binding TaskName}" FontSize="12" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                            </StackPanel>
                          </DataTemplate>
                        </GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="计划" Width="NaN">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding PlanText}" FontSize="11.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding PlanText}" ToolTipService.InitialShowDelay="100" ToolTipService.BetweenShowDelay="0"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="状态" Width="70">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding StateText}" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="上次运行" Width="150">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding LastRunText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding LastRunText}" ToolTipService.InitialShowDelay="100" ToolTipService.BetweenShowDelay="0"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="上次结果" Width="100">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding ResultText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding ResultHint}" ToolTipService.InitialShowDelay="100" ToolTipService.BetweenShowDelay="0" Foreground="{Binding ResultBrush}"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="下次运行" Width="150">
                        <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding NextRunText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding NextRunText}" ToolTipService.InitialShowDelay="100" ToolTipService.BetweenShowDelay="0"/></DataTemplate></GridViewColumn.CellTemplate>
                      </GridViewColumn>
                    </GridView>
                  </ListView.View>
                </ListView>
              </Grid>
            </Border>
            <Border Grid.Row="2" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1">
<!-- 低分屏兜底: 详情表单高, 包一层 ScrollViewer 保证保存/删除按钮永远可操作 -->
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
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
                    <TextBox x:Name="txtSchedTime" Style="{StaticResource st_inputMono}" Text="09:00" ToolTipService.InitialShowDelay="100" ToolTip="多个时间点用逗号分隔,如 09:00,14:00,18:00"/>
                    <StackPanel x:Name="spnFreq" Orientation="Horizontal" Visibility="Collapsed">
                      <TextBlock Text="每隔" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBox x:Name="txtSchedFreq" Style="{StaticResource st_inputMono}" Width="56" Margin="6,0" Text="5" ToolTipService.InitialShowDelay="100" ToolTip="重复间隔"/>
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
                      <TextBox x:Name="txtSchedInterval" Style="{StaticResource st_inputMono}" Width="56" Margin="6,0" Text="1" ToolTipService.InitialShowDelay="100" ToolTip="高频任务的重复间隔"/>
                      <TextBlock x:Name="txtSchedIntervalUnit" Text="天" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBlock x:Name="txtSchedIntervalHint" Text="(0 表示每天)" VerticalAlignment="Center" FontSize="11" Foreground="{DynamicResource C_Faint}" Margin="8,0,0,0"/>
                    </StackPanel>
                    <StackPanel x:Name="spnMonthly" Orientation="Horizontal" Visibility="Collapsed">
                      <TextBlock Text="每月" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
                      <TextBox x:Name="txtSchedMonthDay" Style="{StaticResource st_inputMono}" Width="56" Margin="6,0" Text="1" ToolTipService.InitialShowDelay="100" ToolTip="每月的几号运行,1-31; 31 表示每月最后一天"/>
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
                    <!-- 下次运行: 标签与值放同一 StackPanel, 避免同列两个兄弟元素按列宽对齐时相互覆盖 -->
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                      <TextBlock Text="下次运行" FontSize="11" Foreground="{DynamicResource C_Sub}" VerticalAlignment="Center"/>
                      <TextBlock x:Name="txtSchedNextRun" Text="—" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Ink}" Margin="6,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Grid>
                </Border>
                <StackPanel Grid.Row="9" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,12,0,0">
                  <Button x:Name="btnSchedExport" Content="导出 XML" Style="{StaticResource st_btnGhost}" ToolTipService.InitialShowDelay="100" ToolTip="导出任务定义到 XML 文件"/>
                  <Button x:Name="btnSchedRunNow" Content="立即运行" Style="{StaticResource st_btnSecondary}" Margin="8,0,0,0"/>
                  <Button x:Name="btnSchedToggle" Content="启用/禁用" Style="{StaticResource st_btnSecondary}" Margin="8,0,0,0"/>
                  <Button x:Name="btnSchedDelete" Content="删除任务" Style="{StaticResource st_btnDanger}" Margin="8,0,0,0"/>
                  <Button x:Name="btnSchedSave" Content="保存任务" Style="{StaticResource st_btnPrimary}" Margin="8,0,0,0"/>
                </StackPanel>
              </Grid>
              </ScrollViewer>
            </Border>
          </Grid>
          <Border Grid.Row="2" Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Padding="10,6" Margin="0,10,0,0">
            <TextBlock Text="原理:每个任务调用 Win32_ShadowCopy.Create 创建 ClientAccessible 卷影,旧卷影由系统存储配额自动淘汰。任务注册在 任务计划程序 → ShadowConsole 目录下。" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}"/>
          </Border>
        </Grid>
        <Grid x:Name="pageLog" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
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
              <CheckBox x:Name="chkLogDisk" Content="日志落盘" VerticalAlignment="Center" Margin="0,0,14,0" FontSize="12" Foreground="{DynamicResource C_Ink}" ToolTipService.InitialShowDelay="100" ToolTip="默认关闭: 诊断日志只存在内存里, 退出即消失, 磁盘不留痕迹。打开后写入 %TEMP%\shadowconsole\*.log(系统不会自动清理 %TEMP%, 长期使用会变成陈年垃圾); 关闭时会立即清理一次已落盘的日志。"/>
              <Button x:Name="btnDiag" Content="诊断日志" Style="{StaticResource st_btnGhost}"/>
              <Button x:Name="btnLogCopy" Content="复制输出" Style="{StaticResource st_btnSecondary}" Margin="8,0,0,0"/>
              <Button x:Name="btnLogClear" Content="清空" Style="{StaticResource st_btnGhost}" Margin="8,0,0,0"/>
            </StackPanel>
          </Grid>
          <Border Grid.Row="1" Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" Margin="0,0,0,10">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="30"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <Border Background="{DynamicResource C_Bg}" BorderBrush="{DynamicResource C_Border}" BorderThickness="0,0,0,1">
                <StackPanel Orientation="Horizontal" Margin="10,0" VerticalAlignment="Center">
                  <TextBlock Text="任务队列" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource C_Sub}"/>
                  <TextBlock x:Name="txtJobSummary" FontSize="11" Foreground="{DynamicResource C_Faint}" Margin="10,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <ListView x:Name="lstJobs" Grid.Row="1" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}" BorderThickness="0" Height="118">
                <ListView.View>
                  <GridView>
                    <GridView.ColumnHeaderContainerStyle>
                      <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                    </GridView.ColumnHeaderContainerStyle>
                    <GridViewColumn Header="时间" Width="85">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding TimeText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="任务" Width="300">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" FontSize="11.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="状态" Width="75">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate>
                          <TextBlock Text="{Binding StateText}" FontSize="11.5" FontWeight="SemiBold" Foreground="{Binding StateBrush}" VerticalAlignment="Center"/>
                        </DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="说明" Width="NaN">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Detail}" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                  </GridView>
                </ListView.View>
              </ListView>
            </Grid>
          </Border>
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" MinWidth="300"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <ListView x:Name="lstLog" Style="{StaticResource st_list}" ItemContainerStyle="{StaticResource st_listItem}">
              <ListView.View>
                <GridView>
                  <GridView.ColumnHeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader" BasedOn="{StaticResource st_listHeader}"/>
                  </GridView.ColumnHeaderContainerStyle>
                  <GridViewColumn Header="时间" Width="95">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding TimeText}" FontFamily="Cascadia Mono, Consolas" FontSize="11" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="工具" Width="80">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Tool}" FontFamily="Cascadia Mono, Consolas" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="命令" Width="NaN">
                    <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Args}" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                  </GridViewColumn>
                  <GridViewColumn Header="退出码" Width="NaN">
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
                    <GridViewColumn Header="名称" Width="NaN">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" FontSize="12.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="类型" Width="NaN">
                      <GridViewColumn.CellTemplate>
                        <DataTemplate>
                          <StackPanel Orientation="Horizontal">
                            <Border Width="6" Height="6" Background="{Binding TypeBrush}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                            <TextBlock Text="{Binding TypeText}" FontSize="12" VerticalAlignment="Center"/>
                          </StackPanel>
                        </DataTemplate>
                      </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="版本" Width="NaN">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Version}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="提供程序 ID" Width="170">
                      <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="CLSID" Width="195">
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
                <GridViewColumn Header="状态" Width="NaN">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <StackPanel Orientation="Horizontal">
                        <Border Width="7" Height="7" Background="{Binding StateBrush}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock Text="{Binding StateText}" FontSize="12" VerticalAlignment="Center" FontWeight="SemiBold"/>
                      </StackPanel>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="写入程序" Width="NaN">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" FontSize="12.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="写入程序 ID" Width="225">
                  <GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Id}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource C_Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="实例 ID" Width="195">
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
<!-- 数据更新提示层: 窗口正中 70% 透明超大加粗"等待更新中"(StackPanel 整体居中, 无写死坐标)。
     小方块动画宽度固定 —— 点数变化不改尺寸, 否则每次变化触发全窗口布局重算导致卡顿。 -->
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
      <!-- 对话框宽度自适应(2026-09-20): MaxWidth 封顶 + Margin 让出边距, 窄窗口(720P/KVM)时跟随收缩不溢出 -->
      <Border Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" MaxWidth="400" Margin="16,0" HorizontalAlignment="Center" VerticalAlignment="Center">
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
      <!-- 对话框宽度自适应(同 grdConfirm): MaxWidth 封顶 + Margin 收缩 -->
      <Border Background="{DynamicResource C_Panel}" BorderBrush="{DynamicResource C_Border}" BorderThickness="1" MaxWidth="420" Margin="16,0" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Grid Margin="22">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
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
          <Grid Grid.Row="2" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="64"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="lblResizeDiff" Text="存储位置" VerticalAlignment="Center" FontSize="12.5" Foreground="{DynamicResource C_Sub}"/>
            <!-- 差异区所在卷: 候选=NTFS/ReFS 卷 + 卷自身(始终保留); 项为纯字符串, 真实卷键在 $script:ResizeDiffKeys 按下标对应 -->
            <ComboBox x:Name="cboResizeDiff" Grid.Column="1" Style="{StaticResource st_combo}" ItemContainerStyle="{StaticResource st_comboItem}" IsEditable="False" ToolTipService.InitialShowDelay="100" ToolTip="卷影差异数据保存在该卷上; 更换位置会创建新的存储关联"/>
          </Grid>
          <StackPanel Grid.Row="3" Margin="0,12,0,0">
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
          <TextBlock x:Name="txtResizeHint" Grid.Row="4" FontSize="11.5" Foreground="{DynamicResource C_Faint}" TextWrapping="Wrap" Margin="0,12,0,0" Text="上限只约束新写入的差异数据,已有卷影不受影响。存储位置可选 NTFS/ReFS 卷;本卷文件系统不能存放差异区时,请选择其他卷,设置后即可为该卷创建卷影。更换位置会创建新的存储关联,旧关联会询问是否清理(若其中仍有卷影,则保留待其删除)。"/>
          <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
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
  # 卷卡片面板的组间分割线颜色: 面板是在窗口创建后用代码插入的, 不走 DynamicResource, 需显式同步
  try { Sync-CardPanelBrush } catch {}
}

# 把当前主题的分隔线颜色同步给主页卷卡片面板(面板用代码插入, 不参与 DynamicResource 自动更新)
function Sync-CardPanelBrush {
  $p = Get-N 'cardHost'
  if (-not $p) { return }
# 面板实例在 ItemsPresenter 的视觉树里, 按类型查找; 首帧前可能还没生成(靠后续调用补)
  $found = $null
  $stack = New-Object System.Collections.Generic.Stack[object]
  $stack.Push($p)
  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    if ($cur -is [CardPanel]) { $found = $cur; break }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($cur)
    for ($i = 0; $i -lt $n; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($cur, $i)) }
  }
  if ($found) {
    # 组间装饰横线: 用 C_SepLine(不是表格分隔线 C_Divider —— 那档太浅, 2px 线在视觉上等于不存在)
    $brush = $window.Resources['C_SepLine']
    if (-not $brush) { $brush = $window.Resources['C_Divider'] }
    $found.SeparatorBrush = $brush
    $found.InvalidateArrange()
  }
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

# 旋转动画只启动一次: 任务泵 100ms tick 会反复调 Start-Spin, 每次重建动画持续占用 UI 线程
# → 右键菜单/操作卡顿
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
# ===== 任务队列: 串行(FIFO)执行 + 执行状态反馈 =====
# 状态: 等待中=已入队未开始 / 执行中=独占执行权 / 完成 / 失败 / 已合并=入队前被同键请求吸收
function Update-StatusIndicator {
  try {
    $spn = Get-N 'spnStatus'
    $cur = $script:JobCurrent
    $queCount = if ($script:JobQueue) { $script:JobQueue.Count } else { 0 }
    $hasBusy = ($cur -or $queCount -gt 0)
    if (-not $hasBusy) {
      if ($spn.Visibility -ne 'Collapsed') { $spn.Visibility = 'Collapsed' }
      Stop-Spin
      Stop-UpdateHint
      # 空闲即回到就绪态: 清掉上一轮的"执行中/排队"文案(下次进入忙态会重新计时)
      $script:StatusTickCount = 0
      return
    }
    if ($spn.Visibility -ne 'Visible') {
      $spn.Visibility = 'Visible'
      $script:StatusTickCount = 0
    }
    $anyVisible = $false
    if ($cur -and -not $cur.Quiet) { $anyVisible = $true }
    if (-not $anyVisible) { foreach ($t in $script:JobQueue) { if (-not $t.Quiet) { $anyVisible = $true; break } } }
    if ($anyVisible) { Start-UpdateHint } else { Stop-UpdateHint }
    # 节流: 每 5 tick(≈500ms)更新一次文本; 可见性/动画即时
    $script:StatusTickCount++
    if (($script:StatusTickCount % 5) -ne 1) { return }
    $txt = ''
    if ($cur) {
      $txt = '[执行中] ' + $cur.Name
      if ($cur.StartTime) {
        $sec = [string]::Format($script:InvCulture, '{0:0.0}s', ((Get-Date) - $cur.StartTime).TotalSeconds)
        $txt += (' · ' + $sec)
      }
      if ($cur.IsRefresh) {
        $line = Read-ProgressLine
        if ($line) {
          $p = $line -split '\|'
          if ($p.Count -ge 3) { $txt += (' · ' + $p[1] + ' ' + $p[2]) }
        }
      }
    }
    if ($queCount -gt 0) {
      $txt += ((' · ' + $(if ($cur) { '' } else { '[等待中] ' })) + '排队 ' + $queCount)
    }
    (Get-N 'txtStatus').Text = $txt
    Start-Spin
  } catch {}
}

# 刷新进度通道: 走内存共享通道(原先用 %TEMP% 下的进度文件传, 又一处 %TEMP% 残留):
# $script:Shared 是同步化 hashtable, 主/后台 runspace 持有同一实例(后台经任务参数拿到引用)。
$script:Shared = [hashtable]::Synchronized(@{})
$script:ProgLine = ''

function Read-ProgressLine {
  try {
    $line = [string]$script:Shared['prog']
    if (-not $line) { return $null }
    if ($line -eq $script:ProgLine) { return $null }
    $script:ProgLine = $line
    return $line
  } catch { return $null }
}

# 所有表格 ListView 的名字(列宽/列顺序/排序/横向滚动复位都按这个清单遍历); 新增表格时加进来
$script:ListNames = @('lstShadows','lstStorage','lstProviders','lstWriters','lstSchedTasks','lstLog')
$script:AllListNames = @('lstShadows','lstStorage','lstProviders','lstWriters','lstSchedTasks','lstLog','lstJobs')

# 计划任务类型: 内部标识 ↔ 界面标签, 两张表下标一一对应(下拉 SelectedIndex 即类型下标)
$script:SchedTypes  = @('minute','hour','day','week','month')
$script:SchedTypeLabels = @('按分钟循环','按小时循环','每天','每周','每月')

function Get-SettingsValues {
  $vals = @{
    Theme = $script:ThemeMode
# 「日志落盘」开关存的是**用户偏好**(LogDiskPref), 不是本次生效值 —— /debug 只是一次性覆盖,
# 不该被保存固化成"以后都落盘"。
    LogDisk = [bool]$script:LogDiskPref
    WLeft = $window.Left
    WTop = $window.Top
    WW = $window.Width
    WH = $window.Height
    NavPage = [int]$script:NavIndex
# 布局版本: 2=定时任务页改上下堆叠 3=卷影页改卡片:列表=2:1 4=列表下限改常驻 MinHeight
#         5=界面定稿尺寸基线(窗口 1020×885 / 卡片自适应 3 列 / 配额条自适应)。旧设置兼容, 门禁 -ge 4。
# 旧设置里的 lstSchedTasks 列宽是 330 窄栏时代留下的, 读取时删除让其用新默认值。
    LayoutVersion = 5
  }
  try {
    $mg = $window.FindName('mainGrid')
    if ($mg) { $vals.NavW = $mg.ColumnDefinitions[0].ActualWidth }
  } catch {}
  try {
    $ps = $window.FindName('pageShadows')
# 只在用户拖过分割条后记录卡片区高度 —— 否则窗口一缩放就把瞬时高度当成手工布局存下来
    if ($ps -and $script:ShadowRowManual) { $vals.CardH = $ps.RowDefinitions[1].ActualHeight }
  } catch {}
  # 表格列宽(所有 ListView 的 GridView 列, 表头去掉排序箭头)
  try {
    $colW = @{}
    foreach ($ln in $script:ListNames) {
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
    foreach ($ln in $script:ListNames) {
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
# 自身路径: bat 提取时注入 $script:VssSelfFile(提权进程也可靠) → 兜底 $env:VSS_SELF → $PSCommandPath
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
    Write-Diag 'runpath' ('[cfg-save ' + (Get-Date -Format 'HH:mm:ss.fff') + '] OK self=' + (Get-SelfPath) + ' keys=' + ($data.Keys -join ','))
  } catch {
    Write-Diag 'taskerr' ('[settings save ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString())
  }
}

function Load-Settings {
  try {
    $raw = Read-SettingsRaw
    if ($raw) {
      $obj = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($obj) {
        Write-Diag 'runpath' ('[cfg-load ' + (Get-Date -Format 'HH:mm:ss.fff') + '] self=' + (Get-SelfPath) + ' keys=' + ($obj.PSObject.Properties.Name -join ','))
        return $obj
      }
    }
  } catch {}
  return $null
}

# ===== 启动卫生(窗口创建之前做, 保证异常初始化也能清干净) =====
$script:Settings = Load-Settings
if ($script:Settings -and $null -ne $script:Settings.LogDisk) {
  $script:LogDiskPref = ($script:Settings.LogDisk -eq $true)
} else {
  $script:LogDiskPref = $false
}
# 生效状态 = 设置里的偏好 或 /debug 一次性覆盖
$script:LogDisk = ($script:LogDiskPref -or $script:DebugMode)
try {
  if ($script:LogDisk) {
    # 落盘开着: 保留上次的日志, 但按 500 行截断(与命令日志一致)
    $null = Truncate-DiskLogs
  } else {
    # 落盘关着(默认): 上次留下的日志/临时 XML 一律删掉 —— 崩溃残留也清, 兑现"无残留"
    $null = Clear-DiskLogs
  }
} catch {}
Write-Diag 'runpath' ('[startup ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] debug=' + $script:DebugMode + ' logdisk=' + $script:LogDisk)

function Format-Size {
  param([double]$Bytes)
  $inv = [Globalization.CultureInfo]::InvariantCulture
  if ($Bytes -ge 1TB) { return [string]::Format($inv, '{0:0.0} TB', ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return [string]::Format($inv, '{0:0.0} GB', ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return [string]::Format($inv, '{0:0.0} MB', ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return [string]::Format($inv, '{0:0.0} KB', ($Bytes / 1KB)) }
  return [string]::Format($inv, '{0} B', $Bytes)
}
# 构造"静默执行 + 捕获输出"的进程启动参数。输出编码必须用**系统 OEM 代码页**(vssadmin/schtasks
# 输出本地代码页文本, 用 UTF-8 读会乱码)。本函数在后台 runspace 执行, 纯 .NET。
function New-ProcInfo {
  param([string]$Exe, [string]$ArgStr)
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
  if ($oemEnc) {
    $psi.StandardOutputEncoding = $oemEnc; $psi.StandardErrorEncoding = $oemEnc
  } else {
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::Default } catch {}
    try { $psi.StandardErrorEncoding = [System.Text.Encoding]::Default } catch {}
  }
  return $psi
}

function Invoke-ToolBg {
  param([string]$Exe, [string]$ArgStr, [int]$TimeoutSec = 120)
  $psi = New-ProcInfo -Exe $Exe -ArgStr $ArgStr
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

# 异步启动外部命令(配合 Wait-ProcResult): 让 vssadmin list writers(~3s, 刷新耗时大头)与后续
# WMI 查询/计划任务读取重叠执行, 整轮刷新 4.2s→~3s(该命令本身是硬下限)。
function Start-ProcAsync {
  param([string]$Exe, [string]$ArgStr)
  $psi = New-ProcInfo -Exe $Exe -ArgStr $ArgStr
  $p = [System.Diagnostics.Process]::new()
  $p.StartInfo = $psi
  try { $p.Start() | Out-Null } catch { return $null }
  # stdout/stderr 异步读, 防止缓冲区填满导致进程阻塞; 结果稍后由 Wait-ProcResult 收割
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  return @{ Proc = $p; OutTask = $outTask; ErrTask = $errTask; Started = [datetime]::Now }
}

# 收割异步进程结果(配合 Start-ProcAsync): 轮到收割时进程多半已跑完(WaitForExit 秒回), 超时强杀。
function Wait-ProcResult {
  param($Handle, [int]$TimeoutSec = 120)
  if (-not $Handle -or -not $Handle.Proc) { return $null }
  $finished = $Handle.Proc.WaitForExit($TimeoutSec * 1000)
  if (-not $finished) { try { $Handle.Proc.Kill() } catch {}; $Handle.Proc.WaitForExit() }
  $out = ''; $err = ''
  try { $out = $Handle.OutTask.Result } catch {}
  try { $err = $Handle.ErrTask.Result } catch {}
  $text = ($out.TrimEnd() + "`r`n" + $err.TrimEnd()).Trim()
  return [pscustomobject]@{ ExitCode = $Handle.Proc.ExitCode; Output = $text.TrimEnd(); Duration = (([datetime]::Now) - $Handle.Started).TotalSeconds; TimedOut = (-not $finished) }
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
  param(
    [string]$Tool, [string[]]$ArgList, [string]$Label,
    [ScriptBlock]$OnDone = $null, [int]$TimeoutSec = 180,
    # 调用方直接提供核心读取脚本(本函数自建后台脚本块, 供 Open-ShadowBrowser 等复用)
    [string]$Body = $null,
    # 非空时启用"连点合并": 同字符串的请求在排队/执行期间会被合并成一条
    [string]$CoalesceKey = $null
  )
  if (-not $OnDone) { $OnDone = { param($e) } }
  if ($Tool -eq 'vssadmin') { $exe = $script:VssAdmin }
  elseif ($Tool -eq 'schtasks') { $exe = $script:Schtasks }
  else { $exe = $script:Diskshadow }
  $argStr = (($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } }) -join ' ')
  # 命令日志条目立即登记(Running=true 显示为 …), 真正发起在队列轮到它时
  $entry = [pscustomobject]@{
    Time = Get-Date; Tool = $Tool; Args = $argStr; ExitCode = 0; Duration = 0
    Output = ''; Running = $true
  }
  $script:Log.Add($entry) | Out-Null
  Update-LogView
# 启动契约: Launch 只负责"发起 + 返回后台任务对象"; 结果回调**统一挂在 Job 的 OnDone 上**
# (早前挂在 Add-Task 上 → 两条通道都触发, 回调执行两次)。
# ⚠ 硬约束(踩坑): 必须在**闭包外**把要用的值取成普通局部变量再交给闭包捕获 ——
#   .GetNewClosure() 快照的是函数局部作用域, 闭包体内直读 $script:X 会解析为空/null。
#   曾因此让 $b 变成空串 → 后台跑空脚本 → 命令日志恒为"后台执行失败: -101"。
#   故先算好 $bodyScript / $bodyArgs, 闭包内只引用这两个局部变量。
  if ($Body) {
    $bodyScript = $Body
    $bodyArgs = @($ArgList)
  } elseif ($Tool -eq 'wmi') {
    $bodyScript = $script:WmiBody
    $bodyArgs = @($ArgList[0])
  } else {
    $bodyScript = $script:ToolBody
    $bodyArgs = @($exe, $argStr, $TimeoutSec)
  }
  $launch = {
    return (Add-Task -Name $Label -Body $bodyScript -ArgList $bodyArgs)
  }.GetNewClosure()
  Submit-Job -Name $Label -Kind 'write' -Launch $launch -CoalesceKey $CoalesceKey -OnDone {
    param($ok, $res, $err)
# 被合并时(ok=$false, res=$null): 本次请求没有独立结果, 但它那条日志条目必须收尾,
# 否则永远停在 Running=$true(日志里那行一直是 …)。
    if (-not $ok -and -not $res -and ("" + $err) -like '已合并*') {
      $entry.Running = $false
      $entry.ExitCode = 0
      $entry.Output = [string]$err
      try { Update-LogView } catch {}
      return
    }
    # $res 是后台脚本的返回值: 本函数约定为 [pscustomobject]@{ ExitCode; Output; Duration }
    if (-not $ok -or -not $res) {
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
      Write-Diag 'taskerr' ('[cmd ui ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString())
    }
  }.GetNewClosure()
}

function Parse-Writers {
  param([string]$Raw)
  # 常量定义在函数体内: 本函数在后台 runspace 执行(见 Get-BgBody), 不继承主 runspace 的 $script: 变量
  $stateMap = @{ 1='稳定'; 2='等待冻结'; 3='等待解冻'; 4='解冻后待命'; 5='失败'; 6='冻结失败'; 7='释放失败'; 8='解冻失败' }
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
      $cur.StateText = if ($stateMap.ContainsKey($cur.State)) { $stateMap[$cur.State] } else { ('状态 {0}' -f $cur.State) }
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

# 主页卷卡片面板: 按卷分组排布(不显示组标题), 组与组之间强制换行并用横线分隔。
# 为什么不用 WrapPanel: 它按可用宽度自动折行, 无法"保证每组从新一列开始", 也插不了分隔线。
# 卡片外距**全组统一**(= 列间距 10px); 列宽 = 卡片宽 + 统一外距, 面板按 colIdx × 列宽放置。
# 折行宽度由 MeasureOverride 用容器可用宽度算(不依赖 ScrollViewer 实际宽度, 否则首帧退化成单列)。
if (-not ('CardPanel' -as [type])) {
  Add-Type -ReferencedAssemblies @('System.Xaml','PresentationFramework','PresentationCore','WindowsBase','System.Management.Automation') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

public class CardPanel : Panel
{
// 卡片宽度自适应: 列宽 = 视口宽 / TargetColumns(标准 3 列), 夹在 [MinItemWidth, MaxItemWidth]
    public static readonly DependencyProperty MinItemWidthProperty =
        DependencyProperty.Register("MinItemWidth", typeof(double), typeof(CardPanel),
            new FrameworkPropertyMetadata(190.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public double MinItemWidth
    {
        get { return (double)GetValue(MinItemWidthProperty); }
        set { SetValue(MinItemWidthProperty, value); }
    }

    public static readonly DependencyProperty MaxItemWidthProperty =
        DependencyProperty.Register("MaxItemWidth", typeof(double), typeof(CardPanel),
            new FrameworkPropertyMetadata(320.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public double MaxItemWidth
    {
        get { return (double)GetValue(MaxItemWidthProperty); }
        set { SetValue(MaxItemWidthProperty, value); }
    }

    public static readonly DependencyProperty TargetColumnsProperty =
        DependencyProperty.Register("TargetColumns", typeof(int), typeof(CardPanel),
            new FrameworkPropertyMetadata(3, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public int TargetColumns
    {
        get { return (int)GetValue(TargetColumnsProperty); }
        set { SetValue(TargetColumnsProperty, value); }
    }

    public static readonly DependencyProperty RowGapProperty =
        DependencyProperty.Register("RowGap", typeof(double), typeof(CardPanel),
            new FrameworkPropertyMetadata(13.0, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public double RowGap
    {
        get { return (double)GetValue(RowGapProperty); }
        set { SetValue(RowGapProperty, value); }
    }

// 取分组号。三层兜底, 顺序不能颠倒:
// 1) DataContext → PSObject.Properties(正路): Group 是 NoteProperty, 只在 PSObject 里, 反射取不到;
// 2) FrameworkElement.Tag(备用): ItemsControl 给每个条目套了 ContentPresenter, 而 Tag 写在
//    DataTemplate 内层的卡片 Border 上 —— 从 ContentPresenter 读 Tag 必然为空;
// 3) CLR 反射: 万一以后数据源换成普通 CLR 对象。
    private static int GroupNum(UIElement e)
    {
        var f = e as FrameworkElement;
        if (f == null) return 0;

        object dc = f.DataContext;
        if (dc != null)
        {
            var ps = dc as System.Management.Automation.PSObject;
            if (ps == null) ps = System.Management.Automation.PSObject.AsPSObject(dc);
            if (ps != null && ps.Properties != null && ps.Properties["Group"] != null)
            {
                object pv = ps.Properties["Group"].Value;
                if (pv != null) { try { return Convert.ToInt32(pv); } catch { } }
            }
        }

        object tag = f.Tag;
        if (tag != null) { try { return Convert.ToInt32(tag); } catch { } }

        if (dc != null)
        {
            try
            {
                var pi = dc.GetType().GetProperty("Group");
                if (pi != null)
                {
                    object v2 = pi.GetValue(dc, null);
                    if (v2 != null) return Convert.ToInt32(v2);
                }
            }
            catch { }
        }
        return 0;
    }

// 取"真正的卡片元素": ItemsControl 给每个数据项套了一层 ContentPresenter, 而卡片的
// Width/Margin/样式都在 DataTemplate 内层的 Border 上 —— 直接读容器只会拿到 NaN/0。
    private static FrameworkElement CardOf(UIElement e)
    {
        var f = e as FrameworkElement;
        if (f == null) return null;
// 容器自身若已带 Width 或非零外距, 说明面板直接装的就是卡片, 否则下钻一层(ContentPresenter → 卡片 Border)
        int n = VisualTreeHelper.GetChildrenCount(f);
        for (int i = 0; i < n; i++)
        {
            var inner = VisualTreeHelper.GetChild(f, i) as FrameworkElement;
            if (inner == null) continue;
            if (!double.IsNaN(inner.Width) || inner.Margin != default(Thickness)) return inner;
        }
        return f;
    }

// 统一算列宽与列数(Measure/Arrange 共用): 列宽 = 视口宽 / TargetColumns, 夹在
// [MinItemWidth, MaxItemWidth]; 列数 = 视口宽能放下的整列数(至少 1)。宽度 Infinity/NaN 时退回 2 列。
    private void CalcGrid(double availW, out double colW, out int cols)
    {
        double avail = availW;
        if (double.IsInfinity(avail) || double.IsNaN(avail) || avail <= 0)
        {
            colW = 246.0;
            cols = 2;
            return;
        }
        int target = TargetColumns > 0 ? TargetColumns : 3;
        colW = System.Math.Floor(avail / target);
        if (colW < MinItemWidth) colW = MinItemWidth;
        if (colW > MaxItemWidth) colW = MaxItemWidth;
        cols = (int)System.Math.Floor(avail / colW);
        if (cols < 1) cols = 1;
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var items = new List<UIElement>();
        foreach (UIElement c in InternalChildren) items.Add(c);
        // 空集合直接返回零尺寸(设计器/解析阶段会走到这里)
        if (items.Count == 0) return new Size(0, 0);

        double colW; int cols;
        CalcGrid(availableSize.Width, out colW, out cols);

        // 卡片自适应宽度: 测量约束 = 列宽(高不限), 卡片内容(TextTrimming/星号列)随之伸缩
        Size itemAvail = new Size(colW, double.PositiveInfinity);
// 组间分割线的留白用 RowGap, "组切换"和"行满"两处各自推进, 必须与 Arrange 成对。
        double y = 0, rowH = 0;
        int col = 0, prevG = 0;
        bool hasPrev = false;
// rowClosed: 上一行是否已被"行满"分支推进过(组内新行与上一行刚填满都是 col==0, 只能靠它区分)
        bool rowClosed = false;

        foreach (UIElement e in items)
        {
            int g = GroupNum(e);
// 组号变化即强制换行到新一列并留出组间空当; 只有"上一行未收尾"时才在这里补一格 RowGap。
            if (hasPrev && prevG != g)
            {
                if (!rowClosed) y += rowH + RowGap;
                rowH = 0; col = 0;
            }
            e.Measure(itemAvail);
            double h = e.DesiredSize.Height;
            if (h > rowH) rowH = h;
            rowClosed = false;
            col++;
            if (col >= cols)
            {
                y += rowH + RowGap;
                rowH = 0; col = 0; rowClosed = true;
            }
            prevG = g; hasPrev = true;
        }
// 末行未满/恰好填满两种情形都落回"最后一行行首 + 最后一行的占位高", 与 ArrangeOverride 同口径。
        if (col > 0) y += rowH;
        else if (y > 0) y -= RowGap;

// 宽度必须与 ArrangeOverride 将收到的 finalSize.Width 对齐: 宿主是 ScrollViewer(横向滚动条
// Disabled), 会被拉伸到视口宽 —— 若这里返回较小的 maxW, 就会"测量按 3 列算高、排布按 4 列摆"。
        double width = (double.IsInfinity(availableSize.Width) || double.IsNaN(availableSize.Width))
            ? colW * cols
            : availableSize.Width;
        if (y < 0) y = 0;
        return new Size(width, y);
    }

// 组间装饰横线: 用独立管理的 Rectangle 画, 不放进 InternalChildren(否则会被当成卡片排布)
    private readonly List<System.Windows.Shapes.Rectangle> _seps = new List<System.Windows.Shapes.Rectangle>();

// ★ 关键修复: 分割线此前"永远画不出来"的根因不是颜色太浅, 而是 **SeparatorBrush 一直是 null**
//   (Sync-CardPanelBrush 的调用全在数据绑定之前, 绑定后没人补设 → Fill=null → WPF 不绘制)。
//   三个配套改动: ① DP 默认值改为非 null(兜底墨色); ② 改用 ResolveSepBrush() 在每次 Arrange
//   时按需取主题色; ③ 保留显式赋值能力(显式值 > 资源 > 兜底)。
    private static readonly Brush FallbackSepBrush = MakeFrozen(0xD0, 0xD5, 0xDC);

    private static Brush MakeFrozen(byte r, byte g, byte b)
    {
        var br = new SolidColorBrush(Color.FromRgb(r, g, b));
        br.Freeze();
        return br;
    }

    public static readonly DependencyProperty SeparatorBrushProperty =
        DependencyProperty.Register("SeparatorBrush", typeof(Brush), typeof(CardPanel),
            new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public Brush SeparatorBrush
    {
        get { return (Brush)GetValue(SeparatorBrushProperty); }
        set { SetValue(SeparatorBrushProperty, value); }
    }

// 本次绘制实际用的线色: 显式赋值 > 窗口资源(C_SepLine, 跟随主题) > 兜底墨色。
    private Brush ResolveSepBrush()
    {
        var b = SeparatorBrush;
        if (b != null) return b;
        try
        {
            var host = Window.GetWindow(this);
            if (host != null)
            {
                b = host.TryFindResource("C_SepLine") as Brush;
                if (b == null) b = host.TryFindResource("C_Divider") as Brush;
            }
        }
        catch { }
        return b != null ? b : FallbackSepBrush;
    }

// 线高 2px: 1px 完全不可辨, 3px 在 100% 缩放下明显偏粗(用户反馈"太粗")。
    public static readonly DependencyProperty SeparatorThicknessProperty =
        DependencyProperty.Register("SeparatorThickness", typeof(double), typeof(CardPanel),
            new FrameworkPropertyMetadata(2.0, FrameworkPropertyMetadataOptions.AffectsArrange));

    public double SeparatorThickness
    {
        get { return (double)GetValue(SeparatorThicknessProperty); }
        set { SetValue(SeparatorThicknessProperty, value); }
    }

// 线两端的内缩量: 同时决定横线长度(宽 = finalSize.Width - SeparatorPad*2)。默认 4, 留一点呼吸感。
    public static readonly DependencyProperty SeparatorPadProperty =
        DependencyProperty.Register("SeparatorPad", typeof(double), typeof(CardPanel),
            new FrameworkPropertyMetadata(4.0, FrameworkPropertyMetadataOptions.AffectsArrange));

    public double SeparatorPad
    {
        get { return (double)GetValue(SeparatorPadProperty); }
        set { SetValue(SeparatorPadProperty, value); }
    }

    protected override int VisualChildrenCount
    {
        get { return base.VisualChildrenCount + _seps.Count; }
    }

    protected override Visual GetVisualChild(int index)
    {
        int b = base.VisualChildrenCount;
        if (index < b) return base.GetVisualChild(index);
        return _seps[index - b];
    }

    // 按需要的条数补齐/回收装饰线元素(只用于组间横线)。
    private void SyncSeparators(int need)
    {
        while (_seps.Count < need)
        {
            var r = new System.Windows.Shapes.Rectangle();
            r.IsHitTestVisible = false;
            // 圆角让两端显得柔和, 配合内缩更像装饰条
            r.RadiusX = 1; r.RadiusY = 1;
            _seps.Add(r);
            AddVisualChild(r);
        }
        while (_seps.Count > need)
        {
            var r = _seps[_seps.Count - 1];
            _seps.RemoveAt(_seps.Count - 1);
            RemoveVisualChild(r);
        }
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double colW; int cols;
        CalcGrid(finalSize.Width, out colW, out cols);
// DPI 缩放因子提为方法级: 卡片摆位与装饰线摆位都要用 —— 否则装饰线那段引用 sx/sy 会因
// 超出循环作用域而编译失败, 整个 CardPanel 类型编译不过, 分组会静默退化成 WrapPanel。
        DpiScale dpi = VisualTreeHelper.GetDpi(this);
        double sx = dpi.DpiScaleX > 0 ? dpi.DpiScaleX : 1.0;
        double sy = dpi.DpiScaleY > 0 ? dpi.DpiScaleY : 1.0;

// 按 (行, 列) 显式定位。rowY/colIdx 是"网格单元"坐标, 每遇组切换或列满就推进一行。
// rowH = 卡片的 DesiredSize.Height(含下外距), 行间距靠 RowGap 给。
// 组间留白只有一个来源: 组切换分支里的 rowY += rowH + RowGap(不要再叠加别的修正量)。
        double rowY = 0, rowH = 0;
        int colIdx = 0, prevG = 0;
        bool hasPrev = false;
// rowClosed: 上一行是否已被"行满"分支收尾推进过(不能用 colIdx==0 代替, 两者都是 0)
        bool rowClosed = false;
// 每处组切换产生一条横线: 记录 (线的上边缘 y, 左边的起点 x)
        var sepY = new List<double>();
        var sepX = new List<double>();
        foreach (UIElement e in InternalChildren)
        {
            int g = GroupNum(e);
// 组号变化即换行到新一列, 同时记下两条横线的位置
            if (hasPrev && prevG != g)
            {
// 组末行与组首行之间必须只有一个 RowGap 的空当, 分割线压在这个空当的中线。
// rowClosed==false → 这里补一次 rowH+RowGap; ==true → 行满分支已推进过, 不再加。
                if (!rowClosed)
                {
                    sepY.Add(rowY + rowH + RowGap / 2);
                    sepX.Add(0);
                    rowY += rowH + RowGap;
                }
                else
                {
                    sepY.Add(rowY - RowGap / 2);
                    sepX.Add(0);
                }
                // 组切换也意味着"上一行到此结束": 上一行没被行满分支收尾时, 这里把行高归零、
                // 列号归零 —— 下一组从新的一行开始(组间留白只由上面的 rowY += rowH + RowGap 提供)。
                rowH = 0; colIdx = 0;
            }
// 位置与外距取"卡片本体"(容器内层)的: 面板拿到的是 ContentPresenter, 内层 Border 自带右/下外距。
// 卡片自适应宽度后: 槽位宽 = 整列宽 colW, 内层 Border 在槽位内吃掉自己的外距。
            var fe = CardOf(e);
            Thickness m = fe != null ? fe.Margin : new Thickness(0);
            double w = colW - m.Left - m.Right;
            double slotW = colW;
            double h = e.DesiredSize.Height;
            if (double.IsNaN(slotW) || slotW <= 0) slotW = e.DesiredSize.Width;
            if (h < 0) h = 0;
            double cardLeft = colIdx * colW;

// ★★★ 关键修复: 把摆位对齐到**整设备像素**(否则"选中框右侧比其他几边细")。
//   窗口的 UseLayoutRounding 只作用于布局系统自己算出的槽位, 本面板是手工 Arrange, 不替我取整。
//   症状(125% 缩放): 容器左缘落在奇数物理像素上时右框只剩 1px(两轮改厚度/改 Round 都无效,
//   病根是**相位**不是厚度)。定稿修法: a) 位置 Floor; b) 尺寸 Ceiling; c) 槽位多留 1 设备像素。
            double snapL = Math.Floor(cardLeft * sx) / sx;
            double snapT = Math.Floor((rowY + m.Top) * sy) / sy;
            double snapW = (Math.Ceiling(slotW * sx) + 1.0) / sx;
            double snapH = (Math.Ceiling(h * sy) + 1.0) / sy;
            if (snapW < slotW) snapW = slotW + 1.0 / sx;
            if (snapH < h) snapH = h + 1.0 / sy;
            e.Arrange(new Rect(snapL, snapT, snapW, snapH));
            // 行占位高用"卡片总占位"(含上下外距) = 外层容器的 DesiredSize.Height
            if (e.DesiredSize.Height > rowH) rowH = e.DesiredSize.Height;
            rowClosed = false;   // 本行已经有卡片了, 尚未收尾
            colIdx++;
            if (colIdx >= cols)
            {
                // 行满: 推进到下一行并标记该行已收尾
                rowY += rowH + RowGap;
                rowH = 0; colIdx = 0; rowClosed = true;
            }
            prevG = g; hasPrev = true;
        }

        // 同步装饰线: 数量对齐后逐条摆位(只有组间横线)。
        SyncSeparators(sepY.Count);
        Brush sepBrush = ResolveSepBrush();
// ★ 横线长度 = 跟随内部视口宽度, 与卡片彻底解耦: finalSize 就是面板 Arrange 拿到的宽度
//   (= ScrollViewer 拉伸后的内部视口宽), 左右各留 SeparatorPad 内缩。
//   前三版都错在"跟错了参照物"(跟卡片右缘 → 短一截; 跟 colW*cols → 长度随列数跳; 固定 40px → 用户否决)。
        double lineW = finalSize.Width - SeparatorPad * 2.0;
        if (double.IsNaN(lineW) || double.IsInfinity(lineW) || lineW < 2) lineW = 2;
// 装饰线也必须对齐整设备像素, 否则 2.0 逻辑px(=2.5 物理px)同样出现取整伪影。
        double sepSnapW = Math.Round(lineW * sx) / sx;
        if (sepSnapW < 2) sepSnapW = lineW;
        double sepThickSnap = Math.Round(SeparatorThickness * sy) / sy;
        if (sepThickSnap < 1) sepThickSnap = SeparatorThickness;
        for (int k = 0; k < _seps.Count; k++)
        {
            var r = _seps[k];
            r.Fill = sepBrush;
// 横线: 左端自面板左缘内缩 SeparatorPad, 长度撑满内部视口; 线高压在组间空当中线。
            double left = sepX[k] + SeparatorPad;
            double top = sepY[k] - SeparatorThickness / 2.0;
            double sLeft = Math.Round(left * sx) / sx;
            double sTop = Math.Round(top * sy) / sy;
            r.Arrange(new Rect(sLeft, sTop, sepSnapW, sepThickSnap));
        }

// 返回"内容真实占用的尺寸": 行满分支在最后一行也推进了一次 RowGap, 而 MeasureOverride 末行不推进;
// 直接返回 finalSize 会让滚动条范围与实际内容差一个 RowGap(底部被裁一条)。
        double contentH;
        if (colIdx > 0) contentH = rowY + rowH;        // 末行未满: rowH 是该行占位高
        else contentH = rowY - RowGap;                 // 末行恰好填满: rowY 已含尾部 RowGap, 去掉
        if (contentH < 0) contentH = 0;
        return new Size(finalSize.Width, contentH);
    }
}
'@
}

function Get-RealCache {
  $qLog = New-Object System.Collections.Generic.List[object]
# 诊断日志(后台侧): 本函数在独立 runspace 里跑, 用不了主 runspace 的 Write-Diag, 先攒在 $diag 里由主 runspace 转写。
  $diag = New-Object System.Collections.Generic.List[string]
# 查询日志: 每条记录 工具/参数/退出码/耗时/输出, 同时把当前阶段写进共享通道供 UI 显示。
# 进度走内存共享通道($script:Shared 由 Epilogue 注入), 不写磁盘文件。
    $logQ = { param($tool, $argStr, $exit, $dur, $out)
      $qLog.Add([pscustomobject]@{ Time = Get-Date; Tool = $tool; Args = $argStr; ExitCode = $exit; Duration = $dur; Output = $out; Running = $false }) | Out-Null
    try { $script:Shared['prog'] = ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}|{1}|{2}', (Get-Date -Format 'HH:mm:ss'), $tool, $argStr)) } catch {}
  }
  $runWmi = { param($cls, $filter)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rows = if ($filter) { @(Get-CimInstance $cls -Filter $filter -ErrorAction SilentlyContinue) } else { @(Get-CimInstance $cls -ErrorAction SilentlyContinue) }
    $sw.Stop()
# 命令日志的"原始输出"逐条展开查询到的字段(只写"查询到 N 条"会让人以为查询没生效)。
# ⚠ 本函数在后台 runspace 执行, 所有表达式必须 [void] 抑制输出, 否则混进返回值。
    $dump = New-Object System.Text.StringBuilder
    [void]$dump.AppendLine(('查询到 {0} 条记录' -f $rows.Count))
    $ri = 0
    foreach ($r in $rows) {
      $ri++
      [void]$dump.AppendLine('')
      [void]$dump.AppendLine(('[#{0}] {1}' -f $ri, $cls))
      $props = if ($r.CimInstanceProperties) { $r.CimInstanceProperties } else { $r.PSObject.Properties }
      foreach ($p in $props) {
        $v = $p.Value
        $vs = if ($null -eq $v) { '(空)' }
              elseif ($v -is [datetime]) { $v.ToString('yyyy-MM-dd HH:mm:ss') }
              elseif ($v -is [System.Array]) { (@($v) | ForEach-Object { [string]$_ }) -join ', ' }
              else { ([string]$v) }
        [void]$dump.AppendLine(('  {0,-30}: {1}' -f $p.Name, $vs))
      }
    }
    & $logQ 'WMI' $cls 0 $sw.Elapsed.TotalSeconds $dump.ToString()
    return $rows
  }
# 慢命令先异步启动(与后续查询重叠): vssadmin list writers ~3s 是刷新耗时大头, 重叠后整轮 4.2s→~3s。
  $scExe = Join-Path $env:SystemRoot 'System32\sc.exe'
  $wHandle = Start-ProcAsync -Exe $script:VssAdmin -ArgStr 'list writers'
  $qHandle = Start-ProcAsync -Exe $scExe -ArgStr 'query VSS'
  $qcHandle = Start-ProcAsync -Exe $scExe -ArgStr 'qc VSS'
  $vols = @(& $runWmi 'Win32_Volume')
  $volMap = @{}
# 全量卷列表: 固定磁盘(DriveType=3) + 移动磁盘/U 盘(2) 且有文件系统的卷(与"磁盘管理"一致),
# 这样无盘符/仅挂载到文件夹的卷也能被发现。⚠ Win32_Volume 没有 VolumeName 属性: 卷标是 Label, 挂载路径是 Name。
  $volumeList = New-Object System.Collections.Generic.List[object]
  foreach ($v in $vols) {
    if (($v.DriveType -ne 3 -and $v.DriveType -ne 2) -or -not $v.FileSystem) { continue }
    # DeviceID(卷 GUID 路径)是稳定唯一键;盘符便于反查;卷标(Label)可能为空或重复,仅作辅助键
    if ($v.DeviceID) { $volMap[$v.DeviceID.TrimEnd('\')] = $v }
    if ($v.Label) { $volMap[$v.Label] = $v }
    if ($v.DriveLetter) { $volMap[[string]$v.DriveLetter.TrimEnd('\')] = $v }
    $volumeList.Add($v) | Out-Null
  }
# 解析"规范键": 有盘符返回盘符(如 C:), 无盘符返回 DeviceID(\\?\Volume{...})
  $resolveKey = {
    param($vol)
    # 字符串: 盘符形式(C: / C:\)直接返回, 不依赖卷表(卷表里没有 "C:" 这种键)
    if ($vol -is [string]) {
      $s = ([string]$vol).TrimEnd('\')
      if ($s -match '^[A-Za-z]:$') { return $s }
      if ($volMap.ContainsKey($s)) {
        $vv = $volMap[$s]
        if ($vv.DriveLetter) { return ([string]$vv.DriveLetter).TrimEnd('\') }
        return $s
      }
      return $null
    }
// 依次尝试卷标识字段(DeviceID / VolumeName / Volume)。任一命中且该卷有盘符 → 返回盘符;
// 命中但无盘符 → 记下卷 GUID 继续尝试其余字段(提前 return 会把有盘符的卷误判成无盘符卷)。
    $fallback = $null
    foreach ($k in @($vol.DeviceID, $vol.VolumeName, $vol.Volume)) {
      if (-not $k) { continue }
      $kk = ([string]$k).TrimEnd('\')
      if ($volMap.ContainsKey($kk)) {
        $vv = $volMap[$kk]
        if ($vv.DriveLetter) { return ([string]$vv.DriveLetter).TrimEnd('\') }
        if (-not $fallback) { $fallback = $kk }
      }
    }
    return $fallback
  }
# 卷显示名映射: 已挂载显示挂载位置, 未挂载显示卷 GUID(卡片与列表统一用它)
  $displayByKey = @{}
  $tipByKey = @{}
  $guidByKey = @{}
  foreach ($v in $volumeList) {
    $key = & $resolveKey $v
    if (-not $key) { continue }
    $devId = [string]$v.DeviceID
    $volName = [string]$v.Name
    # Win32_Volume.Name 已挂载时为盘符或挂载文件夹路径(C:\ / D:\xxx),未挂载时等于 DeviceID
    $mount = $null
    if ($volName -and $devId -and ($volName.TrimEnd('\') -ne $devId.TrimEnd('\'))) { $mount = $volName.TrimEnd('\') }
    # 未挂载回退卷 GUID;完整 GUID 过长,卡片/列表显示前 8 位十六进制,完整值放 ToolTip
    $gm = [regex]::Match($devId, '\{[0-9a-fA-F\-]+\}')
    if ($gm.Success) {
      $g = $gm.Value.Trim('{', '}')
      $guidShort = '{' + $g.Substring(0, [Math]::Min(8, $g.Length)) + '…}'
    } else {
      $guidShort = $devId
    }
    $displayByKey[$key] = if ($mount) { $mount } else { $guidShort }
    $tipByKey[$key] = if ($mount) { $mount } else { $devId }
    $guidByKey[$key] = $devId
  }
  # 统一分组口径: 卡片与配额页都调用它决定 Group(1 固定盘 / 2 移动盘·路径映射 / 3 仅GUID), 保证两页同一套分组逻辑, 不另起一套
  $getVolumeGroup = {
    param($vv, $kkey, $gmap)
    $devId = if ($gmap -and $gmap.ContainsKey($kkey)) { $gmap[$kkey] } else { $kkey }
    $volName = [string]$vv.Name
    $hasLetter = [bool]($vv.DriveLetter)
    $mountPath = $false
    if ($volName) {
      $nn = $volName.TrimEnd('\')
      $mountPath = ($nn -and $devId -and ($nn -ne $devId.TrimEnd('\')) -and ($nn -notmatch '^[A-Za-z]:$'))
    }
    $grp = 3
    if ($vv.DriveType -eq 3 -and $hasLetter) { $grp = 1 }
    elseif (($vv.DriveType -eq 2 -and $hasLetter) -or ($vv.DriveType -eq 3 -and $mountPath)) { $grp = 2 }
    return [pscustomobject]@{ Group = $grp; MountPath = $mountPath }
  }
  $dl = {
    param([string]$k)
    if (-not $k) { return '' }
    $kk = $k.TrimEnd('\')
    if ($displayByKey.ContainsKey($kk)) { return $displayByKey[$kk] }
    return $kk
  }
  $shadows = @(& $runWmi 'Win32_ShadowCopy')
  $storages = @(& $runWmi 'Win32_ShadowStorage')
  $providers = @(& $runWmi 'Win32_ShadowProvider')

  $shadowRows = New-Object System.Collections.Generic.List[object]
  foreach ($s in $shadows) {
    $letter = & $resolveKey $s
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
      Letter = $letter.TrimEnd('\')
      LetterDisplay = (& $dl $letter)
      Id = $s.ID.ToUpper()
      Device = $s.DeviceObject
      TypeText = ($flags -join ' · ')
      CanAct = $script:CanAct
    }) | Out-Null
  }

  $storageRows = New-Object System.Collections.Generic.List[object]
  $storageByKey = @{}
  foreach ($st in $storages) {
    $key = & $resolveKey $st.Volume
    if (-not $key) { continue }
    $key = $key.TrimEnd('\')
    if (-not $storageByKey.ContainsKey($key)) { $storageByKey[$key] = $st }
  }
  # 所有固定卷都生成配额行(有存储关联的填实际值,无的显示"未设置"),保证配额页不遗漏无盘符卷
  foreach ($v in $volumeList) {
    $key = & $resolveKey $v
    if (-not $key) { continue }
    $key = $key.TrimEnd('\')
    # 复用主页分组逻辑(与卡片同一套口径): 1 固定盘 / 2 移动盘·路径映射 / 3 仅GUID
    $grp = (& $getVolumeGroup $v $key $guidByKey).Group
    $st = $storageByKey[$key]
    # 行底色依据: 该卷文件系统能否自存差异区 + 是否已有存储关联 + 是否创建过卷影
    $fsT = if ($v.FileSystem) { [string]$v.FileSystem } else { '-' }
    $vssOkR = (@('NTFS', 'ReFS') -contains $fsT)
    $shadowCnt = @($shadowRows | Where-Object { $_.Letter -eq $key }).Count
    $rowState = if (-not $vssOkR -and -not $st) { 'nosetup' } elseif ($shadowCnt -eq 0) { 'noshadow' } else { 'none' }
    $row = [pscustomobject]@{
      Letter = $key
      Group = $grp
      LetterDisplay = (& $dl $key)
      LabelText = if ($v.Label) { [string]$v.Label } else { '—' }
      FsText = $fsT
      UsedText = '—'
      AllocText = '—'
      MaxText = '未设置'
      Pct = 0
      PctText = '—'
      # 尚无存储关联: 位置显示占位符, 不再显示卷自身(文件系统不能自存时那样显示是误导)
      DiffLetter = $key
      DiffDisplay = '—'
      MaxBytes = [uint64]0
      HasStorage = $false
      RowState = $rowState
      CanAct = $script:CanAct
      # 客户端非 NTFS/ReFS 卷无法设置配额(同卡片口径): 按钮置灰, 点击弹错误提示
      QuotaGrayed = (-not (Test-IsServerEdition)) -and (-not $vssOkR)
      QuotaTip = if ((-not (Test-IsServerEdition)) -and (-not $vssOkR)) { 'Windows 客户端不支持设置差分位置，无法调整' } else { '调整该卷的卷影存储配额(上限)' }
    }
    if ($st) {
      $diffKey = & $resolveKey $st.DiffVolume
      if (-not $diffKey) { $diffKey = $key }
      $maxUnbounded = ($st.MaxSpace -eq [uint64]::MaxValue)
      # 配额进度:有上限 = 卷影占用/配额;UNBOUNDED = 卷影占用/(该卷空闲空间+卷影占用)
      if ($maxUnbounded) {
        $freeSpace = if ($null -ne $v.FreeSpace -and [uint64]$v.FreeSpace -ge 0) { [uint64]$v.FreeSpace } else { 0 }
        $pct = if (($st.UsedSpace + $freeSpace) -gt 0) { [double]$st.UsedSpace / ($st.UsedSpace + $freeSpace) * 100 } else { 0 }
      } else {
        $pct = if ($st.MaxSpace -gt 0) { [double]$st.UsedSpace / $st.MaxSpace * 100 } else { 0 }
      }
      $row.UsedText = Format-Size $st.UsedSpace
      $row.AllocText = Format-Size $st.AllocatedSpace
      $row.MaxText = if ($maxUnbounded) { 'UNBOUNDED' } else { Format-Size $st.MaxSpace }
      $row.Pct = $pct
      $row.PctText = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}%', $pct)
      $row.DiffLetter = $diffKey.TrimEnd('\')
      $row.DiffDisplay = (& $dl $diffKey)
      $row.MaxBytes = $st.MaxSpace
      $row.HasStorage = $true
      # 进度条两列: 未设配额的行**不提供**这两个属性(XAML 绑定留空 → 两列自动宽度 → 不画条)
      $row | Add-Member -NotePropertyName BarUsed -NotePropertyValue ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', $pct)) -Force
      $row | Add-Member -NotePropertyName BarFree -NotePropertyValue ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', ([Math]::Max(100 - $pct, 0)))) -Force
    }
    $storageRows.Add($row) | Out-Null
  }
  # 配额页与主页卡片复用同一分组口径: 按 Group, Letter 排序, 使分组顺序与主页一致
  $storageRows = [System.Collections.Generic.List[object]]@($storageRows | Sort-Object -Property Group, Letter)

$providerRows = New-Object System.Collections.Generic.List[object]
  foreach ($p in $providers) {
    $typeText = switch ($p.Type) { 1 { '系统' } 2 { '软件' } 3 { '硬件' } default { '未知' } }
    $typeBrush = switch ($p.Type) { 1 { $script:Brush_Accent } 2 { $script:Brush_Success } 3 { $script:Brush_Warn } default { $script:Brush_Faint } }
    $providerRows.Add([pscustomobject]@{
      Name = $p.Name; TypeText = $typeText; TypeBrush = $typeBrush
      Version = $p.Version; Id = $p.ID.ToUpper(); Clsid = $p.CLSID.ToUpper()
    }) | Out-Null
  }

# 支持创建卷影的文件系统: 依据微软文档(VSS FAQ "可以创建非 NTFS 卷的卷影副本", 但差异区域须在
# NTFS 上; VShadow 文档: "卷影复制需要 NTFS 或 ReFS"), 故只支持 NTFS / ReFS。-contains 大小写不敏感。
  $fsOkList = @('NTFS', 'ReFS')
  $cards = New-Object System.Collections.Generic.List[object]
  foreach ($v in $volumeList) {
    $key = & $resolveKey $v
    if (-not $key) { continue }
    $key = $key.TrimEnd('\')
    $sc = @($shadowRows | Where-Object { $_.Letter -eq $key })
    $newest = $null
    foreach ($s in $sc) {
      $t = [datetime]::MinValue
      if ([datetime]::TryParseExact($s.CreatedText, 'yyyy/MM/dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { $newest = $t }
    }
    $stRow = $storageRows | Where-Object { $_.Letter -eq $key } | Select-Object -First 1
    # 是否已有存储关联(差异区设在别的卷): 卷影存储行对每个固定卷都有, HasStorage 即代表有关联
    $hasAssoc = [bool]($stRow -and $stRow.HasStorage)
    $pctUsed = if ($v.Capacity -gt 0) { ($v.Capacity - $v.FreeSpace) / $v.Capacity * 100 } else { 0 }
    $label = if ($v.Label) { [string]$v.Label } else { '本地磁盘' }
    $fsText = if ($v.FileSystem) { [string]$v.FileSystem } else { '-' }
    # 文件系统是否支持卷影(NTFS/ReFS 支持)
    $vssOk = ($fsOkList -contains $fsText)
    # 服务器/客户端判定(已缓存于 $script:IsServer): 客户端无法跨盘存差异区, 决定"创建卷影"与"设置配额"可用性
    $isServer = Test-IsServerEdition
    # 配额在本机(客户端)对"非 NTFS/ReFS"卷彻底不可用: 这类卷只能靠跨盘存差异区解锁, 而客户端 VSS 不支持 → 按钮置灰且点击报错
    $quotaGrayed = (-not $isServer) -and (-not $vssOk)
    # 创建卷影在本机(客户端)对"非 NTFS/ReFS 且无外部存储关联"的卷不可用: 同样因无法跨盘存差异区
    $createGrayed = (-not $isServer) -and (-not $vssOk) -and (-not $hasAssoc)
    # CreateReady = 可以直接创建卷影: 本卷能自存差异区, 或已把存储位置设到其他卷(解锁非 NTFS/ReFS 卷)
    $createReady = ($vssOk -or $hasAssoc)
    # 显示名统一取共享映射:已挂载=挂载位置(盘符/挂载文件夹),未挂载=卷 GUID
    $display = if ($displayByKey.ContainsKey($key)) { $displayByKey[$key] } else { $key }
    $tip = if ($tipByKey.ContainsKey($key)) { $tipByKey[$key] } else { $key }
# 路径映射(挂载到文件夹): 无盘符且 Name 是文件夹路径(不含盘符形式)而非卷 GUID 路径。
# 分组口径(卡片与配额页共用): 1=有盘符的固定盘 2=有盘符的移动盘+路径映射 3=只有 GUID 的卷。
    $grpInfo = & $getVolumeGroup $v $key $guidByKey
    $grp = $grpInfo.Group
    $mountPath = $grpInfo.MountPath
    $cards.Add([pscustomobject]@{
      Letter = $key
      DisplayLetter = $display
      TipText = $tip
      MountPath = $mountPath
      Group = $grp
      Label = $label
      FsText = $fsText
      VssSupported = $vssOk
      # 文件系统不支持卷影的提示: 服务器可改存储位置解锁(可用), 客户端(无法跨盘)则彻底不可用
      FsTip = if (-not $script:CanAct) { '需要管理员权限:请点击左上角"以管理员身份重新启动"' }
              elseif (-not $vssOk) {
                if ($isServer) {
                  if ($hasAssoc) { ('文件系统 {0} 不能在本卷保存卷影,差异数据当前保存在 {1}' -f $fsText, [string]$stRow.DiffDisplay) }
                  else { ('文件系统 {0} 不能在本卷保存卷影,点击后在配额窗口设置存储位置(差异区)即可创建卷影' -f $fsText) }
                } else {
                  '本卷文件系统不支持内部存放卷影差分，请设置存储位置'
                }
              }
              else { $null }
      # CanCreate = 按钮可点(管理员即可); CreateReady = 点击直接创建(true)还是先弹配额设置位置(false)
      CanCreate = $script:CanAct
      CreateReady = $createReady
      # 客户端非 NTFS/ReFS 卷: 配额与(无关联时的)创建均不可用 → 按钮置灰, 点击弹错误提示而非进入死路
      QuotaGrayed = $quotaGrayed
      CreateGrayed = $createGrayed
      QuotaTip = if ($quotaGrayed) { 'Windows 客户端不支持设置差分位置，无法调整' }
                 elseif (-not $vssOk -and $hasAssoc) { ('该卷文件系统为 {0},差异数据当前保存在 {1};可调整存储配额上限' -f $fsText, [string]$stRow.DiffDisplay) }
                 elseif (-not $vssOk) { '该卷文件系统不能在本卷保存卷影;服务器上可在配额窗口设置存储位置(差异区)到其他卷来解锁,再调整上限' }
                 else { '调整该卷的卷影存储配额(上限)' }
      HasAssoc = $hasAssoc
      SpaceText = ('可用 {0} / 共 {1}' -f (Format-Size $v.FreeSpace), (Format-Size $v.Capacity))
      FreeBytes = $v.FreeSpace
      PctUsed = [double]$pctUsed
      BarUsed = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', $pctUsed)
      BarFree = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}*', ([Math]::Max(100 - $pctUsed, 0)))
      ShadowCountText = ('{0} 个卷影' -f $sc.Count)
      NewestText = if ($newest) { ('最新 {0}' -f $newest.ToString('MM/dd HH:mm')) } else { '无卷影副本' }
      Active = $false
      CanAct = $script:CanAct
    }) | Out-Null
  }
# 主页卡片按组排序(1 固定盘 → 2 移动盘/路径映射 → 3 仅 GUID), 组内按卷键排序(盘符 < 路径 < GUID)。
  $orderedCards = New-Object System.Collections.Generic.List[object]
  foreach ($c in @($cards | Sort-Object -Property Group, Letter)) { $orderedCards.Add($c) | Out-Null }

# 计划任务读取放在收割慢命令之前, 与 vssadmin list writers(~3s)完全重叠执行。
  $schedTasks = New-Object System.Collections.Generic.List[object]
  try {
    $stList = Get-SchedTasks -Logger $logQ
    if ($null -ne $stList) { $schedTasks = $stList }
  } catch {
    try { $diag.Add(('[sched read ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message)) | Out-Null } catch {}
  }

  # 收割开头异步启动的慢命令(此刻多半已跑完, WaitForExit 秒回; Duration 为启动→收割墙钟)
  $writersRaw = ''
  $wRes = Wait-ProcResult $wHandle 120
  if ($wRes) { & $logQ 'vssadmin' 'list writers' $wRes.ExitCode $wRes.Duration $wRes.Output; $writersRaw = $wRes.Output }
  $writers = Parse-Writers $writersRaw
  $vssState = 'unknown'
  $vssStart = ''
  $qRes = Wait-ProcResult $qHandle 15
  if ($qRes) {
    & $logQ 'sc' 'query VSS' $qRes.ExitCode $qRes.Duration $qRes.Output
    $m = [regex]::Match($qRes.Output, 'STATE\s*:\s*(\d+)\s*(\w+)')
    if ($m.Success) { $vssState = $m.Groups[2].Value }
  }
  $qcRes = Wait-ProcResult $qcHandle 15
  if ($qcRes) {
    & $logQ 'sc' 'qc VSS' $qcRes.ExitCode $qcRes.Duration $qcRes.Output
    $m2 = [regex]::Match($qcRes.Output, 'START_TYPE\s*:\s*(\d+)\s*(\w+)')
    if ($m2.Success) {
      $code = [int]$m2.Groups[1].Value
      $vssStart = if ($code -eq 4) { 'Disabled' } elseif ($code -eq 2) { 'Auto' } else { 'Manual' }
    }
  }

  return @{
    Cards = $orderedCards; Shadows = $shadowRows; Storage = $storageRows
    Providers = $providerRows; Writers = $writers
    SchedTasks = $schedTasks
    VssRunning = ($vssState -eq 'RUNNING'); VssState = $vssState; VssStart = $vssStart
    Queries = $qLog
    Diag = $diag
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
# ★ 数据绑定完成后必须补一次线色同步: 面板实例是 ItemsPresenter 在**首次有数据**时才装起来的,
# 此前的调用都在绑定之前, 绑定后不补设 → SeparatorBrush 永远停在 null, 分割线一条也画不出来。
  try { Sync-CardPanelBrush } catch {}
  # 布局生效后再补一次: 上面这次可能仍在同一次布局周期内, 资源查找/面板实例以最终状态为准
  try { $cardHost.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{ try { Sync-CardPanelBrush } catch {} }) | Out-Null } catch {}
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
  if ($script:FilterLetter) { (Get-N 'txtFilter').Text = ('选中{0}：取消' -f $(if ($script:FilterDisplay) { $script:FilterDisplay } else { $script:FilterLetter })) }
  $enabled = [bool]$script:FilterLetter
# 置灰由 Sync-ActionButtons 统一负责(同时看"是否选中卷"与"队列是否忙碌"), 这里不再单独赋值。
  Sync-ActionButtons
  try { Apply-SavedSort } catch {}
}

# 统一决定写操作按钮的可用性: 操作条件(选中卷/管理员) + 队列是否忙碌(防误触, 排队本身是支持的)。
function Sync-ActionButtons {
  try {
    $busy = [bool]($script:JobCurrent -or ($script:JobQueue -and $script:JobQueue.Count -gt 0))
    $sel = [bool]$script:FilterLetter
    $b1 = Get-N 'btnShadowCreate'
    if ($b1) { $b1.IsEnabled = $sel -and $script:CanAct -and -not $busy }
    $b2 = Get-N 'btnShadowOldest'
    if ($b2) { $b2.IsEnabled = $sel -and $script:CanAct -and -not $busy }
    $b3 = Get-N 'btnShadowAll'
    if ($b3) { $b3.IsEnabled = $sel -and $script:CanAct -and -not $busy }
    $b4 = Get-N 'btnStorageResize'
    if ($b4) {
      $row = (Get-N 'lstStorage').SelectedItem
      $b4.IsEnabled = [bool]$row -and $script:CanAct -and -not $busy -and -not ($row -and $row.QuotaGrayed)
    }
  } catch {}
}

function Update-OtherViews {
  $cache = $script:Cache
  if (-not $cache) { return }
  (Get-N 'lstStorage').ItemsSource = $cache.Storage
# 存储配额页复用主页分组口径(GroupDescription 按 Group 分组), 表头排序只作用于组内。
  try {
    $sv = [System.Windows.Data.CollectionViewSource]::GetDefaultView((Get-N 'lstStorage').ItemsSource)
    if ($sv -and $sv.CanGroup) {
      $hasG = $false
      if ($sv.GroupDescriptions.Count -gt 0) {
        for ($gi = 0; $gi -lt $sv.GroupDescriptions.Count; $gi++) {
          $gd = $sv.GroupDescriptions[$gi]
          if ($gd -is [System.Windows.Data.PropertyGroupDescription] -and $gd.PropertyName -eq 'Group') { $hasG = $true; break }
        }
      }
      if (-not $hasG) { $sv.GroupDescriptions.Add([System.Windows.Data.PropertyGroupDescription]::new('Group')) }
    }
  } catch {}
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

# ===== 任务队列核心: 串行执行 + 合并 + 失败恢复 + 关窗续跑 =====
# 串行的理由: 连点"创建卷影"会并发发起多个 WMI Create → 后到者撞上 VSS "另一个卷影操作正在进行"
#   (返回码 9 → 日志 ExitCode -209), 结果错乱。同一时刻只允许一个任务执行中, 按入队顺序推进。
# 重复点击: 写操作按"卷+动作"合并(CoalesceKey), 重复执行无意义且必撞 VSS;
#   状态刷新是幂等读取, 已排队就跳过新请求(避免连点刷出一长串冗余读取)。
# 失败恢复: 无论抛异常/启动失败/回调报错, 都在 Complete-Job 里统一收尾并释放 $script:JobCurrent。
# 关窗续跑: add_Closing 只置标志并阻塞 UI, 不取消任务; 事件循环继续泵, 队列排空才放行关闭。
function Start-JobPump {
  if (-not $script:JobPump) {
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(120)
    $t.add_Tick({ Pump-Jobs })
    $t.Start()
    $script:JobPump = $t
  }
}

# 入队。返回 JobId; 被合并时返回 -1
function Submit-Job {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Kind,          # write | refresh
    [Parameter(Mandatory = $true)][ScriptBlock]$Launch,   # 轮到自己时调用, 返回 $null 或后台任务对象
    [ScriptBlock]$OnDone = $null,
    [string]$CoalesceKey = $null,
    [switch]$Quiet
  )
  # ---- 去重: 同一 CoalesceKey 的后一次请求吸收进已排队/执行中的那一条 ----
  if ($CoalesceKey) {
    $dup = $null
    if ($script:JobCurrent -and $script:JobCurrent.CoalesceKey -eq $CoalesceKey) { $dup = $script:JobCurrent }
    if (-not $dup) {
      foreach ($t in $script:JobQueue) { if ($t.CoalesceKey -eq $CoalesceKey) { $dup = $t; break } }
    }
    if ($dup) {
# 合并语义(踩坑): **不能**把新请求的 OnDone 覆盖到被合并的那条上 —— 每个 OnDone 都闭包持有
# 自己那条日志 $entry, 覆盖后被顶掉的那条永远停在 Running=$true。正确做法: 保留原 OnDone 不动。
      $script:JobLog.Add([pscustomobject]@{
        Time = Get-Date; Name = $Name; State = '已合并'; StateText = '已合并'
        Info = ('已并入「' + $dup.Name + '」, 未重复执行')
      }) | Out-Null
      Trim-JobLog
      Update-JobView
      Update-StatusIndicator
      # 通知被合并方: 用 $null 表示"没有独立结果", 调用方据此收起自己的 pending 状态
      if ($OnDone) { try { & $OnDone $false $null '已合并到正在执行中的同类任务' } catch {} }
      return -1
    }
  }
  # ---- 刷新幂等: 已有刷新在排队/执行中就不再入队 ----
  if ($Kind -eq 'refresh') {
    if ($script:JobCurrent -and $script:JobCurrent.Kind -eq 'refresh') { return -1 }
    foreach ($t in $script:JobQueue) { if ($t.Kind -eq 'refresh') { return -1 } }
  }
  $script:JobSeq++
  $job = [pscustomobject]@{
    JobId = $script:JobSeq; Name = $Name; Kind = $Kind
    Launch = $Launch; OnDone = $OnDone; CoalesceKey = $CoalesceKey
    Quiet = [bool]$Quiet; IsRefresh = ($Kind -eq 'refresh')
    BgTask = $null; StartTime = $null; State = '等待中'
  }
  $script:JobQueue.Add($job)
  Start-JobPump
  Update-JobView
  Update-StatusIndicator
  return $job.JobId
}

# 串行推进: ① 收敛已完成的后台任务 ② 队列空且无在跑 → 发起下一个 ③ 空则停泵
# 完成判断只看后台层打的 t.Collected 标记, **不读** Async 状态 —— Job 发起后任务可能还没被
# 丢进 runspace(Async 仍是 null), 直接读 Async.IsCompleted 会无限等待。
$script:JobTickCount = 0
function Pump-Jobs {
  try {
    # ① 当前任务对应的后台任务已被后台层回收 → 收敛
    $cur = $script:JobCurrent
    if ($cur -and $cur.BgTask -and $cur.BgTask.Collected) {
      $ok = [bool]$cur.BgTask.Ok
      $res = $cur.BgTask.Result
      $err = [string]$cur.BgTask.ErrorText
      Complete-Job $cur $ok $res $err
      $cur = $null
    }
# ①' 兜底: 后台任务迟迟没被回收(如 BgPump 意外停摆), 催一次后台层, 避免队列卡死在"执行中"
    elseif ($cur -and $cur.BgTask -and -not $cur.BgTask.Collected) {
      try { if (-not $script:BgPump -and $script:TaskQueue.Count -eq 0 -and $script:TaskRunning.Count -gt 0) { Start-TaskPump } } catch {}
    }
    # ② 没有在跑的任务 → 从队首取一个发起(写操作因此天然串行)
    if (-not $script:JobCurrent -and $script:JobQueue.Count -gt 0) {
      $job = $script:JobQueue[0]
      $script:JobQueue.RemoveAt(0)
      $script:JobCurrent = $job
      $job.State = '执行中'
      $job.StartTime = Get-Date
      try {
        $job.BgTask = & $job.Launch
        if (-not $job.BgTask) { throw '任务未返回后台句柄' }
      } catch {
        # 启动即失败: 立刻归位并继续推进, 不能把队列留在这条任务上
        $job.BgTask = $null
        Complete-Job $job $false $null $_.Exception.Message
      }
    }
    # ③ 彻底空闲 → 停泵(避免 120ms 空转), 并放行正在等待关闭的窗口
    if (-not $script:JobCurrent -and $script:JobQueue.Count -eq 0) {
      if ($script:JobPump) { try { $script:JobPump.Stop() } catch {}; $script:JobPump = $null }
      if ($script:JobClosing) {
        # 队列已排空: 复位标志再关闭, 否则 Closing 会被自己的守卫再次拦下(窗口永远关不掉)
        try { $script:JobClosing = $false; $script:MainDispatcher.BeginInvoke([action]{ try { $window.Close() } catch {} }) | Out-Null } catch {}
      }
    } else {
      # 有任务在跑/排队: 每 5 tick(≈600ms)刷新一次队列面板, 让"执行中"的耗时持续走动
      $script:JobTickCount++
      if (($script:JobTickCount % 5) -eq 1) { try { Update-JobView } catch {} }
    }
    Update-StatusIndicator
  } catch {
    Write-Diag 'joberr' ('[pump ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString())
  }
}

# 统一收尾: 释放执行权(无论成败) → 回调 → 记状态 → 立刻推进下一个
function Complete-Job {
  # 参数名不用 $Error: 那会遮蔽 PowerShell 的自动变量 $Error(错误集合), 是个经典陷阱
  param($Job, [bool]$Ok, $Result, [string]$ErrText)
  $script:JobCurrent = $null
  $Job.State = if ($Ok) { '完成' } else { '失败' }
  $jobOk = $Ok; $jobRes = $Result; $jobErr = $ErrText
  if ($Job.OnDone) {
    try { & $Job.OnDone $jobOk $jobRes $jobErr } catch {
      $jobOk = $false; $jobErr = $_.Exception.Message
      Write-Diag 'joberr' ('[job ui ' + $Job.Name + '] ' + $_.Exception.Message)
    }
  }
  $el = 0.0
  try { if ($Job.StartTime) { $el = ((Get-Date) - $Job.StartTime).TotalSeconds } } catch {}
  $script:JobLog.Add([pscustomobject]@{
    Time = Get-Date; Name = $Job.Name
    State = $Job.State; StateText = $Job.State
    Info = if ($jobOk) { ('耗时 ' + [string]::Format($script:InvCulture, '{0:0.0}s', $el)) } else { ('失败: ' + $jobErr) }
  }) | Out-Null
  Trim-JobLog
  try { Update-JobView } catch {}
  # 失败不中断队列: 这里只做收尾记录, 下一个任务由 Pump-Jobs 的下一轮 tick 自然接上
  if (-not $jobOk) {
    try { Show-Toast -Message ('任务失败: ' + $Job.Name) -Type 'err' } catch {}
  }
  # 收尾时可能又有新任务入队(如 OnDone 里触发刷新), 下一轮 tick 会接上; 顺带立刻催一次
  try { Start-JobPump } catch {}
}

function Trim-JobLog {
  while ($script:JobLog.Count -gt 50) { $script:JobLog.RemoveAt(0) }
}

function Update-JobView {
  try {
    $list = Get-N 'lstJobs'
    if (-not $list) { return }
    # 置灰写操作触发按钮: 队列里有任务在跑/排队时先禁用, 防止误触产生重复请求
    Sync-ActionButtons
    $items = New-Object System.Collections.Generic.List[object]
    if ($script:JobCurrent) {
      $c = $script:JobCurrent
      $el = if ($c.StartTime) { [string]::Format($script:InvCulture, '{0:0.0}s', ((Get-Date) - $c.StartTime).TotalSeconds) } else { '' }
      $items.Add([pscustomobject]@{ Order = 0; TimeText = $c.StartTime.ToString('HH:mm:ss'); Name = $c.Name; StateText = '执行中'; Detail = ('已运行 ' + $el); StateBrush = $window.Resources['C_Accent'] }) | Out-Null
    }
    $i = 0
    foreach ($t in $script:JobQueue) {
      $i++
      # 排队中的任务还没开始, StartTime 为 null —— 直接 ToString 会抛异常并中断整个面板刷新
      $qTime = if ($t.StartTime) { $t.StartTime.ToString('HH:mm:ss') } else { '' }
      $items.Add([pscustomobject]@{ Order = $i; TimeText = $qTime; Name = $t.Name; StateText = '等待中'; Detail = ('排队第 ' + $i + ' 位'); StateBrush = $window.Resources['C_Warn'] }) | Out-Null
    }
    foreach ($h in $script:JobLog) {
      if ($h.State -eq '完成') { $b = $window.Resources['C_Success'] }
      elseif ($h.State -eq '已合并') { $b = $window.Resources['C_Faint'] }
      else { $b = $window.Resources['C_Danger'] }
      $items.Add([pscustomobject]@{ Order = 900; TimeText = $h.Time.ToString('HH:mm:ss'); Name = $h.Name; StateText = $h.StateText; Detail = $h.Info; StateBrush = $b }) | Out-Null
    }
    $list.ItemsSource = $items
    # 汇总行: 一眼看出"当前在跑什么 / 还排着几个"(状态反馈的最小信息量)
    $sum = Get-N 'txtJobSummary'
    if ($sum) {
      $running = if ($script:JobCurrent) { $script:JobCurrent.Name } else { '空闲' }
      $q = $script:JobQueue.Count
      $sum.Text = ('执行中: {0}{1}' -f $running, $(if ($q -gt 0) { ('   ·   等待中 ' + $q + ' 个') } else { '' }))
    }
    try { Reset-ListHScroll $list } catch {}
  } catch {}
}

# 后台 body 构建: 缓存函数 AST(只解析一次主脚本, 3 个 body 复用), 避免每次启动重复 ParseFile。
# 拼装"后台执行体": 指定函数的源码文本 + 收尾脚本(Epilogue), 在独立 runspace 中执行。
# ⚠ 硬约束: 该 runspace 与主 runspace 零共享 —— $script: 变量/函数/UI 对象一律不可见。
#   只能使用: 函数内局部变量 / 函数体内定义的常量 / 经 $args 显式传入的值。
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

# 后台执行层: 只负责把脚本丢进独立 runspace, 并**自己回收已完成的槽位**。
# 槽位回收不能外移(踩坑): 早前把"结束判断"搬到 Pump-Jobs, 结果 TaskRunning 只增不减 →
# 下一个任务永远排不进去(队列面板"执行中"卡死不动, 后台泵仍在空转)。
$script:TaskQueue = New-Object System.Collections.Generic.List[object]
$script:TaskRunning = @{}
$script:TaskSeq = 0
$script:TaskMaxRun = 1
$script:PendingRefresh = $false

# 入队一个后台任务, 返回任务对象(供 Submit-Job 的 Launch 交给队列跟踪完成状态)
function Add-Task {
  param([string]$Name, [string]$Body, [ScriptBlock]$OnDone, [object[]]$ArgList = @(), [switch]$IsRefresh, [switch]$Quiet)
  $script:TaskSeq++
  $task = [pscustomobject]@{
    Seq = $script:TaskSeq; Name = $Name; Body = $Body; ArgList = $ArgList
    OnDone = $OnDone; IsRefresh = [bool]$IsRefresh; Quiet = [bool]$Quiet
    PS = $null; Async = $null; StartTime = $null; Collected = $false
  }
  $script:TaskQueue.Add($task)
  Start-TaskPump
  return $task
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

# 回收后台层里已跑完的槽位。返回刚被回收的任务列表, 供 Pump-Jobs 判断"我等的那个回来了没有"。
function Collect-FinishedTasks {
  $done = New-Object System.Collections.Generic.List[object]
  if ($script:TaskRunning.Count -eq 0) { return ,$done }
  $keys = @($script:TaskRunning.Keys)
  foreach ($k in $keys) {
    $t = $script:TaskRunning[$k]
    if (-not $t) { continue }
    # 已发起 且 已完成 → 回收(未发起的 Async 为 null, 绝不能在这里判完成)
    if ($t.Async -and $t.Async.IsCompleted) {
      $ok = $true; $res = $null; $err = ''
      try {
        $out = $t.PS.EndInvoke($t.Async)
        if ($out -and $out.Count -gt 0) { $res = $out[$out.Count - 1] }
      } catch {
        $ok = $false; $err = $_.Exception.Message
        Write-Diag 'taskerr' ('[collect ' + (Get-Date -Format 'HH:mm:ss.fff') + ' task=' + $t.Name + '] ' + $_.Exception.ToString())
      } finally {
        try { $t.PS.Dispose() } catch {}
      }
      $t.Collected = $true
      $script:TaskRunning.Remove($k) | Out-Null
      # 结果挂回任务对象, 让持有该任务引用的 Job 直接读取(不再依赖回调管道)
      $t | Add-Member -NotePropertyName Ok -NotePropertyValue $ok -Force
      $t | Add-Member -NotePropertyName Result -NotePropertyValue $res -Force
      $t | Add-Member -NotePropertyName ErrorText -NotePropertyValue $err -Force
      $done.Add($t) | Out-Null
# ⚠ 不在这里回调 $t.OnDone: 回调统一由 Complete-Job 负责 —— 两层都触发会导致回调执行两次。
    }
  }
  return ,$done
}

function Pump-Tasks {
  # ① 先回收已完成槽位(必须在发起之前, 否则 Count 拦住新任务)
  $null = Collect-FinishedTasks
  # ② 再按并发上限发起新任务
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
      # 启动失败: 立即标记为已回收并回调, 不能让这个槽位空占着
      try { if ($task.OnDone) { & $task.OnDone $false $null $_.Exception.Message } } catch {}
      Write-Diag 'taskerr' ('[task start ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.ToString())
    }
  }
  # ③ 空则停泵(避免 100ms 空转)
  if ($script:TaskRunning.Count -eq 0 -and $script:TaskQueue.Count -eq 0) {
    if ($script:BgPump) { try { $script:BgPump.Stop() } catch {}; $script:BgPump = $null }
  }
}

function Refresh-All {
  # 更新主题画刷(刷新任务后台使用; 每次调用幂等刷新)
  try {
    $script:Brush_Accent = $window.Resources['C_Accent']
    $script:Brush_Success = $window.Resources['C_Success']
    $script:Brush_Warn = $window.Resources['C_Warn']
    $script:Brush_Danger = $window.Resources['C_Danger']
    $script:Brush_Faint = $window.Resources['C_Faint']
    $script:Brush_Sub = $window.Resources['C_Sub']
  } catch {}
# 刷新也走队列(幂等, 已排队则跳过)。⚠ Submit-Job 返回的已是 int(JobId), 再取 .JobId 得 $null
#   → PendingRefresh 恒 true → OnDone 每轮补刷一次, 形成"打开后不停刷新"的死循环。
  $added = Submit-Job -Name '正在读取系统状态' -Kind 'refresh' -Launch $script:RefreshLaunch -OnDone {
    param($ok, $res, $err)
    if ($ok -and $res) {
      $script:Cache = $res
      # 后台 runspace 攒下的诊断行: 转写到主 runspace 的统一通道(内存缓冲 / 按开关落盘)
      try { if ($res.Diag) { foreach ($d in $res.Diag) { Write-Diag 'taskerr' ([string]$d) } } } catch {}
      # 各视图更新独立 try: 单个视图失败不影响其他视图与下次刷新
      try {
        if ($res.Queries) {
          foreach ($qq in $res.Queries) { $script:Log.Add($qq) | Out-Null }
          Update-LogView
        }
      } catch {
        Write-Diag 'taskerr' ('[view log ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | '))
      }
      try { Update-ShadowsView } catch {
        Write-Diag 'taskerr' ('[view shadows ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | '))
      }
      try { Update-OtherViews } catch {
        Write-Diag 'taskerr' ('[view other ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | '))
      }
      # 卷列表与计划任务已随本次刷新一并读回: 统一渲染计划任务页(目标卷下拉复用本次卡片, 任务列表复用本次 SchedTasks)
      try { Update-SchedView } catch {
        Write-Diag 'taskerr' ('[sched view ' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' :: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | '))
      }
      # 数据绑定后, 把各列表横向滚动条重置到最左(横向滚动条应默认显示第一列, 而非停在末尾)
      try { foreach ($ln in $script:AllListNames) { Reset-ListHScroll ($window.FindName($ln)) } } catch {}
    } else {
      $script:Cache = $null
      try {
        (Get-N 'dotVss').Background = $window.Resources['C_Danger']
        (Get-N 'txtVss').Text = 'VSS 服务: 读取失败'
        (Get-N 'txtLastRefresh').Text = ('上次刷新 失败: ' + $err)
      } catch {}
      Show-Toast -Message ('读取系统状态失败: ' + $err) -Type 'err'
    }
    # 若刷新期间有新请求被跳过合并, 补刷一次保证视图最新(如写操作恰在刷新读完后完成)
    if ($script:PendingRefresh) {
      $script:PendingRefresh = $false
      try { Refresh-All } catch {}
    }
  }
  if ($added -gt 0) {
# 事件驱动进度: 清空进度通道, 后台每完成一个查询阶段更新一次(内存共享通道, 不落盘)
    try { $script:Shared['prog'] = '' } catch {}
    $script:ProgLine = ''
  } else {
    # 已有刷新在运行/排队 → 标记待补刷(当前刷新完成后再刷一次)
    $script:PendingRefresh = $true
  }
}

# 刷新的发起脚本: 与使用方(Refresh-All)分开, 避免 Refresh-All 先于 Submit-Job 定义
$script:RefreshLaunch = {
  Add-Task -Name '正在读取系统状态' -Body $script:BgBody -ArgList @(
    $script:CanAct, $script:VssAdmin, $script:Brush_Accent,
    $script:Brush_Success, $script:Brush_Warn, $script:Brush_Danger, $script:Brush_Faint, $script:Brush_Sub,
    $script:Shared
  )
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
  try { Reset-ListHScroll $list } catch {}
}

# 递归查找节点内部的 ScrollViewer(ListView 内部的 ScrollViewer 不在直接可视树里, 需递归)
function Get-InnerScrollViewer {
  param($node)
  if (-not $node) { return $null }
  if ($node -is [System.Windows.Controls.ScrollViewer]) { return $node }
  try {
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
    for ($i = 0; $i -lt $n; $i++) {
      $ch = [System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)
      $r = Get-InnerScrollViewer $ch
      if ($r) { return $r }
    }
  } catch {}
  return $null
}

# 把列表横向滚动条重置到最左侧(横向滚动条应默认显示第一列, 而非停在末尾)
function Reset-ListHScroll {
  param($listView)
  try {
    if (-not $listView) { return }
    $sv = Get-InnerScrollViewer $listView
    if ($sv -and $sv.ScrollableWidth -gt 0) { $sv.ScrollToHorizontalOffset(0) }
  } catch {}
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

# 填充配额对话框的「存储位置」下拉: 候选 = NTFS/ReFS 卷 + 卷自身(始终保留, 否则非 NTFS/ReFS
# 卷的"尚未设置外部存储"状态无法表达)。项是纯字符串, 真实卷键在 $script:ResizeDiffKeys 按下标对应。
function Fill-ResizeDiff {
  param([string]$ForNorm, [string]$DiffKey)
  $cbo = Get-N 'cboResizeDiff'
  $script:ResizeDiffKeys = @()
  $items = New-Object System.Collections.Generic.List[string]
  $vssFlags = New-Object System.Collections.Generic.List[bool]
  $selfIdx = -1
  $selfVssOk = $false
  $cards = @()
  if ($script:Cache -and $script:Cache.Cards) { $cards = [object[]]$script:Cache.Cards }
  foreach ($c in $cards) {
    if (-not $c) { continue }
    $key = [string]$c.Letter
    $isSelf = ($key -eq $ForNorm)
    if (-not $c.VssSupported -and -not $isSelf) { continue }
    $sizeText = Format-Size $c.FreeBytes
    if ($isSelf -and -not $c.VssSupported) {
      [void]$items.Add(('{0}  ·  可用 {1} (本卷不能存放差异区)' -f [string]$c.DisplayLetter, $sizeText))
    } else {
      [void]$items.Add(('{0}  ·  可用 {1}' -f [string]$c.DisplayLetter, $sizeText))
    }
    $script:ResizeDiffKeys += $key
    [void]$vssFlags.Add([bool]$c.VssSupported)
    if ($isSelf) { $selfIdx = $script:ResizeDiffKeys.Count - 1; $selfVssOk = [bool]$c.VssSupported }
  }
  # 兜底: 候选为空(极端场景) → 至少给出卷自身, 保证对话框可用
  if ($script:ResizeDiffKeys.Count -eq 0) { [void]$items.Add($ForNorm); $script:ResizeDiffKeys = @($ForNorm); [void]$vssFlags.Add($false); $selfIdx = 0 }
  $cbo.Items.Clear()
  foreach ($s in $items) { [void]$cbo.Items.Add($s) }
  $curIdx = -1
  for ($i = 0; $i -lt $script:ResizeDiffKeys.Count; $i++) { if ($script:ResizeDiffKeys[$i] -eq $DiffKey) { $curIdx = $i; break } }
  if ($curIdx -lt 0) {
    if ($selfIdx -ge 0 -and $selfVssOk) { $curIdx = $selfIdx }
    else {
      # 自身不能存差异区 → 默认选第一个 NTFS/ReFS 候选, 引导把差异区设到别的卷
      $curIdx = 0
      for ($i = 0; $i -lt $vssFlags.Count; $i++) { if ($vssFlags[$i]) { $curIdx = $i; break } }
    }
  }
  $cbo.SelectedIndex = $curIdx
  return $curIdx
}

function Show-ResizeDialog {
  param([string]$Letter, [string]$CurText, [uint64]$CurBytes, [string]$DiffKey, [string]$ForKey)
  (Get-N 'txtResizeTitle').Text = ('调整存储配额 · {0}' -f $Letter)
  (Get-N 'txtResizeCur').Text = '当前: ' + $CurText
  $isUnbounded = ($CurBytes -eq [uint64]::MaxValue -or $CurBytes -eq 0)
  (Get-N 'rbResizeAuto').IsChecked = $isUnbounded
  (Get-N 'rbResizeCustom').IsChecked = -not $isUnbounded
  (Get-N 'txtResizeGB').Text = if ($isUnbounded) { '' } else { [string]::Format($script:InvCulture, '{0:0}', ($CurBytes / 1GB)) }
# 存储位置(差异区)下拉填充, 选中逻辑见 Fill-ResizeDiff
  $selfKey = if ($ForKey) { $ForKey.TrimEnd('\') } else { $Letter.TrimEnd('\') }
  $null = Fill-ResizeDiff -ForNorm $selfKey -DiffKey $DiffKey
  # 客户端 VSS 不支持跨盘存储: 锁定差异区到本卷, 仅保留设置上限能力(避免误选其他卷后报 0x80070032)
  $cboDiff = Get-N 'cboResizeDiff'
  $hintDiff = Get-N 'txtResizeHint'
  if (-not (Test-IsServerEdition)) {
    $selfIdx = -1
    for ($i = 0; $i -lt $script:ResizeDiffKeys.Count; $i++) { if ($script:ResizeDiffKeys[$i] -eq $selfKey) { $selfIdx = $i; break } }
    if ($selfIdx -ge 0) { $cboDiff.SelectedIndex = $selfIdx }
    $cboDiff.IsEnabled = $false
    $cboDiff.ToolTip = '客户端 Windows 不支持将卷影存储位置改到其他卷(差异区须与原卷同盘,失败码 0x80070032);本工具仅可调整本卷上限。'
    $hintDiff.Text = '上限只约束新写入的差异数据,已有卷影不受影响。客户端 Windows 仅支持调整本卷上限,无法将存储位置改到其他卷(差异区须与原卷同盘,失败码 0x80070032)。'
    # 客户端不支持跨盘存储 → "存储位置"整行置灰, 提示该选项不可用
    $lblDiff = Get-N 'lblResizeDiff'
    if ($lblDiff) { $lblDiff.Foreground = [System.Windows.Media.Brushes]::Gray }
  } else {
    $cboDiff.IsEnabled = $true
    $hintDiff.Text = '上限只约束新写入的差异数据,已有卷影不受影响。存储位置可选 NTFS/ReFS 卷;本卷文件系统不能存放差异区时,请选择其他卷,设置后即可为该卷创建卷影。更换位置会创建新的存储关联,旧关联会询问是否清理(若其中仍有卷影,则保留待其删除)。'
    # 服务器支持跨盘存储 → 恢复正常文字颜色(重新绑定主题资源, 兼容明暗主题)
    $lblDiff = Get-N 'lblResizeDiff'
    if ($lblDiff) { $lblDiff.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'C_Sub') }
  }
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

function Get-VolumeDisplayName {
  param([string]$Letter)
  if (-not $Letter) { return '' }
  $k = $Letter.TrimEnd('\')
  $c = @($script:Cache.Cards | Where-Object { $_.Letter -eq $k } | Select-Object -First 1)
  if ($c -and $c.DisplayLetter) { return [string]$c.DisplayLetter }
  return $k
}

function Invoke-CreateShadow {
  param([string]$Letter)
  if (-not $script:CanAct -or -not $Letter) { return }
  $capCard = @($script:Cache.Cards | Where-Object { $_.Letter -eq $Letter } | Select-Object -First 1)
  # 不能在本卷存差异区且尚未设置外部存储位置 → 不弹确认, 直接带去配额窗口设置存储位置
  if ($capCard -and -not $capCard.CreateReady) { Invoke-ResizeFor $Letter; return }
  $letter = $Letter.TrimEnd('\')
  $disp = Get-VolumeDisplayName $Letter
  $volPath = $letter + '\'
  $msg = '写时复制会在数秒内创建一份当前时点的卷影,期间卷的读写不受影响。'
  if ($capCard -and -not $capCard.VssSupported) {
    # 卷影差异数据不在本卷, 确认时明示实际保存位置
    $srow = @($script:Cache.Storage | Where-Object { $_.Letter -eq $Letter } | Select-Object -First 1)
    if ($srow) { $msg = $msg + "`n" + ('差异卷为 {0} 文件系统,卷影差异数据将保存到存储位置 {1}。' -f $capCard.FsText, [string]$srow.DiffDisplay) }
  }
  if (Show-Confirm -Title ('创建卷影 · ' + $disp) -Message $msg -Cmd ('Win32_ShadowCopy.Create(Volume="' + $volPath + '", Context="ClientAccessible")')) {
    # CoalesceKey 按"卷+动作": 同一卷连点只跑一次; 不同卷的请求照常排队(都是有效请求)
    Invoke-SystemTool -Tool 'wmi' -ArgList @($letter) -Label ('正在创建卷影 · ' + $letter) -CoalesceKey ('create|' + $letter) -OnDone {
      param($e)
      if ($e.ExitCode -eq 0) {
        Show-Toast -Message ('已创建 {0} 卷影副本' -f $disp)
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
  $id = [string]$Shadow.Id
  $letter = [string]$Shadow.Letter
  $dev = [string]$Shadow.Device
  if (-not $id) { Show-Toast -Message '该卷影缺少浏览所需信息' -Type 'warn'; return }
# 打开卷影在后台任务执行(UI 零阻塞, 后台 runspace 可直接查 WMI): 卷影设备对象 → 目录符号链接 → explorer。
# ⚠ 只走符号链接: 经典 UNC 路径 \\localhost\X$\@GMT- 依赖 SMB/管理共享整条链路, Windows 更新后会被禁用;
#   符号链接对所有卷(有盘符/无盘符/仅挂载到文件夹)一律可用且不依赖网络栈。
  $body = @'
$id = $args[0]
$dev = $args[1]
$openEx = {
  param($path)
  try {
    $e = New-Object System.Diagnostics.ProcessStartInfo
    $e.FileName = 'explorer.exe'
    $e.Arguments = $path
    $e.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($e) | Out-Null
    return 'OK'
  } catch { return ('打开资源管理器失败: ' + $_.Exception.Message) }
}
try {
  if (-not $dev) {
    try {
      $sc0 = Get-CimInstance Win32_ShadowCopy -Filter ("ID='" + $id + "'") -ErrorAction SilentlyContinue
      if ($sc0 -and $sc0.DeviceObject) { $dev = [string]$sc0.DeviceObject }
    } catch {}
  }
  $linkErr = ''
  if ($dev) {
    $mnt = Join-Path $env:TEMP 'shadowconsole\mnt'
    $safe = ($id -replace '[^0-9A-Za-z\-]', '')
    if (-not $safe) { $safe = 'shadow' }
    $link = Join-Path $mnt $safe
    try { [System.IO.Directory]::CreateDirectory($mnt) | Out-Null } catch {}
    if ([System.IO.Directory]::Exists($link)) {
      try {
        $rp = New-Object System.Diagnostics.ProcessStartInfo
        $rp.FileName = (Join-Path $env:SystemRoot 'System32\cmd.exe')
        $rp.Arguments = '/c rmdir "' + $link + '"'
        $rp.UseShellExecute = $false
        $rp.CreateNoWindow = $true
        [System.Diagnostics.Process]::Start($rp).WaitForExit(5000) | Out-Null
      } catch {}
    }
    $target = ([string]$dev).TrimEnd('\') + '\'
    $outText = ''
    try {
      $mp = New-Object System.Diagnostics.ProcessStartInfo
      $mp.FileName = (Join-Path $env:SystemRoot 'System32\cmd.exe')
      $mp.Arguments = '/c mklink /D "' + $link + '" "' + $target + '"'
      $mp.UseShellExecute = $false
      $mp.CreateNoWindow = $true
      $mp.RedirectStandardOutput = $true
      $mp.RedirectStandardError = $true
      $pr = [System.Diagnostics.Process]::Start($mp)
      $outText = ($pr.StandardOutput.ReadToEnd() + ' ' + $pr.StandardError.ReadToEnd()).Trim()
      $pr.WaitForExit(10000) | Out-Null
      if ($pr.ExitCode -ne 0) { $linkErr = ('创建卷影访问链接失败(需要管理员权限): ' + $outText) }
    } catch { $linkErr = ('创建卷影访问链接失败: ' + $_.Exception.Message) }
    if (-not $linkErr) {
      # 链接建成功后还要确认目标设备可达(Directory.Exists 对"指向不可达目标的链接"返回 False)
      $linked = $false
      try { $linked = [System.IO.Directory]::Exists($link) } catch {}
      if (-not $linked) { $linkErr = ('卷影设备当前不可访问: ' + $target + $(if ($outText) { ' — ' + $outText } else { '' })) }
    }
    if (-not $linkErr) { return (& $openEx $link) }
  } else {
    $linkErr = '无法定位该卷影的设备对象'
  }
  if (-not $linkErr) { $linkErr = '未知原因,未能打开卷影' }
  return $linkErr
} catch { return ('打开卷影异常: ' + $_.Exception.Message) }
'@
# 打开卷影也走队列(静默): 与写操作共用一条串行链, 避免与正在进行的 VSS 操作抢占
  Invoke-SystemTool -Label ('正在打开卷影 · ' + $letter) -Tool 'custom' -ArgList @($id, $dev) -Body $body `
    -CoalesceKey ('browse|' + $id) -OnDone {
      param($e)
      if ($e.Output -and $e.Output -ne 'OK') { Show-Toast -Message $e.Output -Type 'warn' }
    }
}

# 删除卷影: 三种口径(指定 ID / 删最旧 / 全删)走同一套"确认 → 命令 → 提示"流程。Mode: id|oldest|all
function Invoke-DeleteShadow {
  param([string]$Id, [ValidateSet('id','oldest','all')][string]$Mode = 'id', [string]$Letter)
  if (-not $script:CanAct) { return }
  $forPath = $Letter.TrimEnd('\') + '\'
  $disp = if ($Letter) { Get-VolumeDisplayName $Letter } else { '' }
  switch ($Mode) {
    'id' {
      if (-not $Id) { return }
      $title = '删除卷影副本'
      $msg  = '将删除指定的卷影副本并释放对应差异存储空间。'
      $cmd  = 'vssadmin delete shadows /shadow=' + $Id + ' /quiet'
      $delArgs = @('delete', 'shadows', ('/shadow=' + $Id), '/quiet')
      $label = '正在删除卷影'
      $coalesce = 'delshadow|' + $Id
      $okMsg = '已删除卷影副本'
    }
    'oldest' {
      if (-not $Letter) { return }
      $title = '删除最旧卷影 · ' + $disp
      $msg  = '将删除该卷最早的卷影副本,用于释放差异存储空间。'
      $cmd  = 'vssadmin delete shadows /for=' + $forPath + ' /oldest /quiet'
      $delArgs = @('delete', 'shadows', ('/for=' + $forPath), '/oldest', '/quiet')
      $label = '正在删除最旧卷影 · ' + $forPath
      $coalesce = 'deloldest|' + $forPath
      $okMsg = '已删除最旧卷影'
    }
    'all' {
      if (-not $Letter) { return }
      $title = '全部删除 · ' + $disp
      $msg  = '将删除该卷的全部卷影副本并释放全部差异存储空间。此操作不可撤销!'
      $cmd  = 'vssadmin delete shadows /for=' + $forPath + ' /all /quiet'
      $delArgs = @('delete', 'shadows', ('/for=' + $forPath), '/all', '/quiet')
      $label = '正在删除全部卷影'
      $coalesce = 'delall|' + $forPath
      $okMsg = '已删除全部卷影'
    }
  }
  if (-not (Show-Confirm -Title $title -Message $msg -Cmd $cmd -Danger)) { return }
  Invoke-SystemTool -Tool 'vssadmin' -ArgList $delArgs -Label $label -CoalesceKey $coalesce -OnDone {
    param($e)
    if ($e.ExitCode -eq 0) {
      Show-Toast $okMsg
      Refresh-All
    } else {
      Show-Toast -Message ('删除失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
    }
  }.GetNewClosure()
}

# 探测当前 vssadmin 是否支持 add/delete shadowstorage(客户端 Windows 没有这两个子命令, 属服务器版专属)。
# 客户端只能靠 resize shadowstorage: 同卷关联不存在时自动创建并设上限, 跨盘不支持(0x80070032),
# 且无法 delete 旧关联(迁移已存在的存储位置需先在「系统保护」里移除旧关联)。
function Test-VssAddDeleteSupport {
  if ($null -ne $script:VssSupportsAddDelete) { return $script:VssSupportsAddDelete }
  $script:VssSupportsAddDelete = $false
  try {
    $probe = & vssadmin /? 2>&1
    if ($probe -join "`n" -match 'Add ShadowStorage') { $script:VssSupportsAddDelete = $true }
  } catch { }
  return $script:VssSupportsAddDelete
}

# 判断是否为服务器版 Windows(ProductType<>1 即服务器/域控): UI 层据此决定"跨盘存储位置"下拉是否可用。
function Test-IsServerEdition {
  if ($null -ne $script:IsServer) { return $script:IsServer }
  $script:IsServer = $false
  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($os -and $os.ProductType -ne 1) { $script:IsServer = $true }
  } catch {
    # 回退: 用 vssadmin 探测 add shadowstorage 是否存在(服务器才有)
    try {
      $probe = & vssadmin /? 2>&1
      if ($probe -join "`n" -match 'Add ShadowStorage') { $script:IsServer = $true }
    } catch { }
  }
  return $script:IsServer
}

function Invoke-ResizeFor {
  param([string]$Letter)
  if (-not $script:CanAct -or -not $Letter) { return }
# 配额(上限)在客户端与服务器均可设置(客户端 resize 对"同卷"关联有效); 仅"跨盘存储位置"在客户端
# 不可用(差异区须与原卷同盘, 0x80070032), 该动作在下方 else 分支拦截。
# 不再按文件系统拦截: 服务器上本卷不能存差异区的卷(如 FAT32)正是靠这里解锁卷影。
  $row = @($script:Cache.Storage | Where-Object { $_.Letter -eq $Letter } | Select-Object -First 1)
  if (-not $row) { Show-Toast -Message '该卷没有存储配额记录' -Type 'warn'; return }
  $hasStorage = [bool]$row.HasStorage
  $curText = if ($hasStorage) { ('已用 {0} / 上限 {1}' -f $row.UsedText, $row.MaxText) } else { '尚未设置存储配额' }
  $disp = Get-VolumeDisplayName $Letter
  # 当前差异区卷: 有关联取关联卷, 无关联兜底为卷自身(自存储)
  $curDiff = if ($row.DiffLetter -and $row.DiffLetter -ne '—') { $row.DiffLetter } else { $Letter.TrimEnd('\') }
  $result = Show-ResizeDialog -Letter $disp -CurText $curText -CurBytes $row.MaxBytes -DiffKey $curDiff -ForKey $Letter
  if (-not $result) { return }
  $newDiff = [string]$result.Diff
  if (-not $newDiff) { $newDiff = $Letter.TrimEnd('\') }
  $maxArg = if ($result.Mode -eq 'auto') { '/maxsize=UNBOUNDED' } else { [string]::Format($script:InvCulture, '/maxsize={0:0}GB', $result.GB) }
  # 把规范键(盘符或 \\?\Volume{...})转换为 VSS 可用的卷路径(带结尾反斜杠),无盘符卷同样适用
  $forPath = $Letter.TrimEnd('\') + '\'
  $disp = Get-VolumeDisplayName $Letter
  if ($newDiff -eq $curDiff) {
    # 位置未变: 有关联 → resize 现有关联; 无关联 → 优先 add(服务器版), 客户端无 add 则用 resize(自动创建)
    $diffPath = $curDiff.TrimEnd('\') + '\'
    if ($hasStorage) { $op = 'resize' }
    else { $op = if (Test-VssAddDeleteSupport) { 'add' } else { 'resize' } }
    $args1 = @($op, 'shadowstorage', ('/for=' + $forPath), ('/on=' + $diffPath), $maxArg)
    Invoke-SystemTool -Tool 'vssadmin' -ArgList $args1 -Label ('正在调整配额 · ' + $disp) -CoalesceKey ('quota|' + $forPath) -OnDone {
      param($e)
      if ($e.ExitCode -eq 0) {
        Show-Toast -Message ('已设置 {0} 存储配额' -f $disp)
        Refresh-All
      } else {
        Show-Toast -Message ('调整失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
      }
    }.GetNewClosure()
  } else {
    # 跨盘改存储位置: 客户端 VSS 不支持(无 add/delete shadowstorage, resize 跨盘报 0x80070032); 对话框在客户端已锁定差异区到本卷, 此处为防御性拦截
    if (-not (Test-VssAddDeleteSupport)) {
      Show-Toast -Message '客户端 VSS 不支持跨盘存储:无法将卷影存储位置改到其他卷(差异区须与原卷同盘,失败码 0x80070032)。请在服务器版执行,或保持本卷存储仅调整上限。' -Type 'warn'
      return
    }
    $newPath = $newDiff.TrimEnd('\') + '\'
    $newDisp = Get-VolumeDisplayName $newDiff
    $oldDisp = Get-VolumeDisplayName $curDiff
    $supportsAddDel = Test-VssAddDeleteSupport
    if ($supportsAddDel) {
      # 服务器版 vssadmin(支持 add/delete shadowstorage): 先 add 新关联(失败则中止,避免卷失去存储区),再按需 delete 旧关联
      $argsAdd = @('add', 'shadowstorage', ('/for=' + $forPath), ('/on=' + $newPath), $maxArg)
      Invoke-SystemTool -Tool 'vssadmin' -ArgList $argsAdd -Label ('正在设置存储位置 · ' + $disp) -CoalesceKey ('storageloc|' + $forPath) -OnDone {
        param($e)
        if ($e.ExitCode -ne 0) {
          Show-Toast -Message ('创建新存储关联失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
          return
        }
        # 首次设置(之前无任何关联): 没有旧关联可清理, 直接完成
        if (-not $hasStorage) {
          Show-Toast -Message ('存储位置已设置到 {0},现在可以为该卷创建卷影' -f $newDisp)
          Refresh-All
          return
        }
        $msg = ('存储位置已切换到 {0}。是否同时删除 {1} 上的旧存储关联?`n`n若旧存储区仍承载现有卷影副本,删除可能连同删除这些卷影;选择取消则保留旧关联,不影响新位置生效。' -f $newDisp, $oldDisp)
        if (Show-Confirm -Title ('清理旧存储关联 · ' + $disp) -Message $msg -Cmd ('vssadmin delete shadowstorage /for=' + $forPath + ' /on=' + ($curDiff.TrimEnd('\') + '\')) -Danger) {
          $argsDel = @('delete', 'shadowstorage', ('/for=' + $forPath), ('/on=' + ($curDiff.TrimEnd('\') + '\')))
          Invoke-SystemTool -Tool 'vssadmin' -ArgList $argsDel -Label ('正在清理旧存储关联 · ' + $oldDisp) -OnDone {
            param($e2)
            if ($e2.ExitCode -eq 0) {
              Show-Toast -Message ('存储位置已迁移到 {0},旧关联已清理' -f $newDisp)
            } else {
              Show-Toast -Message ('存储位置已迁移到 {0};旧关联删除失败(可能仍有卷影占用),已保留' -f $newDisp) -Type 'warn'
            }
            Refresh-All
          }.GetNewClosure()
        } else {
          Show-Toast -Message ('存储位置已迁移到 {0},旧关联已保留' -f $newDisp)
          Refresh-All
        }
      }.GetNewClosure()
    } else {
# 客户端 vssadmin(无 add/delete): 一律用 resize(关联不存在时自动创建)。源卷只能有 1 个存储关联,
# 已有旧关联时 resize 到新位置会报"已达最大关联数", 需先在「系统保护」关闭该卷以移除旧关联。
      $argsRes = @('resize', 'shadowstorage', ('/for=' + $forPath), ('/on=' + $newPath), $maxArg)
      Invoke-SystemTool -Tool 'vssadmin' -ArgList $argsRes -Label ('正在设置存储位置 · ' + $disp) -OnDone {
        param($e)
        if ($e.ExitCode -ne 0) {
          if ($hasStorage) {
            Show-Toast -Message '无法迁移存储位置:本系统 vssadmin 不支持删除现有存储关联。请先在「系统保护」中关闭该卷的系统保护(删除现有还原点)以移除旧关联,再重试。' -Type 'err'
          } else {
            Show-Toast -Message ('设置存储位置失败 (退出码 {0}),详见命令日志' -f $e.ExitCode) -Type 'err'
          }
          return
        }
        Show-Toast -Message ('存储位置已设置到 {0},现在可以为该卷创建卷影' -f $newDisp)
        Refresh-All
      }.GetNewClosure()
    }
  }
}



try {
  $window = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
} catch {
  $detail = $_.Exception.InnerException.Message
  throw "窗口 XAML 解析失败: $detail"
}
if (-not $window) { throw '窗口对象未能创建' }

# 主页卷卡片面板换成 CardPanel: XAML 里引用不到 Add-Type 动态编译的类型, 故在窗口创建后用代码替换 ItemsPanel。
try {
  $cardHost = Get-N 'cardHost'
  if ($cardHost) {
    $tpl = New-Object System.Windows.Controls.ItemsPanelTemplate
    $tpl.VisualTree = (New-Object System.Windows.FrameworkElementFactory([CardPanel]))
    $cardHost.ItemsPanel = $tpl
    # 分割线颜色由 Sync-CardPanelBrush 在视觉树里按类型找到面板实例后设置, 这里不保留模板引用
  }
} catch {
  # 面板替换失败时退回 XAML 里的 WrapPanel, 功能不受影响(只是没有分组换行与分割线)
}

# 卷影页上下的高度约束: 卡片区 : 卷影列表 = 2 : 1(列表占 1/3), 列表**永远**至少露出
# 一行有效数据(表头 + 一行 = 70px), 拖分割条也压不破。三条实测结论:
#  A) 一行带 MinHeight/MaxHeight 就**完全退出**星号分配 —— 卡片行上不许常驻任何 Min/Max;
#  B) 下限必须写 **RowDefinitions[3].MinHeight**(写在 ListView 上拦不住分割条, 行会被压到 0);
#  C) 设 MinHeight 不影响比例, 所以下限可以**常驻**, 不需要运行时切换。
$script:ListHeaderH = 32   # st_listHeader 的 Height
$script:ListRowH    = 36   # st_listItem 的 Height
$script:CardRowMaxH = 400  # 卡片区的设计上限(给 MaxHeight 会退出星号分配 → 余量归列表)

function Get-ListOneRowH {
# "一行有效数据" = 表头 + 一行 + ListView 上下边框 1px×2 + 2px 容差(实测 70 时刚好完整可见)
  $h = 0
  try {
    $lv = Get-N 'lstShadows'
    if ($lv) {
      $th = $script:ListHeaderH
      $tr = $script:ListRowH
      try {
        if ($lv.View -and $lv.View.ColumnHeaderContainerStyle) {
          $v = $lv.View.ColumnHeaderContainerStyle.Setters | Where-Object { $_.Property.Name -eq 'Height' } | Select-Object -First 1
          if ($v -and [double]$v.Value -gt 0) { $th = [double]$v.Value }
        }
      } catch {}
      try {
        $v2 = $lv.ItemContainerStyle.Setters | Where-Object { $_.Property.Name -eq 'Height' } | Select-Object -First 1
        if ($v2 -and [double]$v2.Value -gt 0) { $tr = [double]$v2.Value }
      } catch {}
      $h = $th + $tr
    }
  } catch {}
  if ($h -le 0) { $h = $script:ListHeaderH + $script:ListRowH }
  return $h + 4
}

function Update-ShadowPageRows {
  try {
    $ps = $window.FindName('pageShadows')
    if (-not $ps) { return }
    $rowCard = $ps.RowDefinitions[1]
    $rowList = $ps.RowDefinitions[3]

# 列表下限常驻: 无论窗口多大、分割条拖到哪都压不破"表头 + 一行"(必须放在手工布局的提前返回之前)
    $oneRow = Get-ListOneRowH
    if ([double]$rowList.MinHeight -ne $oneRow) { $rowList.MinHeight = $oneRow }
    if ($rowCard.MinHeight -ne 0) { $rowCard.MinHeight = 0 }

    # 拖过分割条之后不再自动改比例 —— 用户亲手调过的布局优先
    if ($script:ShadowRowManual) { return }

    # 卡片区封顶: 只在这里给卡片行加 MaxHeight。加了它就退出星号分配(见上 A)),
    # 余量于是全部落进列表行, 正是想要的效果。够不到上限时把 MaxHeight 清成无限, 恢复 2:1。
    $total = $ps.ActualHeight
    if ($total -le 0) { $total = $window.Height - 112 }
    if ($total -le 0) { return }
    $sc = $window.FindName('splitCard')
    $split = if ($sc -and $sc.ActualHeight -gt 0) { $sc.ActualHeight } else { 5 }
    $avail = $total - $split
    if ($avail -le 100) { return }

    if ($avail -gt $script:CardRowMaxH * 3) {
      if ($rowCard.MaxHeight -ne $script:CardRowMaxH) { $rowCard.MaxHeight = $script:CardRowMaxH }
    } elseif (-not [double]::IsInfinity($rowCard.MaxHeight)) {
      $rowCard.MaxHeight = [double]::PositiveInfinity
    }
  } catch {}
}

$script:NavNames = @('navShadows','navStorage','navDiskShadow','navLog','navSysInfo')
$script:PageNames = @('pageShadows','pageStorage','pageDiskShadow','pageLog','pageSysInfo')

for ($i = 0; $i -lt $script:NavNames.Count; $i++) {
  $btn = Get-N $script:NavNames[$i]
  $btn.Tag = $i
  $btn.add_Click([System.Windows.RoutedEventHandler]{ Set-Nav ([int]$this.Tag) })
}
# 首帧前把分割线颜色给上面板(此后 Set-Theme 会持续同步)
try { Sync-CardPanelBrush } catch {}

try {

Set-Nav 0
(Get-N 'btnRefresh').add_Click({ Refresh-All })
(Get-N 'btnDocs').add_Click({ Start-Process 'https://learn.microsoft.com/zh-cn/windows-server/storage/file-server/volume-shadow-copy-service' })
(Get-N 'btnRelaunch').add_Click({
  $hostExe = (Get-Process -Id $PID).Path
  $relArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  if ($script:DebugMode) { $relArgs += '/debug' }
  Start-Process -FilePath $hostExe -ArgumentList $relArgs -Verb RunAs | Out-Null
  $window.Close()
})
(Get-N 'btnTheme').add_Click({
# 两态循环(Light/Dark): System 先解析为系统实际主题, 否则系统为亮色时 System 与 Light 视觉重复, 要点两次
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
(Get-N 'btnShadowOldest').add_Click({ if ($script:FilterLetter) { Invoke-DeleteShadow -Mode oldest -Letter $script:FilterLetter } })
(Get-N 'btnShadowAll').add_Click({ if ($script:FilterLetter) { Invoke-DeleteShadow -Mode all -Letter $script:FilterLetter } })
(Get-N 'btnStorageResize').add_Click({
  $sel = (Get-N 'lstStorage').SelectedItem
  if ($sel -and $sel.QuotaGrayed) {
    Show-Toast -Message 'Windows 客户端不支持设置差分位置，无法调整' -Type 'err'
    return
  }
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
# 诊断日志(内存缓冲): 默认不落盘, 想看只能从这里看 —— 显示到右侧"原始输出"面板
(Get-N 'btnDiag').add_Click({
  $head = if ($script:LogDisk) { ('日志落盘: 开  →  ' + $script:LogDir + '\*.log') } else { '日志落盘: 关  (只在内存, 退出即消失)' }
  (Get-N 'txtLogDetail').Text = ($head + "`r`n" + (Get-DiagDump))
  Show-Toast '已载入内存中的诊断日志'
})
# 「日志落盘」开关: 默认关(日志只进内存); 打开 → 写 %TEMP%\shadowconsole\*.log; 关闭 → 立即清理一次
try { (Get-N 'chkLogDisk').IsChecked = [bool]$script:LogDisk } catch {}
(Get-N 'chkLogDisk').add_Checked({ Set-LogDisk $true })
(Get-N 'chkLogDisk').add_Unchecked({ Set-LogDisk $false })

$script:SchedPrefix = 'ShadowConsole-'
$script:SchedEditing = $null

# 用 Get-ScheduledTask 读取任务(结构化对象, 无 CSV 引号解析问题; schtasks 的 CSV 输出格式不规范)。
# 本函数在统一刷新的后台 runspace 执行, 通过 -Logger 回调把本次读取并进同一条命令日志通道。
function Get-SchedTasks {
  param([ScriptBlock]$Logger = $null)
  $list = New-Object System.Collections.Generic.List[object]
  $dump = New-Object System.Text.StringBuilder
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $exit = 0
  try {
    $ts = @(Get-ScheduledTask -TaskPath '\ShadowConsole\' -ErrorAction SilentlyContinue)
    [void]$dump.AppendLine(('查询到 {0} 个计划任务' -f $ts.Count))
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
        # 卷标识: 盘符(X:) 或 无盘符卷的 GUID 路径(\\?\Volume{...}) —— 与主界面卷列表的规范键一致
        if ($cmd -match '-L\s+"?(\\\\\?\\Volume\{[^"]+\}|[A-Za-z]:)"?') { $letter = $Matches[1] }
        elseif ($cmd -match 'L=(\\\\\?\\Volume\{[^"]+\}|[A-Za-z]:)') { $letter = $Matches[1] }
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
          StateBrush = if ($enabled) { $script:Brush_Success } else { $script:Brush_Faint }
          PlanText = $planText
          LastRunText = if ($lastRun) { $lastRun } else { '—' }
          NextRunText = if ($nextRun) { $nextRun } else { '—' }
          ResultText = $resInfo.Text
          ResultHint = $resInfo.Hint
          ResultBrush = $resInfo.Brush
        }) | Out-Null
        [void]$dump.AppendLine(('  [#{0}] {1}  原始参数: {2}' -f $list.Count, $taskName, $(if ($cmd) { $cmd } else { '(空)' })))
        [void]$dump.AppendLine(('         目标卷={0}  {1}  状态={2}  上次={3}  下次={4}  结果={5}' -f $(if ($letter) { $letter } else { '(未识别)' }), $planText, $(if ($enabled) { '已启用' } else { '已禁用' }), $(if ($lastRun) { $lastRun } else { '—' }), $(if ($nextRun) { $nextRun } else { '—' }), $resInfo.Text))
      } catch {
        $exit = 1
        [void]$dump.AppendLine(('  任务解析失败: ' + $_.Exception.Message))
      }
    }
  } catch {
    $exit = 1
    [void]$dump.AppendLine(('读取计划任务失败: ' + $_.Exception.Message))
  }
  $sw.Stop()
  if ($Logger) { try { & $Logger 'ScheduledTask' 'Get-ScheduledTask \ShadowConsole\' $exit $sw.Elapsed.TotalSeconds $dump.ToString() } catch {} }
  # 关键:强制返回数组,防 PowerShell 单元素自动展开成 PSCustomObject 导致 ItemsSource 绑定失败
  return ,$list
}

# 运行结果码翻译(在后台 runspace 执行, 画刷来自注入的 $script:Brush_*)
function Get-TaskResultInfo {
  param([string]$Code)
  $code = ($code -replace '\s','').ToLower()
  $brush = $script:Brush_Sub
  $text = $code; $hint = $code
  if (-not $code) { $text = '—'; $hint = '从未运行' }
  elseif ($code -eq '0x0') { $text = '0x0 成功'; $hint = '上次运行成功完成'; $brush = $script:Brush_Success }
  elseif ($code -eq '0x41303') { $text = '0x41303 未运行'; $hint = '任务尚未运行过'; $brush = $script:Brush_Faint }
  elseif ($code -eq '0x41301') { $text = '0x41301 已禁用'; $hint = '任务被禁用时未运行'; $brush = $script:Brush_Faint }
  elseif ($code -eq '0x41300') { $text = '0x41300 运行中'; $hint = '任务当前正在运行'; $brush = $script:Brush_Warn }
  elseif ($code -eq '0x1') { $text = '0x1 一般错误'; $hint = '发生未指定的错误'; $brush = $script:Brush_Danger }
  elseif ($code -eq '0x80070002') { $text = '0x80070002 找不到文件'; $hint = '命令或脚本路径不存在'; $brush = $script:Brush_Danger }
  elseif ($code -eq '0x800710e0') { $text = '0x800710E0 拒绝请求'; $hint = '操作被拒绝(可能因权限)'; $brush = $script:Brush_Danger }
  elseif ($code -eq '0x8004131f') { $text = '0x8004131F 未就绪'; $hint = '任务未准备好运行'; $brush = $script:Brush_Warn }
  elseif ($code -match '^0x') { $text = $code; $hint = '未知结果码,可查看任务计划程序事件日志'; $brush = $script:Brush_Warn }
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

# 生成计划触发器 XML。⚠ schema 子元素顺序: StartBoundary → Enabled → Repetition → ScheduleByX(Repetition 必须在 Schedule 之前)
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
# 每月最后一天用 <Day>Last</Day>(Day 取 1-31 或 "Last"; LastDayOfMonth 元素不合法)
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
function Set-WeekChips {  param([int[]]$Sel)
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

# 定时任务「目标卷」下拉: 复用主界面已读好的卷卡片($script:Cache.Cards), 不另外枚举。
# 只保留可创建卷影的卷(VssSupported), FAT32/exFAT/EFI 直接排除。
# 下拉项只放纯字符串, 真实卷键/显示名分别存 $script:SchedVolKeys / $script:SchedVolNames 按下标对应。
function Fill-SchedVolumes {
  $cbo = Get-N 'cboSchedLetter'
  if (-not $cbo) { return }
  # 记住当前选中卷的键,重建后尽量复原选中项
  $prevKey = $null
  if ($cbo.SelectedIndex -ge 0 -and $cbo.SelectedIndex -lt $script:SchedVolKeys.Count) { $prevKey = [string]$script:SchedVolKeys[$cbo.SelectedIndex] }
  $fsOkList = @('NTFS', 'ReFS')
  $keys = New-Object System.Collections.Generic.List[string]
  $names = New-Object System.Collections.Generic.List[string]
# ⚠ 不能写 @($script:Cache.Cards): PS 5.1 的 @() 包装 List[object](元素为 PSObject)会抛 "Argument types do not match"
  $cards = @()
  if ($script:Cache -and $script:Cache.Cards) { $cards = [object[]]$script:Cache.Cards }
  foreach ($c in $cards) {
    if (-not $c) { continue }
    # 可创建 = 本卷能自存差异区(NTFS/ReFS), 或已把存储位置设到其他卷(HasAssoc) —— 与主界面卡片的 CreateReady 同一语义
    if (-not $c.VssSupported -and -not $c.HasAssoc) { continue }
    $keys.Add([string]$c.Letter) | Out-Null
    $names.Add([string]$c.DisplayLetter) | Out-Null
  }
# 兜底: 缓存尚未就绪且下拉为空时才本地枚举一次; 缓存就绪后由 Refresh-All 完成时再调本函数覆盖。
  if ($keys.Count -eq 0 -and $cbo.Items.Count -eq 0) {
    foreach ($d in @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and ($fsOkList -contains $_.DriveFormat) })) {
      $n = $d.Name.TrimEnd('\')
      $keys.Add($n) | Out-Null
      $names.Add($n) | Out-Null
    }
  }
  if ($keys.Count -eq 0) { return }
  $cbo.Items.Clear()
  $fsByKey = @{}
  foreach ($c in $cards) { if ($c -and $c.VssSupported) { $fsByKey[[string]$c.Letter] = [string]$c.FsText } }
  for ($i = 0; $i -lt $keys.Count; $i++) {
    $fs = if ($fsByKey.ContainsKey($keys[$i]) -and $fsByKey[$keys[$i]]) { $fsByKey[$keys[$i]] } else { '' }
    [void]$cbo.Items.Add($(if ($fs) { ('{0}  ·  {1}' -f $names[$i], $fs) } else { $names[$i] }))
  }
# ToArray() 本身就是数组, 不需要 @() 包装(规避上面提到的 PS 5.1 @() 怪癖)
  $script:SchedVolKeys = $keys.ToArray()
  $script:SchedVolNames = $names.ToArray()
  $idx = 0
  if ($prevKey) {
    for ($i = 0; $i -lt $script:SchedVolKeys.Count; $i++) { if ($script:SchedVolKeys[$i] -eq $prevKey) { $idx = $i; break } }
  }
  $cbo.SelectedIndex = $idx
}

function Update-SchedView {
# 计划任务数据来自统一刷新(后台已读好存于 $script:Cache.SchedTasks), 本函数只做 UI 渲染。
  $tasks = @()
  if ($script:Cache -and $script:Cache.SchedTasks) { $tasks = $script:Cache.SchedTasks }
  $lst = Get-N 'lstSchedTasks'
  $lst.ItemsSource = $null
  $lst.ItemsSource = $tasks
  # 目标卷下拉:直接复用主界面卷列表(见 Fill-SchedVolumes),刷新完成后会再调一次补齐无盘符卷
  Fill-SchedVolumes
  $cboType = Get-N 'cboSchedType'
  if ($cboType.Items.Count -eq 0) {
    foreach ($lbl in $script:SchedTypeLabels) { [void]$cboType.Items.Add($lbl) }
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
  try { Reset-ListHScroll $lst } catch {}
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
  (Get-N 'txtSchedDesc').Text = ($plan + ' · 目标卷 ' + $(if ($sel.Letter) { Get-VolumeDisplayName $sel.Letter } else { '未知' }))
  # 运行信息
  $txtLast.Text = $sel.LastRunText
  $txtRes.Text = $sel.ResultText
  $txtNext.Text = $sel.NextRunText
  # 目标卷回显(下拉是纯字符串,真实卷键在 $script:SchedVolKeys 里按下标对应)
  $cbo = Get-N 'cboSchedLetter'
  for ($i = 0; $i -lt $script:SchedVolKeys.Count; $i++) {
    if ([string]$script:SchedVolKeys[$i] -eq [string]$sel.Letter) { $cbo.SelectedIndex = $i; break }
  }
  # 计划类型回显(下拉索引 = $script:SchedTypes 里的下标)
  $cboType = Get-N 'cboSchedType'
  $ti = [array]::IndexOf($script:SchedTypes, [string]$sel.Type)
  $cboType.SelectedIndex = if ($ti -ge 0) { $ti } else { 2 }
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
  # 下拉项是纯字符串(卷显示名 + 文件系统),真实卷键按下标从 $script:SchedVolKeys 取回
  $cboVol = Get-N 'cboSchedLetter'
  $vi = $cboVol.SelectedIndex
  $letter = if ($vi -ge 0 -and $vi -lt $script:SchedVolKeys.Count) { [string]$script:SchedVolKeys[$vi] } else { '' }
  $volDisp = if ($vi -ge 0 -and $vi -lt $script:SchedVolNames.Count) { [string]$script:SchedVolNames[$vi] } else { $letter }
  $timeRaw = (Get-N 'txtSchedTime').Text.Trim()
  $name = (Get-N 'txtSchedName').Text.Trim()
  $comment = (Get-N 'txtSchedComment').Text.Trim()
  $typeIdx = (Get-N 'cboSchedType').SelectedIndex
  if ($typeIdx -lt 0 -or $typeIdx -gt 4) { $typeIdx = 2 }
  $type = $script:SchedTypes[$typeIdx]
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
  if (-not $name) { $name = $script:SchedPrefix + (($volDisp.TrimEnd(':')) -replace '[\\/:*?"<>|{}]', '_') }
  elseif ($name -notmatch $script:SchedPrefix) { $name = $script:SchedPrefix + $name }
  $name = $name -replace '[\\/:*?"<>|]','_'
  $taskName = $name.Replace($script:SchedPrefix,'')
  $fullName = '\ShadowConsole\' + $taskName
  # 编辑改名的旧任务清理(走队列: 串行 FIFO 先删旧名再建新名; 命令日志统一记录 schtasks 命令)
  $editing = $script:SchedEditing
  $oldNameToDelete = ''
  if ($editing -and $editing.TaskName -and $editing.TaskName -ne $taskName) {
    $oldNameToDelete = '\ShadowConsole\' + $editing.TaskName
  }
  $scriptText = Get-SchedScript -Letter $letter
  $dir = Join-Path $env:TEMP 'shadowconsole'
  try { [IO.Directory]::CreateDirectory($dir) | Out-Null } catch {}
  $scriptFile = Join-Path $dir ('sched_' + $taskName + '.ps1')
  try { [IO.File]::WriteAllText($scriptFile, $scriptText, (New-Object Text.UTF8Encoding $true)) } catch { Show-Toast -Message '写入脚本失败' -Type 'err'; return }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# 参数编码到命令行供回读(编辑回显); XML 特殊字符转义(描述含 & < > 会致 XML 解析失败)
  $argTail = (' -L "' + $letter + '" -T "' + ($times -join ',') + '" -TYPE ' + $type + ' -INT ' + $interval + ' -W "' + ($week -join ',') + '" -MD ' + $monthDay + ' -SAWA ' + $(if($sawa){'1'}else{'0'}))
  $trigXml = Get-SchedTriggersXml -Type $type -Times $times -Interval $interval -Week $week -MonthDay $monthDay
  $planDesc = (Get-SchedPlanText -Type $type -Times $times -Interval $interval -Week $week -MonthDay $monthDay)
  $schedDesc = ('ShadowConsole 定时卷影任务 (' + $planDesc + ' · ' + $volDisp + ')')
# 描述并入 Description(RegistrationInfo 无 Comment 元素, 带 <Comment> 报 SCHED_E_UNEXPECTEDNODE)
  $fullDesc = if ($comment) { ($comment + ' | ' + $schedDesc) } else { $schedDesc }
# 用任务 XML 创建(避免 schtasks /TR 命令行的引号解析问题, 支持含空格路径)
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
  # 旧名清理 + 创建 都走队列(串行 FIFO, 先删旧名再建新名); 命令日志统一记录 schtasks 命令
  if ($oldNameToDelete) {
    Invoke-SystemTool -Tool 'schtasks' -ArgList @('/Delete', '/TN', $oldNameToDelete, '/F') -Label ('正在清理旧任务 · ' + $oldNameToDelete) -CoalesceKey ('scheddel|' + $oldNameToDelete)
  }
  Invoke-SystemTool -Tool 'schtasks' -ArgList @('/Create', '/TN', $fullName, '/XML', $xmlFile, '/F') -Label ('正在保存计划任务 · ' + $taskName) -CoalesceKey ('schedsave|' + $taskName) -OnDone {
    param($e)
# XML 只是 schtasks /Create 的中间产物: 任务建好即删(不留 %TEMP% 残留)
    try { Remove-Item -LiteralPath $xmlFile -Force -ErrorAction SilentlyContinue } catch {}
    if ($e.ExitCode -eq 0) {
      Show-Toast -Message ('已保存计划任务 ' + $taskName)
      Refresh-All
    } else {
      # 详细错误:写诊断日志(默认只在内存; 开了「日志落盘」才写 %TEMP%) + toast 展示完整信息; 命令日志亦已记录本次 schtasks 输出
      try {
        Write-Diag 'sched_err' ('[{0}] save {1} FAILED:`n{2}`nXML file: {3}`n----`n' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $fullName, $e.Output, $xmlFile)
      } catch {}
      Show-Toast -Message ('保存失败: ' + $e.Output) -Type 'err'
    }
  }.GetNewClosure()
}

# 周几 chips 点击切换。⚠ 硬约束(踩坑): 切换逻辑要放在**函数**里, 不能直写在闭包体内 ——
#   闭包体内直读/直写 $script:X 会被 GetNewClosure 的冻结快照吃掉(表现为"点了没反应")。
$script:SchedWeekSel = @(1..7)
function Toggle-WeekDay {
  param([int]$Day)
  if ($script:SchedWeekSel -contains $Day) {
    $script:SchedWeekSel = @($script:SchedWeekSel | Where-Object { $_ -ne $Day })
  } else {
    $script:SchedWeekSel = @(@($script:SchedWeekSel) + $Day | Sort-Object -Unique)
  }
  Set-WeekChips $script:SchedWeekSel
}
$chipNames = @('chipMon','chipTue','chipWed','chipThu','chipFri','chipSat','chipSun')
for ($i = 0; $i -lt $chipNames.Count; $i++) {
  $day = $i + 1
  $chip = Get-N $chipNames[$i]
  $chip.add_MouseLeftButtonUp({
    Toggle-WeekDay -Day $day
  }.GetNewClosure())
}
(Get-N 'cboSchedType').add_SelectionChanged({
  $idx = (Get-N 'cboSchedType').SelectedIndex
  if ($idx -lt 0 -or $idx -gt 4) { $idx = 2 }
  $type = $script:SchedTypes[$idx]
  Set-SchedTypeUI $type
})

# 按钮组显隐:「新增任务」固定在标题条右端; 保存常驻; 导出/运行/启用/删除需选中任务
function Update-SchedActionBtns {
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  $hasSel = ($null -ne $sel)
  $canWrite = [bool]$script:CanAct
  (Get-N 'btnSchedExport').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  (Get-N 'btnSchedRunNow').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  (Get-N 'btnSchedToggle').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  (Get-N 'btnSchedDelete').Visibility = if ($hasSel) { 'Visible' } else { 'Collapsed' }
  # 只读模式: 写操作按钮禁用(新增/保存/运行/启用/删除), 导出为只读保留
  (Get-N 'btnSchedNew').IsEnabled = $canWrite
  (Get-N 'btnSchedSave').IsEnabled = $canWrite
  (Get-N 'btnSchedRunNow').IsEnabled = $canWrite
  (Get-N 'btnSchedToggle').IsEnabled = $canWrite
  (Get-N 'btnSchedDelete').IsEnabled = $canWrite
  (Get-N 'btnSchedExport').IsEnabled = $true
}
(Get-N 'btnSchedRefresh').add_Click({ Refresh-All })
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
# 新增: 清空表单进新建模式(列表取消选中会触发 SelectionChanged 重置; 本来就未选中则手动重置)
(Get-N 'btnSchedNew').add_Click({
  if ((Get-N 'lstSchedTasks').SelectedIndex -ge 0) {
    (Get-N 'lstSchedTasks').SelectedIndex = -1
  } else {
    $script:SchedEditing = $null
    Show-SchedDetail $null
    Update-SchedActionBtns
  }
})
# 保存:新建模式下创建新任务; 选中任务时更新现有任务
(Get-N 'btnSchedSave').add_Click({ Save-SchedTask })
# 计划任务写操作(运行/启用禁用/删除)也走队列, 与卷影写操作共用一条串行链。Action: run|toggle|delete
function Invoke-SchedAction {
  param([ValidateSet('run','toggle','delete')][string]$Action)
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  if (-not $sel) { Show-Toast -Message '请先选择任务' -Type 'warn'; return }
  $taskName = [string]$sel.TaskName
  $fullName = '\ShadowConsole\' + $taskName
  switch ($Action) {
    'run' {
      if (-not $script:CanAct) { Show-Toast -Message '只读模式无法触发任务' -Type 'warn'; return }
      $args1 = @('/Run', '/TN', $fullName)
      $label = '正在触发任务 · ' + $taskName
      $coalesce = 'schedrun|' + $taskName
      $okMsg = '已触发任务 ' + $taskName
      $errMsg = '触发失败: '
    }
    'toggle' {
      if (-not $script:CanAct) { Show-Toast -Message '只读模式无法启用/禁用任务' -Type 'warn'; return }
      $verb = if ($sel.Enabled) { '禁用' } else { '启用' }
      $args1 = @('/Change', $(if ($sel.Enabled) { '/DISABLE' } else { '/ENABLE' }), '/TN', $fullName)
      $label = '正在' + $verb + '任务 · ' + $taskName
      $coalesce = 'schedtoggle|' + $taskName
      $okMsg = '已' + $verb + '任务 ' + $taskName
      $errMsg = '操作失败: '
    }
    'delete' {
      if (-not $script:CanAct) { Show-Toast -Message '只读模式无法删除任务' -Type 'warn'; return }
      if (-not (Show-Confirm -Title '删除计划任务' -Message ('将删除计划任务 ' + $taskName + ',其已创建的卷影副本不受影响。') -Cmd ('schtasks /Delete /TN ' + $fullName + ' /F') -Danger)) { return }
      $args1 = @('/Delete', '/TN', $fullName, '/F')
      $label = '正在删除任务 · ' + $taskName
      $coalesce = 'scheddelete|' + $taskName
      $okMsg = '已删除任务 ' + $taskName
      $errMsg = '删除失败: '
    }
  }
  Invoke-SystemTool -Tool 'schtasks' -ArgList $args1 -Label $label -CoalesceKey $coalesce -OnDone {
    param($e)
    if ($e.ExitCode -eq 0) {
      Show-Toast -Message $okMsg
      Refresh-All
      if ($Action -eq 'delete') { Show-SchedDetail $null }
    } else {
      Show-Toast -Message ($errMsg + $e.Output) -Type 'err'
    }
  }.GetNewClosure()
}
(Get-N 'btnSchedRunNow').add_Click({ Invoke-SchedAction 'run' })
(Get-N 'btnSchedToggle').add_Click({ Invoke-SchedAction 'toggle' })
(Get-N 'btnSchedDelete').add_Click({ Invoke-SchedAction 'delete' })
# 导出任务定义(只读, 但同样走队列 + 命令日志, 与其它 schtasks 命令一致)
function Invoke-SchedExport {
  $sel = (Get-N 'lstSchedTasks').SelectedItem
  if (-not $sel) { Show-Toast -Message '请先选择任务' -Type 'warn'; return }
  $fullName = '\ShadowConsole\' + $sel.TaskName
  $taskName = [string]$sel.TaskName
  $dlg = New-Object Microsoft.Win32.SaveFileDialog
  $dlg.Title = '导出任务定义'
  $dlg.Filter = '任务定义 (*.xml)|*.xml'
  $dlg.FileName = $taskName + '.xml'
  if ($dlg.ShowDialog() -ne $true) { return }
  $targetPath = [string]$dlg.FileName
  Invoke-SystemTool -Tool 'schtasks' -ArgList @('/Query', '/TN', $fullName, '/XML', 'ONE') -Label ('正在导出任务 · ' + $taskName) -OnDone {
    param($e)
    if ($e.ExitCode -eq 0 -and $e.Output) {
      try {
        [IO.File]::WriteAllText($targetPath, $e.Output, (New-Object Text.UTF8Encoding $true))
        Show-Toast -Message ('已导出任务 ' + $taskName)
      } catch { Show-Toast -Message ('导出失败: ' + $_.Exception.Message) -Type 'err' }
    } else { Show-Toast -Message ('导出失败: ' + $e.Output) -Type 'err' }
  }.GetNewClosure()
}
(Get-N 'btnSchedExport').add_Click({ Invoke-SchedExport })


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
  # 存储位置(差异区)卷键按下标取回(下拉只放纯字符串)
  $idx = (Get-N 'cboResizeDiff').SelectedIndex
  $diff = if ($idx -ge 0 -and $idx -lt $script:ResizeDiffKeys.Count) { [string]$script:ResizeDiffKeys[$idx] } else { '' }
  $result | Add-Member -NotePropertyName Diff -NotePropertyValue $diff
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
  # 客户端非 NTFS/ReFS 卷无法设置配额 → 置灰(禁用)该按钮, 提示不可用;
  # 与"队列忙碌时置灰"合并到 Sync-ActionButtons 统一计算, 避免两处互相覆盖
  Sync-ActionButtons
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
    if ($btn.Name -eq 'btnCardCreate') {
      # 尚未就绪(不能自存差异区且未设外部存储) → 灰色按钮点击不是创建, 而是带去配额窗口设置存储位置
      $card0 = @($script:Cache.Cards | Where-Object { $_ -and [string]$_.Letter -eq [string]$letter } | Select-Object -First 1)
      if ($card0 -and $card0.CreateGrayed) {
        Show-Toast -Message '本卷文件系统不支持内部存放卷影差分，请设置存储位置' -Type 'err'
        return
      }
      if ($card0 -and -not $card0.CreateReady) { Invoke-ResizeFor $letter } else { Invoke-CreateShadow $letter }
    }
    elseif ($btn.Name -eq 'btnCardQuota') {
      $card0 = @($script:Cache.Cards | Where-Object { $_ -and [string]$_.Letter -eq [string]$letter } | Select-Object -First 1)
      if ($card0 -and $card0.QuotaGrayed) {
        Show-Toast -Message 'Windows 客户端不支持设置差分位置，无法调整' -Type 'err'
        return
      }
      Invoke-ResizeFor $letter
    }
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
      if ($script:FilterLetter -eq $data.Letter) { $script:FilterLetter = $null; $script:FilterDisplay = $null }
      else { $script:FilterLetter = $data.Letter; $script:FilterDisplay = $data.DisplayLetter }
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
    'lstShadows:创建时间' = 'CreatedText'; 'lstShadows:卷' = 'LetterDisplay'; 'lstShadows:阴影 ID' = 'Id'; 'lstShadows:设备对象' = 'Device'; 'lstShadows:属性' = 'TypeText'
    'lstStorage:卷' = 'LetterDisplay'; 'lstStorage:卷标' = 'LabelText'; 'lstStorage:文件系统' = 'FsText'; 'lstStorage:已用空间' = 'UsedText'; 'lstStorage:已分配' = 'AllocText'; 'lstStorage:上限' = 'MaxText'; 'lstStorage:存储位置' = 'DiffDisplay'
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
    # 分组列表(如存储配额页):组顺序按既定口径固定(1 固定盘 → 2 移动盘·路径映射 → 3 仅GUID), 不随排序改变;
    # 把 Group 作为主键(Asc)置顶, 点击列只在组内排序, 分组不被打乱。
    if ($view.GroupDescriptions.Count -gt 0) {
      $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Group', [System.ComponentModel.ListSortDirection]::Ascending)))
    }
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
        # 分组列表:组顺序按既定口径固定, 主键 Group(Asc)置顶, 已保存的列排序只作用于组内
        if ($view.GroupDescriptions.Count -gt 0) {
          $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Group', [System.ComponentModel.ListSortDirection]::Ascending)))
        }
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
# 表格状态(列宽/排序/列顺序)持久化: 监听"落地值本身"的变化, 不轮询也不监听拖动过程事件 ——
# 列宽用 DependencyPropertyDescriptor 监听 GridViewColumn.Width;
# 列顺序用 GridViewColumnCollection 的 CollectionChanged; 排序在 Add-ListSort 里直接保存。
foreach ($lvName in $script:ListNames) {
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
    (Get-N 'txtBrowse').Text = ('选中卷影{0}{1} · 打开' -f $sel.LetterDisplay, $sel.CreatedText)
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
    if ($data -and $data.QuotaGrayed) {
      Show-Toast -Message 'Windows 客户端不支持设置差分位置，无法调整' -Type 'err'
      return
    }
    if ($data) { Invoke-ResizeFor $data.Letter }
  }
})

$window.add_PreviewKeyDown({
  if ($_.Key -eq [System.Windows.Input.Key]::F5) { Refresh-All; $_.Handled = $true }
})
# 页面离开(关窗)时不丢任务: 首次 Closing 只拦截+置标志, 队列排空后由 Pump-Jobs 回调 Close()。
$window.add_Closing({
  param($s, $e)
  if ($script:JobClosing) { return }
  if ($script:JobCurrent -or $script:JobQueue.Count -gt 0) {
    $e.Cancel = $true
    $script:JobClosing = $true
    $pending = $script:JobQueue.Count + $(if ($script:JobCurrent) { 1 } else { 0 })
    try { Show-Toast -Message ('还有 ' + $pending + ' 个任务未完成，正在按顺序执行完毕后退出…') -Type 'warn' } catch {}
    try { Start-JobPump } catch {}
  }
})
$window.add_Closed({
  try { Save-Settings (Get-SettingsValues) } catch {}
  try { if ($script:SettingsTimer) { $script:SettingsTimer.Stop() } } catch {}
  try { if ($script:BgPump) { $script:BgPump.Stop() } } catch {}
  try { if ($script:JobPump) { $script:JobPump.Stop() } } catch {}
# 清理"无盘符卷"浏览用的目录符号链接: 必须用 cmd rmdir 删链接本身 —— 绝不能用 [IO.Directory]::Delete(,$true), 那会跟随链接删到卷影设备上的内容
  try {
    $mnt = Join-Path $env:TEMP 'shadowconsole\mnt'
    if ([System.IO.Directory]::Exists($mnt)) {
      foreach ($d in [System.IO.Directory]::GetDirectories($mnt)) {
        try {
          $rp = New-Object System.Diagnostics.ProcessStartInfo
          $rp.FileName = (Join-Path $env:SystemRoot 'System32\cmd.exe')
          $rp.Arguments = '/c rmdir "' + $d + '"'
          $rp.UseShellExecute = $false
          $rp.CreateNoWindow = $true
          [System.Diagnostics.Process]::Start($rp).WaitForExit(3000) | Out-Null
        } catch {}
      }
    }
  } catch {}
})
# 事件驱动保存:窗口尺寸/位置/分割条变化时 3 秒防抖保存一次
$window.add_SizeChanged({ Schedule-SettingsSave; Update-ShadowPageRows })
$window.add_LocationChanged({ Schedule-SettingsSave })
try {
  $sn = $window.FindName('splitNav')
  if ($sn) { $sn.add_DragCompleted({ Schedule-SettingsSave }) }
} catch {}
try {
  $sc = $window.FindName('splitCard')
  if ($sc) {
    # 用户拖过分割条 → 记标志, 之后窗口缩放不再自动改比例(尊重手工布局)
    $sc.add_DragStarted({ $script:ShadowRowManual = $true })
    $sc.add_DragCompleted({ Schedule-SettingsSave })
  }
} catch {}

$mode = 'System'
# 设置已在脚本前段(启动卫生处)读过并保存到 $script:Settings, 这里直接复用, 不重复读文件
$script:SavedColWidths = if ($script:Settings) { $script:Settings.ColWidths } else { $null }
# 一次性迁移: 布局 v2 之前保存的 lstSchedTasks 列宽是 330 窄栏时代的, 恢复会把新布局的默认宽压回去 → 删除这些键
if ($script:SavedColWidths -and -not ($script:Settings -and [int]$script:Settings.LayoutVersion -ge 2)) {
  try {
    $staleKeys = @()
    foreach ($p in $script:SavedColWidths.PSObject.Properties) { if ($p.Name -like 'lstSchedTasks:*') { $staleKeys += $p.Name } }
    foreach ($k in $staleKeys) { $script:SavedColWidths.PSObject.Properties.Remove($k) }
  } catch {}
}
$script:SavedSortState = if ($script:Settings) { $script:Settings.SortState } else { $null }
# 内置默认排序(定稿基线): 键 = 列表名, 值 = @{Col=表头; Dir=Asc|Desc}
if (-not $script:SavedSortState) {
  $script:SavedSortState = [pscustomobject]@{
    'lstShadows'    = [pscustomobject]@{ 'Col' = '创建时间'; 'Dir' = 'Desc' }
    'lstStorage'    = [pscustomobject]@{ 'Col' = '卷';       'Dir' = 'Asc'  }
    'lstSchedTasks' = [pscustomobject]@{ 'Col' = '任务';     'Dir' = 'Desc' }
    'lstWriters'    = [pscustomobject]@{ 'Col' = '状态';     'Dir' = 'Desc' }
  }
}
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
# 只恢复"用户亲手拖过分割条"时保存的卡片区高度。旧设置没有 LayoutVersion 4 标记, 其 CardH
# 出自已失效的版本(固定 220px 时代 / 列表下限失效那版), 一律忽略, 让新默认比例生效。
      if ($ps -and $null -ne $p.CardH -and [double]$p.CardH -gt 0 -and [int]$p.LayoutVersion -ge 4) {
        $ps.RowDefinitions[1].Height = [System.Windows.GridLength]::new([double]$p.CardH)
        $script:ShadowRowManual = $true
      }
    } catch {}
    # 恢复上次导航页
    try {
      $restorePage = 0
      if ($null -ne $p.NavPage -and [int]$p.NavPage -ge 0 -and [int]$p.NavPage -lt $script:NavNames.Count) { $restorePage = [int]$p.NavPage }
      Set-Nav $restorePage
    } catch {}
  }
# 存储配额页始终可见: 客户端可正常查看并设置本卷上限; 仅"跨盘改存储位置"由 Invoke-ResizeFor
# 在客户端拦截(0x80070032), 对话框已锁定差异区到本卷。
# 窗口尺寸无条件钳制到工作区: 低分屏上默认 1020×885 或旧配置的大尺寸会超出屏幕, 底部按钮被截走。
  try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($window.Width -gt $wa.Width) { $window.Width = $wa.Width }
    if ($window.Height -gt $wa.Height) { $window.Height = $wa.Height }
  } catch {}
} catch {}
# 恢复表格列顺序(先排顺序, 列宽按表头匹配不受顺序影响)与列宽
try { Apply-SavedColOrder } catch {}
try { Apply-SavedColWidths } catch {}
# 卷影页卡片区/列表的 2:1 比例(需要窗口已有实际高度, 放在窗口尺寸恢复之后)
try { Update-ShadowPageRows } catch {}

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
# 意象: 写时复制 —— 底层卷 + 卷影副本 + 时钟=快照时间点。
# 配色: 底层 #5A7FD6 / 顶层 #7BA3F0 / 描边 #3B5AA0 / 纹路 #8CA9E8 / 高光 #E1EAFB / 时钟 #274E8E
# 所有坐标用 512×512 设计稿单位写, 由 $k 统一缩放(换尺寸只改 $k)。
function New-ConsoleIconBmp {
  param([int]$Size)
  $k = $Size / 512.0
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $argb = { param($r, $gg, $b) [System.Drawing.Color]::FromArgb(255, $r, $gg, $b) }
  $pen    = New-Object System.Drawing.Pen((& $argb 59 90 160), [Math]::Max(1.0, [double](3 * $k)))
  $penClk = New-Object System.Drawing.Pen((& $argb 39 78 142), [Math]::Max(1.0, [double](9 * $k)))
  $penSml = New-Object System.Drawing.Pen((& $argb 39 78 142), [Math]::Max(1.0, [double](8 * $k)))
  $brushes = @(
    (New-Object System.Drawing.SolidBrush((& $argb 90 127 214))),   # 底层卷
    (New-Object System.Drawing.SolidBrush((& $argb 123 163 240))),  # 顶层卷影
    (New-Object System.Drawing.SolidBrush((& $argb 140 169 232))),  # 数据纹路
    (New-Object System.Drawing.SolidBrush((& $argb 225 234 251))),  # 高光
    (New-Object System.Drawing.SolidBrush((& $argb 39 78 142)))     # 时钟
  )
  # 三个画图小工具: 统一做 512 设计稿 → 实际像素的换算
  $fill  = { param($b, $x, $y, $w, $h) $g.FillRectangle($b, ($x * $k), ($y * $k), ($w * $k), ($h * $k)) }
  $frame = { param($p, $x, $y, $w, $h) $g.DrawRectangle($p, ($x * $k), ($y * $k), ($w * $k), ($h * $k)) }
  try {
    # 底层方块(原始卷) + 描边
    & $fill $brushes[0] 84 108 340 340
    & $frame $pen 84 108 340 340
    # 底层卷数据纹路(仅大尺寸可见)
    if ($Size -ge 48) {
      & $fill $brushes[2] 108 160 292 8
      & $fill $brushes[2] 108 184 292 8
    }
    # 顶层方块(卷影副本) + 描边
    & $fill $brushes[1] 156 76 340 340
    & $frame $pen 156 76 340 340
    # 顶层左上高光条(扁平色块)
    & $fill $brushes[3] 172 94 308 24
    # 时钟(快照时间点; 16px 只画圆环+一针, 保证小尺寸清晰)
    $cx = 326 * $k; $cy = 246 * $k
    if ($Size -ge 24) {
      $g.DrawEllipse($penClk, ($cx - 80 * $k), ($cy - 80 * $k), (160 * $k), (160 * $k))
      $g.DrawLine($penClk, $cx, $cy, $cx, (200 * $k))
      $g.DrawLine($penClk, $cx, $cy, (384 * $k), (260 * $k))
      $g.FillEllipse($brushes[4], ($cx - 10 * $k), ($cy - 10 * $k), (20 * $k), (20 * $k))
    } else {
      $g.DrawEllipse($penSml, ($cx - 6 * $k), ($cy - 6 * $k), (12 * $k), (12 * $k))
      $g.DrawLine($penSml, $cx, $cy, $cx, ($cy - 3 * $k))
    }
  } finally {
    $pen.Dispose(); $penClk.Dispose(); $penSml.Dispose()
    foreach ($b in $brushes) { $b.Dispose() }
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

# 日志目录卫生已在脚本前段完成(启动卫生: 落盘关 → 清旧日志; 落盘开 → 500 行截断)
Write-Diag 'runpath' ('apartment: ' + [System.Threading.Thread]::CurrentThread.ApartmentState)
$pre = [System.Windows.Application]::Current
Write-Diag 'runpath' ('pre-Current: ' + $(if ($pre) { 'YES ' + $pre.GetType().FullName } else { 'NO' }))
$app = New-Object System.Windows.Application
$app.MainWindow = $window
$script:MainDispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
# 降低 GC 暂停: 交互持续产生小对象分配 → 堆涨到阈值后周期性 Gen2 压缩, 每 ~2s 暂停 UI 线程
# 几十 ms(= "滑动流畅但周期性卡一下"的根源)。SustainedLowLatency 延迟 Gen2 压缩避免阻塞。
try { [System.Runtime.GCSettings]::LatencyMode = [System.Runtime.GCLatencyMode]::SustainedLowLatency } catch {}
# 位图缓存: 内容区渲染结果缓存为位图, 动画/状态文本变化时直接叠加缓存位图而非实时矢量重渲染
try {
  $bc = New-Object System.Windows.Media.BitmapCache(1.0)
  $bc.EnableClearType = $false
  $mainGrid.CacheMode = $bc
} catch {}
$script:BgBody = Get-BgBody -Functions @('Format-Size','New-ProcInfo','Parse-Writers','Get-RealCache','Test-IsServerEdition','Get-SchedTasks','Get-TaskResultInfo','Get-SchedPlanText','Start-ProcAsync','Wait-ProcResult') -Epilogue @'
$script:CanAct = $args[0]
$script:VssAdmin = $args[1]
$script:Brush_Accent = $args[2]
$script:Brush_Success = $args[3]
$script:Brush_Warn = $args[4]
$script:Brush_Danger = $args[5]
$script:Brush_Faint = $args[6]
$script:Brush_Sub = $args[7]
$script:Shared = $args[8]
# 注入项仅限"运行时状态 / UI 对象"。纯常量(文件系统白名单、状态名映射等)一律写在函数体内 —— 每多一个注入依赖就多一处"漏注入 = 静默失效"的隐患。
$result = Get-RealCache
$result
'@
$script:ToolBody = Get-BgBody -Functions @('New-ProcInfo','Invoke-ToolBg') -Epilogue @'
$r = Invoke-ToolBg -Exe $args[0] -ArgStr $args[1] -TimeoutSec $args[2]
$r
'@
$script:WmiBody = Get-BgBody -Functions @('Invoke-WmiCreateShadow') -Epilogue @'
$r = Invoke-WmiCreateShadow -Letter $args[0]
$r
'@

$window.add_Loaded({
# UI 线程卡顿监测(诊断用): 200ms 看门狗, tick 间隔 >400ms 就记一条 stutter, 用于定位卡顿来源。
  $script:WdLast = $null
  $watchDog = New-Object System.Windows.Threading.DispatcherTimer
  $watchDog.Interval = [TimeSpan]::FromMilliseconds(200)
  $watchDog.add_Tick({
    try {
      $now = [DateTime]::Now
      if ($script:WdLast) {
        $gap = ($now - $script:WdLast).TotalMilliseconds
        if ($gap -gt 400) {
          Write-Diag 'stutter' ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] UI阻塞 ' + [int]$gap + 'ms')
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
      Write-Diag 'tickerr2' ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $_.Exception.Message + ' @line ' + $_.InvocationInfo.ScriptLineNumber + ' :: ' + $_.InvocationInfo.Line.Trim())
    } catch {}
  }
# 空闲预热: PS 5.1 脚本块首次执行才编译(实测二次执行快 ~24x), 提前编译常用链消除首次操作卡顿
  $warmTimer = New-Object System.Windows.Threading.DispatcherTimer
  $warmTimer.Interval = [TimeSpan]::FromSeconds(1)
  $warmTimer.add_Tick({
    param($s, $e)
# 用事件参数 $s(=timer 自身)停止: PS 事件处理器执行时动态作用域不含 Loaded 局部变量, 写
# $warmTimer.Stop() 会得到 null→异常被吞→timer 永不停止→1s 无限循环。
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
    Write-Diag 'disptex' ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $e.Exception.ToString())
    $e.Handled = $true
  } catch {}
})
try {
  Write-Diag 'runpath' ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] Run before')
  $null = $app.Run($window)
  Write-Diag 'runpath' ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] direct OK')
# 退出即清理(无残留): 删除运行时临时脚本(PS -File 已整体读入内存, 可安全删正在执行的脚本);
# 提权进程同样执行本段(其 $PSCommandPath 即临时脚本)。诊断日志默认只在内存, 不留磁盘痕迹。
  try {
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'shadowconsole\vss_console_run.ps1') -Force -ErrorAction SilentlyContinue
  } catch {}
  # 目录空了就整个删掉(不留空壳); 计划任务要用的 sched_*.ps1 还在则保留目录
  try {
    $d = $script:LogDir
    if ((Test-Path -LiteralPath $d) -and (@(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
      Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
    }
  } catch {}
} catch {
  Write-Diag 'runpath' ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] direct FAILED - ' + $_.Exception.Message)
  $ex = $_.Exception
  $n = 0
  while ($ex -and $n -lt 8) { Write-Diag 'runpath' ('  L' + $n + ' [' + $ex.GetType().FullName + '] ' + $ex.Message); $ex = $ex.InnerException; $n++ }
  $mi = [System.Windows.Application].GetMethod('Run', [Type[]]@([System.Windows.Window]))
  $null = $mi.Invoke($app, @([System.Windows.Window]$window))
  Write-Diag 'runpath' 'reflection OK'
}
} catch {
  $err = $_.Exception
  $parts = @()
  while ($err) { $parts += $err.Message; $err = $err.InnerException }
  $state = ('   state: window=' + $(if ($window) { $window.GetType().FullName } else { 'NULL' }) + ' app=' + $(if ($app) { $app.GetType().FullName } else { 'NULL' }) + ' runEx=' + $_.Exception.GetType().FullName)
  $msg = '初始化失败: ' + ($parts -join ' ← ') + $state
  $msg += "`r`n   stacktrace: " + $_.Exception.StackTrace
# 崩溃信息: 进诊断日志(默认只在内存; 开了「日志落盘」或用 /debug 才落 %TEMP%\shadowconsole\crash.log)
  try {
    $where = ('   at line {0} | {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    $stack = '   stack: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | ')
    Write-Diag 'crash' ('{0}  {1}{2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, $where, $stack)
  } catch {}
  try {
    $mb = [System.Windows.MessageBox]::Show($msg, $script:AppName, 'OK', 'Error')
  } catch {}
}
#===CONFIG-BEGIN===

#===CONFIG-END===

__VSS_PS1_END__
