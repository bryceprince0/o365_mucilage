﻿Import-Module ActiveDirectory;
Import-Module -Force 'C:\cron\creds.psm1';
$ErrorActionPreference = "Stop";

Function Log {
   Param ([string]$logstring)
   Add-content "C:\cron\directory_wrangler.log" -value $("{0} ({1} - {2}): {3}" -f $(Get-Date), $(GCI $MyInvocation.PSCommandPath | Select -Expand Name), $pid, $logstring);
}

try {
    # Store the domain max password age in days.
    $DefaultmaxPasswordAgeDays = (Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge.Days;

    # get all the mailbox records (local Mailboxes and Office 365 RemoteMailboxes)
    $mailboxes = $(Get-Mailbox -ResultSize unlimited | select userprincipalname, primarysmtpaddress, recipienttypedetails) + $(Get-RemoteMailbox -ResultSize unlimited | select userprincipalname, primarysmtpaddress, recipienttypedetails);
    $mailboxes | convertto-json > 'C:\cron\mailboxes.json';
    
    # read the full user DB from OIM CMS. 
    $users = Invoke-RestMethod ("{0}?all" -f $user_api) -WebSession $oimsession;
    # do a workaround to vault PowerShell's dumb 10mb JSON limit
    if (-not $users.objects) {
        [void][System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions");
        $json = New-Object -TypeName System.Web.Script.Serialization.JavaScriptSerializer;
        $json.MaxJsonLength = 104857600;
        $users = $json.Deserialize($users, [System.Object]);
    }
    
    # user object attributes we care about
    $keynames = @("Title", "DisplayName", "GivenName", "Surname", "Company", "physicalDeliveryOfficeName", "StreetAddress", "Division", "Department", "Country", "State",
        "wWWHomePage", "Manager", "EmployeeID", "EmployeeNumber", "HomePhone", "telephoneNumber", "Mobile", "Fax");
    $adprops = $keynames + @("EmailAddress", "UserPrincipalName", "Modified", "AccountExpirationDate", "Info", "pwdLastSet");
    
    # read the user list from AD. apply a rough filter for accounts we want to load into OIM CMS:
    # - email address is *.wa.gov.au or dpaw.onmicrosoft.com
    # - has both a first name and surname
    # - DN contains a sub-OU called "Users"
    # - DN does not contain a sub-OU with "Administrators" in the name
    $adusers = Get-ADUser -server $adserver -Filter {EmailAddress -like "*@*wa.gov.au" -and Surname -ne $false} -Properties $adprops | where distinguishedName -Like "*OU=Users*" | where distinguishedName -NotLike "*Administrators*";
    $adusers += Get-ADUser -server $adserver -Filter {EmailAddress -like "*@dpaw.onmicrosoft.com"} -Properties $adprops;
    Log $("Processing {0} users" -f $adusers.Length);

    # If an AD user doesn't exist in OIM CMS, load the data from current AD record in via the REST API
    ForEach ($aduser in $adusers | where { $_.EmailAddress -notin $users.objects.email }) {
        $simpleuser = $aduser | select ObjectGUID, DistinguishedName, Name, Title, SamAccountName, GivenName, Surname, EmailAddress, Modified, Enabled, AccountExpirationDate, pwdLastSet;
        $simpleuser.Modified = Get-Date $aduser.Modified -Format s;
        if ($aduser.AccountExpirationDate) { 
            $simpleuser.AccountExpirationDate = Get-Date $aduser.AccountExpirationDate -Format s;
        }
        $simpleuser | Add-Member -type NoteProperty -name PasswordMaxAgeDays -value $DefaultmaxPasswordAgeDays;
        $userjson = $simpleuser | ConvertTo-Json;
        (Invoke-RestMethod $user_api -Body $userjson -Method Post -ContentType "application/json" -Verbose -WebSession $oimsession).ad_data;
    }

    # for each OIM CMS DepartmentUser
    foreach ($user in $users.objects) {
        # find the equivalent Active Directory Object
        $aduser = $adusers | where EmailAddress -like $($user.email);
        If ($aduser) {
            # if the OIM CMS user object was modified in the last hour
            if (($(Get-Date) - (New-TimeSpan -Minutes 60)) -lt $(Get-Date $user.date_updated) -and ($aduser.Modified -lt $(Get-Date $user.date_updated))) {
                # set all the properties on the AD object to match the OIM CMS object
                $aduser.Title = $user.title;
                $aduser.DisplayName, $aduser.GivenName, $aduser.Surname = $user.name, $user.given_name, $user.surname;
                $aduser.Company = $user.org_data.cost_centre.code;
                $aduser.physicalDeliveryOfficeName = $user.org_unit__location__name;
                $aduser.StreetAddress = $user.org_unit__location__address;
                if ($user.org_data.units) {
                    $aduser.Division = $user.org_data.units[1].name;
                    $aduser.Department = $user.org_data.units[0].name; 
                }
                $aduser.Country, $aduser.State = "AU", "Western Australia";
                $aduser.wWWHomePage = "https://oim.dpaw.wa.gov.au/userinfo?email=" + $user.email;
                $aduser.EmployeeNumber, $aduser.EmployeeID = $user.employee_id, $user.employee_id;
                $aduser.telephoneNumber, $aduser.Mobile = $user.telephone, $user.mobile_phone;
                $aduser.Fax = $user.org_unit__location__fax;
                if ($user.parent__email -ne ($adusers | where distinguishedname -like $aduser.Manager).emailaddress) {
                    $aduser.Manager = ($adusers | where emailaddress -like $($user.parent__email)).DistinguishedName;
                }
                # make all of the undefined properties the string "N/A"
                foreach ($prop in $aduser.ModifiedProperties) { 
                    if ((-not $aduser.$prop) -and ($prop -notlike "manager")) {
                        $aduser.$prop = "N/A";
                    } 
                }
                # push changes back to AD
                try {
                    Set-ADUser -verbose -server $adserver -instance $aduser;
                    # thumbnailPhoto isn't added as a property of $aduser for some dumb reason, so we have to push it seperately
                    #if ($user.photo_ad -and $user.photo_ad.startswith('http')) {
                    #    Set-ADUser -verbose -server $adserver $aduser -replace @{thumbnailPhoto=$(Invoke-WebRequest $user.photo_ad -WebSession $oimsession).content};
                    #}

                } catch [System.Exception] {
                    Log $("ERROR: set-aduser failed on {0}" -f $user.email);
                    Log $($aduser | select $($aduser.ModifiedProperties) | convertto-json);
                    $except = $_;
                    Log $($except | convertto-json);
                }
            }
            # if the AD object was modified after the OIM CMS object
            if ($aduser.Modified -gt $(Get-Date $user.ad_data.Modified)) {
                # find the mailbox object
                $mb = $mailboxes | where userprincipalname -like $user.email;
                # glom the mailbox object onto the AD object
                $simpleuser = $aduser | select ObjectGUID, @{name="mailbox";expression={$mb}}, @{name="Modified";expression={Get-Date $_.Modified -Format s}}, info, DistinguishedName, Name, Title, SamAccountName, GivenName, Surname, EmailAddress, Enabled, AccountExpirationDate, pwdLastSet;
                $simpleuser | Add-Member -type NoteProperty -name PasswordMaxAgeDays -value $DefaultmaxPasswordAgeDays;
                if ($aduser.AccountExpirationDate) { 
                    $simpleuser.AccountExpirationDate = Get-Date $aduser.AccountExpirationDate -Format s;
                }
                # convert the whole lot to JSON and push to OIM CMS
                $userjson = [System.Text.Encoding]::UTF8.GetBytes($($simpleuser | ConvertTo-Json));
                try {
                    $ad_data = (Invoke-RestMethod $user_api -Body $userjson -Method Post -ContentType "application/json" -WebSession $oimsession).ad_data;
                } catch [System.Exception] {
                    Log $("ERROR: update cms failed on {0}" -f $user.email);
                    Log $($simpleuser | ConvertTo-Json);
                }
            }
        } 

        # if user is enabled, update AD data field in OIM CMS
        if ((-not $aduser) -or ($aduser.enabled -eq $false)) {
            if (-not $user.ad_deleted) {
                $userjson = [System.Text.Encoding]::UTF8.GetBytes($(@{EmailAddress = $user.email;Deleted = $true} | convertto-json));
                $ad_data = (Invoke-RestMethod $user_api -Body $userjson -Method Post -ContentType "application/json" -Verbose -WebSession $oimsession).ad_data;
            }
        }
    }

    # we've done a whole pile of AD changes, so now's a good time to run AADSync to push them to O365
    Log "Azure AD Connect Syncing with O365";
    Start-ADSyncSyncCycle -PolicyType Delta;
    # this command is not blocking, and the new AAD Connect API is crap at polling for activity
    # so let's just block for 60 seconds!
    Start-Sleep -s 60;

    # finally, we want to do some operations on Office 365 accounts not handled by AADSync
    # start by reading the full user list 
    $msolusers = get-msoluser -all | select userprincipalname, lastdirsynctime, @{name="licenses";expression={[string]$_.licenses.accountskuid}}, signinname, immutableid, whencreated, displayname, firstname, lastname;
    $msolusers | convertto-json > 'C:\cron\msolusers.json';

    # rig the UPN for each user account so that it matches the primary SMTP address.
    foreach ($aduser in $adusers | where {$_.emailaddress -ne $_.userprincipalname}) {
        $immutableid = [System.Convert]::ToBase64String($aduser.ObjectGuid.toByteArray());
        $msoluser = $msolusers | where immutableid -eq $immutableid;
        If ($msoluser) {
            Set-MsolUserPrincipalName -UserPrincipalName $msoluser.UserPrincipalName -NewUserPrincipalName $aduser.emailaddress -Verbose;
            Set-ADUser $aduser -UserPrincipalName $aduser.emailaddress -Verbose;
        } Else {
            Log $("Warning: MSOL object not found for {0}" -f $aduser.UserPrincipalName);
        }
    }

    # for each Exchange Online mailbox that doesn't have it, add an archive mailbox
    $mailboxes | where recipienttypedetails -like remoteusermailbox | where { $_.archivestatus -eq "None" } | foreach { 
        Enable-RemoteMailbox -Identity $_.userprincipalname -Archive;
    }

    # for each Exchange Online mailbox where it doesn't match, set the PrimarySmtpAddress to match the UserPrincipalName
    $mailboxes | where recipienttypedetails -like remoteusermailbox | where { $_.userprincipalname -ne $_.primarysmtpaddress } | foreach { 
        Set-RemoteMailbox $_.userprincipalname -PrimarySmtpAddress $_.userprincipalname -EmailAddressPolicyEnabled $false -Verbose;
    }
    
    # for each "In cloud" user in Azure AD which is licensed
    ForEach ($msoluser in $msolusers | where lastdirsynctime -eq $null | where licenses) {
        $username = $msoluser.FirstName + $msoluser.LastName;
        $username = $username.Substring(0,[System.Math]::Min(15, $username.Length));
        # link existing users
        $upn = $msoluser.UserPrincipalName;
        $existing = Get-ADUser -Filter { UserPrincipalName -like $upn };
        if ($existing) {
            $immutableid = [System.Convert]::ToBase64String($existing.ObjectGUID.tobytearray());
            Set-MsolUser -UserPrincipalName $upn -ImmutableId $immutableid;
            continue;
        }
        # Create new user
        Log $("About to create O365 user: New-ADUser $username -Verbose -Path `"OU=Users,OU=DPaW,dc=corporateict,dc=domain`" -Enabled $true -UserPrincipalName $($msoluser.UserPrincipalName) -EmailAddress $($msoluser.UserPrincipalName) -DisplayName $($msoluser.DisplayName) -GivenName $($msoluser.FirstName) -Surname $($msoluser.LastName) -PasswordNotRequired $true");
        New-ADUser $username -Verbose -Path "OU=Users,OU=DPaW,dc=corporateict,dc=domain" -Enabled $true -UserPrincipalName $msoluser.UserPrincipalName -EmailAddress $msoluser.UserPrincipalName -DisplayName $msoluser.DisplayName -GivenName $msoluser.FirstName -Surname $msoluser.LastName -PasswordNotRequired $true;
        # wait for changes to propagate
        sleep 10;
        Set-ADUser -Identity $username -Add @{'proxyAddresses'='SMTP:'+$msoluser.UserPrincipalName};
        # add remotemailbox object, RemoteRoutingAddress starts out wrong! needs to be fixed to dpaw.mail.onmicrosoft.com, once proxyaddresses updates
        Enable-RemoteMailbox -Identity $msoluser.UserPrincipalName -PrimarySmtpAddress $msoluser.UserPrincipalName -RemoteRoutingAddress $msoluser.UserPrincipalName;
    }

    # quick loop to fix RemteRoutingAddress; previously some RemoteMailbox objects were provisioned manually with the wrong one
    ForEach ($mb in Get-RemoteMailbox -ResultSize Unlimited | Where {-not ($_.RemoteRoutingAddress -like "*@dpaw.mail.onmicrosoft.com" )}) {
        $remote = $mb.EmailAddresses.SmtpAddress | Where {$_ -like "*@dpaw.mail.onmicrosoft.com"} | Select -First 1;
        If ($remote) {
            $mb | Set-RemoteMailbox -RemoteRoutingAddress $remote;
        }
    }

    Log "Finished";
} catch [System.Exception] {
    Log "ERROR: Exception caught, dying =(";
    $except = $_;
    Log $($except | convertto-json);
}

# cleanup
Get-PSSession | Remove-PSSession;