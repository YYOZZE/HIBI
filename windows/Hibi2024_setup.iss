; 与桌面交付脚本一致；快捷方式：中文 UI → 希比-2023，否则 → hibi-2023

#define MyAppName "希比-2023"
#define MyAppNameEn "hibi-2023"
#define MyAppVersion "3.0.14"
#define MyAppPublisher "Tsingcoop"
#define MyAppExeName "jideshi_hibi.exe"
#define SourceDir "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\HIBI-2023\build\windows\x64\runner\Release"
#define AppIcon "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\HIBI-2023\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{A7E3B2C1-D4F5-6789-ABCD-EF0123456789}
AppName=hibi-2023
AppVersion={#MyAppVersion}
AppVerName=hibi-2023 {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppNameEn}
DefaultGroupName=hibi-2023
OutputDir=c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\HIBI-2023\release\V3.0.14
OutputBaseFilename=Hibi2023_Setup_{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
ChangesAssociations=yes
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\HIBI-2023\assets\icons\hbm_file_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Registry]
; 注册 HIBI 思维节点文件，双击 .hbm 时把文件路径作为启动参数传给应用。
Root: HKCR; Subkey: ".hbm"; ValueType: string; ValueName: ""; ValueData: "HibiMindNode"; Flags: uninsdeletevalue
Root: HKCR; Subkey: "HibiMindNode"; ValueType: string; ValueName: ""; ValueData: "HIBI 思维节点"; Flags: uninsdeletekey
Root: HKCR; Subkey: "HibiMindNode\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\hbm_file_icon.ico,0"
Root: HKCR; Subkey: "HibiMindNode\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Icons]
Name: "{autoprograms}\希比-2023"; Filename: "{app}\{#MyAppExeName}"; Check: IsChineseUI
Name: "{autodesktop}\希比-2023"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; Check: IsChineseUI
Name: "{autoprograms}\hibi-2023"; Filename: "{app}\{#MyAppExeName}"; Check: not IsChineseUI
Name: "{autodesktop}\hibi-2023"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; Check: not IsChineseUI

[Run]
; 与 LANDrop 同类局域网工具一致，安装时按程序放行局域网 TCP/UDP。
; 规则绑定 exe 路径，不固定接收端口，因此端口自动回退后仍然有效。
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""HIBI File Transfer In"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""HIBI File Transfer Out"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""HIBI File Transfer In"" dir=in action=allow program=""{app}\{#MyAppExeName}"" enable=yes profile=private,public"; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""HIBI File Transfer Out"" dir=out action=allow program=""{app}\{#MyAppExeName}"" enable=yes profile=private,public"; Flags: runhidden waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "Launch 希比-2023"; Flags: nowait postinstall skipifsilent; Check: IsChineseUI
Filename: "{app}\{#MyAppExeName}"; Description: "Launch hibi-2023"; Flags: nowait postinstall skipifsilent; Check: not IsChineseUI

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""HIBI File Transfer In"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveHibiFirewallIn"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""HIBI File Transfer Out"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveHibiFirewallOut"

[Code]
function GetUserDefaultUILanguage: Cardinal; external 'GetUserDefaultUILanguage@kernel32.dll stdcall';

function IsChineseUI: Boolean;
var
  LangId: Cardinal;
begin
  LangId := GetUserDefaultUILanguage;
  Result := (LangId and $03FF) = $04;
end;
