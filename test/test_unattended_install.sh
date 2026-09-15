#!/bin/sh
set -eu

export LC_ALL=C
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/brew-distill-unattended-test.XXXXXX")

cleanup() {
  if [ -n "${server_pid:-}" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

monitor="$test_dir/monitor.sock"
commands="$test_dir/commands.log"
frame="$test_dir/frame.ppm"
command_file="$test_dir/install-command.txt"
output="$test_dir/unattended.json"
cat > "$command_file" <<'EOF'
echo ok
EOF

cat > "$test_dir/fake-monitor.rb" <<'RUBY'
#!/usr/bin/env ruby
# frozen_string_literal: true

require "socket"

socket_path, command_log = ARGV
File.unlink(socket_path) if File.exist?(socket_path)
server = UNIXServer.new(socket_path)
paused = false
screendumps = 0

def write_frame(path, width, height, red, green, blue)
  pixel = [red, green, blue].pack("C3")
  File.binwrite(path, "P6\n#{width} #{height}\n255\n" + (pixel * (width * height)))
end

def write_uefi_shell_frame(path, width, height)
  header = "P6\n#{width} #{height}\n255\n"
  data = ("\0" * (width * height * 3)).b
  [[2, 1], [2, 2], [6, 1], [6, 2]].each do |row, column|
    x = column * width / 32
    y = row * height / 18
    pixel = (y * width + x) * 3
    3.times { |channel| data.setbyte(pixel + channel, 255) }
  end
  File.binwrite(path, header + data)
end

File.open(command_log, "w") do |log|
  uefi_shell = ENV["UEFI_SHELL"] == "1"
  loop do
    client = server.accept
    client.write("QEMU fake monitor\n(qemu) ")
    command = client.gets.to_s.chomp
    log.puts(command)
    log.flush
    response = case command
               when /\Ascreendump (.+)\z/
                 screendumps += 1
                 if uefi_shell && screendumps >= 2
                   write_uefi_shell_frame(Regexp.last_match(1), 64, 36)
                 else
                   case screendumps
                   when 1, 5, 6, 8, 9
                     write_frame(Regexp.last_match(1), 64, 36, 220, 220, 220)
                   when 2..4, 7, 10..100
                     write_frame(Regexp.last_match(1), 32, 18, 20, 20, 220)
                   end
                 end
                 ""
               when "info status"
                 paused ? "VM status: paused" : "VM status: running"
               when "stop"
                 paused = true
                 ""
               when "cont"
                 paused = false
                 ""
               else
                 ""
               end
    client.write("#{response}\n(qemu) ")
    client.close
  end
end
RUBY
chmod 755 "$test_dir/fake-monitor.rb"

ruby "$test_dir/fake-monitor.rb" "$monitor" "$commands" &
server_pid=$!

if ! DISTILL_UNATTENDED_FRAME_WAIT=0 \
  DISTILL_UNATTENDED_PICKER_SETTLE=0 \
  DISTILL_UNATTENDED_RECOVERY_SETTLE=0 \
  DISTILL_UNATTENDED_RECOVERY_STILL_MAX=1 \
  DISTILL_UNATTENDED_RECOVERY_STILL_FRAMES=2 \
  DISTILL_UNATTENDED_TERMINAL_WAIT=0 \
  DISTILL_UNATTENDED_INSTALL_REBOOT_GRACE=0 \
  DISTILL_UNATTENDED_INSTALL_REBOOT_TIMEOUT=10 \
  DISTILL_UNATTENDED_DONE_QUIET=0 \
  DISTILL_UNATTENDED_HUNG_STILL=10 \
  DISTILL_UNATTENDED_PICKER_REPRESS=0 \
  DISTILL_UNATTENDED_TOTAL_BUDGET=30 \
  DISTILL_UNATTENDED_POLL=0 \
  DISTILL_UNATTENDED_KEY_DELAY=0 \
  DISTILL_UNATTENDED_TYPE_DELAY=0 \
  ruby "$repo_dir/scripts/hvf/unattended-install" \
    --monitor "$monitor" --disk-gib 64 --command-file "$command_file" \
    --output "$output" --frame "$frame" > "$test_dir/driver.log" 2>&1; then
  cat "$test_dir/driver.log" >&2
  cat "$commands" >&2
  exit 1
fi

jq -e '.schema == 1 and .status == "passed" and .guest_install_seconds >= 0 and .reboots == 1 and any(.events[]; contains("install finished"))' \
  "$output" >/dev/null
test -s "$test_dir/screen-before-command.ppm"
test -s "$test_dir/screen-after-typing.ppm"
test -s "$test_dir/screen-first-reboot.ppm"
test -s "$test_dir/unattended-frames.jsonl"
jq -s -e 'all(.[]; .uefi_shell_like == false)' "$test_dir/unattended-frames.jsonl" >/dev/null
grep -Fqx -- 'sendkey ctrl-f2' "$commands"
grep -Fqx -- 'sendkey e' "$commands"
grep -Fqx -- 'sendkey ret' "$commands"

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
unset server_pid
shell_monitor="$test_dir/shell-monitor.sock"
shell_commands="$test_dir/shell-commands.log"
shell_output="$test_dir/shell-unattended.json"
UEFI_SHELL=1 ruby "$test_dir/fake-monitor.rb" "$shell_monitor" "$shell_commands" &
server_pid=$!
if DISTILL_UNATTENDED_FRAME_WAIT=0 \
  DISTILL_UNATTENDED_PICKER_SETTLE=0 \
  DISTILL_UNATTENDED_RECOVERY_SETTLE=0 \
  DISTILL_UNATTENDED_RECOVERY_TIMEOUT=10 \
  DISTILL_UNATTENDED_RECOVERY_STILL_MAX=1 \
  DISTILL_UNATTENDED_RECOVERY_STILL_FRAMES=2 \
  DISTILL_UNATTENDED_POLL=0 \
  DISTILL_UNATTENDED_KEY_DELAY=0 \
  DISTILL_UNATTENDED_TYPE_DELAY=0 \
  ruby "$repo_dir/scripts/hvf/unattended-install" \
    --monitor "$shell_monitor" --disk-gib 64 --command-file "$command_file" \
    --output "$shell_output" --frame "$test_dir/shell-frame.ppm" > "$test_dir/shell-driver.log" 2>&1; then
  cat "$test_dir/shell-driver.log" >&2
  exit 1
fi
jq -e '.status == "failed" and (.error | contains("UEFI Shell")) and .guest_install_seconds == null' \
  "$shell_output" >/dev/null
jq -s -e 'any(.[]; .uefi_shell_like == true)' \
  "$test_dir/unattended-frames.jsonl" >/dev/null
test -s "$test_dir/screen-recovery-timeout.ppm"

printf '%s\n' ok
