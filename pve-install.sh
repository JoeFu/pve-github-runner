#!/bin/bash
# GitHub Actions self-hosted runners on Proxmox VE (7.2 or newer), in one go: an Ubuntu 24.04
# VM with Docker, QEMU/KVM and a few runners registered as services. Run it on the Proxmox VE
# host as root, for example from the node's Shell in the web interface:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/JoeFu/pve-github-runner/main/pve-install.sh)" -- --repo OWNER/NAME
#
# It needs a way to register runners, one of:
#   GITHUB_TOKEN=...    a token that may manage the repository's runners (fine-grained:
#                       Administration read/write; for --org: the organization's
#                       "Self-hosted runners" read/write). It's also what --set-variable uses.
#   --token TOKEN       a registration token, from your own machine:
#                       gh api -X POST repos/OWNER/NAME/actions/runners/registration-token --jq .token
#   neither             it asks for a registration token.
#
# Options (all optional except --repo or --org):
#   --repo OWNER/NAME   runners for this repository
#   --org ORG           runners for every repository of this organization
#   --token TOKEN       a registration token (good for an hour)
#   --count N           how many runners; each runs one job at a time (default 3)
#   --labels A,B        extra labels (self-hosted, linux and x64 are always there)
#   --group NAME        the organization's runner group (with --org)
#   --set-variable VAR  once the runners are up, set the repository variable VAR to
#                       "self-hosted" (with --repo and GITHUB_TOKEN), for workflows that say
#                       runs-on: ${{ vars.VAR || 'ubuntu-24.04' }}
#   --vmid N            the VM's id (default: the next free one)
#   --name NAME         the VM's name, also the runners' name prefix (default gh-runner)
#   --storage ID        storage for the disks (default local-lvm, else the first for images)
#   --bridge BRIDGE     network bridge (default vmbr0)
#   --vlan TAG          VLAN tag on that bridge
#   --disk SIZE         disk size (default 100G)
#   --cores N           (default 4)
#   --memory MIB        (default 8192)
#   --ssh-key FILE      public keys for the VM's "ubuntu" user (default: root's on this host)
#   --yes               don't ask before creating the VM
set -euo pipefail

SOURCE=${PGR_SOURCE:-https://raw.githubusercontent.com/JoeFu/pve-github-runner/main}
IMAGE_URL=https://cloud-images.ubuntu.com/noble/current
IMAGE=noble-server-cloudimg-amd64.img

repo='' org='' token='' count=3 labels='' group='' set_variable='' vmid='' name=gh-runner storage=''
bridge=vmbr0 vlan='' disk=100G cores=4 memory=8192 ssh_key='' yes=''
while (( $# )); do
    case $1 in
        --repo) repo=$2; shift 2 ;;
        --org) org=$2; shift 2 ;;
        --token) token=$2; shift 2 ;;
        --count) count=$2; shift 2 ;;
        --labels) labels=$2; shift 2 ;;
        --group) group=$2; shift 2 ;;
        --set-variable) set_variable=$2; shift 2 ;;
        --vmid) vmid=$2; shift 2 ;;
        --name) name=$2; shift 2 ;;
        --storage) storage=$2; shift 2 ;;
        --bridge) bridge=$2; shift 2 ;;
        --vlan) vlan=$2; shift 2 ;;
        --disk) disk=$2; shift 2 ;;
        --cores) cores=$2; shift 2 ;;
        --memory) memory=$2; shift 2 ;;
        --ssh-key) ssh_key=$2; shift 2 ;;
        --yes|-y) yes=1; shift ;;
        -h|--help) sed -n '2,36p' "$0" 2>/dev/null || true; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $(id -u) == 0 ]] || die "run this as root on the Proxmox VE host"
{ command -v qm && command -v pvesm; } >/dev/null || die "this is not a Proxmox VE host (no qm / pvesm)"

if [[ -z $repo && -z $org ]]; then
    [[ -t 0 && -z $yes ]] || die "pass --repo OWNER/NAME or --org ORG"
    read -r -p "Runners for which repository (OWNER/NAME)? " repo
fi
[[ -n $repo && -n $org ]] && die "pass --repo or --org, not both"
if [[ -n $repo ]]; then
    [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must look like OWNER/NAME"
    url=https://github.com/$repo scope=repos/$repo
else
    [[ $org =~ ^[A-Za-z0-9_.-]+$ ]] || die "--org must be an organization's name"
    url=https://github.com/$org scope=orgs/$org
fi
[[ $count =~ ^[1-9][0-9]*$ ]] || die "--count must be a positive number"
[[ $name =~ ^[A-Za-z0-9-]+$ ]] || die "--name may only have letters, digits and dashes"
[[ -z $set_variable || ( -n $repo && -n ${GITHUB_TOKEN:-} ) ]] || die "--set-variable needs --repo and GITHUB_TOKEN"

json() {  # json EXPR < JSON: a value from JSON, with Perl's core JSON::PP (always on Proxmox VE)
    perl -MJSON::PP -e 'my $d = decode_json(do { local $/; <STDIN> }); my $v = eval $ARGV[0]; print defined $v ? $v : ""' "$1"
}
api() {  # api METHOD PATH [BODY]: the GitHub API with GITHUB_TOKEN
    local args=(-fsSL -X "$1" -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28")
    [[ -n ${3:-} ]] && args+=(-d "$3")
    curl "${args[@]}" "https://api.github.com/$2"
}

# Nested virtualization: the VM gets the CPU type "host", so jobs inside it have KVM.
if ! grep -Eqw 'vmx|svm' /proc/cpuinfo; then
    warn "this CPU has no hardware virtualization: jobs that boot VMs will be slow"
elif [[ $(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null) != *[Y1]* ]]; then
    warn "nested virtualization is off on this host: jobs that boot VMs will be slow"
fi

if [[ -z $token && -z ${GITHUB_TOKEN:-} ]]; then
    [[ -t 0 && -z $yes ]] || die "pass --token or set GITHUB_TOKEN"
    echo "A registration token, from your own machine:"
    echo "  gh api -X POST $scope/actions/runners/registration-token --jq .token"
    read -r -s -p "Token: " token
    echo
    [[ -n $token ]] || die "no token"
fi

work=/var/tmp/pve-github-runner
mkdir -p "$work"

# --- what goes into the VM -------------------------------------------------------------------

# Run from a checkout, it uses the runner-setup.sh next to it; run as bash -c "$(curl ...)",
# there is no file (and no BASH_SOURCE), so it downloads the one from the same place.
here=''
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
fi
if [[ -n $here && -f $here/runner-setup.sh ]]; then
    cp "$here/runner-setup.sh" "$work/runner-setup.sh"
else
    curl -fsSL "$SOURCE/runner-setup.sh" -o "$work/runner-setup.sh" || die "can't download $SOURCE/runner-setup.sh"
fi
head -n 1 "$work/runner-setup.sh" | grep -q '^#!' || die "runner-setup.sh doesn't look like a script"

say "Ubuntu 24.04 cloud image"
curl -fsSL "$IMAGE_URL/SHA256SUMS" -o "$work/SHA256SUMS"
want=$(awk -v f="*$IMAGE" '$2 == f || $2 == substr(f, 2) { print $1 }' "$work/SHA256SUMS")
[[ -n $want ]] || die "no checksum for $IMAGE"
if [[ ! -f $work/$IMAGE ]] || [[ $(sha256sum "$work/$IMAGE" | cut -d' ' -f1) != "$want" ]]; then
    curl -fL --progress-bar "$IMAGE_URL/$IMAGE" -o "$work/$IMAGE.part"
    [[ $(sha256sum "$work/$IMAGE.part" | cut -d' ' -f1) == "$want" ]] || die "$IMAGE: checksum mismatch"
    mv "$work/$IMAGE.part" "$work/$IMAGE"
else
    echo "cached, checksum ok"
fi

# --- the VM ----------------------------------------------------------------------------------

[[ -n $vmid ]] || vmid=$(pvesh get /cluster/nextid)
qm status "$vmid" >/dev/null 2>&1 && die "VM $vmid already exists"
if [[ -z $storage ]]; then
    storages=$(pvesm status --content images --enabled 1 2>/dev/null | awk 'NR > 1 { print $1 }')
    if grep -qx local-lvm <<<"$storages"; then storage=local-lvm; else storage=$(head -n 1 <<<"$storages"); fi
    [[ -n $storage ]] || die "no storage for VM disks; pass --storage"
fi
# Cloud-init vendor data (packages, the setup script) is a "snippet", which lives on a
# directory storage that allows them.
snippets=$(pvesm status --content snippets --enabled 1 2>/dev/null | awk 'NR > 1 { print $1; exit }')
add_snippets=
if [[ -z $snippets ]]; then
    pvesm status --enabled 1 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx local || die "no storage allows snippets; enable them on a directory storage (Datacenter -> Storage)"
    snippets=local add_snippets=1
fi
keys=${ssh_key:-/root/.ssh/authorized_keys}
[[ -n $ssh_key && ! -f $ssh_key ]] && die "no such file: $ssh_key"
[[ -f $keys ]] || keys=

say "Runners for $url"
echo "  VM $vmid \"$name\": $cores cores (host), $memory MiB, $disk disk on $storage, network $bridge${vlan:+ (VLAN $vlan)}"
echo "  $count runner(s): $name-1 ... $name-$count${labels:+, labels $labels}"
[[ -n $keys ]] && echo "  ssh: ubuntu@<its address>, with the keys in $keys"
[[ -n $add_snippets ]] && echo "  the storage \"local\" will also allow snippets (for cloud-init)"
[[ -n $set_variable ]] && echo "  then the repository variable $set_variable = self-hosted"
if [[ -z $yes ]]; then
    read -r -p "Create and start it? [Y/n] " answer
    [[ -z $answer || $answer == [Yy]* ]] || exit 0
fi

if [[ -n $add_snippets ]]; then
    content=$(pvesh get /storage/local --output-format json | json '$d->{content}')
    pvesm set local --content "${content:+$content,}snippets"
fi
snippet=pve-github-runner-$vmid.yaml
snippet_path=$(pvesm path "$snippets:snippets/$snippet")
mkdir -p "$(dirname "$snippet_path")"
# No token in here: it is handed over through the guest agent once the VM is up.
cat > "$snippet_path" <<EOF
#cloud-config
package_update: true
packages: [qemu-guest-agent]
write_files:
  - path: /usr/local/sbin/runner-setup.sh
    permissions: "0755"
    encoding: b64
    content: $(base64 -w0 "$work/runner-setup.sh")
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
EOF

net="virtio,bridge=$bridge${vlan:+,tag=$vlan}"
qm create "$vmid" --name "$name" --ostype l26 --machine q35 \
    --cpu host --cores "$cores" --memory "$memory" --balloon 0 \
    --scsihw virtio-scsi-single --net0 "$net" \
    --scsi0 "$storage:0,import-from=$work/$IMAGE,discard=on,ssd=1,iothread=1" \
    --ide2 "$storage:cloudinit" --boot order=scsi0 --serial0 socket \
    --agent enabled=1 --onboot 1 --tags github-runner \
    --ipconfig0 ip=dhcp --cicustom "vendor=$snippets:snippets/$snippet" \
    --description "GitHub Actions runners for $url (pve-github-runner)" >/dev/null
[[ -n $keys ]] && qm set "$vmid" --sshkeys "$keys" >/dev/null
qm resize "$vmid" scsi0 "$disk" >/dev/null
qm start "$vmid"
say "VM $vmid is starting."

# --- the runners -----------------------------------------------------------------------------

echo -n "Waiting for its guest agent (cloud-init installs it)"
for i in $(seq 1 200); do
    qm guest cmd "$vmid" ping >/dev/null 2>&1 && break
    (( i == 200 )) && { echo; die "no guest agent after 10 minutes; look at the VM's console"; }
    sleep 3
    echo -n .
done
echo

if [[ -z $token ]]; then
    token=$(api POST "$scope/actions/runners/registration-token" | json '$d->{token}') ||
        die "GITHUB_TOKEN can't create a registration token for $url"
fi

say "Setting up the runners (5-10 minutes)"
started=$(qm guest exec "$vmid" --synchronous 0 -- env \
    "RUNNER_URL=$url" "RUNNER_TOKEN=$token" "RUNNER_COUNT=$count" "RUNNER_NAME=$name" \
    "LABELS=$labels" "RUNNER_GROUP=$group" \
    bash -c 'cloud-init status --wait >/dev/null 2>&1; exec bash /usr/local/sbin/runner-setup.sh >/var/log/runner-setup.log 2>&1')
pid=$(json '$d->{pid}' <<<"$started")
[[ -n $pid ]] || die "couldn't start the setup in the VM"
guest_tail() { qm guest exec "$vmid" -- tail -n "$1" /var/log/runner-setup.log 2>/dev/null | json '$d->{"out-data"}'; }
code=
for _ in $(seq 1 360); do
    sleep 5
    status=$(qm guest exec-status "$vmid" "$pid" 2>/dev/null) || continue
    if [[ $(json '$d->{exited}' <<<"$status") == 1 ]]; then
        code=$(json '$d->{exitcode}' <<<"$status")
        break
    fi
    line=$(guest_tail 1 | tr -d '\r\n' | cut -c1-100)
    printf '\r\033[K  %s' "$line"
done
printf '\r\033[K'
if [[ $code != 0 ]]; then
    guest_tail 30 >&2 || true
    die "the setup ${code:+failed (exit $code)}${code:-took more than 30 minutes}; the whole log is /var/log/runner-setup.log in the VM"
fi
guest_tail 3 | grep -v '^$' || true

if [[ -n $set_variable ]]; then
    online=0
    for _ in $(seq 1 24); do
        online=$(api GET "$scope/actions/runners?per_page=100" |
            json "scalar grep { \$_->{status} eq 'online' && \$_->{name} =~ /^\Q$name\E-\d+\$/ } @{\$d->{runners}}")
        (( online >= count )) && break
        sleep 5
    done
    if (( online >= 1 )); then
        body="{\"name\":\"$set_variable\",\"value\":\"self-hosted\"}"
        api PATCH "$scope/actions/variables/$set_variable" "$body" >/dev/null 2>&1 ||
            api POST "$scope/actions/variables" "$body" >/dev/null ||
            die "couldn't set the variable $set_variable"
        say "$set_variable = self-hosted: workflows that use it now run here ($online runner(s) online)."
    else
        warn "no runner is online yet, so $set_variable was left alone"
    fi
fi

address=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null |
    json 'my @a = map { $_->{"ip-address"} } grep { $_->{"ip-address-type"} eq "ipv4" && $_->{"ip-address"} !~ /^127\./ && $_->{"ip-address"} !~ /^172\.1[78]\./ } map { @{$_->{"ip-addresses"} || []} } @$d; $a[0]' || true)
say "Done: $count runner(s) for $url"
if [[ -n $repo ]]; then echo "  Runners: $url/settings/actions/runners"; else echo "  Runners: https://github.com/organizations/$org/settings/actions/runners"; fi
[[ -n $address && -n $keys ]] && echo "  ssh ubuntu@$address"
echo "  More runners later, in the VM: sudo RUNNER_URL=$url RUNNER_TOKEN=<token> RUNNER_COUNT=<n> RUNNER_NAME=$name bash /usr/local/sbin/runner-setup.sh"
