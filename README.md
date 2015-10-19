# stales

Finds git branches that haven't been touched in a while and aren't unmerged,
making them good candidates for deletion.

See `help.d` for the various options, which include:

- Which branch is the main ("master") branch
- How old (in days) a branch must be in order to be considered stale
- Which branches to keep, regardless of age
- Options to generate (or run!) a `git push` command to delete stale branches
