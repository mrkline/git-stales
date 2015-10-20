# stales

Finds git branches that haven't been touched in a while and aren't unmerged,
making them good candidates for deletion.

## Requirements

1. Git 1.7.0+ (for `git push --delete`)

2. A [D](http://dlang.org) toolchain

## How do I build it?

1. [Get a D compiler.](http://dlang.org/download.html)

2. Run `make`.

## How do I run it?

See `help.d` for the various options, which include:

- Which branch is the main ("master") branch
- How old (in days) a branch must be in order to be considered stale
- Which branches to keep, regardless of age
- Options to generate (or run!) a `git push` command to delete stale branches
