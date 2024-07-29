echo on
{app_pkgs_script}
echo All environment variables:
set
echo End of environment variables
echo Running command: 
{command}
echo Command completed with exit code %ERRORLEVEL%
