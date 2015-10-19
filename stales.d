import std.algorithm;
import std.array : array;
import std.conv : to;
import std.datetime;
import std.exception : enforce;
import std.getopt;
import std.process;
import std.regex;
import std.stdio;
import std.string : strip, stripLeft, indexOf;
import std.typecons : tuple;

import help;

/// Returns a range of branches that are on both remotes
auto findRemoteBranches(string[] keepers)
{
    // Compile our regular expressions first
    // (to spit out any regex errors before we light up "git branch")
    Regex!char[] regexes = keepers.map!(k => regex(k)).array;

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
        // Filter out ones we want to keep
        .filter!(b => !regexes.any!(r => b.matchFirst(r)))
        // Allocate a new string for each line (byLine reuses a buffer)
        .map!(m => m.idup);

    return remoteBranches.array;
}

string extractBranchName(string fullBranchName) pure
{
    immutable firstSlash = fullBranchName.indexOf('/');
    return fullBranchName[firstSlash + 1 .. $];
}

string extractRemote(string fullBranchName) pure
{
    immutable firstSlash = fullBranchName.indexOf('/');
    return fullBranchName[0 .. firstSlash];
}

/// Takes a branch name string and strips the remote off the front
auto splitRemoteNameFromBranch(string fullBranchName) pure
{
    immutable firstSlash = fullBranchName.indexOf('/');
    return tuple!("remote", "branch")(
        fullBranchName[0 .. firstSlash],
        fullBranchName[firstSlash + 1 .. $]);
}

Duration ageOfBranch(string branch)
{
    auto showResult = execute(["git", "show", "-s", "--format=%cD", branch]);
    enforce(showResult.status == 0, "git show failed on branch " ~ branch);
    immutable rfc822 = showResult.output.strip();
    immutable branchDate = parseRFC822DateTime(rfc822);
    return Clock.currTime - branchDate;
}

// Gives how many commits branch is ahead and behind mainBranch
auto aheadBehindCounts(string branch, string mainBranch = "master")
{
    auto revListResult = execute(
        ["git", "rev-list", "--left-right", "--count", branch ~ "..." ~ mainBranch]);
    enforce(revListResult.status == 0,
            "git rev-list failed on branches " ~ branch ~ " and " ~ mainBranch);

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
    string mainBranch = "master";
    string[] keepers;
    int verbosity = 0;
    bool pushDeletes = false;
    bool dryRun = false;

    try {
        getopt(args,
               config.caseSensitive,
               config.bundling,
               "help|h", { writeAndSucceed(helpText); },
               "version|V", { writeAndSucceed(versionString); },
               "verbose|v+", &verbosity,
               "main-branch|m", &mainBranch,
               "age-cutoff|a", &ageCutoff,
               "keep|k", &keepers,
               "push-deletes|d", &pushDeletes,
               "dry-run|n", &dryRun,
              );
    }
    catch (GetOptException ex) {
        writeAndFail(ex.msg, "\n\n", helpText);
    }

    if (ageCutoff < 1) writeAndFail("Age cutoff must be at least one day");

    if (pushDeletes && dryRun)
        writeAndFail("--push-deletes and --dry-run specified (pick one)");

    string[] stales;

    foreach (branch; findRemoteBranches(keepers)) {
        immutable counts = aheadBehindCounts(branch, mainBranch);
        // Ignore unmerged branches
        if (counts.ahead > 0) {
            if (verbosity > 1) {
                stderr.writeln(branch, " has ", counts.ahead,
                               " unmerged commits. Skipping.");
            }
            continue;
        }

        // Ignore younger branches
        immutable ageInDays = ageOfBranch(branch).total!"days";
        if (ageInDays < ageCutoff) {
            if (verbosity > 1) {
                stderr.writeln(branch, " is ", ageInDays,
                               " days old. Skipping.");
            }
            continue;
        }

        if (verbosity > 0) {
            stderr.writeln(branch, " is ", ageInDays, " days old and ",
                           counts.behind, " commits behind ", mainBranch, '.');
        }
        stales ~= branch;
    }

    if (dryRun || pushDeletes) {
        // Group branches by remote
        // The sorting is probably unneeded - doesn't Git organize branches
        // by remote?
        auto remoteGroups = stales
            .sort!((a, b) => extractRemote(a) < extractRemote(b))
            .chunkBy!(a => extractRemote(a));

        foreach (group; remoteGroups) {
            // group is a tuple. Member 0 is the remote name.
            string[] deleteCommand = ["git", "push", "--delete", group[0]];
            // Member 1 is the list of branches for that remote.
            deleteCommand ~= group[1].map!(b => extractBranchName(b)).array;

            if (pushDeletes) {
                auto deleteResult = execute(deleteCommand);
                enforce(deleteResult.status == 0, "git push --delete failed");
            }
            else
            {
                writeln(joiner(deleteCommand, " "));
            }
        }
    }
    else {
        writeln("Stale branches:");
        foreach (stale; stales)
            writeln(stale);
    }
    return 0;
}
