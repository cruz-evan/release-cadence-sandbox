import 'dart:convert';
import 'dart:io';

import 'release_tools.dart';

// The existing version tag pins QA's code independently of the release PR head.
void main(List<String> args) => runScript(() {
  if (args.isEmpty || args.first == '--help') {
    stdout.writeln(
      'dart build_scripts/finalize_release.dart merged-release-pr-number',
    );
    return;
  }
  if (args.length != 1 || !RegExp(r'^[0-9]+$').hasMatch(args.single)) {
    throw ArgumentError('Expected a pull request number');
  }
  final repo = repository();
  final pr = api('repos/$repo/pulls/${args.single}');
  if (pr['merged'] != true ||
      pr['base']['ref'] != 'master' ||
      pr['base']['repo']['full_name'] != repo ||
      pr['head']['repo']['full_name'] != repo) {
    throw StateError(
      'Expected a merged, same-repository release PR into master',
    );
  }
  final branch = pr['head']['ref'] as String;
  final parts = branch.split('/');
  if (parts.length != 2 || parts[0] != 'release') {
    throw StateError('Expected release/<version>');
  }
  final version = parts[1];
  checkVersion(version);
  final tag = version;
  final commit = releaseTagCommit(repo, tag);
  if (commit == null) {
    throw StateError(
      'Missing $tag; run finish to tag the approved release before merging',
    );
  }
  final comparison = api('repos/$repo/compare/$commit...${pr['head']['sha']}');
  if (!['ahead', 'identical'].contains(comparison['status'])) {
    throw StateError('The release PR does not contain the tagged release commit');
  }

  // Read the approved release commit, not the integration PR head or master merge.
  final versionFile = jsonDecode(
    gh([
      'api',
      '--method',
      'GET',
      'repos/$repo/contents/VERSION.json',
      '-f',
      'ref=$commit',
      '-H',
      'Accept: application/vnd.github.raw+json',
    ]),
  );
  if (versionFile['version'] != version) {
    throw StateError('$branch does not match VERSION.json at $commit');
  }
  final release = releaseForTag(repo, tag);
  if (release == null)
    throw StateError('Missing version-matched notes for $tag');

  // Publish without changing the title, notes, or assets edited during QA.
  if (release['draft'] == true) {
    gh([
      'api',
      '--method',
      'PATCH',
      'repos/$repo/releases/${release['id']}',
      '-f',
      'target_commitish=$commit',
      '-F',
      'draft=false',
      '-f',
      'make_latest=false',
      '--silent',
    ]);
  }
  summary(
    'Published notes for existing $tag at approved release commit $commit after release PR #${args.single} '
    'merged into master. Store promotion follows separately.',
  );
});
