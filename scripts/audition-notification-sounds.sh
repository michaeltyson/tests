#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
candidate_root="$script_dir/../Tests/Resources/NotificationSounds/Candidates"

usage() {
    echo "Usage: $0 [warm|glass|mechanical|all]"
}

play_family() {
    family=$1
    echo "Auditioning $family: Ignition, Fracture, Resolved"
    for sound in Ignition Fracture Resolved; do
        file="$candidate_root/$family/Tests-$sound.wav"
        if [ ! -f "$file" ]; then
            echo "Missing $file; run scripts/generate-notification-sounds.py first." >&2
            exit 1
        fi
        echo "  $sound"
        /usr/bin/afplay "$file"
        sleep 1
    done
}

selection=${1:-all}
case "$selection" in
    warm|glass|mechanical)
        play_family "$selection"
        ;;
    all)
        for family in warm glass mechanical; do
            play_family "$family"
        done
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
