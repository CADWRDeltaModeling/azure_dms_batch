#!/bin/bash

# Set default values for wait_minutes, max_modified_minutes, and delete_modified_minutes
wait_minutes=5
max_modified_minutes=10
delete_modified_minutes=240

# Parse command line options with getopts
while getopts ":w:m:d:" opt; do
  case ${opt} in
    w )
      wait_minutes="${OPTARG}"
      ;;
    m )
      max_modified_minutes="${OPTARG}"
      ;;
    d )
      delete_modified_minutes="${OPTARG}"
      ;;
    \? )
      echo "Invalid option: -${OPTARG}" >&2
      exit 1
      ;;
    : )
      echo "Option -${OPTARG} requires an argument." >&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

# rest of the args are source and destination directories
# set source and destination directories


if [ $# -lt  2 ]; then
  echo "Usage: $0 source_dir dest_dir"
  exit 1
fi

src_dir="$1"
dest_dir="$2"

# copy from src_dir to dest_dir excluding the output directory
echo "Starting copy loop from ${src_dir} to ${dest_dir}"
modified_minutes=${max_modified_minutes}
while true
do
    start_time=$(date +%s)
    # copying files modified at least ${wait_minutes} minutes ago but no more than ${modified_minutes} minutes ago
    echo "Copying files modified from ${wait_minutes} to ${modified_minutes} minutes ago"
    find "${src_dir}" -type f -mmin +${wait_minutes} -mmin -${modified_minutes} -exec cp --parents {} "${dest_dir}" \;
    # find output directory under src directory and delete *.nc files older than ${delete_modified_minutes} minutes from it
    echo "Deleting files from ${src_dir} older than ${delete_modified_minutes} minutes"
    find "${src_dir}" -type d -name "outputs" -exec find {} -type f -mmin +${delete_modified_minutes} -name "*.nc" -delete \;
    sleep 60 # giving a breathing room of 60 seconds for overlap in case it's delayed.
    end_time=$(date +%s)
    diff=$((end_time - start_time))
    diff_in_mins=$((diff / 60))
    # max modified minutes is the greater of diff_in_mins and max_modified_minutes
    modified_minutes=$((diff_in_mins > max_modified_minutes ? diff_in_mins : max_modified_minutes))
done