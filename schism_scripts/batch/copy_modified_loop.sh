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
storage_account="$3"
container="$4"
# SAS needs to be defined in the environment of calling script
if [[ -z "${SAS}" ]]; then
  echo "SAS needs to be defined in the environment of calling script"
  exit 1
fi
# copy from src_dir to dest_dir excluding the output directory
echo "Starting copy loop from ${src_dir} to ${dest_dir}"
modified_minutes=${max_modified_minutes}
wait_seconds=$((wait_minutes * 60))
# 
echo "Waiting for ${max_modified_minutes} minutes before starting copy loop for the first time!"
sleep $((max_modified_minutes * 60))
# loop forever
while true
do
    start_time=$(date +%s)
    # copying files modified no more than ${modified_minutes} minutes ago
    echo "Copying files modified upto ${modified_minutes} minutes ago"
    # find files modified in the last modified_minutes minutes and copy them to dest_dir
    # OPTION1: cp with blobfuse mounted dir (slower due to writeback cache)
    # find "${src_dir}" -type f -mmin "-${modified_minutes}" -exec cp -v --parents {} "${dest_dir}" \;
    # OPTION2: azcopy (faster, but need to install azcopy and set up SAS). Also sync scans destination and source so is slower
    # use azcopy sync (not sure how preformance compares to cp))
    #echo "syncing ${src_dir} to ${container}/${src_dir}"
    #azcopy sync "./" "https://${storage_account}.blob.core.windows.net/${container}/${src_dir}?${SAS}"
    # OPTION3: azcopy as exec from find but each file is copied separately (slower)
    # find "${src_dir}" -type f -mmin "-${modified_minutes}" -exec azcopy cp {} "https://${storage_account}.blob.core.windows.net/${container}/${dest_dir}?${SAS}" \;
    # OPTION 4: find files modified in the last modified_minutes minutes and then azcopy with list-of-files filter for faster copying times
    # MAJOR ASSUMPTION: current directory is the study directory
    # FIXME: $dest_dir is not used in the azcopy command as $src_dir is enough information to construct the destination path
    # UNDOCUMENTED WAY: use --list-of-files option to azcopy
    #find . -type f -mmin "-${modified_minutes}" -print > /tmp/azcopy_filelist.txt
    #azcopy cp "./*" "https://${storage_account}.blob.core.windows.net/${container}/${src_dir}?${SAS}" --list-of-files /tmp/azcopy_filelist.txt
    # DOCUMENTED WAY: construct a semi-colon separated list of files as an environment variable and use --include-path option to azcopy
    azcopy_filelist=$(find . -type f -mmin "-${modified_minutes}" -print0 | tr '\0' ';')
    #if azcopy_filelist is not empty then azcopy
    if [ -z "${azcopy_filelist}" ]; then
      echo "No files to copy... skipping this time."
    else
      azcopy cp "./*" "https://${storage_account}.blob.core.windows.net/${container}/${src_dir}?${SAS}" --include-path ${azcopy_filelist} --preserve-symlinks;
    fi
    # find output directory under src directory and delete *.nc files older than ${delete_modified_minutes} minutes from it
    echo "Deleting files from ${src_dir} older than ${delete_modified_minutes} minutes"
    find . -type d -name "outputs" -exec find {} -type f -mmin +${delete_modified_minutes} -name "*.nc" -delete \;
    sleep $wait_seconds # giving a breathing room of 60 seconds for overlap in case it's delayed.
    end_time=$(date +%s)
    diff=$((end_time - start_time))
    diff_in_mins=$((diff / 60))+1 # adding 1 to make sure we don't miss any files
    # max modified minutes is the greater of diff_in_mins and max_modified_minutes so we don't miss any files
    modified_minutes=$((diff_in_mins > max_modified_minutes ? diff_in_mins : max_modified_minutes))
done
