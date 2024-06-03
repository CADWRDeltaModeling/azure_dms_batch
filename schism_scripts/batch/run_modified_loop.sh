#!/bin/bash
# runs a command on modified files in a directory
# Set default values for wait_minutes, max_modified_minutes, and delete_modified_minutes
# output every command that is run
# set -x
#
pattern="*"
wait_minutes=5 # loop sleep time in minutes
min_modified_minutes=5 # minimum time to wait before starting run loop
max_modified_minutes=10 # maximum time to wait before starting run loop

# Parse command line options with getopts
while getopts ":w:m:x:p:c:" opt; do
  case ${opt} in
    w )
      wait_minutes="${OPTARG}"
      ;;
    m )
      min_modified_minutes="${OPTARG}"
      ;;
    x )
      max_modified_minutes="${OPTARG}"
      ;;
    p )
      pattern="${OPTARG}" # pattern to match files, same as glob
      ;;
    c )
      command="${OPTARG}" # command to run on modified files
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


if [ $# -lt  1 ]; then
  echo "Usage: $0 -c command watch_dir"
  exit 1
fi

src_dir="$1"
modified_minutes=${max_modified_minutes}
wait_seconds=$((wait_minutes * 60))
# loop until finish is set to 1 by SIGUSR1
finish=0
exit_after_copy=0
trap 'finish=1' SIGUSR1
# 
echo "Waiting for ${max_modified_minutes} minutes before starting run loop for the first time!"
sleep $((max_modified_minutes * 60))
# copy from src_dir to dest_dir excluding the output directory
echo "Starting run loop watching ${src_dir}"
while true
do
    start_time=$(date +%s)
    # copying files modified no more than ${modified_minutes} minutes ago
    echo "Finding files modified upto ${modified_minutes} minutes ago that match ${pattern} and running ${command}"
    # Find files that were modified within the specified time range min_modified_minutes and max_modified_minutes
    find "${src_dir}" -name "${pattern}" -type f -mmin +${min_modified_minutes} -mmin -${max_modified_minutes} -exec ${command} {} \;
    # 
    if [ $finish -eq 1 ]; then
      echo "Received SIGUSR1... exiting after this run!"
      exit_after_copy=1
    fi
    if [ $exit_after_copy -eq 1 ]; then
      echo "Exiting after last run after receiving signal!"
      exit 0
    fi
    sleep $wait_seconds # giving a breathing room of 60 seconds for overlap in case it's delayed.
    end_time=$(date +%s)
    diff=$((end_time - start_time))
    diff_in_mins=$((diff / 60))+1 # adding 1 to make sure we don't miss any files
    # max modified minutes is the greater of diff_in_mins and max_modified_minutes so we don't miss any files
    modified_minutes=$((diff_in_mins > max_modified_minutes ? diff_in_mins : max_modified_minutes))
done
