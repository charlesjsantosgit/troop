Unicode True
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!ifndef APP_VERSION
  !error "APP_VERSION was not supplied"
!endif
!ifndef FILE_VERSION
  !error "FILE_VERSION was not supplied"
!endif
!ifndef GAME_EXE
  !error "GAME_EXE was not supplied"
!endif
!ifndef GAME_PCK
  !error "GAME_PCK was not supplied"
!endif
!ifndef GODOT_LICENSE
  !error "GODOT_LICENSE was not supplied"
!endif
!ifndef PLAYER_README
  !error "PLAYER_README was not supplied"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE was not supplied"
!endif

!define APP_NAME "TROOP"
!define APP_PUBLISHER "Charles Santos"
!define APP_REG_KEY "Software\TROOP"
!define UNINSTALL_REG_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\TROOP"

Name "${APP_NAME}"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
InstallDirRegKey HKCU "${APP_REG_KEY}" "InstallDir"
RequestExecutionLevel user
BrandingText "TROOP ${APP_VERSION}"
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${FILE_VERSION}"
VIAddVersionKey /LANG=1033 "ProductName" "${APP_NAME}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1033 "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=1033 "FileDescription" "TROOP installer"
VIAddVersionKey /LANG=1033 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright 2026 Charles Santos"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\TROOP.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Play TROOP"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext current
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "TROOP requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd

Section "TROOP" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"

  File "/oname=TROOP.exe" "${GAME_EXE}"
  File "/oname=TROOP.pck" "${GAME_PCK}"
  File "/oname=GODOT_LICENSE.txt" "${GODOT_LICENSE}"
  File "/oname=README.txt" "${PLAYER_README}"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\TROOP"
  CreateShortcut "$SMPROGRAMS\TROOP\TROOP.lnk" "$INSTDIR\TROOP.exe" "" "$INSTDIR\TROOP.exe" 0
  CreateShortcut "$SMPROGRAMS\TROOP\Uninstall TROOP.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\TROOP.lnk" "$INSTDIR\TROOP.exe" "" "$INSTDIR\TROOP.exe" 0

  WriteRegStr HKCU "${APP_REG_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayIcon" "$INSTDIR\TROOP.exe"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "QuietUninstallString" "$\"$INSTDIR\Uninstall.exe$\" /S"
  WriteRegDWORD HKCU "${UNINSTALL_REG_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_REG_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current

  Delete "$DESKTOP\TROOP.lnk"
  Delete "$SMPROGRAMS\TROOP\TROOP.lnk"
  Delete "$SMPROGRAMS\TROOP\Uninstall TROOP.lnk"
  RMDir "$SMPROGRAMS\TROOP"

  Delete "$INSTDIR\TROOP.exe"
  Delete "$INSTDIR\TROOP.pck"
  Delete "$INSTDIR\GODOT_LICENSE.txt"
  Delete "$INSTDIR\README.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "${UNINSTALL_REG_KEY}"
  DeleteRegKey HKCU "${APP_REG_KEY}"
SectionEnd
