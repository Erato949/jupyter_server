#!/bin/bash
set -e

# Define key paths used throughout the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
VENV_DIR="$PROJECT_DIR/venv"
PID_FILE="$PROJECT_DIR/jupyter_server.pid"
LOG_FILE="$PROJECT_DIR/jupyter_server.log"

# Parse CLI arguments for automation flags
AUTO_MODE=""
for arg in "$@"; do
  case $arg in
    --auto-all)
      AUTO_MODE="all"
      ;;
    --auto-none)
      AUTO_MODE="none"
      ;;
    --auto=*)
      AUTO_MODE="${arg#*=}"
      ;;
    --prompt)
      AUTO_MODE="prompt"
      ;;
  esac
done

# Function to install optional dependency groups
install_optional() {
    local group=$1
    local py_exe=$2 # Expect venv python exe (passed by setup_environment)
    local proj_dir_win="$3" # Expect Windows project dir path (passed by setup_environment, ensure quotes)

    # Construct Windows path within quotes
    local req_file_win="$proj_dir_win/requirements-${group}.txt"
    # Need bash path for file existence check ONLY
    local req_file_bash="$(dirname "${BASH_SOURCE[0]}")/requirements-${group}.txt"

    echo "Installing optional group: $group (checking $req_file_bash)"
    if [ -f "$req_file_bash" ]; then
         # Use quotes around py_exe and req_file_win
         echo "  Running: \"$py_exe\" -m pip install -r \"$req_file_win\""
         "$py_exe" -m pip install -r "$req_file_win"
    else
        echo "Warning: requirements-${group}.txt not found (checked $req_file_bash), skipping."
    fi
}

# Setup Environment: Creates venv (if needed externally), installs base and optional requirements.
setup_environment() {
    local proj_dir_win="$1" # Expect Windows project dir path from the calling process

    if [ -z "$proj_dir_win" ]; then
        echo " ERROR: Windows Project Directory path was not provided to setup_environment function."
        exit 1
    fi

    echo " Assuming virtual environment directory already exists at $VENV_DIR (Bash path)"
    # Print received path carefully
    echo " Using Windows Project Directory for requirements: $proj_dir_win"

    # Check if the venv directory actually exists (using bash path)
    if [ ! -d "$VENV_DIR" ]; then
        echo " ERROR: Virtual environment directory $VENV_DIR does not exist. It should have been created by the calling process."
        exit 1
    fi

    # --- Find Python executable INSIDE the venv --- 
    # This ensures we use the correct interpreter within the virtual environment.
    VENV_PYTHON_EXE=""
    if [ -f "$VENV_DIR/Scripts/python.exe" ]; then
        # Windows - use directly
        VENV_PYTHON_EXE="$VENV_DIR/Scripts/python.exe"
    elif [ -f "$VENV_DIR/bin/python" ]; then
        # Linux/macOS
        VENV_PYTHON_EXE="$VENV_DIR/bin/python"
    else
        echo " ERROR: Could not find python executable INSIDE the created/existing venv ($VENV_DIR/Scripts or $VENV_DIR/bin)"
        exit 1
    fi
    # --- End find venv Python ---

    echo " Using venv Python for pip: $VENV_PYTHON_EXE"

    # Construct Windows path for requirements file, ensuring quotes for pip.
    REQUIREMENTS_BASE_WIN="$proj_dir_win/requirements-base.txt"
    # Print constructed path carefully
    echo " Using base requirements path for pip: $REQUIREMENTS_BASE_WIN"

    echo "Installing core requirements (base)..."
    # Use quotes around py_exe and REQUIREMENTS_BASE_WIN
    echo "  Running: \"$VENV_PYTHON_EXE\" -m pip install --upgrade pip"
    "$VENV_PYTHON_EXE" -m pip install --upgrade pip
    echo "  Running: \"$VENV_PYTHON_EXE\" -m pip install -r \"$REQUIREMENTS_BASE_WIN\""
    "$VENV_PYTHON_EXE" -m pip install -r "$REQUIREMENTS_BASE_WIN"

    echo " Optional installs mode: $AUTO_MODE"

    local optional_args="${@:2}" # Get all args after the windows path
    AUTO_MODE=""
    for arg in $optional_args; do
      case $arg in
        --auto-all) AUTO_MODE="all";; --auto-none) AUTO_MODE="none";; --auto=*) AUTO_MODE="${arg#*=}";; --prompt) AUTO_MODE="prompt";;
      esac
    done

    if [[ $AUTO_MODE == "all" ]]; then
        install_optional "gpu" "$VENV_PYTHON_EXE" "$proj_dir_win"
        install_optional "rag" "$VENV_PYTHON_EXE" "$proj_dir_win"
        install_optional "agents" "$VENV_PYTHON_EXE" "$proj_dir_win"
        install_optional "llm-training" "$VENV_PYTHON_EXE" "$proj_dir_win"

    elif [[ $AUTO_MODE == "none" ]]; then
        echo "Skipping all optional installs."

    elif [[ $AUTO_MODE == "prompt" || -z $AUTO_MODE ]]; then
        read -p "Install optional GPU packages? (yes/no): " install_gpu
        if [[ $install_gpu == "yes" ]]; then install_optional "gpu" "$VENV_PYTHON_EXE" "$proj_dir_win"; fi

        read -p "Install optional RAG packages? (yes/no): " install_rag
        if [[ $install_rag == "yes" ]]; then install_optional "rag" "$VENV_PYTHON_EXE" "$proj_dir_win"; fi

        read -p "Install optional Agents packages? (yes/no): " install_agents
        if [[ $install_agents == "yes" ]]; then install_optional "agents" "$VENV_PYTHON_EXE" "$proj_dir_win"; fi

        read -p "Install optional LLM Training packages? (yes/no): " install_llm
        if [[ $install_llm == "yes" ]]; then install_optional "llm-training" "$VENV_PYTHON_EXE" "$proj_dir_win"; fi
    else
        IFS=',' read -ra OPT_GROUPS <<< "$AUTO_MODE"
        for group in "${OPT_GROUPS[@]}"; do
            install_optional "$group" "$VENV_PYTHON_EXE" "$proj_dir_win"
        done
    fi
}

# Start Jupyter Server: Finds venv python, starts server in background, saves PID.
start_server() {
    # --- Add Internal Venv Python Finding Logic ---
    # Script finds the python executable within the expected venv structure.
    local venv_python_exe=""
    if [ -f "$VENV_DIR/Scripts/python.exe" ]; then
        venv_python_exe="$VENV_DIR/Scripts/python.exe"
    elif [ -f "$VENV_DIR/bin/python" ]; then
        venv_python_exe="$VENV_DIR/bin/python"
    else
        echo " ERROR: Could not find python executable INSIDE venv ($VENV_DIR/Scripts or $VENV_DIR/bin) needed to start server."
        exit 1
    fi
    echo " Using venv Python: $venv_python_exe"
    # --- End Internal Finding Logic ---

    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null; then
            echo " Jupyter server is already running (PID $PID)."
            exit 0
        else
            echo " Stale PID file found. Removing..."
            rm "$PID_FILE"
        fi
    fi

    echo "Starting Jupyter Notebook server in the background..."
    # CRITICAL FIX: Changed --ip=0.0.0.0 to --ip=127.0.0.1 and removed --NotebookApp.token=''
    nohup "$venv_python_exe" -m jupyter notebook --no-browser --ip=127.0.0.1 >> "$LOG_FILE" 2>&1 &
    server_pid=$!
    echo "Starting Jupyter server in the background... Logging to $LOG_FILE"
    echo $server_pid > "$PID_FILE"
    echo " Jupyter server started. PID $(cat "$PID_FILE")"
}

# Stop Jupyter Server: Reads PID file, kills process, removes PID file.
stop_server() {
    if [ ! -f "$PID_FILE" ]; then
        echo "No PID file found. Server may not be running."
        exit 1
    fi

    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null; then
        echo "Stopping Jupyter server (PID $PID)..."
        kill $PID
        rm "$PID_FILE"
        echo " Server stopped."
    else
        echo "Process $PID not found. Removing stale PID file."
        rm "$PID_FILE"
    fi
}

# Restart Jupyter Server: Calls stop_server then start_server.
restart_server() {
    echo "Restarting Jupyter server..."
    stop_server
    sleep 2 # Give it a moment to fully stop
    start_server # Call start_server without the argument
}

# Status of Jupyter Server
status_server() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null; then
            echo " Jupyter server is running (PID $PID)."
        else
            echo " PID file exists but process $PID not running."
        fi
    else
        echo " No running Jupyter server found."
    fi
}

# --- Main Execution Logic --- 

# Main command router: Determines which function to call based on the first argument.
COMMAND=$1
# ARG2 is now only relevant for setup (Windows project directory path)
ARG2=$2 

# Main command router
case $COMMAND in
    start)
        start_server
        ;;
    stop)
        stop_server
        ;;
    restart)
        restart_server
        ;;
    status)
        status_server
        ;;
    setup)
        # Expects Windows project dir path as ARG2, optional flags follow
        setup_environment "$ARG2" "${@:3}"
        ;;
    *)
        # Update usage message to reflect that start/restart no longer take python path
        echo "Usage: $0 {start|stop|restart|status|setup <win_proj_dir_path> [optional_flags]}"
        exit 1
        ;;
esac
