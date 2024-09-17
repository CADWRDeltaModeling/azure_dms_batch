export NHOT_WRITE=4800;
iterations=$(tail -100 outputs/mirror.out | grep "TIME STEP" | awk '{print $3}' | tr -d ';' | tail -1);
iterations=$((($iterations/$NHOT_WRITE)*$NHOT_WRITE));
echo $iterations;
