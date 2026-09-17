---
name: nix-shell
description: >
  These are NixOS machines with a deliberately small global package set. A
  missing command is expected, not a blocker: run it through `nix-shell -p`.
alwaysApply: true
---

# Missing commands

A command that is not on PATH is usually just not installed globally, not
absent from the machine. `ffprobe: command not found` is not a reason to give
up on a task, work around it in another language, or ask the user to install
something.

- Run a one-off through `nix-shell -p <pkg> --run '<command>'`. The package is
  fetched from the binary cache on first use and cached afterwards, so this
  costs seconds, not a rebuild.
- Several packages at once: `nix-shell -p ffmpeg imagemagick --run '...'`.
- The attribute name is usually the command name, but not always
  (`ffprobe`/`ffmpeg` are both in `ffmpeg`, `convert` is in `imagemagick`,
  `magick` in IMv7). Search with `nix search nixpkgs <name>` when unsure.
- This is for **ad-hoc, throwaway** use during a task: inspecting a file,
  converting an image, probing a video. A tool the user will need again belongs
  in their configuration instead - say so rather than leaving them with a
  command that only worked inside your shell.
- Tools that run your command in their own process (a video reader needing
  `ffprobe`, for instance) do not see a `nix-shell` environment you entered in
  `bash`. Do the work in the shell and hand the tool the produced file.
