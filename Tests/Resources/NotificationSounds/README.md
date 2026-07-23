# Tests notification sound candidates

These sounds are original, deterministic procedural renders. They contain no
third-party samples and can be regenerated with:

```sh
python3 scripts/generate-notification-sounds.py
```

Audition one family or all three:

```sh
scripts/audition-notification-sounds.sh warm
scripts/audition-notification-sounds.sh glass
scripts/audition-notification-sounds.sh mechanical
scripts/audition-notification-sounds.sh all
```

Each family contains the same semantic sequence:

- `Tests-Ignition.wav`: tests started
- `Tests-Fracture.wav`: tests failed
- `Tests-Resolved.wav`: tests succeeded

The `Candidates` directory is intentionally not included in the app's Copy
Bundle Resources phase. Once a family is selected, copy its three files into a
`Final` directory and add only those files to the application resources.
