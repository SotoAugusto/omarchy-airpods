#!/usr/bin/env bash
# setup's decision logic, against a fake main.conf with every privileged
# action and the package manager stubbed out.
#
# The case that matters is the first one. Installing the daemon sets the BlueZ
# DeviceID as a side effect — airpods-tui's own post_install hook writes it —
# so a setup script that asks "did I edit the file?" concludes no, skips the
# bluetooth restart and the re-pair warning, and reports Ready while the
# control channel is not yet usable. It has to ask "was it absent when we
# started?" instead.
#
# Reported by a marketplace reviewer against 0.1.9, which fails this test.
set -uo pipefail
cd "$(dirname "$0")"

SRC="${1:-../setup}"
failures=0

run_case() {
  local name="$1" preexisting="$2" hook_sets="$3" pkg_installed="$4"
  local want_restart="$5"
  local dir conf out
  dir=$(mktemp -d); conf="$dir/main.conf"

  printf '[General]\n' > "$conf"
  [[ $preexisting == yes ]] && printf 'DeviceID = bluetooth:004C:0000:0000\n' >> "$conf"

  # Every external dependency is substituted out of the script text rather
  # than shadowed with shell functions: the script runs in its own bash
  # process, so exported-function stubs silently do not apply and every case
  # ends up exercising whichever path the real machine happens to be in.
  local detect="false"
  [[ $pkg_installed == yes ]] && detect="true"
  # A plain append, not a sed address match: what matters is that the line
  # exists afterwards, and bracket escaping through two layers of quoting is
  # exactly the kind of thing that silently matches nothing and turns the test
  # green for the wrong reason.
  local hook=":"
  [[ $hook_sets == yes ]] &&
    hook="printf 'DeviceID = bluetooth:004C:0000:0000\\n' >> $conf"

  sed -e "s|CONF=/etc/bluetooth/main.conf|CONF=$conf|" \
      -e "s|if command -v airpods-tui >/dev/null 2>&1; then|if $detect; then|" \
      -e "s|    yay -S --needed airpods-tui-bin .*|    echo INSTALLED_PACKAGE; $hook|" \
      -e "s|    sudo sed -i|    sed -i|" \
      -e "s| sudo tee -a| tee -a|" \
      -e "s|  sudo systemctl restart bluetooth .*|  echo RESTARTED_BLUETOOTH|" \
      -e "s|if systemctl --user is-enabled airpods-tui >/dev/null 2>&1; then|if false; then|" \
      -e "s|  systemctl --user enable --now airpods-tui .*|  echo ENABLED|" \
      -e "s|systemctl --user restart airpods-tui .*|echo RESTARTED_DAEMON|" \
      -e "s|if command -v omarchy >/dev/null 2>&1; then|if true; then|" \
      -e "s|  omarchy restart shell .*|  echo RESTARTED_SHELL|" \
      "$SRC" > "$dir/setup"
  chmod +x "$dir/setup"

  out=$(printf 'y\n' | XDG_STATE_HOME="$dir/state" bash "$dir/setup" 2>&1)

  local got_restart=no got_repair=no
  local got_daemon_restart=no got_shell_restart=no
  local got_onboarding=no
  grep -q RESTARTED_BLUETOOTH <<<"$out" && got_restart=yes
  grep -q "forget and re-pair" <<<"$out" && got_repair=yes
  grep -q RESTARTED_DAEMON <<<"$out" && got_daemon_restart=yes
  grep -q RESTARTED_SHELL <<<"$out" && got_shell_restart=yes
  [[ -f "$dir/state/omarchy/airpods-onboarding.json" ]] && got_onboarding=yes

  if [[ $got_restart == "$want_restart" && $got_repair == "$want_restart" \
      && $got_onboarding == "$want_restart" \
      && $got_daemon_restart == yes && $got_shell_restart == yes ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s: bluetooth=%s re-pair=%s onboarding=%s, wanted all %s; daemon=%s shell=%s, wanted yes\n' \
           "$name" "$got_restart" "$got_repair" "$want_restart" \
           "$got_onboarding" "$got_daemon_restart" "$got_shell_restart"
    failures=$((failures + 1))
  fi
  rm -rf "$dir"
}

echo "setup: bluetooth restart and re-pair warning"
#         name                                  pre  hook pkg  want
run_case "fresh install, hook sets the DeviceID" no   yes  no   yes
run_case "no package, setup sets it itself"      no   no   no   yes
run_case "package present, DeviceID missing"     no   no   yes  yes
run_case "already fully configured"              yes  no   yes  no

echo
if (( failures )); then
  echo "$failures failed"
  exit 1
fi
echo "all setup tests passed"
