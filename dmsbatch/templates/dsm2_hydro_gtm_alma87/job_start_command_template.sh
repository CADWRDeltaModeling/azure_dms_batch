echo "Job Start Task Start"
echo "Host: $(hostname)"
echo "AZ_BATCH_APP_PACKAGE_dsm2_hydro_gtm=$AZ_BATCH_APP_PACKAGE_dsm2_hydro_gtm"
env | grep -i AZ_BATCH_APP_PACKAGE || echo "(no AZ_BATCH_APP_PACKAGE_* vars set)"

if [ -n "$AZ_BATCH_APP_PACKAGE_dsm2_hydro_gtm" ]; then
    cd "$AZ_BATCH_APP_PACKAGE_dsm2_hydro_gtm"
    echo "Contents of $AZ_BATCH_APP_PACKAGE_dsm2_hydro_gtm before extraction:"
    ls -la .
    TARBALL=$(find . -maxdepth 1 -name 'DSM2*.tar.gz' | head -1)
    EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name 'DSM2-*' | head -1)
    if [ -n "$TARBALL" ] && [ -z "$EXTRACTED_DIR" ]; then
        echo "Extracting $TARBALL in $(pwd)"
        tar -xvzf "$TARBALL"
        echo "Contents after extraction:"
        ls -la .
    else
        echo "DSM2 already extracted (found $EXTRACTED_DIR), or no DSM2*.tar.gz found; skipping"
    fi
else
    echo "WARNING: DSM2 app package (dsm2_hydro_gtm) not found; add it to app_pkgs in your job config"
fi

if [ -n "$AZ_BATCH_APP_PACKAGE_da_climatology" ]; then
    cd "$AZ_BATCH_APP_PACKAGE_da_climatology"
    echo "Contents of $AZ_BATCH_APP_PACKAGE_da_climatology before extraction:"
    ls -la .
    TARBALL=$(find . -maxdepth 1 -name 'da_climatology*.tar.gz' | head -1)
    if [ -n "$TARBALL" ] && [ ! -x env/bin/python ]; then
        echo "Extracting $TARBALL into $(pwd)/env"
        mkdir -p env
        tar -xzf "$TARBALL" -C env
        env/bin/conda-unpack
        # conda-pack extraction skips ldconfig/post-link scripts, so SONAME symlinks
        # (e.g. libgomp.so.1 -> libgomp.so.1.0.0) that a live conda install would
        # normally have are missing; recreate any missing libfoo.so.N -> libfoo.so.N.*
        for libfile in env/lib/*.so.*.*; do
            [ -e "$libfile" ] || continue
            soname=$(basename "$libfile" | sed -E 's/(\.so\.[0-9]+)\..*/\1/')
            [ -e "env/lib/$soname" ] || ln -s "$(basename "$libfile")" "env/lib/$soname"
        done
        echo "export PATH=\"$AZ_BATCH_APP_PACKAGE_da_climatology/env/bin:\$PATH\"" > env/bin/activate_da_climatology.sh
        echo "export LD_LIBRARY_PATH=\"$AZ_BATCH_APP_PACKAGE_da_climatology/env/lib:\$LD_LIBRARY_PATH\"" >> env/bin/activate_da_climatology.sh
        echo "Contents of env/bin after extraction and conda-unpack:"
        ls env/bin | head -5
    else
        echo "da_climatology env already extracted/unpacked, or no da_climatology*.tar.gz found"
    fi
else
    echo "WARNING: da_climatology app package not found; add it to app_pkgs in your job config"
fi

cd "$AZ_BATCH_TASK_WORKING_DIR"
# GTM node/knot runs all read the same common_input/timeseries/zero_ec_run study and
# tidefile -- job_start_command_resource_files pulls them into this prep task's own
# working dir (see job config's job_start_command_resource_files); move them once into
# $AZ_BATCH_NODE_SHARED_DIR so every task scheduled on this node shares one copy
# instead of each task re-downloading it.
if [ -d "dsm2_studies" ]; then
    if [ ! -d "$AZ_BATCH_NODE_SHARED_DIR/dsm2_studies" ]; then
        echo "Moving shared dsm2_studies/ to $AZ_BATCH_NODE_SHARED_DIR"
        mv dsm2_studies "$AZ_BATCH_NODE_SHARED_DIR/dsm2_studies"
    else
        echo "Shared dsm2_studies already present in $AZ_BATCH_NODE_SHARED_DIR; skipping"
        rm -rf dsm2_studies
    fi
    echo "Contents of $AZ_BATCH_NODE_SHARED_DIR/dsm2_studies:"
    ls -la "$AZ_BATCH_NODE_SHARED_DIR/dsm2_studies"
else
    echo "(no dsm2_studies/ staged by job_start_command_resource_files; skipping shared-dir move)"
fi

echo "Job Start Task Done"

