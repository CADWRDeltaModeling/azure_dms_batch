echo Main task $(pwd);
ulimit -s unlimited;
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh 
bash ./Miniconda3-latest-Linux-x86_64.sh -b -p ~/miniconda3 
~/miniconda3/bin/conda init bash 
source ~/miniconda3/etc/profile.d/conda.sh 
conda update -y conda 
conda install -y -n base conda-libmamba-solver 
conda create -n suxarray -c conda-forge --solver=libmamba -y python=3.10 shapely holoviews uxarray=2023.06 datashader netcdf4 click
git clone https://github.com/CADWRDeltaModeling/suxarray 
pushd suxarray 
conda activate suxarray
pip install --no-deps . 
pop
# setup local disk
ln -s /mnt/local $AZ_BATCH_TASK_WORKING_DIR/simulations;
cd $AZ_BATCH_TASK_WORKING_DIR/simulations; # make sure to match this to the coordination command template
# setup study directory
mkdir -p $(dirname {study_dir});
azcopy copy "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}?{sas}" $(dirname {study_dir}) --recursive --include-regex="(out2d|salinity|horizontalVel(X|Y)|zCoordinates)_\d+\.nc";
# change to study directory
cd {study_dir};
# download the post-processing script
wget https://raw.githubusercontent.com/CADWRDeltaModeling/BayDeltaSCHISM/4cb8720258b01e462e95048b575484ca04a651a3/bdschism/bdschism/calculate_depth_average.py 
#
{mpi_command};
#
echo "Post-processing Done!";
# upload the results: TBD
#azcopy copy $(dirname {study_dir}) "https://{storage_account_name}.blob.core.windows.net/{storage_container_name}/{study_dir}?{sas}"" --recursive --exclude-path="*" --include-path="*depth_average*" --overwrite=ifSourceNewer;
# no semicolon for last command
echo "Done with everything. Shutting down"
