import std.algorithm;
import std.array : array;
import std.conv : to;
import std.datetime;
import std.exception : enforce;
import std.getopt;
import std.process;
import std.stdio;
import std.string : strip, stripLeft, indexOf;
import std.typecons : tuple;

import help;

/// Returns a range of branches that are on both remotes
auto findRemoteBranches()
{
    // -r lists remote branches
    auto remoteBranchFinder = pipeProcess(["git", "branch", "-r"], Redirect.stdout);
    // Make sure the process dies with us
    scope (failure) kill(remoteBranchFinder.pid);
    scope (exit) {
        enforce(wait(remoteBranchFinder.pid) == 0, "git branch -r failed");
    }

    auto remoteBranches = remoteBranchFinder.stdout
        .byLine()
        // Filter out tracking branches (e.g. origin/HEAD -> origin/something)
        .filter!(b => !b.canFind("->"))
        // git branch -r puts whitespace on the left. Strip that.
        .map!(b => stripLeft(b))
        // Allocate a new string for each line (byLine reuses a buffer)
        .map!(m => m.idup);

    return remoteBranches.array;
}

/// Takes a branch name string and strips the remote off the front
auto splitRemoteNameFromBranch(string branch) pure
{
    immutable firstSlash = branch.indexOf('/');
    return tuple!("remote", "branch")(
        branch[0 .. firstSlash],
        branch[firstSlash + 1 .. $]);
}

Duration ageOfBranch(string branch)
{
    auto showResult = execute(["git", "show", "-s", "--format=%cD", branch]);
    enforce(showResult.status == 0, "git show failed on branch " ~ branch);
    immutable rfc822 = showResult.output.strip();
    immutable branchDate = parseRFC822DateTime(rfc822);
    return Clock.currTime - branchDate;
}

// Gives how many commits branch is ahead and behind upstream
auto aheadBehindCounts(string branch, string upstream = "master")
{
    auto revListResult = execute(
        ["git", "rev-list", "--left-right", "--count", branch ~ "..." ~ upstream]);
    enforce(revListResult.status == 0,
            "git rev-list failed on branches " ~ branch ~ " and " ~ upstream);

    // The above rev-list command gives <commits ahead><tab><commits behind>
    auto counts = revListResult.output.strip().splitter('\t');
    string ahead = counts.front;
    counts.popFront();
    string behind = counts.front;
    counts.popFront();
    enforce(counts.empty, "Unexpected git rev-list output");

    return tuple!("ahead", "behind")(ahead.to!int, behind.to!int);
}

int main(string[] args)
{
    int ageCutoff = 30;
    int verbose = 0;

    try {
        getopt(args,
               config.caseSensitive,
               config.bundling,
               "help|h", { writeAndSucceed(helpText); },
               "version|V", { writeAndSucceed(versionString); },
               "verbose|v+", &verbose,
               "age-cutoff|a", &ageCutoff
              );
    }
    catch (GetOptException ex) {
        writeAndFail(ex.msg, "\n\n", helpText);
    }

    if (ageCutoff < 1) writeAndFail("Age cutoff must be at least one day");

    string[] stales;

    foreach (branch; findRemoteBranches()) {
        immutable counts = aheadBehindCounts(branch);
        // Ignore unmerged branches
        if (counts.ahead > 0) {
            if (verbose > 1) {
                stderr.writeln(branch, " has ", counts.ahead,
                               " unmerged commits. Skipping.");
            }
            continue;
        }

        // Ignore younger branches
        immutable ageInDays = ageOfBranch(branch).total!"days";
        if (ageInDays < ageCutoff) {
            if (verbose > 1) {
                stderr.writeln(branch, " is ", ageInDays,
                               " days old. Skipping.");
            }
            continue;
        }

        if (verbose > 0) {
            stderr.writeln(branch, " is ", ageInDays, " days old and ",
                           counts.behind, " commits behind master.");
        }
        stales ~= branch;
    }
    writeln("Stale branches:");
    foreach (stale; stales)
        writeln(stale);
    return 0;
}
