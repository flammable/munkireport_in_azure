#!/bin/bash

# Requirements:
# 1. Install Xcode, or possibly Apple's command-line tools.
# 2. Install the 'az' command via Homebrew: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-macos
# 3. We're using Azure for SSO, so the configuration below reflects that: https://github.com/munkireport/munkireport-php/wiki/Azure-AD-setup
# Please adjust accordingly if your environment is different.

# Resources:
# https://markheath.net/post/wordpress-container-app-service
# https://docs.microsoft.com/en-us/cli/azure/reference-index?view=azure-cli-latest

echo="/bin/echo"
open="/usr/bin/open"
sleep="/bin/sleep"
uname="/usr/bin/uname"

# Homebrew installs the 'az' command at different paths if you're running Apple Silicon vs. Intel:
processor_type=$(${uname} -m)

if [ "${processor_type}" == "arm64" ]; then
 az="/opt/homebrew/bin/az"
else
 az="/usr/local/bin/az"
fi

if [ ! -e "${az}" ]; then
 ${echo} "Error: Please install the az command-line tool to proceed."
 exit 1
fi

##########################################################################################
# EDIT THIS SECTION FIRST
##########################################################################################

app_name=""

subscription=""
location="eastus"

# https://azure.microsoft.com/en-us/pricing/details/app-service/windows/
app_service_plan_sku="P1V2"

# https://azure.microsoft.com/en-us/pricing/details/mysql/flexible-server/
mysql_sku="Standard_B2s"
mysql_storage_size="32"

# https://docs.microsoft.com/en-us/rest/api/storagerp/srp_sku_types
# https://azure.microsoft.com/en-us/pricing/details/storage/blobs/
# https://azure.microsoft.com/en-us/pricing/details/managed-disks/
storage_sku="Standard_LRS"

# Password must adhere to Azure's complexity requirements:
# Your password must be at least 8 characters and at most 128 characters.
# Your password must contain characters from three of the following categories – English uppercase letters, English lowercase letters, numbers (0-9), and non-alphanumeric characters (!, $, #, %, etc.).
# Your password cannot contain all or part of the login name. Part of a login name is defined as three or more consecutive alphanumeric characters.
mysql_admin_user=""
mysql_admin_password=""

mysql_version="5.7"
docker_image="ghcr.io/munkireport/munkireport-php:v5.7.1"
docker_mount_path="/var/munkireport/local"

# Make sure you've set a CNAME for this in DNS
custom_hostname=""
pfx_path=""
pfx_password=""

##########################################################################################
# STOP HERE - RESUME EDITING BELOW
##########################################################################################

# Adhering to Azure naming convention where possible:
# https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations

resource_group="rg-""${app_name}"
plan_name="plan-""${app_name}""${RANDOM}"
mysql_server_name="mysql-""${app_name}""${RANDOM}"
mysql_database="db-""${app_name}""${RANDOM}"
webapp_name="ase-""${app_name}"
storage_customid="st-""${app_name}""${RANDOM}"
storage_accountname="st""${app_name}""${RANDOM}"
share_name="${app_name}"

# Make sure we're logged into Azure
${az} login

# Set correct Azure account
${az} account set --subscription "${subscription}"

# Create a Resource Group - this succeeds if it already exists
${az} group create --location "${location}" --name "${resource_group}"

# Create an App Service Plan to host our App Service
${az} appservice plan create --name "${plan_name}" --resource-group "${resource_group}" --location "${location}" --is-linux --sku "${app_service_plan_sku}"

# Create MySQL server and database
${az} mysql flexible-server create --resource-group "${resource_group}" --name "${mysql_server_name}" --admin-user "${mysql_admin_user}" --admin-password "${mysql_admin_password}" --location "${location}" --sku-name "${mysql_sku}" --version "${mysql_version}" --public-access 0.0.0.0 --storage-size "${mysql_storage_size}" --database-name "${mysql_database}"

# Create Azure App Service
${az} webapp create --name "${webapp_name}" --resource-group "${resource_group}" --plan "${plan_name}" --deployment-container-image-name "${docker_image}" --https-only true

# Set custom hostname
${az} webapp config hostname add --webapp-name "${webapp_name}" --resource-group "${resource_group}" --hostname "${custom_hostname}"

# Upload the SSL certificate and get the thumbprint
thumbprint=$(${az} webapp config ssl upload --certificate-file "${pfx_path}" --certificate-password "${pfx_password}" --name "${webapp_name}" --resource-group "${resource_group}" --query thumbprint --output tsv)

# Bind the uploaded SSL certificate to the App Service
${az} webapp config ssl bind --certificate-thumbprint "${thumbprint}" --ssl-type SNI --name "${webapp_name}" --resource-group "${resource_group}"

# Determine the FQDN for the MySQL host
mysqldbhost=$(${az} mysql flexible-server show --resource-group "${resource_group}" --name "${mysql_server_name}" --query "fullyQualifiedDomainName" --output tsv)

##########################################################################################
# EDIT THIS SECTION SECOND
##########################################################################################

# Configure environment variables for the App Service
# Reference: https://github.com/munkireport/munkireport-php/wiki/.env-Settings

# TODO: move this to a json file so we can import that instead, since it's probably not possible to move this to the top
# Stupid bug from 2020: https://github.com/Azure/azure-cli/issues/14405
# Workaround: https://gist.github.com/zboldyga/8f51868c7b1d7269bb2679fb036d4995

${az} webapp config appsettings set --name "${webapp_name}" --resource-group "${resource_group}" --subscription "${subscription}" --settings \
    CONNECTION_DRIVER=mysql \
    CONNECTION_HOST="${mysqldbhost}" \
    CONNECTION_PORT=3306 \
    CONNECTION_DATABASE="${mysql_database}" \
    CONNECTION_USERNAME="${mysql_admin_user}" \
    CONNECTION_PASSWORD="${mysql_admin_password}" \
    CONNECTION_CHARSET=utf8mb4 \
    CONNECTION_COLLATION=utf8mb4_unicode_ci \
    CONNECTION_STRICT=TRUE \
    CONNECTION_ENGINE=InnoDB \
    CONNECTION_SSL_ENABLED=TRUE \
    CONNECTION_SSL_CA="/var/munkireport/local/certs/DigiCertGlobalRootCA.crt.pem" \
    INDEX_PAGE="" \
    SITENAME="MunkiReport" \
    HIDE_INACTIVE_MODULES=TRUE \
    AUTH_METHODS=SAML \
    AUTH_SAML_SP_NAME_ID_FORMAT=urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress \
    AUTH_SAML_IDP_ENTITY_ID=PLACEHOLDER \
    AUTH_SAML_IDP_SSO_URL=PLACEHOLDER \
    AUTH_SAML_IDP_SLO_URL=PLACEHOLDER \
    AUTH_SAML_USER_ATTR=http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name \
    AUTH_SAML_SECURITY_REQUESTED_AUTHN_CONTEXT=FALSE \
    ROLES_ADMIN="username@domain.tld" \
    ROLES_ARCHIVER="*" \
    AUTH_SECURE=TRUE \
    VNC_LINK="vnc://%s:5900" \
    SSH_LINK="ssh://YOURADMINUSERNAMEHERE@%s" \
    FONTS_SYSTEM=FALSE \
    MODULES='nudge, applications, appusage, ard, bluetooth, certificate, directory_service, disk_report, displays_info, extensions, filevault_status, firewall, gpu, ibridge, installhistory, inventory, managedinstalls, mdm_status, munki_facts, munkiinfo, munkireport, munkireportinfo, network, network_shares, power, printer, profile, security, smart_stats, softwareupdate, supported_os, timemachine, usage_stats, usb, user_sessions, users, wifi' \
    CLIENT_DETAIL_WIDGETS="machine_info_1, machine_info_2, storage_detail, hardware_detail, software_detail, ard, mdm_status_detail, network_detail, users_detail, security_detail, bluetooth_detail" \
    TEMPERATURE_UNIT=F \
    APPS_TO_TRACK='Microsoft Word, Microsoft Excel, Microsoft PowerPoint, Firefox, Google Chrome, GlobalProtect, VMware Fusion, Code42, zoom.us' \
    USERS_LOCAL_ADMIN_THRESHOLD=1 \
    BUNDLEID_IGNORELIST="com.adobe.Acrobat.Uninstaller, com.adobe.ARM, com.adobe.air.Installer, com.adobe.distiller, com.parallels.winapp.*, com.vmware.proxyApp.*, com\\.apple\\.(appstore|airport.*|Automator|keychainaccess|launchpad|iChat|calculator|iCal|Chess|ColorSyncUtility|AddressBook|ActivityMonitor|iTunes|VoiceOverUtility|backup.*|TextEdit|Terminal|systempreferences|mail|PhotoBooth|gamecenter|Preview|Safari|Stickies|RAIDUtility|QuickTimePlayerX|NetworkUtility|Image_Capture|grapher|Grab|FontBook|DiskUtility|DigitalColorMeter|Dictionary|dashboardlauncher|DVDPlayer|Console|BluetoothFileExchange|audio.AudioMIDISetup|ScriptEditor2|MigrateAssistant|bootcampassistant|AudioMIDISetup|Photos|iBooksX|exposelauncher|Maps|FaceTime|reminders|Notes|siri.*|SystemProfiler|launchpad.*), com.apple.print.PrinterProxy, com.google.Chrome.app.*" \
    BUNDLEPATH_IGNORELIST='/System/Library/.*, .*/Library/AutoPkg.*, /.DocumentRevisions-V100/.*, /Library/Application Support/Adobe/Uninstall/.*, .*/Library/Application Support/Google/Chrome/Default/Web Applications/.*,.*\\.app\\/.*\\.app, .*/Library/AutoPkg/*, /Library/(?!Internet).*, /usr/.*, .*/Scripting.localized/.*, /Developer/*'

##########################################################################################
# STOP EDITING
##########################################################################################

# Create Storage Account for custom dashboards, modules, widgets, etc.
${az} storage account create --resource-group "${resource_group}" --name "${storage_accountname}" --location "${location}" --kind StorageV2 --sku "${storage_sku}" --enable-large-file-share --output none

# Determine the access key for the Storage Account
# https://stackoverflow.com/questions/56894664/retrieve-azure-storage-account-key-using-azure-cli
accesskey=$(${az} storage account keys list --resource-group "${resource_group}" --account-name "${storage_accountname}" --query [0].value -o tsv)

# If necessary, determine the access key manually:
# ${az} storage account keys list --resource-group "${resource_group}" --account-name "${storage_accountname}"

# Create file share
${az} storage share-rm create --resource-group "${resource_group}" --storage-account "${storage_accountname}" --name "${share_name}" --quota 1024 --enabled-protocols SMB --output none

# Configure Storage Account for Azure App Service
${az} webapp config storage-account add --resource-group "${resource_group}" --name "${webapp_name}" --custom-id "${storage_customid}" --storage-type AzureFiles --share-name "${share_name}" --account-name "${storage_accountname}" --access-key "${accesskey}" --mount-path "${docker_mount_path}"

# To verify that worked:
# ${az} webapp config storage-account list --resource-group "${resource_group}" --name "${webapp_name}"

# Determine App Service's FQDN
default_hostname=$(${az} webapp show --name "${webapp_name}" --resource-group "${resource_group}" --query "defaultHostName" --output tsv)
# TODO: maybe override this to use "${custom_hostname}" instead, or hardcode it to "${webapp_name}".azurewebsites.net

# Wait 5 seconds, then open FQDN in Safari
${sleep} 5
${open} -a "/Applications/Safari.app" https://"${default_hostname}"

##########################################################################################
# NOTE: STUFF WILL BE BROKEN
##########################################################################################

# To upload data to your Storage Account, use Microsoft Azure Storage Explorer:
# https://azure.microsoft.com/en-us/products/storage/storage-explorer/

# You will need to populate your Storage Account with the following:
# 1. Your MySQL SSL cert, which can be downloaded using these instructions:
# https://docs.microsoft.com/en-us/azure/mysql/flexible-server/how-to-connect-tls-ssl#download-the-public-ssl-certificate
# Match the name/path to the CONNECTION_SSL_CA env variable above
# 2. Your SSO cert. See the MunkiReport wiki for instructions on how to obtain/name that:
# https://github.com/munkireport/munkireport-php/wiki/Azure-AD-setup
# 3. Any custom MunkiReport stuff that you'd like to use: dashboards, modules, widgets, etc.

# Then, load your "${default_hostname}" or "${custom_hostname}", click the Admin menu, Upgrade Database, then click the Update button to populate the database tables.

##########################################################################################
# Troubleshooting
##########################################################################################

# Docker log reference: https://docs.microsoft.com/en-us/azure/app-service/tutorial-custom-container?pivots=container-linux#access-diagnostic-logs
# Azure container logs:
# ${open} -g -a safari https://"${webapp_name}".scm.azurewebsites.net/api/logs/docker
# MunkiReport container logs:
# ${az} webapp log tail --name "${webapp_name}" --resource-group "${resource_group}"

exit
