# stales

Finds git branches that haven't been touched in a while and aren't unmerged,
making them good candidates for deletion.

This is a hard-coded proof of concept. Desired additions:

- Command line options (crazy, right?) such as minimum age
- Mode to run "git push --delete" to the remote to remove these stale branches
