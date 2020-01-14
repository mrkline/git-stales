import std.algorithm;
import std.array;
import std.conv : to;
import std.datetime;
import std.exception : enforce;
import std.getopt;
import std.process;
import std.range : chain;
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

struct StaleLists
{
    string[] locals;
    string[] remotes;
}

/// Returns an array of branches that don't match the "keeper" regexes
StaleLists getStaleBranches(string[] keepers, BranchType type)
{
    // Compile our regular expressions first
    // (to spit out any regex errors before we light up "git branch")
    Regex!char[] regexes = keepers.map!(k => regex(k)).array;

    StaleLists ret;

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
            // Take a copy since byLine reuses the same buffer for each iteration.
            .map!(b => b.idup);

        ret.locals = localBranches.array;
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
            .filter!(b => !regexes.any!(r => extractBranchName(b).matchFirst(r)))
            .map!(b => b.idup);

        ret.remotes = remoteBranches.array;
    }

    return ret;
}

/// Pulls the branch name off a "remote/branch" string
auto extractBranchName(Range)(Range fullBranchName) pure
{
    immutable firstSlash = fullBranchName.indexOf('/');
    return fullBranchName[firstSlash + 1 .. $];
}

/// Pulls the remote name off a "remote/branch" string
auto extractRemote(Range)(Range fullBranchName) pure
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

    auto stales = getStaleBranches(keepers, bt);

    bool filterStales(string branch) {
        // Ignore unmerged branches
        immutable counts = aheadBehindCounts(branch, mainBranch);
        if (counts.ahead > 0) {
            if (verbosity > 1) {
                stderr.writeln(branch, " has ", counts.ahead,
                               " unmerged commits. Skipping.");
            }
            return false;
        }

        // Ignore younger branches
        immutable ageInDays =
                (branchTime(mainBranch) - branchTime(branch)).total!"days";
        if (ageInDays < ageCutoff) {
            if (verbosity > 1) {
                stderr.writeln(branch, " is ", ageInDays,
                               " days old. Skipping.");
            }
            return false;
        }

        // We have a keeper.
        if (verbosity > 0) {
            stderr.writeln(branch, " is ", ageInDays, " days old and ",
                           counts.behind, " commits behind ", mainBranch, '.');
        }
        return true;
    }


    stales.locals = stales.locals.filter!(filterStales).array;
    stales.remotes = stales.remotes.filter!(filterStales).array;

    if (stales.locals.empty && stales.remotes.empty) {
        writeln("No stale branches! (nothing to do)");
        return 0;
    }

    // Build up commands to delete the stale branches if the user wants.
    if (dryRun || pushDeletes) {

        if (!stales.locals.empty) {
            // First, the locals.
            string[] localDeleteCommand = ["git", "branch", "-d"] ~ stales.locals;

            if (pushDeletes) {
                write("deleting local branches...");
                stdout.flush();
                auto deleteResult = execute(localDeleteCommand);
                enforce(deleteResult.status == 0,
                        "'" ~ localDeleteCommand.join(" ") ~ "' failed");
                writeln(" done");
            }
            else {
                writeln(joiner(localDeleteCommand, " "));
            }
        }

        if (!stales.remotes.empty) {
            // Group branches by remote
            // The sorting is probably unneeded - doesn't Git organize branches
            // by remote?
            auto remoteGroups = stales.remotes
                .sort
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
                    enforce(deleteResult.status == 0,
                            "'" ~ remoteDeleteCommand.join(" ") ~ "' failed");
                    writeln(" done");
                }
                else {
                    writeln(joiner(remoteDeleteCommand, " "));
                }
            }
        }
    }
    // Otherwise just print them out.
    else {
        writeln("Stale branches:");
        foreach (stale; chain(stales.locals, stales.remotes))
            writeln(stale);
    }
    return 0;
}
