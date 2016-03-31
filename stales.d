import std.algorithm;
import std.array;
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

/// Used for command line args and determining how to process a given branch
/// (remote branches often need to have the remote name and the rest of the
/// branch name split up)
enum BranchType {
    Local = 1,
    Remote = 2,
    LocalAndRemote = (Local | Remote)
}

struct BranchInfo {
    string fullName;
    BranchType type;
}

/// Returns an array of branches that don't match the "keeper" regexes
BranchInfo[] findRemoteBranches(string[] keepers, BranchType type)
{
    // Compile our regular expressions first
    // (to spit out any regex errors before we light up "git branch")
    Regex!char[] regexes = keepers.map!(k => regex(k)).array;

    BranchInfo[] ret;

    if (type & BranchType.Local) {
        auto localBranchFinder = pipeProcess(["git", "branch"], Redirect.stdout);
        // Make sure the process dies with us
        scope (failure) kill(localBranchFinder.pid);
        scope (exit) {
            enforce(wait(localBranchFinder.pid) == 0, "git branch failed");
        }

        auto localBranches = localBranchFinder.stdout
            .byLine()
            // Filter out the current branch
            .filter!(b => !b.startsWith('*'))
            // git branch puts whitespace on the left. Strip that.
            .map!(b => stripLeft(b))
            // Filter out ones we want to keep
            .filter!(b => !regexes.any!(r => b.matchFirst(r)))
            // Allocate a new string for each line (byLine reuses a buffer)
            .map!(m => m.idup)
            // Tag on the type
            .map!(b => BranchInfo(b, BranchType.Local));

        ret = localBranches.array;
    }

    if (type & BranchType.Remote) {
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
            // The rest mostly the same as above
            .map!(b => stripLeft(b))
            // We idup before we filter because extractBranchName expects
            // an immutable string.
            .map!(m => m.idup)
            .filter!(b => !regexes.any!(r => extractBranchName(b).matchFirst(r)))
            .map!(b => BranchInfo(b, BranchType.Remote));

        auto app = appender(ret);
        app.put(remoteBranches);
        ret = app.data;
    }

    return ret;
}

/// Pulls the branch name off a "remote/branch" string
string extractBranchName(string fullBranchName) pure
{
    immutable firstSlash = fullBranchName.indexOf('/');
    return fullBranchName[firstSlash + 1 .. $];
}

/// Pulls the remote name off a "remote/branch" string
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

SysTime branchTime(string branch)
{
    auto showResult = execute(["git", "show", "-s", "--format=%cD", branch]);
    enforce(showResult.status == 0, "git show failed on branch " ~ branch);
    immutable rfc822 = showResult.output.strip();
    return parseRFC822DateTime(rfc822);
}

// Gives how many commits branch is ahead and behind mainBranch
auto aheadBehindCounts(string branch, string mainBranch = "master")
{
    auto revListResult = execute(
        ["git", "rev-list", "--left-right", "--count", branch ~ "..." ~ mainBranch]);
    enforce(revListResult.status == 0,
            "git rev-list " ~ branch ~ " and " ~ mainBranch);

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
    // Boring args parsing:

    int ageCutoff = 30;
    string mainBranch = "master";
    string[] keepers;
    string types = "both";
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
               "branch-types|t", &types,
               "push-deletes|d", &pushDeletes,
               "dry-run|n", &dryRun,
              );
    }
    catch (GetOptException ex) {
        writeAndFail(ex.msg, "\n\n", helpText);
    }

    // Boring args validation:

    if (ageCutoff < 1) writeAndFail("Age cutoff must be at least one day");

    if (pushDeletes && dryRun)
        writeAndFail("--push-deletes and --dry-run specified (pick one)");

    BranchType bt;
    switch (types) {
        case "local":
            bt = BranchType.Local;
            break;
        case "remote":
            bt = BranchType.Remote;
            break;
        case "both":
            bt = BranchType.LocalAndRemote;
            break;
        default:
            writeAndFail("Invalid branch type (use local, remote, or both)");
    }

    if (execute(["git", "rev-parse", mainBranch]).status != 0)
        writeAndFail("Git couldn't find the branch, \"", mainBranch, '"');

    auto staleAppender = appender!(BranchInfo[])();

    // Get a list of branches we might be interested in,
    // then build up a list of stale ones.
    foreach (branch; findRemoteBranches(keepers, bt)) {
        immutable currentName = branch.fullName;

        // Ignore unmerged branches
        immutable counts = aheadBehindCounts(currentName, mainBranch);
        if (counts.ahead > 0) {
            if (verbosity > 1) {
                stderr.writeln(currentName, " has ", counts.ahead,
                               " unmerged commits. Skipping.");
            }
            continue;
        }

        // Ignore younger branches
        immutable ageInDays =
                (branchTime(mainBranch) - branchTime(currentName)).total!"days";
        if (ageInDays < ageCutoff) {
            if (verbosity > 1) {
                stderr.writeln(currentName, " is ", ageInDays,
                               " days old. Skipping.");
            }
            continue;
        }

        // We have a keeper.
        if (verbosity > 0) {
            stderr.writeln(currentName, " is ", ageInDays, " days old and ",
                           counts.behind, " commits behind ", mainBranch, '.');
        }
        staleAppender.put(branch);
    }
    BranchInfo[] stales = staleAppender.data();

    if (stales.empty) {
        writeln("No stale branches! (nothing to do)");
        return 0;
    }

    // Build up commands to delete the stale branches if the user wants.
    if (dryRun || pushDeletes) {

        // Local and remote branches shouldn't be randomly interspersed,
        // and this makes our job easier below.
        assert(isPartitioned!(s => s.type == BranchType.Local)(stales));

        // First, the locals.
        string[] localDeleteCommand = ["git", "branch", "-d"];
        while (stales[0].type == BranchType.Local) {
            localDeleteCommand ~= stales[0].fullName;
            stales = stales[1 .. $];
        }
        if (pushDeletes) {
            write("deleting local branches...");
            stdout.flush();
            auto deleteResult = execute(localDeleteCommand);
            enforce(deleteResult.status == 0, "git branch -d failed");
            writeln(" done");
        }
        else {
            writeln(joiner(localDeleteCommand, " "));
        }

        // We should be done with local branches now
        assert(all!(s => s.type == BranchType.Remote)(stales));

        // Group branches by remote
        // The sorting is probably unneeded - doesn't Git organize branches
        // by remote?
        auto remoteGroups = stales
            .sort!((a, b) => extractRemote(a.fullName) < extractRemote(b.fullName))
            .map!(s => s.fullName)
            .chunkBy!(a => extractRemote(a));

        foreach (group; remoteGroups) {
            // group is a tuple. Member 0 is the remote name.
            string[] remoteDeleteCommand = ["git", "push", "--delete", group[0]];
            // Member 1 is the list of branches for that remote.
            remoteDeleteCommand ~= group[1].map!(b => extractBranchName(b)).array;

            if (pushDeletes) {
                write("deleting remote branches...");
                stdout.flush();
                auto deleteResult = execute(remoteDeleteCommand);
                enforce(deleteResult.status == 0, "git push --delete failed");
                writeln(" done");
            }
            else {
                writeln(joiner(remoteDeleteCommand, " "));
            }
        }
    }
    // Otherwise just print them out.
    else {
        writeln("Stale branches:");
        foreach (stale; stales)
            writeln(stale.fullName);
    }
    return 0;
}
