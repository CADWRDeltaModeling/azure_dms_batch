echo "In working directory: `pwd`"
echo "Initializing Intel oneAPI"
source /opt/intel/oneapi/setvars.sh intel64
echo "Intitalizing SCHISM"
source $AZ_BATCH_TASK_SHARED_DIR/schism_init.sh
echo "Running command: pschism_PREC_EVAP_GOTM_TVD-VL ${1}"
pschism_PREC_EVAP_GOTM_TVD-VL ${1}
