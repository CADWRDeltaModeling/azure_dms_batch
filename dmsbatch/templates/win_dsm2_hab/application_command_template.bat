echo on
set DSM2_HOME=%AZ_BATCH_APP_PACKAGE_dsm2%\DSM2-8.2.c5aacef7-win32
set VISTA_HOME=%AZ_BATCH_APP_PACKAGE_vista%
set PATH=%PATH%;%AZ_BATCH_APP_PACKAGE_azcopy%\azcopy_windows_amd64_10.25.1;%DSM2_HOME%\bin;%VISTA_HOME%\vista\bin;%AZ_BATCH_APP_PACKAGE_unzip%\bin
call %AZ_BATCH_APP_PACKAGE_python#v37%\Scripts\activate.bat
echo All environment variables:
set
echo End of environment variables
echo Copying from blob to local for the setup first time
cd %AZ_BATCH_TASK_WORKING_DIR%

REM Setup directories first to avoid link issues

set setup_dirs={setup_dirs}

REM Loop over array of directories

for %%d in (%setup_dirs%) do (
    echo Copying %%d
    azcopy copy {setup_dirs_copy_flags} "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/%%d/*?{sas_win}" "%%d" || echo AzCopy failed for %%d but continuing...
)

REM Setup study directory

for %%d in ({study_dir}) do (
    echo Copying %%d
    azcopy copy {study_copy_flags} "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/%%d/*?{sas_win}" "%%d" || echo AzCopy failed for study directory but continuing...
)
if not exist "{study_dir}\outputs" mkdir "{study_dir}\outputs"

REM Change to study directory

cd {study_dir}
echo Setup from blobs done

echo Running command: 
{command}
echo Command completed with exit code %ERRORLEVEL%
