; -----------
; CODE
; -----------
[Code]
// types and variables
type
  TDependency_Entry = record
    Filename: String;
    Parameters: String;
    Title: String;
    URL: String;
    Checksum: String;
    ForceSuccess: Boolean;
    RestartAfter: Boolean;
  end;

var
  Dependency_Memo: String;
  Dependency_List: array of TDependency_Entry;
  Dependency_NeedRestart, Dependency_ForceX86: Boolean;
  Dependency_DownloadPage: TDownloadWizardPage;

procedure Dependency_Add(const Filename, Parameters, Title, URL, Checksum: String; const ForceSuccess, RestartAfter: Boolean);
var
  Dependency: TDependency_Entry;
  DependencyCount: Integer;
begin
  Dependency_Memo := Dependency_Memo + #13#10 + '%1' + Title;

  Dependency.Filename := Filename;
  Dependency.Parameters := Parameters;
  Dependency.Title := Title;

  if FileExists(ExpandConstant('{tmp}{\}') + Filename) then begin
    Dependency.URL := '';
  end else begin
    Dependency.URL := URL;
  end;

  Dependency.Checksum := Checksum;
  Dependency.ForceSuccess := ForceSuccess;
  Dependency.RestartAfter := RestartAfter;

  DependencyCount := GetArrayLength(Dependency_List);
  SetArrayLength(Dependency_List, DependencyCount + 1);
  Dependency_List[DependencyCount] := Dependency;
end;

procedure Dependency_InitializeWizard;
begin
  Dependency_DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

function Dependency_PrepareToInstall(var NeedsRestart: Boolean): String;
var
  DependencyCount, DependencyIndex, ResultCode: Integer;
  Retry: Boolean;
  TempValue: String;
begin
  DependencyCount := GetArrayLength(Dependency_List);

  if DependencyCount > 0 then begin
    Dependency_DownloadPage.Show;

    for DependencyIndex := 0 to DependencyCount - 1 do begin
      if Dependency_List[DependencyIndex].URL <> '' then begin
        Dependency_DownloadPage.Clear;
        Dependency_DownloadPage.Add(Dependency_List[DependencyIndex].URL, Dependency_List[DependencyIndex].Filename, Dependency_List[DependencyIndex].Checksum);

        Retry := True;
        while Retry do begin
          Retry := False;

          try
            Dependency_DownloadPage.Download;
          except
            if Dependency_DownloadPage.AbortedByUser then begin
              Result := Dependency_List[DependencyIndex].Title;
              DependencyIndex := DependencyCount;
            end else begin
              case SuppressibleMsgBox(AddPeriod(GetExceptionMessage), mbError, MB_ABORTRETRYIGNORE, IDIGNORE) of
                IDABORT: begin
                  Result := Dependency_List[DependencyIndex].Title;
                  DependencyIndex := DependencyCount;
                end;
                IDRETRY: begin
                  Retry := True;
                end;
              end;
            end;
          end;
        end;
      end;
    end;

    if Result = '' then begin
      for DependencyIndex := 0 to DependencyCount - 1 do begin
        Dependency_DownloadPage.SetText(Dependency_List[DependencyIndex].Title, '');
        Dependency_DownloadPage.SetProgress(DependencyIndex + 1, DependencyCount + 1);

        while True do begin
          ResultCode := 0;
          if ShellExec('', ExpandConstant('{tmp}{\}') + Dependency_List[DependencyIndex].Filename, Dependency_List[DependencyIndex].Parameters, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then begin
            if Dependency_List[DependencyIndex].RestartAfter then begin
              if DependencyIndex = DependencyCount - 1 then begin
                Dependency_NeedRestart := True;
              end else begin
                NeedsRestart := True;
                Result := Dependency_List[DependencyIndex].Title;
              end;
              break;
            end else if (ResultCode = 0) or Dependency_List[DependencyIndex].ForceSuccess then begin // ERROR_SUCCESS (0)
              break;
            end else if ResultCode = 1641 then begin // ERROR_SUCCESS_REBOOT_INITIATED (1641)
              NeedsRestart := True;
              Result := Dependency_List[DependencyIndex].Title;
              break;
            end else if ResultCode = 3010 then begin // ERROR_SUCCESS_REBOOT_REQUIRED (3010)
              Dependency_NeedRestart := True;
              break;
            end;
          end;

          case SuppressibleMsgBox(FmtMessage(SetupMessage(msgErrorFunctionFailed), [Dependency_List[DependencyIndex].Title, IntToStr(ResultCode)]), mbError, MB_ABORTRETRYIGNORE, IDIGNORE) of
            IDABORT: begin
              Result := Dependency_List[DependencyIndex].Title;
              break;
            end;
            IDIGNORE: begin
              break;
            end;
          end;
        end;

        if Result <> '' then begin
          break;
        end;
      end;

      if NeedsRestart then begin
        TempValue := '"' + ExpandConstant('{srcexe}') + '" /restart=1 /LANG="' + ExpandConstant('{language}') + '" /DIR="' + WizardDirValue + '" /GROUP="' + WizardGroupValue + '" /TYPE="' + WizardSetupType(False) + '" /COMPONENTS="' + WizardSelectedComponents(False) + '" /TASKS="' + WizardSelectedTasks(False) + '"';
        if WizardNoIcons then begin
          TempValue := TempValue + ' /NOICONS';
        end;
        RegWriteStringValue(HKA, 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', '{#SetupSetting("AppName")}', TempValue);
      end;
    end;

    Dependency_DownloadPage.Hide;
  end;
end;

function Dependency_UpdateReadyMemo(const Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := '';
  if MemoUserInfoInfo <> '' then begin
    Result := Result + MemoUserInfoInfo + Newline + NewLine;
  end;
  if MemoDirInfo <> '' then begin
    Result := Result + MemoDirInfo + Newline + NewLine;
  end;
  if MemoTypeInfo <> '' then begin
    Result := Result + MemoTypeInfo + Newline + NewLine;
  end;
  if MemoComponentsInfo <> '' then begin
    Result := Result + MemoComponentsInfo + Newline + NewLine;
  end;
  if MemoGroupInfo <> '' then begin
    Result := Result + MemoGroupInfo + Newline + NewLine;
  end;
  if MemoTasksInfo <> '' then begin
    Result := Result + MemoTasksInfo;
  end;

  if Dependency_Memo <> '' then begin
    if MemoTasksInfo = '' then begin
      Result := Result + SetupMessage(msgReadyMemoTasks);
    end;
    Result := Result + FmtMessage(Dependency_Memo, [Space]);
  end;
end;

function Dependency_IsX64: Boolean;
begin
  Result := not Dependency_ForceX86 and Is64BitInstallMode;
end;

function Dependency_String(const x86, x64: String): String;
begin
  if Dependency_IsX64 then begin
    Result := x64;
  end else begin
    Result := x86;
  end;
end;

function Dependency_ArchSuffix: String;
begin
  Result := Dependency_String('', '_x64');
end;

function Dependency_ArchTitle: String;
begin
  Result := Dependency_String(' (x86)', ' (x64)');
end;

function Dependency_IsNetCoreInstalled(const Version: String): Boolean;
var
  ResultCode: Integer;
begin
  // source code: https://github.com/dotnet/deployment-tools/tree/master/src/clickonce/native/projects/NetCoreCheck
  if not FileExists(ExpandConstant('{tmp}{\}') + 'netcorecheck' + Dependency_ArchSuffix + '.exe') then begin
    ExtractTemporaryFile('netcorecheck' + Dependency_ArchSuffix + '.exe');
  end;
  Result := ShellExec('', ExpandConstant('{tmp}{\}') + 'netcorecheck' + Dependency_ArchSuffix + '.exe', Version, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

procedure Dependency_AddDotNet70;
begin
  // https://dotnet.microsoft.com/download/dotnet/7.0
  if not Dependency_IsNetCoreInstalled('Microsoft.NETCore.App 7.0.0') then begin
    Dependency_Add('dotnet70' + Dependency_ArchSuffix + '.exe',
      '/lcid ' + IntToStr(GetUILanguage) + ' /passive /norestart',
      '.NET Runtime 7.0.0' + Dependency_ArchTitle,
      Dependency_String('https://download.visualstudio.microsoft.com/download/pr/75c0d7c7-9f30-46fd-9675-a301f0e051f4/ec04d5cc40aa6537a4af21fad6bf8ba9/dotnet-runtime-7.0.0-win-x86.exe',
	  'https://download.visualstudio.microsoft.com/download/pr/87bc5966-97cc-498c-8381-bff4c43aafc6/baca88b989e7d2871e989d33a667d8e9/dotnet-runtime-7.0.0-win-x64.exe'),
      '', False, False);
  end;
end;

procedure Dependency_AddDotNet70Desktop;
begin
  // https://dotnet.microsoft.com/download/dotnet/7.0
  if not Dependency_IsNetCoreInstalled('Microsoft.WindowsDesktop.App 7.0.0') then begin
    Dependency_Add('dotnet70desktop' + Dependency_ArchSuffix + '.exe',
      '/lcid ' + IntToStr(GetUILanguage) + ' /passive /norestart',
      '.NET Desktop Runtime 7.0.0' + Dependency_ArchTitle,
      Dependency_String('https://download.visualstudio.microsoft.com/download/pr/d05a833c-2cf9-4d06-89ae-a0f3e10c5c91/c668ff42e23c2f67aa3d80227860585f/windowsdesktop-runtime-7.0.0-win-x86.exe',
	  'https://download.visualstudio.microsoft.com/download/pr/5b2fbe00-507e-450e-8b52-43ab052aadf2/79d54c3a19ce3fce314f2367cf4e3b21/windowsdesktop-runtime-7.0.0-win-x64.exe'),
      '', False, False);
  end;
end;

procedure Dependency_AddVC2005;
begin
  // https://www.microsoft.com/en-US/download/details.aspx?id=26347
  if not IsMsiProductInstalled(Dependency_String('{86C9D5AA-F00C-4921-B3F2-C60AF92E2844}', '{A8D19029-8E5C-4E22-8011-48070F9E796E}'), PackVersionComponents(8, 0, 61000, 0)) then begin
    Dependency_Add('vcredist2005' + Dependency_ArchSuffix + '.exe',
      '/q',
      'Visual C++ 2005 Service Pack 1 Redistributable' + Dependency_ArchTitle,
      Dependency_String('https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE', 'https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE'),
      '', False, False);
  end;
end;

procedure Dependency_AddVC2008;
begin
  // https://www.microsoft.com/en-US/download/details.aspx?id=26368
  if not IsMsiProductInstalled(Dependency_String('{DE2C306F-A067-38EF-B86C-03DE4B0312F9}', '{FDA45DDF-8E17-336F-A3ED-356B7B7C688A}'), PackVersionComponents(9, 0, 30729, 6161)) then begin
    Dependency_Add('vcredist2008' + Dependency_ArchSuffix + '.exe',
      '/q',
      'Visual C++ 2008 Service Pack 1 Redistributable' + Dependency_ArchTitle,
      Dependency_String('https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe', 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe'),
      '', False, False);
  end;
end;

procedure Dependency_AddVC2010;
begin
  // https://www.microsoft.com/en-US/download/details.aspx?id=26999
  if not IsMsiProductInstalled(Dependency_String('{1F4F1D2A-D9DA-32CF-9909-48485DA06DD5}', '{5B75F761-BAC8-33BC-A381-464DDDD813A3}'), PackVersionComponents(10, 0, 40219, 0)) then begin
    Dependency_Add('vcredist2010' + Dependency_ArchSuffix + '.exe',
      '/passive /norestart',
      'Visual C++ 2010 Service Pack 1 Redistributable' + Dependency_ArchTitle,
      Dependency_String('https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe', 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'),
      '', False, False);
  end;
end;

procedure Dependency_AddVC2012;
begin
  // https://www.microsoft.com/en-US/download/details.aspx?id=30679
  if not IsMsiProductInstalled(Dependency_String('{4121ED58-4BD9-3E7B-A8B5-9F8BAAE045B7}', '{EFA6AFA1-738E-3E00-8101-FD03B86B29D1}'), PackVersionComponents(11, 0, 61030, 0)) then begin
    Dependency_Add('vcredist2012' + Dependency_ArchSuffix + '.exe',
      '/passive /norestart',
      'Visual C++ 2012 Update 4 Redistributable' + Dependency_ArchTitle,
      Dependency_String('https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe', 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'),
      '', False, False);
  end;
end;

procedure Dependency_AddVC2013;
begin
  // https://support.microsoft.com/en-US/help/4032938
  if not IsMsiProductInstalled(Dependency_String('{B59F5BF1-67C8-3802-8E59-2CE551A39FC5}', '{20400CF0-DE7C-327E-9AE4-F0F38D9085F8}'), PackVersionComponents(12, 0, 40664, 0)) then begin
    Dependency_Add('vcredist2013' + Dependency_ArchSuffix + '.exe',
      '/passive /norestart',
      'Visual C++ 2013 Update 5 Redistributable' + Dependency_ArchTitle,
      Dependency_String('https://download.visualstudio.microsoft.com/download/pr/10912113/5da66ddebb0ad32ebd4b922fd82e8e25/vcredist_x86.exe', 'https://download.visualstudio.microsoft.com/download/pr/10912041/cee5d6bca2ddbcd039da727bf4acb48a/vcredist_x64.exe'),
      '', False, False);
  end;
end;

procedure Dependency_AddVC2015To2019;
begin
  // https://support.microsoft.com/en-US/help/2977003/the-latest-supported-visual-c-downloads
  if not IsMsiProductInstalled(Dependency_String('{65E5BD06-6392-3027-8C26-853107D3CF1A}', '{36F68A90-239C-34DF-B58C-64B30153CE35}'), PackVersionComponents(14, 29, 30037, 0)) then begin
    Dependency_Add('vcredist2019' + Dependency_ArchSuffix + '.exe',
      '/passive /norestart',
      'Visual C++ 2015-2019 Redistributable' + Dependency_ArchTitle,
      Dependency_String('https://aka.ms/vs/16/release/vc_redist.x86.exe', 'https://aka.ms/vs/16/release/vc_redist.x64.exe'),
      '', False, False);
  end;
end;

procedure Dependency_AddDirectX;
begin
  // https://www.microsoft.com/en-US/download/details.aspx?id=35
  Dependency_Add('dxwebsetup.exe',
    '/q',
    'DirectX Runtime',
    'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe',
    '', True, False);
end;

procedure Dependency_AddHideHide;
begin
  // https://www.microsoft.com/en-US/download/details.aspx?id=35
  Dependency_Add('HidHide_1.2.98_x64.exe',
    '/quiet /norestart',
    'HidHide Drivers v1.2.98',
    'https://github.com/ViGEm/HidHide/releases/download/v1.2.98.0/HidHide_1.2.98_x64.exe',
    '', True, False);
end;

procedure Dependency_AddViGem;
begin
  // https://www.microsoft.com/en-US/download/details.aspx?id=35
  Dependency_Add('ViGEmBus_1.21.442_x64_x86_arm64.exe',
    '/quiet /norestart',
    'ViGEmBus Setup 1.21.442',
    'https://github.com/ViGEm/ViGEmBus/releases/download/v1.21.442.0/ViGEmBus_1.21.442_x64_x86_arm64.exe',
    '', True, False);
end;

procedure Dependency_AddRTSS;
begin
  Dependency_Add('RTSSSetup734.exe',
    '/S',
    'RTSS Setup v7.3.4',
    'https://github.com/Valkirie/HandheldCompanion/raw/main/redist/RTSSSetup734.exe',
    '', True, False);
end;

procedure Dependency_AddHWiNFO;
begin
  Dependency_Add('hwi_746.exe',
    '/silent',
    'HWiNFO v7.4.6',
    'https://github.com/Valkirie/HandheldCompanion/raw/main/redist/hwi_746.exe',
    '', True, False);
end;

[Setup]
; -------------
; SETUP
; -------------
#ifndef Dependency_NoExampleSetup

; requires netcorecheck.exe and netcorecheck_x64.exe (see download link below)
#define UseNetCoreCheck
#ifdef UseNetCoreCheck
  #define UseDotNet70
#endif

#define UseVC2005
#define UseVC2008
#define UseVC2010
#define UseVC2012
#define UseVC2013
#define UseVC2015To2019

#define UseDirectX
; install ViGem first
#define UseViGem
#define UseHideHide
#define UseRTSS
#define UseHWiNFO

#define MyAppSetupName 'Handheld Companion'
#define MyBuildId 'HandheldCompanion'
#define MyAppVersion '0.16.2.3'
#define MyAppPublisher 'BenjaminLSR'
#define MyAppCopyright 'Copyright @ BenjaminLSR'
#define MyAppURL 'https://github.com/Valkirie/HandheldCompanion'
#define MyAppExeName "HandheldCompanion.exe"
#define MySerExeName "ControllerService.exe"
#define MyConfiguration "Release"

#ifdef UseDotNet70
	#define MyConfigurationExt "net7.0"
#endif 

AppName={#MyAppSetupName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppSetupName}
AppCopyright={#MyAppCopyright}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
OutputBaseFilename={#MyBuildId}-{#MyAppVersion}
DefaultGroupName={#MyAppSetupName}
DefaultDirName={autopf}\{#MyAppSetupName}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile="{#SourcePath}\HandheldCompanion\Resources\icon.ico"
SourceDir=redist
OutputDir={#SourcePath}\install
AllowNoIcons=yes
MinVersion=6.0
PrivilegesRequired=admin

// remove next line if you only deploy 32-bit binaries and dependencies
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: en; MessagesFile: "compiler:Default.isl"

[Setup]
AlwaysRestart = yes
CloseApplications = yes

[Files]
#ifdef UseNetCoreCheck
// download netcorecheck.exe: https://go.microsoft.com/fwlink/?linkid=2135256
// download netcorecheck_x64.exe: https://go.microsoft.com/fwlink/?linkid=2135504
Source: "netcorecheck.exe"; Flags: dontcopy noencryption
Source: "netcorecheck_x64.exe"; Flags: dontcopy noencryption
#endif

Source: "{#SourcePath}\bin\{#MyConfiguration}\{#MyConfigurationExt}-windows10.0.19041.0\WinRing0x64.dll"; DestDir: "{app}"; Flags: onlyifdoesntexist
Source: "{#SourcePath}\bin\{#MyConfiguration}\{#MyConfigurationExt}-windows10.0.19041.0\WinRing0x64.sys"; DestDir: "{app}"; Flags: onlyifdoesntexist
Source: "{#SourcePath}\bin\{#MyConfiguration}\{#MyConfigurationExt}-windows10.0.19041.0\*"; Excludes: "*WinRing0x64.*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

Source: "{#SourcePath}\redist\Segoe Fluent Icons.ttf"; DestDir: "{autofonts}"; FontInstall: "Segoe Fluent Icons"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#SourcePath}\redist\PromptFont.otf"; DestDir: "{autofonts}"; FontInstall: "PromptFont"; Flags: uninsneveruninstall

[Icons]
Name: "{group}\{#MyAppSetupName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppSetupName}}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#MyAppSetupName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"

[Run]

[UninstallRun]
Filename: "{sys}\sc.exe"; Parameters: "stop ControllerService" ; RunOnceId: "StopService"; Flags: runascurrentuser runhidden
Filename: "{sys}\sc.exe"; Parameters: "delete ControllerService" ; RunOnceId: "DeleteService"; Flags: runascurrentuser runhidden
Filename: "C:\Program Files\Nefarius Software Solutions e.U\HidHideCLI\HidHideCLI.exe"; Parameters: "--cloak-off" ; RunOnceId: "CloakOff"; Flags: runascurrentuser runhidden

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Registry]
Root: HKLM; Subkey: "Software\Microsoft\Windows\Windows Error Reporting\LocalDumps"; Flags: uninsdeletekeyifempty
Root: HKLM; Subkey: "Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\ControllerService.exe"; ValueType: string; ValueName: "DumpFolder"; ValueData: "{userdocs}\HandheldCompanion\dumps"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\HandheldCompanion.exe"; ValueType: string; ValueName: "DumpFolder"; ValueData: "{userdocs}\HandheldCompanion\dumps"; Flags: uninsdeletekey

[Code]
#include "./UpdateUninstallWizard.iss"       


procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  resultCode:integer;
begin
  if CurUninstallStep = usUninstall then
  begin     
    if not(checkListBox.checked[keepAllCheck]) then
    begin
      if DirExists(ExpandConstant('{userdocs}\{#MyBuildId}\profiles'))  then  
        DelTree(ExpandConstant('{userdocs}\{#MyBuildId}\profiles'), True, True, True);
      if DirExists(ExpandConstant('{userdocs}\{#MyBuildId}\hotkeys'))  then
        DelTree(ExpandConstant('{userdocs}\{#MyBuildId}\hotkeys'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\HandheldCompanion'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\ControllerService'), True, True, True);
      exit;
    end
    else
    begin
      if not(checkListBox.checked[profilesCheck]) then
      begin
        if DirExists(ExpandConstant('{userdocs}\{#MyBuildId}\profiles'))  then  
          DelTree(ExpandConstant('{userdocs}\{#MyBuildId}\profiles'), True, True, True);
      end;

      if not(checkListBox.checked[hotkeysCheck]) then
      begin
        if DirExists(ExpandConstant('{userdocs}\{#MyBuildId}\hotkeys'))  then
          DelTree(ExpandConstant('{userdocs}\{#MyBuildId}\hotkeys'), True, True, True);
      end;
      
      if not(checkListBox.checked[applicationSettingsCheck]) then
      begin 
        DelTree(ExpandConstant('{localappdata}\HandheldCompanion'), True, True, True);
        DelTree(ExpandConstant('{localappdata}\ControllerService'), True, True, True);
      end; 
    end;   
                   
    if not(keepHidhideCheckbox.Checked) then
    begin 
      if(ShellExec('', 'msiexec.exe', '/X{27AF679E-48DB-4B49-A689-1D6A3A52C472} /qn /norestart', '', SW_SHOW, ewWaitUntilTerminated, resultCode)) then  
      begin
        log('Successfully executed Hidhide uninstaller');
        if(resultCode = 0) then
          log('Hidhide uninstaller finished successfully')
        else
          log('Hidhide uninstaller failed with exit code ' +intToStr(resultCode));
      end
      else
      begin
        log('Failed to execute Hidhide uninstaller');
      end;
    end; 
           
    if not(keepVigemCheckbox.Checked) then
    begin 
      if(ShellExec('', 'msiexec.exe', '/X{9C581C76-2D68-40F8-AA6F-94D3C5215C05} /qn /norestart', '', SW_SHOW, ewWaitUntilTerminated, resultCode)) then   
      begin
        log('Successfully executed Vigem uninstaller');
        if(resultCode = 0) then
          log('Vigem uninstaller finished successfully')
        else
          log('Vigem uninstaller failed with exit code ' +intToStr(resultCode));
      end
      else
      begin
        log('Failed to execute Vigem uninstaller');
      end;
    end;
  end;
end;
       

procedure InitializeWizard;
begin
  Dependency_InitializeWizard;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := Dependency_PrepareToInstall(NeedsRestart);
end;

function NeedRestart: Boolean;
begin
  Result := Dependency_NeedRestart;
end;

function UpdateReadyMemo(const Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := Dependency_UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo);
end;

function InitializeSetup: Boolean;
begin

#ifdef UseDotNet70
  Dependency_AddDotNet70;
  Dependency_AddDotNet70Desktop;
#endif

#ifdef UseVC2005
  Dependency_AddVC2005;
#endif
#ifdef UseVC2008
  Dependency_AddVC2008;
#endif
#ifdef UseVC2010
  Dependency_AddVC2010;
#endif
#ifdef UseVC2012
  Dependency_AddVC2012;
#endif
#ifdef UseVC2013
  Dependency_AddVC2013;
#endif
#ifdef UseVC2015To2019
  Dependency_AddVC2015To2019;
#endif

#ifdef UseDirectX
  Dependency_AddDirectX;
#endif

#ifdef UseHideHide
  Dependency_AddHideHide;
#endif

#ifdef UseViGem
  Dependency_AddViGem;
#endif

#ifdef UseRTSS
  Dependency_AddRTSS;
#endif

#ifdef UseHWiNFO
  Dependency_AddHWiNFO;
#endif

  Result := True;
end;

#endif
