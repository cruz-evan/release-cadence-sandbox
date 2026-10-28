import 'dart:convert';
import 'dart:io';

import 'release_tools.dart';

void main(List<String> args) => runScript(() {
  if (args.isEmpty || args.length > 3 || !args.first.startsWith('release/')) {
    throw ArgumentError('Expected release/<version> [build commit SHA] [build notes file]');
  }
  final version = args.first.substring('release/'.length);
  checkVersion(version);
  Directory.current = git(['rev-parse', '--show-toplevel']);
  final repo = repository();
  final release = releaseForTag(repo, version);
  if (release == null) throw StateError('Missing draft notes for $version');
  if (releaseTagCommit(repo, version) != null) {
    if (args.length == 3) File(args[2]).writeAsStringSync(release['body'] as String);
    summary('$version is tagged; its notes are frozen.');
    return;
  }
  git(['fetch', '--no-tags', 'origin', 'refs/heads/${args.first}']);
  final commit = git(['rev-parse', 'FETCH_HEAD^{commit}']);
  if (args.length >= 2 && args[1] != commit) {
    throw StateError('Release branch moved; start a new build from its current head');
  }
  if (jsonDecode(git(['show', '$commit:VERSION.json']))['version'] != version) {
    throw StateError('Release branch must match VERSION.json');
  }
  if (args.length == 3) {
    final scratch = Directory.systemTemp.createTempSync('release-build-notes-');
    try {
      File(args[2]).writeAsStringSync(notesForRelease(repo, version, commit, scratch));
    } finally {
      scratch.deleteSync(recursive: true);
    }
  } else {
    refreshReleaseNotes(repo, version, commit);
  }
});
