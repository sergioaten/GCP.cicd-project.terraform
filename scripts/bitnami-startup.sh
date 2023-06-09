#!/bin/bash

set -e

DEFAULT_UPTIME_DEADLINE="300"  # 5 minutes

metadata_value() {
    curl --retry 5 -sfH "Metadata-Flavor: Google" \
    "http://metadata/computeMetadata/v1/$1"
}

access_token() {
    metadata_value "instance/service-accounts/default/token" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])"
}

uptime_seconds() {
    seconds="$(cat /proc/uptime | cut -d' ' -f1)"
    echo ${seconds%%.*}  # delete floating point.
}

config_url() { metadata_value "instance/attributes/status-config-url"; }
instance_id() { metadata_value "instance/id"; }
variable_path() { metadata_value "instance/attributes/status-variable-path"; }
project_name() { metadata_value "project/project-id"; }
uptime_deadline() {
    metadata_value "instance/attributes/status-uptime-deadline" \
        || echo $DEFAULT_UPTIME_DEADLINE
}

config_name() {
    python3 - $(config_url) <<EOF
import sys, urllib.parse
parsed = urllib.parse.urlparse(sys.argv[1])
print('/'.join(parsed.path.rstrip('/').split('/')[-4:]))
EOF
}

variable_body() {
    encoded_value=$(echo "$2" | base64)
    printf '{"name":"%s", "value":"%s"}\n' "$1" "$encoded_value"
}

post_result() {
    var_subpath=$1
    var_value=$2
    var_path="$(config_name)/variables/$var_subpath/$(instance_id)"

    curl --retry 5 -sH "Authorization: Bearer $(access_token)" \
        -H "Content-Type: application/json" \
        -X POST -d "$(variable_body "$var_path" "$var_value")" \
        "$(config_url)/variables"
}

post_success() {
    post_result "$(variable_path)/success" "${1:-Success}"
}

post_failure() {
    post_result "$(variable_path)/failure" "${1:-Failure}"
}

# The contents of initScript are contained within this function.
custom_init() (
    return 0
)

# The contents of checkScript are contained within this function.
check_success() (
    failed=$(/etc/init.d/bitnami status | grep "not running" | cut -d" " -f1 | tr "\n" " ")
    if [ ! -z "$failed" ]; then
    echo "Processes failed to start: $failed"
    exit 1
    fi
)

check_success_with_retries() {
    deadline="$(uptime_deadline)"
    while [ "$(uptime_seconds)" -lt "$deadline" ]; do
    message=$(check_success)
    case $? in
    0)
        # Success.
        return 0
        ;;
    1)
        # Not ready; continue loop
        ;;
    *)
        # Failure; abort.
        echo $message
        return 1
        ;;
    esac

    sleep 5
    done

    # The check was not successful within the required deadline.
    echo "status check timeout"
    return 1
}

do_init() {
    # Run the init script first. If no init script was specified, this
    # is a no-op.
    echo "software-status: initializing..."

    set +e
    message="$(custom_init)"
    result=$?
    set -e

    if [ $result -ne 0 ]; then
    echo "software-status: init failure"
    post_failure "$message"
    return 1
    fi
}

do_check() {
    # Poll for success.
    echo "software-status: waiting for software to become ready..."
    set +e
    message="$(check_success_with_retries)"
    result=$?
    set -e

    if [ $result -eq 0 ]; then
    echo "software-status: success"
    post_success
    else
    echo "software-status: failed with message: $message"
    post_failure "$message"
    fi
}

# Run the initialization script synchronously.
do_init || exit $?

# The actual software initialization might come after google's init.d
# script that executes our startup script. Thus, launch this script
# into the background so that it does not block init and eventually
# timeout while waiting for software to start.
do_check & disown