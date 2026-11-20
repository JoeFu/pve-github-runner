#!/usr/bin/env bash
# Turn an Ubuntu 24.04 x64 machine into GitHub Actions self-hosted runners. pve-install.sh runs
# this inside the VM it creates; you can also run it by hand on any Ubuntu 24.04 machine:
#
#   sudo RUNNER_URL=https://github.com/OWNER/REPO RUNNER_TOKEN=<registration token> bash runner-setup.sh
#
# A registration token comes from
#   gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token
# (orgs/ORG/... for an organization's runners). It is good for an hour and for any number of
# runners.
#
# Settings (environment):
#   RUNNER_URL      https://github.com/OWNER/REPO, or https://github.com/ORG    (required)
#   RUNNER_TOKEN    the registration token (only needed for runners not registered yet)
#   RUNNER_COUNT    how many runners, each runs one job at a time               (default 3)
#   RUNNER_NAME     name prefix: <prefix>-1, <prefix>-2, ...                    (default: hostname)
#   LABELS          extra labels, comma-separated; self-hosted, linux and x64 are always there
#   RUNNER_GROUP    the organization runner group                               (default: Default)
#   RUNNER_USER     account prefix: runner <prefix>-1 runs as <prefix>-1, ...  (default runner)
#
# Each runner has an account of its own, as on GitHub each job has a machine of its own: jobs
# that run side by side don't share a home, so what setup actions put under ~ (pnpm and its
# store, uv's cache, ...) is never changed by another job halfway through. Docker and KVM are
# still shared.
#
# Running it again is safe: it installs what is missing, registers runners that aren't
# registered yet and leaves the others alone. Runners set up by an older version, all as one
# account, are moved to their own accounts (they stop for a moment; better while no job runs).
#
# Besides the runner it installs what GitHub's ubuntu-24.04 image has that setup actions don't
# install for you: git, gh, jq, zip, python3, build-essential, Docker with buildx, and QEMU with
# OVMF and KVM (for jobs that boot VMs). Like GitHub's runners, the runner accounts may sudo
# without a password, so only use it for repositories whose pull requests you trust.
set -euo pipefail

RUNNER_URL=${RUNNER_URL:-}
RUNNER_COUNT=${RUNNER_COUNT:-3}
RUNNER_NAME=${RUNNER_NAME:-$(hostname)}
RUNNER_USER=${RUNNER_USER:-runner}
RUNNER_ROOT=${RUNNER_ROOT:-/opt/actions-runner}
LABELS=${LABELS:-}
RUNNER_GROUP=${RUNNER_GROUP:-}

say() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run it as root (sudo)"
[[ $RUNNER_URL == https://github.com/* ]] || die "set RUNNER_URL to https://github.com/OWNER/REPO or https://github.com/ORG"
[[ $(uname -m) == x86_64 ]] || die "this script installs the x64 runner"
[[ $RUNNER_COUNT =~ ^[1-9][0-9]*$ ]] || die "RUNNER_COUNT must be a positive number"
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || echo "warning: written for Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}" >&2

say "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
    ca-certificates curl git jq zip unzip python3 python3-venv build-essential \
    docker.io docker-buildx qemu-system-x86 qemu-utils ovmf qemu-guest-agent
systemctl enable --now docker
systemctl enable --now qemu-guest-agent 2>/dev/null || true

if ! command -v gh >/dev/null; then
    say "GitHub CLI"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -q
    apt-get install -y -q gh
fi

add_user() {
    id "$1" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$1"
    usermod -aG docker,kvm "$1"
    echo "$1 ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$1"
    chmod 0440 "/etc/sudoers.d/90-$1"
}

if [[ -e /dev/kvm ]]; then
    echo "KVM: yes"
else
    echo "warning: no /dev/kvm, jobs that boot VMs will be slow. On Proxmox: qm set <vmid> --cpu host" >&2
fi

say "Actions runner"
tag=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)
version=${tag#v}
tarball=actions-runner-linux-x64-$version.tar.gz
cache=$RUNNER_ROOT/$tarball
install -d -m 0755 "$RUNNER_ROOT"
if [[ ! -f $cache ]]; then
    curl -fsSL -o "$cache.part" "https://github.com/actions/runner/releases/download/$tag/$tarball"
    # The release notes carry each package's SHA-256 between these markers.
    want=$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/$tag" | jq -r .body |
        sed -n 's/.*<!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\)<!-- END SHA linux-x64 -->.*/\1/p')
    got=$(sha256sum "$cache.part" | cut -d' ' -f1)
    if [[ -n $want && $want != "$got" ]]; then
        rm -f "$cache.part"
        die "$tarball: checksum $got, the release says $want"
    fi
    [[ -n $want ]] || echo "warning: no checksum in the release notes, not verified" >&2
    mv "$cache.part" "$cache"
fi
echo "version $version"

extra=()
[[ -n $LABELS ]] && extra+=(--labels "$LABELS")
[[ -n $RUNNER_GROUP ]] && extra+=(--runnergroup "$RUNNER_GROUP")
deps_done=
old_users=()
for i in $(seq 1 "$RUNNER_COUNT"); do
    dir=$RUNNER_ROOT/r$i
    name=$RUNNER_NAME-$i
    user=$RUNNER_USER-$i
    add_user "$user"
    if [[ -f $dir/.runner ]]; then
        owner=$(stat -c %U "$dir")
        if [[ $owner != "$user" ]]; then
            # Set up by an older version, as an account shared by every runner. Its
            # registration lives in the folder, so handing the folder over keeps it.
            echo "$name: moving from $owner to $user"
            (
                cd "$dir"
                ./svc.sh stop >/dev/null 2>&1 || true
                ./svc.sh uninstall >/dev/null
            )
            chown -R "$user:$user" "$dir"
            [[ " ${old_users[*]} " == *" $owner "* ]] || old_users+=("$owner")
        else
            echo "$name: registered already"
        fi
    else
        [[ -n ${RUNNER_TOKEN:-} ]] || die "RUNNER_TOKEN is needed to register $name"
        install -d -o "$user" -g "$user" "$dir"
        sudo -u "$user" tar -xzf "$cache" -C "$dir"
        if [[ -z $deps_done ]]; then
            "$dir/bin/installdependencies.sh" >/dev/null
            deps_done=1
        fi
        sudo -u "$user" "$dir/config.sh" --unattended --replace \
            --url "$RUNNER_URL" --token "$RUNNER_TOKEN" --name "$name" --work _work "${extra[@]}"
    fi
    if ! compgen -G "/etc/systemd/system/actions.runner.*.$name.service" >/dev/null; then
        (cd "$dir" && ./svc.sh install "$user" >/dev/null)
    fi
    (cd "$dir" && ./svc.sh start >/dev/null)
    echo "$name: running as $user"
done

for u in "${old_users[@]}"; do
    echo "note: no runner runs as $u any more. To remove the account and what jobs left in its home:"
    echo "  userdel -r $u && rm -f /etc/sudoers.d/90-$u"
done

say "Weekly Docker cleanup"
cat > /etc/cron.weekly/runner-docker-prune <<'EOF'
#!/bin/sh
# Jobs leave Docker images and build cache behind; drop what is a week old.
docker system prune -af --filter until=168h >/dev/null
docker builder prune -af --filter until=168h >/dev/null
EOF
chmod 0755 /etc/cron.weekly/runner-docker-prune

say "Done: $RUNNER_COUNT runner(s) for $RUNNER_URL"
