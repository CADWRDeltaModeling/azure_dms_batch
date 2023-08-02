echo Main task $(pwd);
set -x;
ulimit -s unlimited;
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh;
export TMPHOME=/home/_azbatch; # fix for the fact that azure batch runs under different home directory
bash ./Miniconda3-latest-Linux-x86_64.sh -b -p $TMPHOME/miniconda3;
$TMPHOME/miniconda3/bin/conda init bash;
source $TMPHOME/miniconda3/etc/profile.d/conda.sh;
conda update -y conda;
conda install -y -n base conda-libmamba-solver;
conda create -n suxarray -c conda-forge --solver=libmamba -y python=3.10 shapely holoviews uxarray=2023.06 datashader netcdf4 click;
git clone https://github.com/CADWRDeltaModeling/suxarray;
pushd suxarray;
conda activate suxarray;
pip install --no-deps .;
popd;
# setup local disk
ln -s /mnt/local $AZ_BATCH_TASK_WORKING_DIR;
cd $AZ_BATCH_TASK_WORKING_DIR; # make sure to match this to the coordination command template
git clone -b master --single-branch https://github.com/CADWRDeltaModeling/BayDeltaSCHISM.git baydeltaschism;
# common files from container
azcopy copy --recursive "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{setup_dirs}?{sas}" .;
# setup study directory
mkdir -p $(dirname {study_dir});
# download the results, can be improved by downloading only a subset of files if known.
azcopy copy "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}?{sas}" $(dirname {study_dir}) --recursive --include-regex="{input_file_pattern}";
# change to study directory
cd {study_dir};
#
({mpi_command});
#
echo "Post-processing Done!";
# upload the results: TBD
azcopy copy "{output_file_pattern}" "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{output_folder}?{sas}";
# no semicolon for last command and no new line either
echo "Done with everything. Shutting down"