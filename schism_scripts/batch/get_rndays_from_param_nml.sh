# Extracts the rnday integer value from a SCHISM param.nml file.
# Usage: get_rndays_from_param_nml <path_to_param_nml>
# Prints the integer rnday to stdout, or an error message and returns 0.
# source this file and then use the function in your scripts to get rnday, e.g.
# rndays=$(get_rndays_from_param_nml "/data/runs/my_study/param.nml")

get_rndays_from_param_nml() {
  local param_file="$1"                     # path to param.nml in run_dir

  if [[ ! -f "$param_file" ]]; then
    echo "[SKIP] missing $param_file"
    return 0
  fi

  local rnday_int
  rnday_int=$(awk '
    BEGIN { IGNORECASE=1 }
    /^[[:space:]]*!/ { next }
    {
      gsub(/!.*$/, "")
      if (match($0, /rnday[[:space:]]*=[[:space:]]*([0-9]+(\.[0-9]+)?)/, m)) {
        print int(m[1])
        exit
      }
    }
  ' "$param_file")                                                 # gather rnday_int from param.nml rnday

  if [[ -z "$rnday_int" ]]; then
    echo "[SKIP] could not parse rnday from $param_file"
    return 0
  fi

  echo "$rnday_int"
}
