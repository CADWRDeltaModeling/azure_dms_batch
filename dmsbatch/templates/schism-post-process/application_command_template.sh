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
ln -s /mnt/local $AZ_BATCH_TASK_WORKING_DIR/simulations;
cd $AZ_BATCH_TASK_WORKING_DIR/simulations; # make sure to match this to the coordination command template
git clone -b wip --single-branch https://github.com/kjnam/BayDeltaSCHISM.git baydeltaschism;
# common files from container
azcopy copy "https://dwrbdoschismsa.blob.core.windows.net/itp202306/postprocess/hsi_common.tar.gz?{sas}" .;
tar -xzf hsi_common.tar.gz;
azcopy copy "https://dwrbdoschismsa.blob.core.windows.net/itp202306/postprocess/2016_base/grid_mapping_and_weight.nc?{sas}" common;
# setup study directory
mkdir -p $(dirname {study_dir});
# download the results, can be improved by downloading only a subset of files if known.
export NC_REGEX="outputs/(out2d|salinity|horizontalVel(X|Y)|zCoordinates)_\d+\.nc";
azcopy copy "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}?{sas}" $(dirname {study_dir}) --recursive --include-regex=$NC_REGEX;
# change to study directory
cd {study_dir};
#
({mpi_command});
#
echo "Post-processing Done!";
# upload the results: TBD
azcopy copy "./*.nc" "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/ppbatch/{study_dir}?{sas}";
# no semicolon for last command and no new line either
echo "Done with everything. Shutting down"