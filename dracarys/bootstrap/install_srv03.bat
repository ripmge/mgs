netsh interface ipv4 set address name="Ethernet" static 192.168.10.13 255.255.255.0 192.168.10.1
netsh interface ipv4 set dns name="Ethernet" static 8.8.8.8

:: Disable Windows Firewall
NetSh Advfirewall set allprofiles state off

:: 2. Disable IE Enhanced Security Configuration (IE ESC)
:: For Administrators
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" /v "IsInstalled" /t REG_DWORD /d 0 /f
:: For Users
reg add "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" /v "IsInstalled" /t REG_DWORD /d 0 /f

:: Configure WinRM for Ansible Management
cmd /c "winrm quickconfig -q"
cmd /c "winrm set winrm/config/service @{AllowUnencrypted=\"true\"}"
cmd /c "winrm set winrm/config/service/auth @{Basic=\"true\"}"
cmd /c "winrm set winrm/config/listener?Address=*+Transport=HTTP @{Port=\"5985\"}"

:: Output success signal
echo GOAD Bootstrap Complete > C:\bootstrap.log