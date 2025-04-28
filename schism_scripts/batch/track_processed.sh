#!/bin/bash
# Script to process files that have not been processed before

# File to keep track of processed files
# make this filename unique to the command
all_but_last=("${@:1:$(($#-1))}")
last="${@: -1}"
command_hash=$(echo $all_but_last | sha1sum | awk '{print $1}')
echo "For command: $all_but_last the hash is $command_hash"
processed_files="processed_files_${command_hash}.txt"
# Function to check if a file has been processed before
function has_been_processed {
    file=$1
    # Check if processed_files exists
    if [ ! -f $processed_files ]
    then
        return 1
    fi
    # Check if the file is in the list of processed files
    if grep -Fxq "$file" $processed_files
    then
        return 0
    else
        return 1
    fi
}

# Function to mark a file as processed
function mark_as_processed {
    file=$1
    echo "$file" >> $processed_files
}

# last argument is the file to process
file="$last"
# Check if the file has been processed before
if has_been_processed "$file"
then
    echo "Skipping $file because it has been processed before"
else
    echo "Processing $file"
    # Process the file here
    # run command here with the file as the last argument
    $all_but_last $file
    # Mark the file as processed
    mark_as_processed "$file"
fi
