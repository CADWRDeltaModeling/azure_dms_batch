## Documentation for `run_modified_loop.sh`

### Overview
`run_modified_loop.sh` is a bash script designed to run a specified command on files within a directory that have been modified within a certain time frame. It allows for customization of the time parameters and the file pattern to watch, making it versatile for various automation tasks.

### Features
- **Customizable Wait Times:** Allows setting minimum and maximum wait times before processing files.
- **Flexible File Matching:** Supports custom file patterns to match specific files.
- **Command Execution:** Executes a specified command on the matched, modified files.

### Usage
```bash
./run_modified_loop.sh -c <command> -w <wait_minutes> -m <min_modified_minutes> -x <max_modified_minutes> -p <pattern> <watch_dir>
```
#### Parameters
- `-c <command>`: The command to run on modified files. This is a mandatory parameter.
- `-w <wait_minutes>`: Loop sleep time in minutes. Default is 5 minutes.
- `-m <min_modified_minutes>`: Minimum time to wait before starting the run loop. Default is 5 minutes.
- `-x <max_modified_minutes>`: Maximum time to wait before starting the run loop. Default is 10 minutes.
- `-p <pattern>`: Pattern to match files, similar to glob patterns. Default is * (all files).
- `<watch_dir>`: The directory to watch for modified files. This is a mandatory parameter.

#### Examples
Run a script on all `.txt` files modified within the last 5 to 10 minutes in the `documents` directory:
```bash
./run_modified_loop.sh -c "./process_script.sh" -w 5 -m 5 -x 10 -p "*.txt" documents
```

#### Notes
- Ensure the script has execute permissions (`chmod +x run_modified_loop.sh`) before running it.
- The script uses `find` internally to match files against the specified pattern and modification time criteria.

#### Limitations
- The script currently does not support recursive watching in subdirectories based on the provided example.
- It is designed to run on Unix-like operating systems and may require adjustments for compatibility with other environments.


## Documentation for `track_processed.sh`

### Overview
`track_processed.sh` is a bash script designed to process files that have not been processed before. It keeps track of processed files by recording their names in a unique file associated with the command used for processing. This script is particularly useful for automating tasks on files in a directory where files are added over time and each file should be processed only once.

### Features
- Processes files with a specified command if they haven't been processed before.
- Keeps a record of processed files to prevent reprocessing.
- Allows for any command and its arguments to be passed for processing files.

### Usage

#### Parameters
- `<command>`: The command to execute on unprocessed files. This is a mandatory parameter.
- `[command_args]`: Optional arguments for the command. These should be provided before the file paths.
- `<file_paths>`: One or more paths to files to be potentially processed. This is a mandatory parameter.

### How It Works
1. The script takes a command and optional arguments as its first inputs. The rest of the inputs should be file paths.
2. It generates a unique filename to track processed files based on the command's basename.
3. For each file path provided:
   - The script checks if the file has already been processed by looking for its name in the tracking file.
   - If the file has not been processed, the script executes the specified command with any provided arguments and the file path, then marks the file as processed by adding its name to the tracking file.
   - If the file has been processed before, it is skipped.

### Examples
- Process all `.txt` files in a directory with a custom script, `process_text.sh`, only if they haven't been processed before.
- Process image files with a hypothetical `image_processor` command, passing in `-resize` and `-quality` arguments.

### Notes
- The script assumes that the command provided can accept the file path as the last argument.
- The tracking file is named `processed_files_<command_basename>.txt` and is located in the same directory from which the script is executed.
- Ensure the script has execute permissions (`chmod +x track_processed.sh`) before running it.

### Limitations
- The script does not handle spaces in filenames or command arguments well. It's recommended to avoid spaces or use quotes around arguments and file paths.
- The script does not recursively process files in subdirectories. It only processes files passed directly as arguments.

This documentation provides a comprehensive guide to using and understanding the `track_processed.sh` script, ensuring users can effectively automate the processing of new or unprocessed files with ease.
