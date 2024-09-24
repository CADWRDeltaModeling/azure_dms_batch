# NOTE that the following variables are hard-coded.
SECONDS_PER_DAY=86400
NHOT_WRITE=4800
DT=90
output_interval=$((($NHOT_WRITE * $DT) / $SECONDS_PER_DAY))
simulation_days=$(tail -1 outputs/flux.out | awk -voutput_interval=$output_interval '{print int($1/output_interval)*output_interval}');
# Obtain number of iterations
iterations=$((($simulation_days * SECONDS_PER_DAY) / DT))
echo $iterations;
