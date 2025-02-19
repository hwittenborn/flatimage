#!/tmp/fim/bin/bash

######################################################################
# @author      : Ruan E. Formigoni (ruanformigoni@gmail.com)
# @file        : _boot
# @created     : Monday Jan 23, 2023 21:18:26 -03
#
# @description : Boot fim in chroot
######################################################################

#shellcheck disable=2155

set -e

PID="$$"

export FIM_DIST="TRUNK"

# Rootless tool
export FIM_BACKEND

# Perms
export FIM_ROOT="${FIM_ROOT:+1}"
export FIM_NORM="1"
export FIM_NORM="${FIM_NORM#"${FIM_ROOT}"}"

# Mode
export FIM_RO="${FIM_RO:+1}"
export FIM_RW="1"
export FIM_RW="${FIM_RW#"${FIM_RO}"}"

# Debug
export FIM_DEBUG="${FIM_DEBUG:+1}"
export FIM_NDEBUG="1"
export FIM_NDEBUG="${FIM_NDEBUG#"${FIM_DEBUG}"}"

# Filesystem offset
export FIM_OFFSET="${FIM_OFFSET:?FIM_OFFSET is unset or null}"
export FIM_SECTOR=$((FIM_OFFSET/512))

# Paths
export FIM_DIR_GLOBAL="${FIM_DIR_GLOBAL:?FIM_DIR_GLOBAL is unset or null}"
export FIM_DIR_GLOBAL_BIN="${FIM_DIR_GLOBAL}/bin"
export FIM_DIR_MOUNT="${FIM_DIR_MOUNT:?FIM_DIR_MOUNT is unset or null}"
export FIM_DIR_STATIC="$FIM_DIR_MOUNT/fim/static"
export FIM_FILE_CONFIG="$FIM_DIR_MOUNT/fim/config"
export FIM_DIR_TEMP="${FIM_DIR_TEMP:?FIM_DIR_TEMP is unset or null}"
export FIM_FILE_BINARY="${FIM_FILE_BINARY:?FIM_FILE_BINARY is unset or null}"
export FIM_DIR_BINARY="$(dirname "$FIM_FILE_BINARY")"
export FIM_FILE_BASH="$FIM_DIR_GLOBAL_BIN/bash"
export BASHRC_FILE="$FIM_DIR_TEMP/.bashrc"
export FIM_FILE_PERMS="$FIM_DIR_MOUNT"/fim/perms

# Compression
export FIM_COMPRESSION_LEVEL="${FIM_COMPRESSION_LEVEL:-4}"
export FIM_COMPRESSION_SLACK="${FIM_COMPRESSION_SLACK:-50000}" # 50MB
export FIM_COMPRESSION_DIRS="${FIM_COMPRESSION_DIRS:-/usr /opt}"

# Output stream
export FIM_STREAM="${FIM_DEBUG:+/dev/stdout}"
export FIM_STREAM="${FIM_STREAM:-/dev/null}"

# Emits a message in &2
# $(1..n-1) arguments to echo
# $n message
function _msg()
{
  [ -z "$FIM_DEBUG" ] || echo -e "${@:1:${#@}-1}" "[\033[32m*\033[m] ${*: -1}" >&2;
}

# Wait for a pid to finish execution, similar to 'wait'
# but also works for non-child pids
# $1: pid
function _wait()
{
  # Get pid
  local pid="$1"

  # Wait for process to finish
  while kill -0 "$pid" 2>/dev/null; do
    _msg "Pid $pid running..."
    sleep .1
  done
  _msg "Pid $pid finished..."
}

# Mount the main filesystem
function _mount()
{
  local mode="${FIM_RW:-ro,}"
  local mode="${mode#1}"
  "$FIM_DIR_GLOBAL_BIN"/fuse2fs -o "$mode"fakeroot,offset="$FIM_OFFSET" "$FIM_FILE_BINARY" "$FIM_DIR_MOUNT" &> "$FIM_STREAM"
}

# Unmount the main filesystem
function _unmount()
{
  # Get parent pid
  local ppid="$(pgrep -f "fuse2fs.*offset=$FIM_OFFSET.*$FIM_FILE_BINARY")"

  fusermount -zu "$FIM_DIR_MOUNT"

  _wait "$ppid"
}

# Re-mount the filesystem in new mountpoint
# $1 New mountpoint
function _re_mount()
{
  # Umount from initial mountpoint
  _unmount
  # Mount in new mountpoint
  export FIM_DIR_MOUNT="$1"; _mount
}

# Quits the program
# $* = Termination message
function _die()
{
  [ -z "$*" ] || FIM_DEBUG=1 _msg "$*"
  # Unmount dwarfs
  local sha="$(_config_fetch "sha")"
  if [ -n "$sha" ]; then
    shopt -s nullglob
    for i in "$FIM_DIR_GLOBAL"/dwarfs/"$sha"/*; do
      # Check if is mounted
      if mount | grep "$i" &>/dev/null; then
        # Get parent pid
        local ppid="$(pgrep -f "dwarfs2.*$i")"
        fusermount -zu "$FIM_DIR_GLOBAL"/dwarfs/"$sha"/"$(basename "$i")" &> "$FIM_STREAM" || true
        _wait "$ppid"
      fi
    done
  fi
  # Unmount image
  _unmount &> "$FIM_STREAM"
  # Exit
  kill -s SIGTERM "$PID"
}

trap _die SIGINT EXIT

function _copy_tools()
{
  FIM_RO=1 FIM_RW="" _mount

  for i; do
    local tool="$i"

    if [ ! -f "$FIM_DIR_GLOBAL_BIN"/"$tool" ]; then
      cp "$FIM_DIR_MOUNT/fim/static/$tool" "$FIM_DIR_GLOBAL_BIN"
      chmod +x "$FIM_DIR_GLOBAL_BIN"/"$tool"
    fi
  done

  _unmount
}

# List permissions of sandbox
function _perms_list()
{
  ! grep -i "FIM_PERM_PULSEAUDIO" "$FIM_FILE_PERMS"  &>/dev/null || echo "pulseaudio"
  ! grep -i "FIM_PERM_WAYLAND" "$FIM_FILE_PERMS"     &>/dev/null || echo "wayland"
  ! grep -i "FIM_PERM_X11" "$FIM_FILE_PERMS"         &>/dev/null || echo "x11"
  ! grep -i "FIM_PERM_SESSION_BUS" "$FIM_FILE_PERMS" &>/dev/null || echo "session_bus"
  ! grep -i "FIM_PERM_SYSTEM_BUS" "$FIM_FILE_PERMS"  &>/dev/null || echo "system_bus"
  ! grep -i "FIM_PERM_GPU" "$FIM_FILE_PERMS"         &>/dev/null || echo "gpu"
  ! grep -i "FIM_PERM_INPUT" "$FIM_FILE_PERMS"       &>/dev/null || echo "input"
  ! grep -i "FIM_PERM_USB" "$FIM_FILE_PERMS"         &>/dev/null || echo "usb"
}

# Set permissions of sandbox
function _perms_set()
{
  # Reset perms
  echo "" > "$FIM_FILE_PERMS"

  # Set perms
  local ifs="$IFS" 
  IFS="," 
  #shellcheck disable=2016
  for i in $1; do
    case "$i" in
      pulseaudio)  echo 'FIM_PERM_PULSEAUDIO="${FIM_PERM_PULSEAUDIO:-1}"'   >> "$FIM_FILE_PERMS" ;;
      wayland)     echo 'FIM_PERM_WAYLAND="${FIM_PERM_WAYLAND:-1}"'         >> "$FIM_FILE_PERMS" ;;
      x11)         echo 'FIM_PERM_X11="${FIM_PERM_X11:-1}"'                 >> "$FIM_FILE_PERMS" ;;
      session_bus) echo 'FIM_PERM_SESSION_BUS="${FIM_PERM_SESSION_BUS:-1}"' >> "$FIM_FILE_PERMS" ;;
      system_bus)  echo 'FIM_PERM_SYSTEM_BUS="${FIM_PERM_SYSTEM_BUS:-1}"'   >> "$FIM_FILE_PERMS" ;;
      gpu)         echo 'FIM_PERM_GPU="${FIM_PERM_GPU:-1}"'                 >> "$FIM_FILE_PERMS" ;;
      input)       echo 'FIM_PERM_INPUT="${FIM_PERM_INPUT:-1}"'             >> "$FIM_FILE_PERMS" ;;
      usb)         echo 'FIM_PERM_USB="${FIM_PERM_USB:-1}"'                 >> "$FIM_FILE_PERMS" ;;
      *) _die "Trying to set unknown permission $i"
    esac
  done
  IFS="$ifs" 
}

function _help()
{
  sed -E 's/^\s+://' <<-EOF
  :# FlatImage, $FIM_DIST
  :Avaliable options:
  :- fim-compress: Compress the filesystem to a read-only format.
  :- fim-root: Execute an arbitrary command as root.
  :- fim-exec: Execute an arbitrary command.
  :- fim-cmd: Set the default command to execute when no argument is passed.
  :- fim-resize: Resize the filesystem.
  :- fim-mount: Mount the filesystem in a specified directory
  :    - E.g.: ./focal.fim fim-mount ./mountpoint
  :- fim-xdg: Same as the 'fim-mount' command, however it opens the
  :    mount directory with xdg-open
  :- fim-perms-set: Set the permission for the container, available options are:
  :    pulseaudio, wayland, x11, session_bus, system_bus, gpu, input, usb
  :    - E.g.: ./focal.fim fim-perms pulseaudio,wayland,x11
  :- fim-perms-list: List the current permissions for the container
  :- fim-help: Print this message.
	EOF
}

# Changes the filesystem size
# $1 New sise
function _resize()
{
  # Unmount
  _unmount

  # Resize
  "$FIM_DIR_GLOBAL_BIN"/e2fsck -fy "$FIM_FILE_BINARY"\?offset="$FIM_OFFSET" || true
  "$FIM_DIR_GLOBAL_BIN"/resize2fs "$FIM_FILE_BINARY"\?offset="$FIM_OFFSET" "$1"
  "$FIM_DIR_GLOBAL_BIN"/e2fsck -fy "$FIM_FILE_BINARY"\?offset="$FIM_OFFSET" || true

  # Mount
  _mount
}

# Re-create the filesystem with new data
# $1 New size
# $2 Dir to create image from
function _rebuild()
{
  _unmount

  # Erase current file
  rm "$FIM_FILE_BINARY"

  # Copy startup binary
  cp "$FIM_DIR_TEMP/main" "$FIM_FILE_BINARY"

  # Append tools
  cat "$FIM_DIR_GLOBAL_BIN"/{fuse2fs,e2fsck,bash}  >> "$FIM_FILE_BINARY"

  # Update offset
  FIM_OFFSET="$(du -sb "$FIM_FILE_BINARY" | awk '{print $1}')"

  # Create filesystem
  truncate -s "$1" "$FIM_DIR_TEMP/image.fim"
  "$FIM_DIR_GLOBAL_BIN"/mke2fs -d "$2" -b1024 -t ext2 "$FIM_DIR_TEMP/image.fim"

  # Append filesystem to binary
  cat "$FIM_DIR_TEMP/image.fim" >> "$FIM_FILE_BINARY"

  # Remove filesystem
  rm "$FIM_DIR_TEMP/image.fim"

  # Re-mount
  _mount
}

# Chroots into the filesystem
# $* Command and args
function _exec()
{
  # Check for empty string
  [ -n "$*" ] || FIM_DEBUG=1 _msg "Empty arguments for exec"

  # Fetch CMD
  declare -a cmd
  for i; do
    [ -z "$i" ] || cmd+=("\"$i\"")
  done

  _msg "cmd: ${cmd[*]}"

  # Fetch SHA
  local sha="$(_config_fetch "sha")"
  _msg "sha: $sha"

  # Mount dwarfs files if exist
  [ -f "$FIM_DIR_GLOBAL_BIN/dwarfs" ]  || cp "$FIM_DIR_MOUNT/fim/static/dwarfs" "$FIM_DIR_GLOBAL_BIN"/dwarfs
  chmod +x "$FIM_DIR_GLOBAL_BIN/dwarfs"

  # shellcheck disable=2044
  for i in $(find "$FIM_DIR_MOUNT" -maxdepth 1 -iname "*.dwarfs"); do
    i="$(basename "$i")"
    local fs="$FIM_DIR_MOUNT/$i"
    local mp="$FIM_DIR_GLOBAL/dwarfs/$sha/${i%.dwarfs}"; mkdir -p "$mp"
    "$FIM_DIR_GLOBAL_BIN/dwarfs" "$fs" "$mp" &> "$FIM_STREAM"
  done

  # Export variables to container
  export TERM="xterm"
  if [[ -z "$XDG_RUNTIME_DIR" ]] && [[ -e "/run/user/$(id -u)" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  fi
  export HOST_USERNAME="$(whoami)"
  export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin:/bin:/usr/bin:/usr/local/bin"
  tee "$BASHRC_FILE" &>/dev/null <<- 'EOF'
    export PS1="(flatimage@$(echo "$FIM_DIST" | tr '[:upper:]' '[:lower:]')) → "
	EOF

  # Remove override to avoid problems with apt
  [ -n "$FIM_RO" ] || rm ${FIM_DEBUG:+-v} -f "$FIM_DIR_MOUNT/var/lib/dpkg/statoverride"

  declare -a _cmd

  # Fetch permissions
  # shellcheck disable=1090
  source "$FIM_FILE_PERMS"

  # Run in container
  if [[ "$FIM_BACKEND" = "bwrap" ]]; then
    _msg "Using bubblewrap"

    # Main binary
    _cmd+=("$FIM_DIR_STATIC/bwrap")

    # Root binding
    _cmd+=("${FIM_ROOT:+--uid 0 --gid 0}")

    # Path to subsystem
    _cmd+=("--bind \"$FIM_DIR_MOUNT\" /")

    # User home
    _cmd+=("--bind \"$HOME\" \"$HOME\"")

    # System bindings
    _cmd+=("--dev /dev")
    _cmd+=("--proc /proc")
    _cmd+=("--bind /tmp /tmp")
    _cmd+=("--bind /sys /sys")

    # Pulseaudio
    if [[ "$FIM_PERM_PULSEAUDIO" -eq 1 ]] &&
       [[ -n "$XDG_RUNTIME_DIR" ]]; then
      _msg "PERM: Pulseaudio"
      local PULSE_SOCKET="$XDG_RUNTIME_DIR/pulse/native"
      _cmd+=("--setenv PULSE_SERVER unix:$PULSE_SOCKET")
      _cmd+=("--bind $PULSE_SOCKET $PULSE_SOCKET")
    fi

    # Wayland
    if [[ "$FIM_PERM_WAYLAND" -eq 1 ]] &&
       [[ -n "$XDG_RUNTIME_DIR" ]] &&
       [[ -n "$WAYLAND_DISPLAY" ]]; then
      _msg "PERM: Wayland"
      local WAYLAND_SOCKET_PATH="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
      _cmd+=("--bind $WAYLAND_SOCKET_PATH $WAYLAND_SOCKET_PATH")
      _cmd+=("--setenv WAYLAND_DISPLAY $WAYLAND_DISPLAY")
      _cmd+=("--setenv XDG_RUNTIME_DIR $XDG_RUNTIME_DIR")
    fi

    # X11
    if [[ "$FIM_PERM_X11" -eq 1 ]] &&
       [[ -n "$DISPLAY" ]] &&
       [[ -n "$XAUTHORITY" ]]; then
      _msg "PERM: X11"
      _cmd+=("--setenv DISPLAY $DISPLAY")
      _cmd+=("--setenv XAUTHORITY $XAUTHORITY")
      _cmd+=("--ro-bind $XAUTHORITY $XAUTHORITY")
    fi

    # dbus (user)
    if [[ "$FIM_PERM_SESSION_BUS" -eq 1 ]] &&
       [[ -n "$DBUS_SESSION_BUS_ADDRESS" ]]; then
      _msg "PERM: SESSION BUS"
      local dbus_session_bus_path="${DBUS_SESSION_BUS_ADDRESS#*=}"
      dbus_session_bus_path="${dbus_session_bus_path%%,*}"
      _cmd+=("--setenv DBUS_SESSION_BUS_ADDRESS $DBUS_SESSION_BUS_ADDRESS")
      _cmd+=("--bind $dbus_session_bus_path $dbus_session_bus_path")
    fi

    # dbus (system)
    if [[ "$FIM_PERM_SYSTEM_BUS" -eq 1 ]] &&
       [[ -e "/run/dbus/system_bus_socket" ]]; then
      _msg "PERM: SYSTEM BUS"
      _cmd+=("--bind /run/dbus/system_bus_socket /run/dbus/system_bus_socket")
    fi

    # GPU
    if [[ "$FIM_PERM_GPU" -eq 1 ]] &&
       [[ -e "/dev/dri" ]]; then
      _msg "PERM: GPU"
      _cmd+=("--dev-bind /dev/dri /dev/dri")
    fi

    # Input
    if [[ "$FIM_PERM_INPUT" -eq 1 ]] &&
       [[ -e "/dev/input" ]]; then
      _msg "PERM: Input"
      _cmd+=("--dev-bind /dev/input /dev/input")
    fi
    if [[ "$FIM_PERM_INPUT" -eq 1 ]] &&
       [[ -e "/dev/uinput" ]]; then
      _msg "PERM: Input"
      _cmd+=("--dev-bind /dev/uinput /dev/uinput")
    fi

    # USB
    if [[ "$FIM_PERM_USB" -eq 1 ]] &&
       [[ -e "/dev/bus/usb" ]]; then
      _msg "PERM: USB"
      _cmd+=("--dev-bind /dev/bus/usb /dev/bus/usb")
    fi
    if [[ "$FIM_PERM_USB" -eq 1 ]] &&
       [[ -e "/dev/usb" ]]; then
      _msg "PERM: USB"
      _cmd+=("--dev-bind /dev/usb /dev/usb")
    fi

    # Host info
    [ ! -f "/etc/host.conf"     ] || _cmd+=('--bind "/etc/host.conf"     "/etc/host.conf"')
    [ ! -f "/etc/hosts"         ] || _cmd+=('--bind "/etc/hosts"         "/etc/hosts"')
    [ ! -f "/etc/passwd"        ] || _cmd+=('--bind "/etc/passwd"        "/etc/passwd"')
    [ ! -f "/etc/group"         ] || _cmd+=('--bind "/etc/group"         "/etc/group"')
    [ ! -f "/etc/nsswitch.conf" ] || _cmd+=('--bind "/etc/nsswitch.conf" "/etc/nsswitch.conf"')
    [ ! -f "/etc/resolv.conf"   ] || _cmd+=('--bind "/etc/resolv.conf"   "/etc/resolv.conf"')
  elif [[ "$FIM_BACKEND" = "proot" ]]; then
    _msg "Using proot"

    # Main binary
    _cmd+=("$FIM_DIR_STATIC/proot")

    # Root binding
    _cmd+=("-0")

    # Path to subsystem
    _cmd+=("-r \"$FIM_DIR_MOUNT\"")

    # User home
    _cmd+=("-b \"$HOME\"")

    # System bindings
    _cmd+=("-b /dev")
    _cmd+=("-b /proc")
    _cmd+=("-b /tmp")
    _cmd+=("-b /sys")

    # Pulseaudio
    if [[ "$FIM_PERM_PULSEAUDIO" -eq 1 ]] &&
       [[ -n "$XDG_RUNTIME_DIR" ]]; then
      _msg "PERM: Pulseaudio"
      local PULSE_SOCKET="$XDG_RUNTIME_DIR/pulse/native"
      export PULSE_SERVER="unix:$PULSE_SOCKET"
      _cmd+=("-b $PULSE_SOCKET")
    fi

    # Wayland
    if [[ "$FIM_PERM_WAYLAND" -eq 1 ]] &&
       [[ -n "$XDG_RUNTIME_DIR" ]] &&
       [[ -n "$WAYLAND_DISPLAY" ]]; then
      _msg "PERM: Wayland"
      local WAYLAND_SOCKET_PATH="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
      _cmd+=("-b $WAYLAND_SOCKET_PATH")
      export WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
      export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
    fi

    # X11
    if [[ "$FIM_PERM_X11" -eq 1 ]] &&
       [[ -n "$DISPLAY" ]] &&
       [[ -n "$XAUTHORITY" ]]; then
      _msg "PERM: X11"
      export DISPLAY="$DISPLAY"
      export XAUTHORITY="$XAUTHORITY"
      _cmd+=("-b $XAUTHORITY")
    fi

    # dbus (user)
    if [[ "$FIM_PERM_SESSION_BUS" -eq 1 ]] &&
       [[ -n "$DBUS_SESSION_BUS_ADDRESS" ]]; then
      _msg "PERM: SESSION BUS"
      export DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
      _cmd+=("-b ${DBUS_SESSION_BUS_ADDRESS#*=}")
    fi

    # dbus (system)
    if [[ "$FIM_PERM_SYSTEM_BUS" -eq 1 ]] &&
       [[ -e "/run/dbus/system_bus_socket" ]]; then
      _msg "PERM: SYSTEM BUS"
      _cmd+=("-b /run/dbus/system_bus_socket")
    fi

    # GPU
    if [[ "$FIM_PERM_GPU" -eq 1 ]] &&
       [[ -e "/dev/dri" ]]; then
      _msg "PERM: GPU"
      _cmd+=("-b /dev/dri")
    fi

    # Input
    if [[ "$FIM_PERM_INPUT" -eq 1 ]] &&
       [[ -e "/dev/input" ]]; then
      _msg "PERM: Input"
      _cmd+=("--dev-bind /dev/input /dev/input")
    fi
    if [[ "$FIM_PERM_INPUT" -eq 1 ]] &&
       [[ -e "/dev/uinput" ]]; then
      _msg "PERM: Input"
      _cmd+=("--dev-bind /dev/uinput /dev/uinput")
    fi

    # USB
    if [[ "$FIM_PERM_USB" -eq 1 ]] &&
       [[ -e "/dev/bus/usb" ]]; then
      _msg "PERM: USB"
      _cmd+=("--dev-bind /dev/bus/usb /dev/bus/usb")
    fi
    if [[ "$FIM_PERM_USB" -eq 1 ]] &&
       [[ -e "/dev/usb" ]]; then
      _msg "PERM: USB"
      _cmd+=("--dev-bind /dev/usb /dev/usb")
    fi

    # Host info
    [ ! -f "/etc/host.conf"     ] || _cmd+=('-b "/etc/host.conf"')
    [ ! -f "/etc/hosts"         ] || _cmd+=('-b "/etc/hosts"')
    [ ! -f "/etc/passwd"        ] || _cmd+=('-b "/etc/passwd"')
    [ ! -f "/etc/group"         ] || _cmd+=('-b "/etc/group"')
    [ ! -f "/etc/nsswitch.conf" ] || _cmd+=('-b "/etc/nsswitch.conf"')
    [ ! -f "/etc/resolv.conf"   ] || _cmd+=('-b "/etc/resolv.conf"')
  else
    _die "Invalid backend $FIM_BACKEND"
  fi

  # Shell
  _cmd+=("$FIM_FILE_BASH -c '${cmd[*]}'")

  eval "${_cmd[*]}"
}

# Subdirectory compression
function _compress()
{
  [ -n "$FIM_RW" ] || _die "Set FIM_RW to 1 before compression"
  [ -z "$(_config_fetch "sha")" ] || _die "sha is set (already compressed?)"

  # Copy compressor to binary dir
  [ -f "$FIM_DIR_GLOBAL_BIN/mkdwarfs" ]  || cp "$FIM_DIR_MOUNT/fim/static/mkdwarfs" "$FIM_DIR_GLOBAL_BIN"/mkdwarfs
  chmod +x "$FIM_DIR_GLOBAL_BIN/mkdwarfs"

  # Remove apt lists and cache
  rm -rf "$FIM_DIR_MOUNT"/var/{lib/apt/lists,cache}

  # Create temporary directory to fit-resize fs
  local dir_compressed="$FIM_DIR_TEMP/dir_compressed"
  rm -rf "$dir_compressed"
  mkdir "$dir_compressed"

  # Get SHA and save to re-mount (used as unique identifier)
  local sha="$(sha256sum "$FIM_FILE_BINARY" | awk '{print $1}')"
  _config_set "sha" "$sha"
  _msg "sha: $sha"

  # Compress selected directories
  for i in ${FIM_COMPRESSION_DIRS}; do
    local target="$FIM_DIR_MOUNT/$i"
    [ -d "$target" ] ||  _die "Folder $target not found for compression"
    "$FIM_DIR_GLOBAL_BIN/mkdwarfs" -i "$target" -o "${dir_compressed}/$i.dwarfs" -l"$FIM_COMPRESSION_LEVEL" -f
    rm -rf "$target"
    ln -sf "$FIM_DIR_GLOBAL/dwarfs/$sha/$i" "${dir_compressed}/${i}"
  done


  # Remove remaining files from dev
  rm -rf "${FIM_DIR_MOUNT:?"Empty FIM_DIR_MOUNT"}"/dev

  # Move files to temporary directory
  for i in "$FIM_DIR_MOUNT"/{fim,bin,etc,lib,lib64,opt,root,run,sbin,share,tmp,usr,var}; do
    { mv "$i" "$dir_compressed" || true; } &>"$FIM_STREAM"
  done

  # Update permissions
  chmod -R +rw "$dir_compressed"

  # Resize to fit files size + slack
  local size_files="$( echo $(( $(du -sb "$dir_compressed" | awk '{print $1}') / 1024 )) | awk '{ gsub("K","",$1); print $1}')"
  local size_offset="$((FIM_OFFSET/1024))" # Bytes to K
  local size_slack="$FIM_COMPRESSION_SLACK";
  size_new="$((size_files+size_offset+size_slack))"

  _msg "Size files  : $size_files"
  _msg "Size offset : $size_files"
  _msg "Size slack  : $size_slack"
  _msg "Size sum    : $size_new"

  # Resize
  _rebuild "$size_new"K "$dir_compressed"

  # Remove mount dirs
  rm -rf "${FIM_DIR_MOUNT:?"Empty mount var"}"/{tmp,proc,sys,dev,run}

  # Create required mount points if not exists
  mkdir -p "$FIM_DIR_MOUNT"/{tmp,proc,sys,dev,run,home}
}

function _config_list()
{
  while read -r i; do
    [ -z "$i" ] || echo "$i"
  done < "$FIM_FILE_CONFIG"
}

function _config_fetch()
{
  local opt="$1"

  [ -f "$FIM_FILE_CONFIG" ] || { echo ""; exit; }

  grep -io "$opt = .*" "$FIM_FILE_CONFIG" | awk '{$1=$2=""; print substr($0, 3)}'
}

function _config_set()
{
  local opt="$1"; shift
  local entry="$opt = $*"

  if grep "$opt" "$FIM_FILE_CONFIG" &>"$FIM_STREAM"; then
    sed -i "s|$opt =.*|$entry|" "$FIM_FILE_CONFIG"
  else
    echo "$entry" >> "$FIM_FILE_CONFIG"
  fi
}

function main()
{
  _msg "FIM_OFFSET         : $FIM_OFFSET"
  _msg "FIM_RO             : $FIM_RO"
  _msg "FIM_RW             : $FIM_RW"
  _msg "FIM_STREAM         : $FIM_STREAM"
  _msg "FIM_ROOT           : $FIM_ROOT"
  _msg "FIM_NORM           : $FIM_NORM"
  _msg "FIM_DEBUG          : $FIM_DEBUG"
  _msg "FIM_NDEBUG         : $FIM_NDEBUG"
  _msg "FIM_DIR_GLOBAL     : $FIM_DIR_GLOBAL"
  _msg "FIM_DIR_GLOBAL_BIN : $FIM_DIR_GLOBAL_BIN"
  _msg "FIM_DIR_MOUNT      : $FIM_DIR_MOUNT"
  _msg "FIM_DIR_TEMP       : $FIM_DIR_TEMP"
  _msg "FIM_DIR_BINARY     : $FIM_DIR_BINARY"
  _msg "FIM_FILE_BINARY    : $FIM_FILE_BINARY"
  _msg '$*                  : '"$*"

  # Check filesystem
  "$FIM_DIR_GLOBAL_BIN"/e2fsck -fy "$FIM_FILE_BINARY"\?offset="$FIM_OFFSET" &> "$FIM_STREAM" || true

  # Copy tools
  _copy_tools "resize2fs" "mke2fs"

  # Mount filesystem
  _mount

  # Check if config exists, else try to touch if mounted as RW
  [ -f "$FIM_FILE_CONFIG" ] || { [ -n "$FIM_RO" ] || touch "$FIM_FILE_CONFIG"; }

  # Check if custom home directory is set
  local home="$(_config_fetch "home")"
  # # Expand
  home="$(eval echo "$home")"
  # # Set & show on debug mode
  [[ -z "$home" ]] || { mkdir -p "$home" && export HOME="$home"; }
  _msg "FIM_HOME        : $HOME"

  # If FIM_BACKEND is not defined check the config
  # or set it to bwrap
  if [[ -z "$FIM_BACKEND" ]]; then
    local fim_tool="$(_config_fetch "backend")"
    if [[ -n "$fim_tool" ]]; then
      FIM_BACKEND="$fim_tool"
    else
      FIM_BACKEND="bwrap"
    fi
  fi

  if [[ "${1:-}" =~ fim-(.*) ]]; then
    case "${BASH_REMATCH[1]}" in
      "compress") _compress ;;
      "root") FIM_ROOT=1; FIM_NORM="" ;&
      "exec") shift; _exec "$@" ;;
      "cmd") _config_set "cmd" "${@:2}" ;;
      "resize") _resize "$2" ;;
      "xdg") _re_mount "$2"; xdg-open "$2"; read -r ;;
      "mount") _re_mount "$2"; read -r ;;
      "config-list") _config_list ;;
      "config-set") _config_set "$2" "$3";;
      "perms-list") _perms_list ;;
      "perms-set") _perms_set "$2";;
      "help") _help;;
      *) _help; _die "Unknown fim command" ;;
    esac
  else
    local default_cmd="$(_config_fetch "cmd")"
    _exec  "${default_cmd:-"$FIM_FILE_BASH"}" "$@"
  fi

}

main "$@"

#  vim: set expandtab fdm=marker ts=2 sw=2 tw=100 et :
