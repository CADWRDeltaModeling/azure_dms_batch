iterations=$1;
hotstart_input="hotstart_000000_$iterations.nc";
cd outputs; 
combine_hotstart7 -i $iterations;
HOTSTART_OUTPUT="hotstart_it=$iterations.nc"
cd ..
if [ -f "outputs/$HOTSTART_OUTPUT" ]; then
    echo "Hotstart file generated: $HOTSTART_OUTPUT"
    mv "outputs/${HOTSTART_OUTPUT}" .
    ln -sf "${HOTSTART_OUTPUT}" hotstart.nc
    echo "Hotstart file linked: hotstart.nc"
else
    echo "Failed to generate hotstart file: $HOTSTART_OUTPUT"
    echo "Continuing with existing setup"
fi
