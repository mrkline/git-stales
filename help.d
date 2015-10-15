import std.stdio;
import std.c.stdlib : exit;

/// Writes whatever you tell it and then exits the program successfully
void writeAndSucceed(S...)(S toWrite)
{
    writeln(toWrite);
    exit(0);
}

/// Writes the help text and fails.
/// If the user explicitly requests help, we'll succeed (see writeAndSucceed),
/// but if what they give us isn't valid, bail.
void writeAndFail(S...)(S helpText)
{
    stderr.writeln(helpText);
    exit(1);
}

string versionString = q"EOS
stales v0.1 by Matt Kline, Fluke Networks
EOS";

string helpText = q"EOS
Usage: stales [--age-cutoff]

stales, when run from a Git directory, lists all branches that are merged into
the upstream/trunk branch (usually "master") and are older than a given number
of days. Such branches are usually good candidates for deletion to keep clutter
down in the repository.

Options:

  --help, -h
    Display this help text.

  --version, -V
    Display version information.

  --age-cutoff, -a <days>
    Specifies in days the oldest a merged branch can be before it is considered
    stale. Defaults to 30.

  --verbose, -v
    Print extra info as the branches are examined to stderr.
    Specify multiple times for additional info.

EOS";