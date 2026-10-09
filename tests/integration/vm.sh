#!/usr/bin/env bash
# A throw-away Ubuntu VM under libvirt/KVM to run the install scripts for real, see
# tests/integration/README.md.
#
#   vm.sh create | start | stop | status | ssh [command] | run <config.json> | destroy [--all]
#
# create    downloads the Ubuntu cloud image (checked against Ubuntu's SHA256SUMS), makes a NAT
#           network of its own and the VM, and waits until it answers over SSH
# run       builds the package from this working tree, generates the VM script from a
#           configuration (easy-cs-ai generate), runs it as root in the VM, prints its log
# ssh       a shell on the VM as the user `tester` (commands as arguments, or on stdin)
# destroy   removes the VM, its disk and its network; --all also removes the image cache
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${ECSAI_VM_DIR:-$HOME/.cache/easy-cs-ai-vm}"
NAME="${ECSAI_VM_NAME:-ecsai-test}"
MEMORY_MB="${ECSAI_VM_MEMORY:-6144}"
VCPUS="${ECSAI_VM_VCPUS:-4}"
DISK_GB="${ECSAI_VM_DISK:-40}"
IMAGE_BASE="${ECSAI_VM_IMAGE_BASE:-https://cloud-images.ubuntu.com/releases/noble/release}"
IMAGE_FILE="${ECSAI_VM_IMAGE_FILE:-ubuntu-24.04-server-cloudimg-amd64.img}"
HTTP_PORT="${ECSAI_VM_HTTP_PORT:-8099}"
RUN_TIMEOUT="${ECSAI_VM_RUN_TIMEOUT:-2400}"
FIRST_SUBNET=151
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

log() { printf '[vm] %s\n' "$*" >&2; }
die() { printf '[vm] ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

need() {
    local missing=() c
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]} (libvirt, qemu, virt-install, xorriso, openssl, curl, jq)"
}

need_libvirt() {
    need virsh virt-install qemu-img xorriso ssh ssh-keygen curl jq
    virsh list >/dev/null 2>&1 || die "no access to $LIBVIRT_DEFAULT_URI: is libvirtd running, and is your user in the libvirt group?"
    [[ -e /dev/kvm ]] || die "/dev/kvm is missing: hardware virtualisation is not available (under WSL, nested virtualisation must be on)"
}

# --- network -------------------------------------------------------------------------------
# A NAT network of our own, so the machine's default one is left alone. Its bridge and subnet
# are numbered: a bridge that survived a restart of libvirtd (it does under WSL) makes libvirt
# refuse the same address, and a new number gets around it.

net_xml() { # <number>
    cat <<EOF
<network>
  <name>$NAME</name>
  <forward mode='nat'/>
  <bridge name='virbr-ecsai$1' stp='on' delay='0'/>
  <ip address='192.168.$1.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.$1.10' end='192.168.$1.50'/></dhcp>
  </ip>
</network>
EOF
}

net_number() { cat "$WORK/net-number" 2>/dev/null || printf '%s\n' "$FIRST_SUBNET"; }

# no `| grep -q` here: grep quits at the first match, virsh then dies of SIGPIPE and pipefail turns that into a failure
net_active() {
    local info
    info="$(virsh net-info "$NAME" 2>/dev/null)" || return 1
    [[ "$info" =~ Active:[[:space:]]+yes ]]
}

ensure_network() {
    local n
    net_active && return 0
    if virsh net-info "$NAME" >/dev/null 2>&1 && virsh net-start "$NAME" >/dev/null 2>&1; then
        return 0
    fi
    n="$(net_number)"
    for _ in $(seq 1 20); do
        virsh net-destroy "$NAME" >/dev/null 2>&1 || true
        virsh net-undefine "$NAME" >/dev/null 2>&1 || true
        net_xml "$n" >"$WORK/net.xml"
        if virsh net-define "$WORK/net.xml" >/dev/null 2>&1 && virsh net-start "$NAME" >/dev/null 2>&1; then
            printf '%s\n' "$n" >"$WORK/net-number"
            log "network $NAME on 192.168.$n.0/24"
            return 0
        fi
        n=$((n + 1))
    done
    die "could not start a NAT network: see 'virsh net-start $NAME'"
}

gateway() { printf '192.168.%s.1\n' "$(net_number)"; }

# --- the VM --------------------------------------------------------------------------------

vm_exists() { virsh dominfo "$NAME" >/dev/null 2>&1; }
vm_running() { [[ "$(virsh domstate "$NAME" 2>/dev/null)" == running ]]; }
vm_ip() { virsh domifaddr "$NAME" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1]; exit }'; }

ssh_base() {
    ssh -i "$WORK/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -o BatchMode=yes "$@"
}

# vm_ssh [args…]: a command on the VM; without arguments, the commands on stdin.
vm_ssh() {
    local ip
    ip="$(vm_ip)"
    [[ -n "$ip" ]] || die "the VM has no address: is it running? ($0 start)"
    if [[ $# -gt 0 ]]; then
        ssh_base -n "tester@$ip" "$@"
    else
        ssh_base "tester@$ip" 'bash -s'
    fi
}

wait_ssh() { # [timeout]
    local deadline=$((SECONDS + ${1:-300})) ip=""
    while ((SECONDS < deadline)); do
        ip="$(vm_ip)"
        if [[ -n "$ip" ]] && ssh_base "tester@$ip" true 2>/dev/null; then
            ssh_base "tester@$ip" 'cloud-init status --wait >/dev/null 2>&1 || true'
            log "the VM answers on $ip"
            return 0
        fi
        sleep 5
    done
    die "the VM does not answer over SSH after ${1:-300}s"
}

fetch_image() {
    local sum
    mkdir -p "$WORK"
    sum="$(curl -fsSL "$IMAGE_BASE/SHA256SUMS" | awk -v f="$IMAGE_FILE" '$2 == "*" f || $2 == f { print $1 }')"
    [[ -n "$sum" ]] || die "no checksum published for $IMAGE_FILE at $IMAGE_BASE"
    if [[ ! -f "$WORK/base.img" || "$(sha256sum "$WORK/base.img" | awk '{print $1}')" != "$sum" ]]; then
        log "downloading $IMAGE_FILE"
        curl -fL -sS --retry 3 -o "$WORK/base.img.part" "$IMAGE_BASE/$IMAGE_FILE"
        mv "$WORK/base.img.part" "$WORK/base.img"
    fi
    [[ "$(sha256sum "$WORK/base.img" | awk '{print $1}')" == "$sum" ]] || die "checksum mismatch for the cloud image"
}

cmd_create() {
    need_libvirt
    vm_exists && die "the VM $NAME already exists: '$0 destroy' first, or '$0 start'"
    mkdir -p "$WORK"
    [[ -f "$WORK/key" ]] || ssh-keygen -q -t ed25519 -N '' -C easy-cs-ai-test -f "$WORK/key"
    fetch_image
    ensure_network

    cat >"$WORK/user-data" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: tester
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$WORK/key.pub")
ssh_pwauth: false
EOF
    printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$NAME" "$(date +%s)" "$NAME" >"$WORK/meta-data"
    rm -f "$WORK/seed.iso"
    (cd "$WORK" && xorriso -as mkisofs -o seed.iso -V cidata -J -r user-data meta-data >/dev/null 2>&1)
    cp "$WORK/base.img" "$WORK/disk.qcow2"
    qemu-img resize -q "$WORK/disk.qcow2" "${DISK_GB}G"

    # the disk goes through the libvirt pool: the user's own directories are out of reach of qemu
    virsh vol-delete "$NAME.qcow2" --pool default >/dev/null 2>&1 || true
    virsh vol-delete "$NAME-seed.iso" --pool default >/dev/null 2>&1 || true
    virsh vol-create-as default "$NAME.qcow2" "${DISK_GB}G" --format qcow2 >/dev/null
    virsh vol-upload "$NAME.qcow2" "$WORK/disk.qcow2" --pool default
    virsh vol-create-as default "$NAME-seed.iso" 1M --format raw >/dev/null
    virsh vol-upload "$NAME-seed.iso" "$WORK/seed.iso" --pool default
    rm -f "$WORK/disk.qcow2"

    log "creating the VM $NAME ($VCPUS vCPU, $MEMORY_MB MB, ${DISK_GB} GB)"
    virt-install --name "$NAME" --memory "$MEMORY_MB" --vcpus "$VCPUS" --cpu host-passthrough \
        --import --disk "vol=default/$NAME.qcow2,bus=virtio" --disk "vol=default/$NAME-seed.iso,device=cdrom" \
        --network "network=$NAME" --osinfo detect=off,require=off --graphics none --noautoconsole >/dev/null
    wait_ssh 300
}

cmd_start() {
    need_libvirt
    vm_exists || die "no VM $NAME: '$0 create' first"
    ensure_network
    vm_running || virsh start "$NAME" >/dev/null
    wait_ssh 300
}

cmd_stop() {
    need_libvirt
    vm_exists || return 0
    vm_running || return 0
    virsh shutdown "$NAME" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do vm_running || return 0; sleep 2; done
    virsh destroy "$NAME" >/dev/null 2>&1 || true
}

cmd_status() {
    need_libvirt
    if ! vm_exists; then echo "no VM $NAME"; return 0; fi
    printf '%s: %s, address %s, network 192.168.%s.0/24\n' "$NAME" "$(virsh domstate "$NAME")" "$(vm_ip || true)" "$(net_number)"
}

cmd_destroy() {
    need_libvirt
    if vm_running; then virsh destroy "$NAME" >/dev/null 2>&1 || true; fi
    if vm_exists; then virsh undefine "$NAME" --nvram >/dev/null 2>&1 || true; fi
    virsh vol-delete "$NAME.qcow2" --pool default >/dev/null 2>&1 || true
    virsh vol-delete "$NAME-seed.iso" --pool default >/dev/null 2>&1 || true
    virsh net-destroy "$NAME" >/dev/null 2>&1 || true
    virsh net-undefine "$NAME" >/dev/null 2>&1 || true
    if [[ "${1:-}" == --all ]]; then
        rm -rf "$WORK"
        log "removed $WORK"
    fi
    log "VM $NAME, its disk and its network are removed"
}

# --- run -----------------------------------------------------------------------------------

# cmd_run <config.json>: the package of this working tree, the script generated from the
# configuration, run as root in the VM. Returns the exit code of the script.
cmd_run() {
    local config="${1:-}" version dist script gw http_pid="" rc=0 end
    [[ -r "$config" ]] || die "usage: $0 run <config.json>"
    need_libvirt
    need python3 sha256sum
    vm_running || cmd_start
    version="$(sed -n 's/^readonly CLI_VERSION=//p' "$ROOT/package/bin/easy-cs-ai")"
    dist="$WORK/dist"
    script="$WORK/vm-install.sh"
    mkdir -p "$dist"
    bash "$ROOT/package/build.sh" --output "$dist" >/dev/null
    gw="$(gateway)"
    EASY_CS_AI_CLI_VERSION="$version" bash "$ROOT/vm_script/generate.sh" --config "$config" --package-format tarball \
        --package-url "http://$gw:$HTTP_PORT/easy-cs-ai-$version.tar.gz" --package-file "$dist/easy-cs-ai-$version.tar.gz" \
        --package-version "$version" --output "$script" >&2

    # the generated script skips the download when this version is installed: remove the
    # package so that it is the code of this working tree that runs (the components stay)
    vm_ssh 'sudo rm -rf /opt/easy-cs-ai /usr/local/bin/easy-cs-ai'
    (cd "$dist" && exec python3 -m http.server "$HTTP_PORT" --bind "$gw" >/dev/null 2>&1) &
    http_pid=$!
    # shellcheck disable=SC2064
    trap "kill $http_pid 2>/dev/null || true" EXIT
    sleep 1
    local ip
    ip="$(vm_ip)"
    scp -q -i "$WORK/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$script" "tester@$ip:/tmp/vm-install.sh"
    vm_ssh 'sudo rm -f /var/log/ecsai-install.log; sudo nohup bash -c "bash /tmp/vm-install.sh > /var/log/ecsai-install.log 2>&1; echo EXIT=\$? >> /var/log/ecsai-install.log" >/dev/null 2>&1 &'

    end=$((SECONDS + RUN_TIMEOUT))
    until vm_ssh 'sudo grep -q "^EXIT=" /var/log/ecsai-install.log' 2>/dev/null; do
        ((SECONDS < end)) || { log "the script is still running after ${RUN_TIMEOUT}s"; rc=124; break; }
        sleep 10
    done
    # the lines of the scripts, without the progress bars and the package manager's output
    vm_ssh "sudo tr '\r' '\n' </var/log/ecsai-install.log | grep -E '^(\[(INFO|WARN|ERROR)\]|EXIT=)' | cut -c1-220" || true
    if ((rc == 0)); then
        rc="$(vm_ssh "sudo sed -n 's/^EXIT=//p' /var/log/ecsai-install.log | tail -1")"
    fi
    return "$rc"
}

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
    create) cmd_create "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    ssh) vm_ssh "$@" ;;
    run) cmd_run "$@" ;;
    destroy) cmd_destroy "$@" ;;
    help | --help | -h) usage ;;
    *) usage >&2; exit 2 ;;
    esac
}

main "$@"
