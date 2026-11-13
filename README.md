# DeplOI Portable

DeplOI Portable is a PowerShell 5.1 / SQLite based portable solution to authenticate against a One Identity REST API (Application Server), read the schema and extract system data.

Each extract is stored in a separate SQLite database those databases can be automatically compared and generate a HTML report of the differences.

Report Header / Overview
<img width="1360" height="501" alt="image" src="https://github.com/user-attachments/assets/eee1e1a7-c967-458a-812b-a50c725cfade" />

Example Diff
<img width="1292" height="628" alt="image" src="https://github.com/user-attachments/assets/dec1bfed-9260-47c5-a76e-bf61b76f2c40" />

## Usage

```powershell
# Extraction (DialogUser-Login)
.\DeplOI.ps1 extract -BaseUrl 'https://host/AppServer' -User viadmin -Password '...' -SystemName PROD

# Only specific data: skip dynamic harvest / extract only a list of comma separated tables
.\DeplOI.ps1 extract -BaseUrl ... -User ... -SkipDynamic
.\DeplOI.ps1 extract -BaseUrl ... -User ... -SkipStatic -Tables DialogConfigParm,DialogScript

# OAuth (interactiv, requires PSAuthClient
https://github.com/alflokken/PSAuthClient/releases 

.\DeplOI.ps1 extract -BaseUrl ... -AuthenticationType OAuth -TokenURL <uri> -ClientID <id> -RedirectURL <uri>

# Compare Extracts
.\DeplOI.ps1 compare -Baseline .\extracts\A.db -Target .\extracts\B.db

# Inspect an extract database
powershell -File .\tools\inspect-extract.ps1 <dateiname>.db
```
