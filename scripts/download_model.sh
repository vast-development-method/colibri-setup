#!/usr/bin/env bash
#
# Manage large, resumable Hugging Face model downloads in detached GNU Screen
# sessions.  Authentication tokens are accepted only through HF_TOKEN or a
# protected token file; token values are never placed in arguments or state.

set -uo pipefail

PROGRAM_NAME="${0##*/}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

DEFAULT_MODEL="mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp"
DEFAULT_EXPECTED_SIZE_GB=380
DEFAULT_MAX_WORKERS=2
DEFAULT_ETAG_TIMEOUT=60
DEFAULT_DOWNLOAD_TIMEOUT=600
DEFAULT_MAX_RETRIES=20
DEFAULT_RETRY_BASE=15
DEFAULT_RETRY_MAX=300
DEFAULT_MIN_FREE_GB=10

HF_BIN="${HF_BIN:-hf}"
SCREEN_BIN="${SCREEN_BIN:-screen}"
MODELS_DIR="${COLIBRI_MODELS_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/colibri/models}"
STATE_DIR="${COLIBRI_DOWNLOAD_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/colibri/downloads}"
HF_ENV_FILE="${COLIBRI_HF_ENV_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/colibri-setup/.env}"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

note() {
    printf '%s\n' "$*"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_uint() {
    local label="$1"
    local value="$2"

    [[ "$value" =~ ^[0-9]+$ ]] || die "${label} must be a non-negative integer."
}

require_positive_uint() {
    local label="$1"
    local value="$2"

    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "${label} must be a positive integer."
}

canonical_path() {
    readlink -m -- "$1"
}

format_bytes() {
    local bytes="$1"

    if command_exists numfmt; then
        numfmt --to=iec-i --suffix=B "$bytes"
    else
        printf '%s bytes' "$bytes"
    fi
}

encode_value() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

decode_value() {
    local value="$1"

    [[ -n "$value" ]] || return 0
    printf '%s' "$value" | base64 --decode 2>/dev/null
}

state_get() {
    local state_file="$1"
    local wanted_key="$2"
    local key encoded

    [[ -f "$state_file" ]] || return 1
    while IFS=$'\t' read -r key encoded; do
        if [[ "$key" == "$wanted_key" ]]; then
            decode_value "$encoded"
            return 0
        fi
    done < "$state_file"
    return 1
}

acquire_state_lock() {
    local state_file="$1"
    local lock_dir="${state_file}.write-lock"
    local attempt lock_mtime current_time

    for ((attempt = 0; attempt < 200; attempt++)); do
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s' "$lock_dir"
            return 0
        fi
        lock_mtime="$(stat -c '%Y' "$lock_dir" 2>/dev/null || printf '0')"
        current_time="$(date '+%s')"
        if [[ "$lock_mtime" =~ ^[0-9]+$ ]] && ((current_time - lock_mtime > 5)); then
            rmdir "$lock_dir" 2>/dev/null || true
        fi
        sleep 0.05
    done
    return 1
}

state_update() {
    local state_file="$1"
    shift
    local write_lock temp_file pair wanted_key wanted_value key encoded
    declare -A update_values=()
    declare -A seen_keys=()

    for pair in "$@"; do
        wanted_key="${pair%%=*}"
        wanted_value="${pair#*=}"
        update_values["$wanted_key"]="$wanted_value"
    done

    write_lock="$(acquire_state_lock "$state_file")" ||
        die "Could not lock download state: ${state_file}"
    temp_file="${state_file}.tmp.$$"

    : > "$temp_file" || {
        rmdir "$write_lock" 2>/dev/null || true
        die "Could not write download state: ${state_file}"
    }

    if [[ -f "$state_file" ]]; then
        while IFS=$'\t' read -r key encoded; do
            if [[ -v "update_values[$key]" ]]; then
                printf '%s\t%s\n' "$key" "$(encode_value "${update_values[$key]}")" >> "$temp_file"
                seen_keys["$key"]=1
            else
                printf '%s\t%s\n' "$key" "$encoded" >> "$temp_file"
            fi
        done < "$state_file"
    fi

    for wanted_key in "${!update_values[@]}"; do
        if [[ ! -v "seen_keys[$wanted_key]" ]]; then
            printf '%s\t%s\n' "$wanted_key" "$(encode_value "${update_values[$wanted_key]}")" >> "$temp_file"
        fi
    done

    if ! chmod 600 "$temp_file" || ! mv -f -- "$temp_file" "$state_file"; then
        rm -f -- "$temp_file" 2>/dev/null || true
        rmdir "$write_lock" 2>/dev/null || true
        die "Could not commit download state: ${state_file}"
    fi
    rmdir "$write_lock" 2>/dev/null || true
}

now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

make_job_id() {
    local model="$1"
    local destination="$2"
    local digest

    digest="$(printf '%s\0%s' "$model" "$destination" | sha256sum | cut -c1-12)"
    printf '%s-%s' "$(date -u '+%Y%m%dT%H%M%SZ')" "$digest"
}

session_is_running() {
    local screen_binary="$1"
    local session="$2"

    "$screen_binary" -S "$session" -Q windows >/dev/null 2>&1
}

validate_token_file() {
    local token_file="$1"
    local mode

    [[ -n "$token_file" ]] || return 0
    [[ -f "$token_file" ]] || die "Token file does not exist: ${token_file}"
    [[ ! -L "$token_file" ]] || die "Token file must not be a symbolic link: ${token_file}"
    mode="$(stat -c '%a' "$token_file" 2>/dev/null)" ||
        die "Could not inspect token-file permissions: ${token_file}"
    [[ "$mode" == "600" ]] ||
        die "Token file must have mode 0600 (run: chmod 600 '${token_file}')."
}

validate_token_value() {
    local token="$1"
    [[ "$token" =~ ^hf_[A-Za-z0-9]+$ ]] ||
        die "HF_TOKEN must be a Hugging Face user token beginning with 'hf_'."
}

load_token_file() {
    local token_file="$1"
    local -a token_lines=()
    local token_value

    validate_token_file "$token_file"
    mapfile -t token_lines <"$token_file"
    ((${#token_lines[@]} == 1)) ||
        die "Token file must contain exactly one value or HF_TOKEN assignment."
    token_value="${token_lines[0]}"
    if [[ "$token_value" == HF_TOKEN=* ]]; then
        token_value="${token_value#HF_TOKEN=}"
    fi
    validate_token_value "$token_value"
    HF_TOKEN="$token_value"
    export HF_TOKEN
    token_value=''
    unset token_value
}

write_default_token() {
    local token="$1"
    local config_dir
    local temporary_file

    validate_token_value "$token"
    config_dir="$(dirname "$HF_ENV_FILE")"
    umask 077
    mkdir -p -- "$config_dir"
    chmod 0700 -- "$config_dir"
    temporary_file="$(mktemp "${config_dir}/.env.tmp.XXXXXX")"
    printf 'HF_TOKEN=%s\n' "$token" >"$temporary_file"
    chmod 0600 "$temporary_file"
    mv -f -- "$temporary_file" "$HF_ENV_FILE"
}

prepare_token() {
    local token_file="$1"
    local prompt_for_token="$2"
    local entered_token=''

    if [[ -n "${HF_TOKEN:-}" ]]; then
        validate_token_value "$HF_TOKEN"
        export HF_TOKEN
        return 0
    fi

    if [[ -n "$token_file" ]]; then
        load_token_file "$token_file"
        return 0
    fi

    if [[ -e "$HF_ENV_FILE" ]]; then
        load_token_file "$HF_ENV_FILE"
        return 0
    fi

    if ((prompt_for_token == 1)) && [[ -t 0 ]]; then
        printf '\nA Hugging Face token is required for managed Hub access.\n'
        printf 'Create a read token at: https://huggingface.co/settings/tokens\n'
        IFS= read -r -s -p 'HF_TOKEN: ' entered_token
        printf '\n'
        [[ -n "$entered_token" ]] || die "HF_TOKEN was empty."
        validate_token_value "$entered_token"
        HF_TOKEN="$entered_token"
        export HF_TOKEN
        write_default_token "$HF_TOKEN"
        note "HF_TOKEN saved in ${HF_ENV_FILE} and exported for Hugging Face operations."
        entered_token=''
        unset entered_token
    else
        die "HF_TOKEN is required. Configure ${HF_ENV_FILE}, export it, or provide a mode-0600 --token-file."
    fi
}

confirm_download() {
    local model="$1"
    local destination="$2"
    local assume_yes="$3"
    local answer

    ((assume_yes == 1)) && return 0
    [[ -t 0 ]] ||
        die "Interactive confirmation is unavailable. Re-run with --yes after reviewing the destination."

    printf '\nModel:       %s\n' "$model"
    printf 'Destination: %s\n' "$destination"
    IFS= read -r -p 'Start this download? [y/N] ' answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || {
        note "Download not started."
        exit 0
    }
}

check_free_space() {
    local destination="$1"
    local expected_size_gb="$2"
    local min_free_gb="$3"
    local parent current_bytes expected_bytes remaining_bytes reserve_bytes required_bytes available_bytes

    parent="$(dirname "$destination")"
    mkdir -p -- "$parent"
    current_bytes=0
    [[ -d "$destination" ]] && current_bytes="$(du -sB1 -- "$destination" | awk '{print $1}')"
    expected_bytes=$((expected_size_gb * 1000000000))
    reserve_bytes=$((min_free_gb * 1000000000))
    remaining_bytes=0
    ((expected_bytes > current_bytes)) && remaining_bytes=$((expected_bytes - current_bytes))
    required_bytes=$((remaining_bytes + reserve_bytes))
    available_bytes="$(df -PB1 -- "$parent" | awk 'NR == 2 {print $4}')"

    [[ "$available_bytes" =~ ^[0-9]+$ ]] ||
        die "Could not determine free space for ${parent}."

    note "Space preflight: $(format_bytes "$available_bytes") available; $(format_bytes "$required_bytes") required (including reserve)."
    if ((available_bytes < required_bytes)); then
        die "Insufficient free space for this download. Existing partial files were included in the calculation."
    fi
}

destination_has_content() {
    local destination="$1"
    [[ -d "$destination" ]] && find "$destination" -mindepth 1 -print -quit | grep -q .
}

find_state_for_destination() {
    local destination="$1"
    local state_file saved_destination

    [[ -d "$STATE_DIR/jobs" ]] || return 1
    for state_file in "$STATE_DIR"/jobs/*.state; do
        [[ -f "$state_file" ]] || continue
        saved_destination="$(state_get "$state_file" destination || true)"
        if [[ "$saved_destination" == "$destination" ]]; then
            printf '%s' "$state_file"
            return 0
        fi
    done
    return 1
}

resolve_state_file() {
    local reference="${1:-}"
    local state_file match='' matches=0 value

    [[ -d "$STATE_DIR/jobs" ]] || return 1
    if [[ -n "$reference" && -f "$STATE_DIR/jobs/${reference}.state" ]]; then
        printf '%s' "$STATE_DIR/jobs/${reference}.state"
        return 0
    fi

    if [[ -z "$reference" ]]; then
        state_file="$(find "$STATE_DIR/jobs" -maxdepth 1 -type f -name '*.state' \
            -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2-)"
        [[ -n "$state_file" ]] || return 1
        printf '%s' "$state_file"
        return 0
    fi

    for state_file in "$STATE_DIR"/jobs/*.state; do
        [[ -f "$state_file" ]] || continue
        for value in \
            "$(state_get "$state_file" job_id || true)" \
            "$(state_get "$state_file" session || true)" \
            "$(basename "$(state_get "$state_file" destination || true)")"; do
            if [[ "$value" == "$reference" ]]; then
                match="$state_file"
                ((matches++))
                break
            fi
        done
    done

    ((matches == 1)) || return 1
    printf '%s' "$match"
}

release_download_lock() {
    local lock_dir="$1"

    [[ -n "$lock_dir" ]] || return 0
    rm -f -- "${lock_dir}/job-id" 2>/dev/null || true
    rmdir -- "$lock_dir" 2>/dev/null || true
}

acquire_download_lock() {
    local lock_dir="$1"
    local job_id="$2"

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$job_id" > "${lock_dir}/job-id"
        chmod 600 "${lock_dir}/job-id"
        return 0
    fi
    return 1
}

print_job_commands() {
    local job_id="$1"

    printf '\nUseful commands:\n'
    printf '  %q status %q\n' "$SCRIPT_PATH" "$job_id"
    printf '  %q attach %q\n' "$SCRIPT_PATH" "$job_id"
    printf '  %q cancel %q\n' "$SCRIPT_PATH" "$job_id"
    printf '  %q resume %q\n' "$SCRIPT_PATH" "$job_id"
}

start_screen_worker() {
    local state_file="$1"
    local screen_binary session job_id

    screen_binary="$(state_get "$state_file" screen_bin)"
    session="$(state_get "$state_file" session)"
    job_id="$(state_get "$state_file" job_id)"
    command_exists "$screen_binary" ||
        die "GNU Screen is not available at '${screen_binary}'. Install the 'screen' package."

    if ! "$screen_binary" -DmS "$session" bash "$SCRIPT_PATH" _worker "$state_file"; then
        state_update "$state_file" \
            "status=launch-failed" \
            "message=GNU Screen could not start the download worker." \
            "updated_at=$(now_utc)"
        release_download_lock "$(state_get "$state_file" lock_dir || true)"
        die "GNU Screen could not start the download worker."
    fi

    note "Download started in detached Screen session: ${session}"
    note "Job: ${job_id}"
    note "State: ${state_file}"
    note "Log: $(state_get "$state_file" log_file)"
    print_job_commands "$job_id"
}

start_command() {
    local model="$DEFAULT_MODEL"
    local folder=''
    local local_dir=''
    local models_dir="$MODELS_DIR"
    local hf_binary="$HF_BIN"
    local screen_binary="$SCREEN_BIN"
    local token_file=''
    local max_workers="$DEFAULT_MAX_WORKERS"
    local etag_timeout="$DEFAULT_ETAG_TIMEOUT"
    local download_timeout="$DEFAULT_DOWNLOAD_TIMEOUT"
    local max_retries="$DEFAULT_MAX_RETRIES"
    local retry_base="$DEFAULT_RETRY_BASE"
    local retry_max="$DEFAULT_RETRY_MAX"
    local expected_size_gb=''
    local min_free_gb="$DEFAULT_MIN_FREE_GB"
    local assume_yes=0
    local prompt_for_token=1
    local model_set=0
    local folder_set=0
    local destination job_id session state_file destination_hash lock_dir existing_state existing_status

    while (($#)); do
        case "$1" in
            --local-dir)
                (($# >= 2)) || die "--local-dir requires a path."
                local_dir="$2"
                shift 2
                ;;
            --models-dir)
                (($# >= 2)) || die "--models-dir requires a path."
                models_dir="$2"
                shift 2
                ;;
            --folder)
                (($# >= 2)) || die "--folder requires a name."
                folder="$2"
                folder_set=1
                shift 2
                ;;
            --hf-bin)
                (($# >= 2)) || die "--hf-bin requires a command or path."
                hf_binary="$2"
                shift 2
                ;;
            --screen-bin)
                (($# >= 2)) || die "--screen-bin requires a command or path."
                screen_binary="$2"
                shift 2
                ;;
            --token-file)
                (($# >= 2)) || die "--token-file requires a path."
                token_file="$(canonical_path "$2")"
                shift 2
                ;;
            --max-workers)
                (($# >= 2)) || die "--max-workers requires a value."
                max_workers="$2"
                shift 2
                ;;
            --etag-timeout)
                (($# >= 2)) || die "--etag-timeout requires seconds."
                etag_timeout="$2"
                shift 2
                ;;
            --download-timeout)
                (($# >= 2)) || die "--download-timeout requires seconds."
                download_timeout="$2"
                shift 2
                ;;
            --max-retries)
                (($# >= 2)) || die "--max-retries requires a value."
                max_retries="$2"
                shift 2
                ;;
            --retry-base)
                (($# >= 2)) || die "--retry-base requires seconds."
                retry_base="$2"
                shift 2
                ;;
            --retry-max)
                (($# >= 2)) || die "--retry-max requires seconds."
                retry_max="$2"
                shift 2
                ;;
            --expected-size-gb)
                (($# >= 2)) || die "--expected-size-gb requires a value."
                expected_size_gb="$2"
                shift 2
                ;;
            --min-free-gb)
                (($# >= 2)) || die "--min-free-gb requires a value."
                min_free_gb="$2"
                shift 2
                ;;
            --yes|-y)
                assume_yes=1
                shift
                ;;
            --no-token-prompt)
                prompt_for_token=0
                shift
                ;;
            --help|-h)
                usage_start
                exit 0
                ;;
            --)
                shift
                while (($#)); do
                    if ((model_set == 0)); then
                        model="$1"
                        model_set=1
                    elif ((folder_set == 0)); then
                        folder="$1"
                        folder_set=1
                    else
                        die "Unexpected argument: $1"
                    fi
                    shift
                done
                ;;
            -*)
                die "Unknown start option: $1"
                ;;
            *)
                if ((model_set == 0)); then
                    model="$1"
                    model_set=1
                elif ((folder_set == 0)); then
                    folder="$1"
                    folder_set=1
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ "$model" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] ||
        die "Model must be a Hugging Face repository in owner/name form."
    if ((folder_set == 1)) && [[ "$folder" == */* ]]; then
        [[ -z "$local_dir" ]] ||
            die "A destination path and --local-dir cannot both be supplied."
        local_dir="$folder"
        folder=''
        folder_set=0
    fi
    [[ -z "$local_dir" || $folder_set -eq 0 ]] ||
        die "--local-dir and --folder cannot be used together."
    if [[ -z "$folder" ]]; then
        folder="${model##*/}"
    fi
    [[ "$folder" != */* && "$folder" != "." && "$folder" != ".." ]] ||
        die "Folder must be a single safe directory name; use --local-dir for a path."

    require_positive_uint "--max-workers" "$max_workers"
    require_positive_uint "--etag-timeout" "$etag_timeout"
    require_positive_uint "--download-timeout" "$download_timeout"
    require_uint "--max-retries" "$max_retries"
    require_positive_uint "--retry-base" "$retry_base"
    require_positive_uint "--retry-max" "$retry_max"
    require_uint "--min-free-gb" "$min_free_gb"
    ((retry_max >= retry_base)) || die "--retry-max must be greater than or equal to --retry-base."

    if [[ -z "$expected_size_gb" ]]; then
        if [[ "$model" == "$DEFAULT_MODEL" ]]; then
            expected_size_gb="$DEFAULT_EXPECTED_SIZE_GB"
        else
            expected_size_gb=0
            warn "Model size is unknown; only the configured free-space reserve will be checked."
        fi
    fi
    require_uint "--expected-size-gb" "$expected_size_gb"

    if [[ -n "$local_dir" ]]; then
        destination="$(canonical_path "$local_dir")"
    else
        destination="$(canonical_path "${models_dir}/${folder}")"
    fi
    [[ "$destination" != "/" ]] || die "The filesystem root cannot be used as a model destination."

    command_exists "$hf_binary" ||
        die "Hugging Face CLI '${hf_binary}' was not found. Install it with: pipx install 'huggingface_hub[cli]'"
    command_exists "$screen_binary" ||
        die "GNU Screen '${screen_binary}' was not found. Install it with your operating system package manager."
    command_exists base64 || die "The 'base64' command is required."
    command_exists sha256sum || die "The 'sha256sum' command is required."

    mkdir -p "$STATE_DIR/jobs" "$STATE_DIR/logs" "$STATE_DIR/locks"
    chmod 700 "$STATE_DIR" "$STATE_DIR/jobs" "$STATE_DIR/logs" "$STATE_DIR/locks"

    existing_state="$(find_state_for_destination "$destination" || true)"
    if [[ -n "$existing_state" ]]; then
        existing_status="$(state_get "$existing_state" status || true)"
        if session_is_running "$(state_get "$existing_state" screen_bin)" \
            "$(state_get "$existing_state" session)"; then
            die "A download already owns this destination (job $(state_get "$existing_state" job_id))."
        fi
        die "This destination already has job state '${existing_status}'. Use '${PROGRAM_NAME} resume $(state_get "$existing_state" job_id)'."
    fi
    if destination_has_content "$destination"; then
        die "Destination is not empty and has no managed job state: ${destination}. Move it, or use a different destination."
    fi

    check_free_space "$destination" "$expected_size_gb" "$min_free_gb"
    confirm_download "$model" "$destination" "$assume_yes"
    validate_token_file "$token_file"
    prepare_token "$token_file" "$prompt_for_token"

    job_id="$(make_job_id "$model" "$destination")"
    session="colibri-hf-${job_id}"
    destination_hash="$(printf '%s' "$destination" | sha256sum | cut -c1-24)"
    lock_dir="${STATE_DIR}/locks/${destination_hash}.lock"
    acquire_download_lock "$lock_dir" "$job_id" ||
        die "Destination lock already exists: ${lock_dir}. Check active jobs with '${PROGRAM_NAME} status'."

    state_file="${STATE_DIR}/jobs/${job_id}.state"
    state_update "$state_file" \
        "job_id=${job_id}" \
        "model=${model}" \
        "destination=${destination}" \
        "session=${session}" \
        "status=queued" \
        "message=Waiting for the download worker to start." \
        "created_at=$(now_utc)" \
        "updated_at=$(now_utc)" \
        "completed_at=" \
        "attempt=0" \
        "hf_bin=${hf_binary}" \
        "screen_bin=${screen_binary}" \
        "token_file=${token_file}" \
        "max_workers=${max_workers}" \
        "etag_timeout=${etag_timeout}" \
        "download_timeout=${download_timeout}" \
        "max_retries=${max_retries}" \
        "retry_base=${retry_base}" \
        "retry_max=${retry_max}" \
        "expected_size_gb=${expected_size_gb}" \
        "min_free_gb=${min_free_gb}" \
        "lock_dir=${lock_dir}" \
        "log_file=${STATE_DIR}/logs/${job_id}.log"

    start_screen_worker "$state_file"
}

sanitize_stream() {
    local secret="${HF_TOKEN:-}"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "$secret" ]]; then
            line="${line//"$secret"/[REDACTED]}"
        fi
        printf '%s\n' "$line"
    done
}

validate_download() {
    local destination="$1"
    local found

    [[ -s "${destination}/config.json" ]] || {
        printf 'config.json is missing or empty'
        return 1
    }
    [[ -s "${destination}/tokenizer.json" ]] || {
        printf 'tokenizer.json is missing or empty'
        return 1
    }
    found="$(find "$destination" -type f -name '*.safetensors' -size +0c -print -quit)"
    [[ -n "$found" ]] || {
        printf 'no non-empty safetensors files were found'
        return 1
    }
    found="$(find "$destination" -type f -iname '*out-mtp*' -size +0c -print -quit)"
    [[ -n "$found" ]] || {
        printf 'no non-empty out-mtp files were found'
        return 1
    }
}

attempt_has_permanent_error() {
    local attempt_log="$1"

    grep -Eqi \
        '(^|[^0-9])(401|403|404)([^0-9]|$)|unauthori[sz]ed|forbidden|repository[[:space:]]+not[[:space:]]+found|entry[[:space:]]+not[[:space:]]+found|no[[:space:]]+space[[:space:]]+left|disk[[:space:]]+quota|permission[[:space:]]+denied|read-only[[:space:]]+file[[:space:]]+system' \
        "$attempt_log"
}

worker_cleanup() {
    local state_file="$1"
    release_download_lock "$(state_get "$state_file" lock_dir || true)"
}

worker_interrupted() {
    local state_file="$1"

    trap - INT TERM HUP
    state_update "$state_file" \
        "status=canceled" \
        "message=Download worker was stopped; partial files remain resumable." \
        "updated_at=$(now_utc)"
    worker_cleanup "$state_file"
    exit 130
}

worker_command() {
    local state_file="${1:-}"
    local model destination hf_binary token_file max_workers etag_timeout download_timeout
    local max_retries retry_base retry_max log_file attempt_log attempt rc delay validation_error

    [[ -n "$state_file" && -f "$state_file" ]] || die "Worker state file is missing."
    trap 'worker_interrupted "$state_file"' INT TERM HUP

    model="$(state_get "$state_file" model)"
    destination="$(state_get "$state_file" destination)"
    hf_binary="$(state_get "$state_file" hf_bin)"
    token_file="$(state_get "$state_file" token_file || true)"
    max_workers="$(state_get "$state_file" max_workers)"
    etag_timeout="$(state_get "$state_file" etag_timeout)"
    download_timeout="$(state_get "$state_file" download_timeout)"
    max_retries="$(state_get "$state_file" max_retries)"
    retry_base="$(state_get "$state_file" retry_base)"
    retry_max="$(state_get "$state_file" retry_max)"
    log_file="$(state_get "$state_file" log_file)"
    attempt_log="${log_file}.attempt"

    prepare_token "$token_file" 0

    mkdir -p -- "$destination"
    chmod 700 "$(dirname "$log_file")" 2>/dev/null || true
    touch "$log_file"
    chmod 600 "$log_file"
    export HF_HUB_ETAG_TIMEOUT="$etag_timeout"
    export HF_HUB_DOWNLOAD_TIMEOUT="$download_timeout"
    export HF_HUB_DISABLE_TELEMETRY=1

    attempt=0
    while ((attempt <= max_retries)); do
        ((attempt++))
        : > "$attempt_log"
        chmod 600 "$attempt_log"
        state_update "$state_file" \
            "status=downloading" \
            "message=Hugging Face download attempt ${attempt} is running." \
            "attempt=${attempt}" \
            "updated_at=$(now_utc)"

        {
            printf '\n[%s] Download attempt %d of %d\n' \
                "$(now_utc)" "$attempt" "$((max_retries + 1))"
        } | tee -a "$log_file"

        set +e
        "$hf_binary" download "$model" \
            --repo-type model \
            --local-dir "$destination" \
            --max-workers "$max_workers" 2>&1 |
            sanitize_stream |
            tee -a "$log_file" "$attempt_log"
        rc=${PIPESTATUS[0]}
        set -e

        if ((rc == 0)); then
            if validation_error="$(validate_download "$destination")"; then
                rm -f -- "$attempt_log"
                state_update "$state_file" \
                    "status=complete" \
                    "message=Download completed and required model files were validated." \
                    "updated_at=$(now_utc)" \
                    "completed_at=$(now_utc)"
                note "Download completed and validated: ${destination}"
                worker_cleanup "$state_file"
                return 0
            fi
            printf '[%s] Validation incomplete: %s\n' "$(now_utc)" "$validation_error" |
                tee -a "$log_file" "$attempt_log"
            rc=65
        fi

        if attempt_has_permanent_error "$attempt_log"; then
            rm -f -- "$attempt_log"
            state_update "$state_file" \
                "status=failed-permanent" \
                "message=Download stopped after a permanent authentication, repository, permission, or storage error. Correct it, then resume." \
                "updated_at=$(now_utc)"
            worker_cleanup "$state_file"
            return "$rc"
        fi

        if ((attempt > max_retries)); then
            rm -f -- "$attempt_log"
            state_update "$state_file" \
                "status=failed-retries" \
                "message=Download exhausted ${max_retries} retries. Partial files remain resumable." \
                "updated_at=$(now_utc)"
            worker_cleanup "$state_file"
            return "$rc"
        fi

        delay="$retry_base"
        if ((attempt > 1)); then
            local backoff_step
            for ((backoff_step = 1; backoff_step < attempt; backoff_step++)); do
                if ((delay >= retry_max || delay > retry_max / 2)); then
                    delay="$retry_max"
                    break
                fi
                delay=$((delay * 2))
            done
        fi
        ((delay > retry_max)) && delay="$retry_max"
        state_update "$state_file" \
            "status=retrying" \
            "message=Transient failure; retrying in ${delay} seconds." \
            "updated_at=$(now_utc)"
        printf '[%s] Transient failure (exit %d). Retrying in %d seconds.\n' \
            "$(now_utc)" "$rc" "$delay" | tee -a "$log_file"
        sleep "$delay"
    done
}

show_one_status() {
    local state_file="$1"
    local job_id status session screen_binary running='no'

    job_id="$(state_get "$state_file" job_id)"
    status="$(state_get "$state_file" status)"
    session="$(state_get "$state_file" session)"
    screen_binary="$(state_get "$state_file" screen_bin)"
    session_is_running "$screen_binary" "$session" && running='yes'

    printf 'Job:         %s\n' "$job_id"
    printf 'Status:      %s\n' "$status"
    printf 'Worker:      %s\n' "$running"
    printf 'Model:       %s\n' "$(state_get "$state_file" model)"
    printf 'Destination: %s\n' "$(state_get "$state_file" destination)"
    printf 'Attempt:     %s\n' "$(state_get "$state_file" attempt)"
    printf 'Updated:     %s\n' "$(state_get "$state_file" updated_at)"
    printf 'Message:     %s\n' "$(state_get "$state_file" message)"
    printf 'Log:         %s\n' "$(state_get "$state_file" log_file)"
    if [[ "$running" == "no" && "$status" =~ ^(queued|downloading|retrying)$ ]]; then
        warn "State says '${status}', but its Screen worker is not running. Use '${PROGRAM_NAME} resume ${job_id}'."
    fi
}

status_command() {
    local reference="${1:-}"
    local state_file first=1

    if [[ -n "$reference" ]]; then
        state_file="$(resolve_state_file "$reference")" ||
            die "No unique download job matches '${reference}'."
        show_one_status "$state_file"
        return
    fi

    [[ -d "$STATE_DIR/jobs" ]] || {
        note "No managed model downloads were found."
        return
    }
    for state_file in "$STATE_DIR"/jobs/*.state; do
        [[ -f "$state_file" ]] || continue
        ((first == 1)) || printf '\n'
        show_one_status "$state_file"
        first=0
    done
    ((first == 0)) || note "No managed model downloads were found."
}

attach_command() {
    local reference="${1:-}"
    local state_file session screen_binary

    state_file="$(resolve_state_file "$reference")" ||
        die "No unique download job matches '${reference:-latest}'."
    session="$(state_get "$state_file" session)"
    screen_binary="$(state_get "$state_file" screen_bin)"
    session_is_running "$screen_binary" "$session" ||
        die "The Screen worker is not running. Review '${PROGRAM_NAME} status $(state_get "$state_file" job_id)' and resume if needed."
    note "Detach without stopping the download by pressing Ctrl-A, then D."
    exec "$screen_binary" -r "$session"
}

cancel_command() {
    local reference="${1:-}"
    local state_file session screen_binary lock_dir

    state_file="$(resolve_state_file "$reference")" ||
        die "No unique download job matches '${reference:-latest}'."
    session="$(state_get "$state_file" session)"
    screen_binary="$(state_get "$state_file" screen_bin)"
    lock_dir="$(state_get "$state_file" lock_dir || true)"

    if session_is_running "$screen_binary" "$session"; then
        "$screen_binary" -S "$session" -X quit || die "Could not stop Screen session ${session}."
        sleep 1
    fi
    state_update "$state_file" \
        "status=canceled" \
        "message=Download canceled; partial model data was preserved and can be resumed." \
        "updated_at=$(now_utc)"
    release_download_lock "$lock_dir"
    note "Download stopped. Partial model files were preserved."
    note "Resume with: ${SCRIPT_PATH} resume $(state_get "$state_file" job_id)"
}

resume_command() {
    local reference=''
    local token_file_override=''
    local prompt_for_token=1
    local state_file status session screen_binary lock_dir job_id destination

    while (($#)); do
        case "$1" in
            --token-file)
                (($# >= 2)) || die "--token-file requires a path."
                token_file_override="$(canonical_path "$2")"
                shift 2
                ;;
            --no-token-prompt)
                prompt_for_token=0
                shift
                ;;
            --help|-h)
                usage_resume
                exit 0
                ;;
            -*)
                die "Unknown resume option: $1"
                ;;
            *)
                [[ -z "$reference" ]] || die "Resume accepts only one job reference."
                reference="$1"
                shift
                ;;
        esac
    done

    state_file="$(resolve_state_file "$reference")" ||
        die "No unique download job matches '${reference:-latest}'."
    status="$(state_get "$state_file" status)"
    [[ "$status" != "complete" ]] || die "This download is already complete."
    session="$(state_get "$state_file" session)"
    screen_binary="$(state_get "$state_file" screen_bin)"
    session_is_running "$screen_binary" "$session" &&
        die "This job is already running. Use '${PROGRAM_NAME} attach $(state_get "$state_file" job_id)'."

    if [[ -n "$token_file_override" ]]; then
        validate_token_file "$token_file_override"
        state_update "$state_file" "token_file=${token_file_override}"
    fi
    prepare_token "$(state_get "$state_file" token_file || true)" "$prompt_for_token"

    job_id="$(state_get "$state_file" job_id)"
    destination="$(state_get "$state_file" destination)"
    lock_dir="$(state_get "$state_file" lock_dir)"
    release_download_lock "$lock_dir"
    acquire_download_lock "$lock_dir" "$job_id" ||
        die "Could not acquire the destination lock. Another download may be using ${destination}."
    state_update "$state_file" \
        "status=queued" \
        "message=Resumed job is waiting for its download worker." \
        "updated_at=$(now_utc)" \
        "completed_at="
    start_screen_worker "$state_file"
}

usage_start() {
    cat <<EOF
Usage:
  ${PROGRAM_NAME} start [MODEL [FOLDER]] [OPTIONS]

Start a resumable Hugging Face model download in a detached GNU Screen session.

Defaults:
  Model:         ${DEFAULT_MODEL}
  Expected size: approximately ${DEFAULT_EXPECTED_SIZE_GB} GB
  Models dir:    ${MODELS_DIR}

Options:
  --local-dir DIR          Exact destination (instead of models-dir/folder)
  --models-dir DIR         Parent model directory
  --folder NAME            Destination folder below models-dir
  --hf-bin COMMAND         Hugging Face CLI command/path (default: ${HF_BIN})
  --screen-bin COMMAND     GNU Screen command/path (default: ${SCREEN_BIN})
  --token-file FILE        Read token from a regular mode-0600 file
  --max-workers N          Parallel Hugging Face workers (default: ${DEFAULT_MAX_WORKERS})
  --etag-timeout SECONDS   Metadata timeout (default: ${DEFAULT_ETAG_TIMEOUT})
  --download-timeout SEC   Per-download timeout (default: ${DEFAULT_DOWNLOAD_TIMEOUT})
  --max-retries N          Retries after the first attempt (default: ${DEFAULT_MAX_RETRIES})
  --retry-base SECONDS     Initial retry delay (default: ${DEFAULT_RETRY_BASE})
  --retry-max SECONDS      Maximum retry delay (default: ${DEFAULT_RETRY_MAX})
  --expected-size-gb N     Expected final size for the free-space check
  --min-free-gb N          Space reserved beyond expected remaining data
  --no-token-prompt        Do not prompt when HF_TOKEN is absent
  --yes, -y                Confirm the download non-interactively

HF_TOKEN is required. It is loaded automatically from ${HF_ENV_FILE}, may be
inherited from the environment, or may be supplied through --token-file. Its
value is exported to the hf subprocess and is never written to arguments,
logs, or job state.
EOF
}

usage_resume() {
    cat <<EOF
Usage:
  ${PROGRAM_NAME} resume [JOB] [--token-file FILE] [--no-token-prompt]

Resume the latest job, or the job selected by ID, Screen name, or unique folder.
Partial model data is retained and Hugging Face resumes missing files.
EOF
}

usage() {
    cat <<EOF
Usage:
  ${PROGRAM_NAME} start [MODEL [FOLDER]] [OPTIONS]
  ${PROGRAM_NAME} status [JOB]
  ${PROGRAM_NAME} attach [JOB]
  ${PROGRAM_NAME} cancel [JOB]
  ${PROGRAM_NAME} resume [JOB] [OPTIONS]

Commands:
  start     Confirm and launch a detached, resumable download
  status    Show one job or all managed jobs
  attach    Open the job's Screen session (Ctrl-A, D detaches safely)
  cancel    Stop the worker without deleting any model files
  resume    Continue a stopped or failed job

Run '${PROGRAM_NAME} start --help' for download tuning options.
EOF
}

main() {
    local command="${1:-help}"
    (($# == 0)) || shift

    case "$command" in
        start)
            start_command "$@"
            ;;
        status)
            (($# <= 1)) || die "Status accepts at most one job reference."
            status_command "${1:-}"
            ;;
        attach)
            (($# <= 1)) || die "Attach accepts at most one job reference."
            attach_command "${1:-}"
            ;;
        cancel)
            (($# <= 1)) || die "Cancel accepts at most one job reference."
            cancel_command "${1:-}"
            ;;
        resume)
            resume_command "$@"
            ;;
        _worker)
            (($# == 1)) || die "Worker requires exactly one state file."
            worker_command "$1"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            die "Unknown command '${command}'. Run '${PROGRAM_NAME} --help'."
            ;;
    esac
}

main "$@"
