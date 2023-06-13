#!/bin/bash

# Initialize variables
script=""
autoRunLoc=$(readlink -f "$0")
proc_name="auto_run_validator" 
args=()
version_location="./openvalidators/__init__.py"
version="__version__"

args=$@

# Check if pm2 is installed
if ! command -v pm2 &> /dev/null
then
    echo "pm2 could not be found. To install see: https://pm2.keymetrics.io/docs/usage/quick-start/"
    exit 1
fi

# Checks if $1 is smaller than $2
# If $1 is smaller than or equal to $2, then true. 
# else false.
versionLessThanOrEqual() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

# Checks if $1 is smaller than $2
# If $1 is smaller than $2, then true. 
# else false.
versionLessThan() {
    [ "$1" = "$2" ] && return 1 || versionLessThanOrEqual $1 $2
}

# Returns the difference between 
# two versions as a numerical value.
get_version_difference() {
    local tag1="$1"
    local tag2="$2"

    # Extract the version numbers from the tags
    local version1=$(echo "$tag1" | sed 's/v//')
    local version2=$(echo "$tag2" | sed 's/v//')

    # Split the version numbers into an array
    IFS='.' read -ra version1_arr <<< "$version1"
    IFS='.' read -ra version2_arr <<< "$version2"

    # Calculate the numerical difference
    local diff=0
    for i in "${!version1_arr[@]}"; do
        local num1=${version1_arr[$i]}
        local num2=${version2_arr[$i]}

        # Compare the numbers and update the difference
        if (( num1 > num2 )); then
            diff=$((diff + num1 - num2))
        elif (( num1 < num2 )); then
            diff=$((diff + num2 - num1))
        fi
    done

    strip_quotes $diff
}



read_version_value() {
    # Read each line in the file
    while IFS= read -r line; do
        # Check if the line contains the variable name
        if [[ "$line" == *"$version"* ]]; then
            # Extract the value of the variable
            local value=$(echo "$line" | awk -F '=' '{print $2}' | tr -d ' ')
            strip_quotes $value
            return 0
        fi
    done < "$version_location"

    echo ""
}

check_variable_value_on_github() {
    local repo="$1"
    local file_path="$2"
    local variable_name="$3"

    local url="https://api.github.com/repos/$repo/contents/$file_path"
    local response=$(curl -s Iv1.0c670416b460e145:e7041d3d739feab1fed83b23a25b720a079d101a "$url")

    # Check if the response contains an error message
    if [[ $response =~ "message" ]]; then
        echo "Error: Failed to retrieve file contents from GitHub."
        return 1
    fi

    # Extract the content from the response
    local content=$(echo "$response" | tr -d '\n' | jq -r '.content')

    if [[ "$content" == "null" ]]; then
        echo "File '$file_path' not found in the repository."
        return 1
    fi

    # Decode the Base64-encoded content
    local decoded_content=$(echo "$content" | base64 --decode)

    # Extract the variable value from the content
    local variable_value=$(echo "$decoded_content" | grep "$variable_name" | awk -F '=' '{print $2}' | tr -d ' ')

    if [[ -z "$variable_value" ]]; then
        echo "Variable '$variable_name' not found in the file '$file_path'."
        return 1
    fi

    strip_quotes $variable_value
}

strip_quotes() {
    local input="$1"

    # Remove leading and trailing quotes using parameter expansion
    local stripped="${input#\"}"
    stripped="${stripped%\"}"

    echo "$stripped"
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --script) script="$2"; shift ;;
        --name) name="$2"; shift ;;
        --*) args+=("$1=$2"); shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Check if script argument was provided
if [[ -z "$script" ]]; then
    echo "The --script argument is required."
    exit 1
fi

branch=$(git branch --show-current)            # get current branch.
echo watching branch: $branch
echo pm2 process name: $proc_name

# Get the current version locally.
current_version=$(read_version_value)

# Check if script is already running with pm2
if pm2 status | grep -q $proc_name; then
    echo "The script is already running with pm2. Stopping and restarting..."
    pm2 delete $proc_name
fi

# Run the Python script with the arguments using pm2
echo "Running $script with the following arguments with pm2:"
echo "${args[@]}"
pm2 start "$script" --name $proc_name --interpreter python3 -- "${args[@]}"

while true; do

    # First ensure that this is a git installation
    if [ -d "./.git" ]; then

        # check value on github remotely
        latest_version=$(check_variable_value_on_github "opentensor/tag_trial_repo_delete_later" "openvalidators/__init__.py" "__version__ ")

        # If the file has been updated
        if versionLessThan $current_version $latest_version; then
            echo "latest version $latest_version"
            echo "current version $current_version"
            diff=$(get_version_difference $latest_version $current_version)
            if [ "$diff" -eq 1 ]; then
                echo "current validator version:" "$current_version" 
                echo "latest validator version:" "$latest_version" 

                # Pull latest changes
                git pull origin $branch
                # latest_version is newer than current_version, should download and reinstall.
                echo "New version published. Updating the local copy."

                # Install latest changes just in case.
                pip install -e ../

                # Check if script is already running with pm2
                if pm2 status | grep -q $proc_name; then
                    echo "The script is already running with pm2. Stopping and restarting..."
                    pm2 delete $proc_name
                fi

                # # Run the Python script with the arguments using pm2
                echo "Running $script with the following arguments with pm2:"
                echo "${args[@]}"
                pm2 start "$script" --name $proc_name --interpreter python3 -- "${args[@]}"

                # Update current version:
                current_version=$(read_version_value)
                echo ""

                # Restart autorun script
                echo "Restarting script..."
                ./$(basename $0) $args && exit
            else
                # current version is newer than the latest on git. This is likely a local copy, so do nothing. 
                echo "**Will not update**"
                echo "The local version is $diff versions behind. Please manually update to the latest version and re-run this script."
            fi
        else
            echo "**Skipping update **"
            echo "$current_version is the same as or more than $latest_version. You are likely running locally."
        fi
    else
        echo "The installation does not appear to be done through Git. Please install from source at https://github.com/opentensor/validators and rerun this script."
    fi
    
    # Wait about 30 minutes
    # This should be plenty of time for validators to catch up
    # and should prevent any rate limitations by GitHub.
    sleep 1800
done
