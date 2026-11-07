#!/bin/zsh
# Builds a 5.1 channel-identification clip: each speaker announces itself in turn
# ("front left", "front right", "center", LFE = 50 Hz tone, "surround left", "surround right").
# Writes:
#   test/channel-id-<rate>.s32le  raw FL FR FC LFE SL SR int32 for `MATBridge run --test-file` (no virtual device needed)
#   test/channel-id-<rate>.wav    the same as a 5.1(side) WAV, for playing through the virtual device later
#   test/silence-<rate>.s32le     2 s of digital silence (for mechanical tests that should be inaudible)
set -euo pipefail
rate=${1:-48000}
cd "${0:A:h}/.."
mkdir -p test
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

names=("front left" "front right" "center" "" "surround left" "surround right")
inputs=()
for i in {1..6}; do
  if [[ $i == 4 ]]; then
    ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=50:sample_rate=${rate}:duration=1.5" -af "volume=0.7,afade=t=in:d=0.05,afade=t=out:st=1.4:d=0.1" -y "$tmp/c$i.wav"
  else
    say -o "$tmp/c$i.aiff" "${names[$i]}"
    ffmpeg -hide_banner -loglevel error -i "$tmp/c$i.aiff" -ar ${rate} -ac 1 -y "$tmp/c$i.wav"
  fi
  inputs+=(-i "$tmp/c$i.wav")
done

# Channel i speaks during slot i (2 s per slot), silent otherwise.
filter=""
for i in {0..5}; do
  filter+="[${i}:a]adelay=$((i * 2000)),apad=whole_dur=12[a${i}];"
done
filter+="[a0][a1][a2][a3][a4][a5]join=inputs=6:channel_layout=5.1(side):map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-SL|5.0-SR[out]"
ffmpeg -hide_banner -loglevel error "${inputs[@]}" -filter_complex "$filter" -map "[out]" -ar ${rate} -c:a pcm_s32le -y "test/channel-id-${rate}.wav"
ffmpeg -hide_banner -loglevel error -i "test/channel-id-${rate}.wav" -f s32le -y "test/channel-id-${rate}.s32le"
ffmpeg -hide_banner -loglevel error -f lavfi -i "anullsrc=r=${rate}:cl=5.1(side)" -t 2 -f s32le -c:a pcm_s32le -y "test/silence-${rate}.s32le"
ls -l test/*-${rate}.*
