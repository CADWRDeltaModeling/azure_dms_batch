#!/bin/bash

# Function to generate an environment variable export script
generate_env_script() {
    local output_file="${1:-env_vars.sh}"
    local filter_pattern="${2:-}"  # Optional: filter variables by pattern (e.g., "AZURE_" or "BATCH_")
    
    echo "#!/bin/bash" > "$output_file"
    echo "# Environment variables captured on $(date)" >> "$output_file"
    echo "# Generated from: $(hostname)" >> "$output_file"
    echo "" >> "$output_file"
    
    # Iterate through all environment variable names
    while IFS= read -r varname; do
        # Apply filter if specified
        if [ -n "$filter_pattern" ]; then
            if [[ ! "$varname" =~ ^${filter_pattern} ]]; then
                continue
            fi
        fi
        
        # Skip some system variables that shouldn't be exported
        case "$varname" in
            PWD|OLDPWD|SHLVL|_|BASH_EXECUTION_STRING|BASH_ARGC|BASH_ARGV)
                continue
                ;;
        esac
        
        # Get the value of the variable (properly handles multiline values)
        value="${!varname}"
        
        # Skip variables with newlines (e.g., bash functions)
        if [[ "$value" == *$'\n'* ]]; then
            continue
        fi
        
        # Escape single quotes in the value
        escaped_value="${value//\'/\'\\\'\'}"
        printf "export %s='%s'\n" "${varname}" "${escaped_value}" >> "$output_file"
    done < <(compgen -e)
    
    chmod +x "$output_file"
    echo "Environment script generated: $output_file"
    echo "To use it, run: source $output_file"
}

# Alternative function that outputs to stdout instead of a file
print_env_script() {
    local filter_pattern="${1:-}"
    
    echo "#!/bin/bash"
    echo "# Environment variables captured on $(date)"
    echo ""
    
    # Iterate through all environment variable names
    while IFS= read -r varname; do
        # Apply filter if specified
        if [ -n "$filter_pattern" ]; then
            if [[ ! "$varname" =~ ^${filter_pattern} ]]; then
                continue
            fi
        fi
        
        # Skip some system variables that shouldn't be exported
        case "$varname" in
            PWD|OLDPWD|SHLVL|_|BASH_EXECUTION_STRING|BASH_ARGC|BASH_ARGV)
                continue
                ;;
        esac
        
        # Get the value of the variable (properly handles multiline values)
        value="${!varname}"
        
        # Skip variables with newlines (e.g., bash functions)
        if [[ "$value" == *$'\n'* ]]; then
            continue
        fi
        
        # Escape single quotes in the value
        escaped_value="${value//\'/\'\\\'\'}"
        printf "export %s='%s'\n" "${varname}" "${escaped_value}"
    done < <(compgen -e)
}

# Function to generate env script with sorted output
generate_env_script_sorted() {
    local output_file="${1:-env_vars.sh}"
    local filter_pattern="${2:-}"
    
    echo "#!/bin/bash" > "$output_file"
    echo "# Environment variables captured on $(date)" >> "$output_file"
    echo "# Generated from: $(hostname)" >> "$output_file"
    echo "" >> "$output_file"
    
    # Iterate through all environment variable names (sorted)
    while IFS= read -r varname; do
        # Apply filter if specified
        if [ -n "$filter_pattern" ]; then
            if [[ ! "$varname" =~ ^${filter_pattern} ]]; then
                continue
            fi
        fi
        
        # Skip some system variables that shouldn't be exported
        case "$varname" in
            PWD|OLDPWD|SHLVL|_|BASH_EXECUTION_STRING|BASH_ARGC|BASH_ARGV)
                continue
                ;;
        esac
        
        # Get the value of the variable (properly handles multiline values)
        value="${!varname}"
        
        # Skip variables with newlines (e.g., bash functions)
        if [[ "$value" == *$'\n'* ]]; then
            continue
        fi
        
        # Escape single quotes in the value
        escaped_value="${value//\'/\'\\\'\'}"
        printf "export %s='%s'\n" "${varname}" "${escaped_value}" >> "$output_file"
    done < <(compgen -e | sort)
    
    chmod +x "$output_file"
    echo "Environment script generated (sorted): $output_file"
    echo "To use it, run: source $output_file"
}

# Example usage (uncomment to test):
# generate_env_script "my_env.sh"                    # All variables
# generate_env_script "azure_env.sh" "AZURE_"        # Only AZURE_* variables
# generate_env_script "batch_env.sh" "AZ_BATCH_"     # Only AZ_BATCH_* variables
# print_env_script > "env_output.sh"                 # Output to stdout, redirect to file
# generate_env_script_sorted "sorted_env.sh"         # Generate with sorted output
