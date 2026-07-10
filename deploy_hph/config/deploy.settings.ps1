<#
    deploy.settings.ps1 (HttpPlatformHandler mode) — edit for the target VM, then
    run deploy.bat. This file must return a HASHTABLE; omitted keys fall back to
    the defaults in ..\lib\DeployHph.psm1 (Get-DeploySettings).
#>
@{
    # ---- Web / IIS -------------------------------------------------------
    Hostname        = 'sitgis.jioconnect.com' # public host header (also the https binding host)
    McpPath         = '/MCPserver'            # ignored in application mode (derived to /<AppAlias>)
    BindHost        = '127.0.0.1'             # the Python process binds loopback
    IisSiteName     = 'MCPserver'             # used only in IisMode='site'
    # AppPoolName defaults to IisSiteName; set to override.
    AppPoolName     = 'MCPserver'

    # ---- Hosting mode ----------------------------------------------------
    # 'site'        = standalone IIS site (original behaviour).
    # 'application' = nest the MCP app UNDER an existing site (e.g. Default Web Site);
    #                 public URL becomes https://<Hostname>/<AppAlias> (=> /MCPserver).
    IisMode         = 'application'
    ParentSite      = 'Default Web Site'
    AppAlias        = 'MCPserver'              # /MCPserver under the parent site

    # ---- HTTPS binding (optional) ----------------------------------------
    # Adds an https (SNI) binding on the parent site using a cert already in
    # LocalMachine\My. Get the thumbprint with:
    #   Get-ChildItem Cert:\LocalMachine\My | ? Subject -like '*sitgis.jioconnect.com*'
    EnableHttps     = 'true'
    CertThumbprint  = 'F66384A3FA2D37872D611CEA939FA92C49E73929'                       # <-- PASTE the sitgis.jioconnect.com cert thumbprint
    HttpsPort       = 443

    # HPH serves the app directory directly, so the site physical path defaults
    # to InstallPath. Only override if you really need a different site root.
    # IisPhysicalPath = 'C:\apps\mcp-server'

    # ---- App pool identity (optional) ------------------------------------
    # Blank = ApplicationPoolIdentity. For least privilege set a domain account
    # (grant it read on the app folder + network access to PostgreSQL).
    AppPoolIdentity = ''                       # e.g. 'DOMAIN\svc-mcp'
    AppPoolPassword = ''                       # from your secret vault

    # ---- App / paths -----------------------------------------------------
    # InstallPath defaults to the project root (parent of this deploy_hph folder).
    # InstallPath   = 'C:\apps\mcp-server'
    StartupTimeLimit = 60                      # seconds HPH waits for Python to start
    AppPort         = 8000                     # used ONLY by the standalone smoke-test step

    # ---- Offline installer bundle ----------------------------------------
    # Defaults to <project-root>\apps-py-iis. For HPH put:
    #   python-*.exe, httpplatformhandler*.msi, VC_redist*.exe, and any *.whl wheels.
    # (URL Rewrite / ARR / NSSM are NOT needed in HttpPlatformHandler mode.)
    # BundleDir     = 'C:\apps-py-iis'
    MinPythonVersion = '3.10'

    # ---- Database (written to app\.env) ----------------------------------
    DbHost          = '10.144.90.128'
    DbPort          = 5432
    DbName          = 'postgres'
    DbUser          = 'postgres'
    DbPassword      = 'postgres1201'                        # set before real deploy (or edit app\.env after)
    DbSchema        = 'public'
    AutoSetupAll    = 'false'
    NeSchema        = ''
    NeTablePrefix   = 'ne'
    AutoSetupNe     = 'true'
}
