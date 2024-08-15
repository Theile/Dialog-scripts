#!/bin/zsh

# This is a script to nudge users to update their macOS to the latest version
# it uses the SOFA feed to get the latest macOS version and compares it to the local version
# if the local version is less than the latest version then a dialog is displayed to the user
# if the local version has been out for more than the required_after_days then the dialog is displayed

## update these as required with org specific text
# app domain to store deferral history

# text for the support message


## end of org specific text

autoload is-at-least

computerName=${2:-$(hostname)}
loggedInUser=${3:-$(stat -f%Su /dev/console)}
maxdeferrals=${4:-5}
nag_after_days=${5:-7}
required_after_days=${6:-14}
appdomain=${6:-"com.orgname.macosupdates"}
helpDeskText=${7:-"If you require assistance with this update, please contact the IT Help Desk"}

# get mac hardware info
spData=$(system_profiler SPHardwareDataType)
serialNumber=$(echo $spData | grep "Serial Number" | awk -F': ' '{print $NF}')
modelName=$(echo $spData | grep "Model Name" | awk -F': ' '{print $NF}')

# array of macos major version to friendly name
declare -A macos_major_version
macos_major_version[12]="Monterey 12"
macos_major_version[13]="Ventura 13"
macos_major_version[14]="Sonoma 14"
macos_major_version[15]="Sequioa 15"

# defaults
width="950"
height="570"
days_since_security_release=0
days_since_release=0


# json function for parsing the SOFA feed
json_value() { # Version 2023.7.24-1 - Copyright (c) 2023 Pico Mitchell - MIT License - Full license and help info at https://randomapplications.com/json_value
	{ set -- "$(/usr/bin/osascript -l 'JavaScript' -e 'function run(argv) { let out = argv.pop(); if ($.NSFileManager.defaultManager.fileExistsAtPath(out))' \
		-e 'out = $.NSString.stringWithContentsOfFileEncodingError(out, $.NSUTF8StringEncoding, ObjC.wrap()).js; if (/^\s*[{[]/.test(out)) out = JSON.parse(out)' \
		-e 'argv.forEach(key => { out = (Array.isArray(out) ? (/^-?\d+$/.test(key) ? (key = +key, out[key < 0 ? (out.length + key) : key]) : (key === "=" ?' \
		-e 'out.length : undefined)) : (out instanceof Object ? out[key] : undefined)); if (out === undefined) throw "Failed to retrieve key/index: " + key })' \
		-e 'return (out instanceof Object ? JSON.stringify(out, null, 2) : out) }' -- "$@" 2>&1 >&3)"; } 3>&1
	[ "${1##* }" != '(-2700)' ] || { set -- "json_value ERROR${1#*Error}"; >&2 printf '%s\n' "${1% *}"; false; }
}

dialogCheck() {
	local dialogApp="/Library/Application Support/Dialog/Dialog.app"
	local installedappversion=$(defaults read "${dialogApp}/Contents/Info.plist" CFBundleShortVersionString || echo 0)
	local requiredVersion=0
	if [ ! -z $1 ]; then
		requiredVersion=$1
	fi 

	# Check for Dialog and install if not found
	is-at-least $requiredVersion $installedappversion
	local result=$?
	if [ ! -e "${dialogApp}" ] || [ $result -ne 0 ]; then
		dialogInstall
	else
		echo "Dialog found. Proceeding..."
	fi
}

dialogInstall() {
	# Get the URL of the latest PKG From the Dialog GitHub repo
    local dialogURL=""
    if [[ $majorVersion -ge 13 ]]; then
        # latest version of Dialog for macOS 13 and above
        dialogURL=$(curl --silent --fail -L "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }")
    elif [[ $majorVersion -eq 12 ]]; then
        # last version of Dialog for macOS 12
        dialogURL="https://github.com/swiftDialog/swiftDialog/releases/download/v2.4.2/dialog-2.4.2-4755.pkg"
    else
        # last version of Dialog for macOS 11
        dialogURL="https://github.com/swiftDialog/swiftDialog/releases/download/v2.2.1/dialog-2.2.1-4591.pkg"
    fi
	
	# Expected Team ID of the downloaded PKG
	local expectedDialogTeamID="PWA5E9TQ59"
	
    # Create temporary working directory
    local workDirectory=$( /usr/bin/basename "$0" )
    local tempDirectory=$( /usr/bin/mktemp -d "/private/tmp/$workDirectory.XXXXXX" )
    # Download the installer package
    /usr/bin/curl --location --silent "$dialogURL" -o "$tempDirectory/Dialog.pkg"
    # Verify the download
    local teamID=$(/usr/sbin/spctl -a -vv -t install "$tempDirectory/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()')
    # Install the package if Team ID validates
    if [ "$expectedDialogTeamID" = "$teamID" ] || [ "$expectedDialogTeamID" = "" ]; then
      /usr/sbin/installer -pkg "$tempDirectory/Dialog.pkg" -target /
    else
      # displayAppleScript # uncomment this if you're using my displayAppleScript function
      # echo "Dialog Team ID verification failed."
      # exit 1 # uncomment this if want script to bail if Dialog install fails
    fi
    # Remove the temporary working directory when done
    /bin/rm -Rf "$tempDirectory"  
}

# function to get the icon for the major version
iconForMajorVer() {
    # OS icons gethered from the App Store
    majorversion=$1

    declare -A macosIcon=(
    [14]="https://is1-ssl.mzstatic.com/image/thumb/Purple116/v4/53/7b/21/537b2109-d127-ba55-95da-552ec54b1d7e/ProductPageIcon.png/460x0w.webp"
    [13]="https://is1-ssl.mzstatic.com/image/thumb/Purple126/v4/01/11/29/01112962-0b21-4351-3e51-28dc1d7fe0a7/ProductPageIcon.png/460x0w.webp"
    [12]="https://is1-ssl.mzstatic.com/image/thumb/Purple116/v4/fc/5f/46/fc5f4610-1647-e0bb-197d-a5a447ec3965/ProductPageIcon.png/460x0w.webp"
    [11]="https://is1-ssl.mzstatic.com/image/thumb/Purple116/v4/48/4b/eb/484beb20-2c97-1f72-cc11-081b82b1f920/ProductPageIcon.png/460x0w.webp"
    )
    iconURL=${macosIcon[$majorversion]}

    if [[ -n $iconURL ]]; then
        echo ${iconURL}
    else 
        echo "sf=applelogo"
    fi
}

# function to get the release notes URL
appleReleaseNotesURL() {
    releaseVer=$1
    securityReleaseURL="https://support.apple.com/en-au/HT201222"
    HT201222=$(curl -sL ${securityReleaseURL})
    releaseNotesURL=$(echo $HT201222 | grep "${releaseVer}</a>" | grep "macOS" | sed -r 's/.*href="([^"]+).*/\1/g')
    if [[ -n $releaseNotesURL ]]; then
        echo $releaseNotesURL
    else
        echo $securityReleaseURL
    fi
}

supportsLatestMacOS() {
    # check if the current hardware supports the latest macOS
    local model_id="$(system_profiler SPHardwareDataType | grep "Model Identifier" | awk -F': ' '{print $NF}')"
    # if we are runniing on a model of type that starts with "VirtualMac"  then return true
    if [[ $model_id == "VirtualMac"* ]]; then
        return 0
    fi
    # count of models
    local model_count=$(json_value "OSVersions" "0" "SupportedModels" "=" "$SOFAFeed" 2>/dev/null)
    for ((i=0; i<${model_count}; i++)); do
        model=$(json_value "OSVersions" "0" "SupportedModels" "$i" "Identifiers" "$model_id" "$SOFAFeed" 2>/dev/null)
        if [[ -n $model ]]; then
            return 0
        fi
    done
    return 1
}

latestMacOSVersion() {
    # get the latest version of macOS
    json_value "OSVersions" "0" "Latest" "ProductVersion" "$SOFAFeed" 2>/dev/null
}

# function to display the dialog
runDialog () {
    updateRequired=0
    if [[ $deferrals -gt $maxdeferrals ]] || [[ $days_since_security_release -gt $required_after_days ]]; then
        updateRequired=1
    fi

    macOSVersion="$1"
    majorVersion=$(echo $macOSVersion | cut -d. -f1)
    message="$2"
    helpText="$3"
    jamfbanner="/Users/${loggedInUser}/Library/Application Support/com.jamfsoftware.selfservice.mac/Documents/Images/brandingheader.png"
    if [[ -e "$jamfbanner" ]]; then
        bannerimage=$jamfbanner
    else    
        bannerimage="colour=red"
    fi
    title="macOS Update Available"
    titlefont="shadow=1"
    macosIcon=$(iconForMajorVer $majorVersion)
    infotext="Apple Security Release Info"
    infolink=$(appleReleaseNotesURL $macOSVersion)
    icon=${$(defaults read /Library/Preferences/com.jamfsoftware.jamf self_service_app_path 2>/dev/null):-"sf=applelogo"}
    button1text="Open Software Update"
    button1ction="open -b com.apple.systempreferences /System/Library/PreferencePanes/SoftwareUpdate.prefPane"
    button2text="Remind Me Tomorrow"
    blurscreen=""

    if [[ $updateRequired -eq 1 ]]; then
        button2text="Update Now"
        if [[ $deferrals -gt $(( $maxdeferrals )) ]]; then
            blurscreen="--blurscreen"
        fi
    fi

    /usr/local/bin/dialog -p -o -d \
                --height ${height} \
                --width ${width} \
                --title "${title}" \
                --titlefont ${titlefont} \
                --bannerimage "${bannerimage}" \
                --bannertitle \
                --bannerheight 100 \
                --overlayicon "${macosIcon}" \
                --iconsize 160 \
                --icon "${icon}" \
                --message "${message}" \
                --infobuttontext "${infotext}" \
                --infobuttonaction "${infolink}" \
                --button1text "${button1text}" \
                --button2text "${button2text}" \
                --helpmessage "${helpText}" \
                ${blurscreen}
    exitcode=$?

    if [[ $exitcode == 0 ]]; then
        updateselected=1
    elif [[ $exitcode == 2 ]] && [[ $updateRequired == 1 ]]; then
        updateselected=1
  	elif [[ $exitcode == 3 ]]; then
  		updateselected=1
    fi

    # update the deferrals count
    if [[ $exitcode -lt 10 ]]; then
        deferrals=$(( $deferrals + 1 ))
        defaults write ${appdomain} ${defarralskey} -int ${deferrals}
    fi

    # open software update
    if [[ $updateselected -eq 1 ]]; then
        if [[ $majorVersion -ge 14 ]]; then
            open "x-apple.systempreferences:com.apple.preferences.softwareupdate"
        else
            /usr/bin/open -b com.apple.systempreferences /System/Library/PreferencePanes/SoftwareUpdate.prefPane
        fi 
    fi
}

function incrementHeightByLines() {
    local lineHeight=28
    local lines=${1:-1}
    local newHeight=$(( $height + $lines * $lineHeight ))
    echo $newHeight
}

# check dialog is installed and up to date
dialogCheck

# get the latest data from SOFA feed
SOFAFeed=$(curl -s --compressed "https://sofafeed.macadmins.io/v1/macos_data_feed.json")

if [[ -z $SOFAFeed ]]; then
    echo "Failed to get SOFA feed"
    exit 1
fi

# get the locally installed version of macOS
local_version=$(sw_vers -productVersion)
local_version_major=$(echo $local_version | cut -d. -f1)
local_version_name=${macos_major_version[$local_version_major]}
update_required=false

# loop through feed count and match on local version
feed_count=$(json_value "OSVersions" "=" "$SOFAFeed" 2>/dev/null)
feed_index=0
for ((i=0; i<${feed_count}; i++)); do
    feed_version_name=$(json_value "OSVersions" "$i" "OSVersion" "$SOFAFeed" 2>/dev/null)
    if [[ $feed_version_name == $local_version_name ]]; then
        feed_index=$i
        break
    fi
done

# get the count of security releases for the locally installed release of macOS
security_release_count=$(json_value "OSVersions" "$feed_index" "SecurityReleases" "=" "$SOFAFeed" 2>/dev/null)

# get the latest version of macOS for the installed release which will be the first item in the security releases array
latest_version=$(json_value "OSVersions" "$feed_index" "SecurityReleases" "0" "ProductVersion" "$SOFAFeed" 2>/dev/null)
latest_version_release_date=$(json_value "OSVersions" "$feed_index" "SecurityReleases" "0" "ReleaseDate" "$SOFAFeed" 2>/dev/null)

# get the number of days since the release date
release_date=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$latest_version_release_date " "+%s" 2>/dev/null)
current_date=$(date "+%s")

# get the required by date and the number of days since release
requiredby=$(date -j -v+${required_after_days}d -f "%s" "$release_date" "+%B %d, %Y" 2>/dev/null)
days_since_release=$(( (current_date - release_date) / 86400 ))

# get the deferrals count
defarralskey="deferrals_${latest_version}"
deferrals=$(defaults read ${appdomain} ${defarralskey} || echo 0)

# check if the latest version is greater than the local version
if is-at-least $local_version $latest_version; then
    # if the number of days since release is greater than the nag_after_days then we need to nag
    if [[ $days_since_release -ge $nag_after_days ]]; then
        update_required=true
    fi
fi

# loop through security releases to find the one that matches the locally installed version of macOS
security_index=0
for ((i=0; i<${security_release_count}; i++)); do
    security_version=$(json_value "OSVersions" "$feed_index" "SecurityReleases" "$i" "ProductVersion" "$SOFAFeed" 2>/dev/null)
    if [[ $security_version == $local_version ]]; then
        security_index=$i
        break
    fi
done

# get the security release date
security_release_date=$(json_value "OSVersions" "$feed_index" "SecurityReleases" "$security_index" "ReleaseDate" "$SOFAFeed" 2>/dev/null)
days_since_security_release=$(( (current_date - $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$security_release_date" "+%s" 2>/dev/null)) / 86400 ))

# get the number of CVEs and actively exploited CVEs
security_CVEs=$(json_value "OSVersions" "$feed_index" "SecurityReleases" "$security_index" "CVEs" "=" "$SOFAFeed" 2>/dev/null)
security_ActivelyExploitedCVEs_count=$(json_value "OSVersions" "$feed_index" "SecurityReleases" "$security_index" "ActivelyExploitedCVEs" "=" "$SOFAFeed" 2>/dev/null)

# if the cve count is greater than 0 then we need to update regardless of the days since release
if [[ $security_ActivelyExploitedCVEs_count -gt 0 ]]; then
    update_required=true
fi

# if the number of days since the instaled version was released is greater than the required after days then we need to update
if [[ $days_since_security_release -ge $required_after_days ]]; then
    update_required=true
fi

# build dialog message
if [[ $security_ActivelyExploitedCVEs_count -gt 0 ]]; then
    supportText="**_There are currently $security_ActivelyExploitedCVEs_count actively exploited CVEs for macOS ${local_version}_**<br>**You must update to the latest version**"
    height=$(incrementHeightByLines 2)
else
    if [[ $days_since_security_release -ge $required_after_days ]]; then
        supportText="This update is required to be applied immediately"
    else
        supportText="This update is required to be applied before ${requiredby}"
    fi
    height=$(incrementHeightByLines 1)
fi

# check if the latest version from latestMacOSVersion is supported on the current hardware 
current_macos_version_major=$(latestMacOSVersion | cut -d. -f1)
if [[ $local_version_major -lt $current_macos_version_major ]] && supportsLatestMacOS; then
    additionalText="macOS ${current_macos_version_major} is available for install and supported on this device.  Please update to the latest OS release at your earliest convenience"
    height=$(incrementHeightByLines 2)
elif ! supportsLatestMacOS; then
    additionalText="**Your device does not support macOS ${current_macos_version_major}**  <br>Support for this device has ended"
    height=$(incrementHeightByLines 2)
fi

message="## **macOS ${latest_version}** is available for install

Your ${modelName} \"${computerName}\" is running macOS version ${local_version}.<br>It has been **${days_since_security_release}** days since the last time the OS was updated.

It is important that you update to **${latest_version}** at your earliest convenience.  <br>
 - Click the Security Release button for more details or the help button for device info.

**Your swift attention to applying this update is appreciated**

### **Security Information**

${supportText}

${additionalText}

You have deferred this update request **${deferrals}** times."

# build help message with device info and service desk contact details
helpText="### Device Information<br><br> \
  - Computer Name: ${computerName}  <br> \
  - Model: ${modelName}  <br> \
  - Serial Number: ${serialNumber}  <br> \
  - Installed macOS Version: ${local_version}  <br> \
  - Latest available Version: ${latest_version}  <br> \
  - Release Date: $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$latest_version_release_date " "+%B %d, %Y" 2>/dev/null)  <br> \
  - Days Since Release: ${days_since_release}  <br> \
  - Required By: ${requiredby}  <br> \
  - Deferrals: ${deferrals} of ${maxdeferrals}  <br> \
  - Security CVEs: ${security_CVEs}  <br> \
  - Actively Exploited CVEs: ${security_ActivelyExploitedCVEs_count}  <br> \
  - Update Required: ${update_required}  <br> \
<br><br> \
### Service Desk Contact<br><br> \
${helpDeskText}"

# if the update is required then display the dialog
# also echo to stdout so info is captured by jamf
if [[ $update_required == true ]]; then
    echo "Update required: $latest_version is available for $local_version_name"
    echo "Release date: $latest_version_release_date "
    echo "Days since release of $latest_version: $days_since_release"
    echo "Days since release of $local_version : $days_since_security_release"
    echo "There are $security_ActivelyExploitedCVEs_count actively exploited CVEs for $local_version"

    runDialog $latest_version "$message" "$helpText"
else
    echo "No update required:"
    echo "Latest version: $latest_version"
    echo "Local version: $local_version"
    echo "Release date: $latest_version_release_date "
    if [[ $days_since_release -lt $nag_after_days ]]; then
        echo "Days since release: $days_since_release"
        echo "Nag starts after: $nag_after_days days"
    fi
fi
