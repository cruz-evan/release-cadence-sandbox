import 'dart:convert';
import 'dart:io';

const versionPattern = r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$';
const gitIdentity = [
  '-c',
  'user.name=Crono-Committer',
  '-c',
  'user.email=Crono_Committer@cronometer.com',
];

// Pass arguments directly to Git/gh, without shell interpolation.
String command(String program, List<String> args) {
  final result = Process.runSync(program, args);
  if (result.exitCode != 0) {
    throw StateError('$program ${args.join(' ')} failed:\n${result.stderr}');
  }
  return (result.stdout as String).trim();
}

String git(List<String> args) => command('git', args);
String gh(List<String> args) => command('gh', args);

String repository() =>
    Platform.environment['GITHUB_REPOSITORY'] ??
    gh(['repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner']);

dynamic api(String path) => jsonDecode(gh(['api', path]));

// gh's slurped pages are flattened into a normal list of releases.
List<Map<String, dynamic>> releases(String repo) {
  final pages =
      jsonDecode(
            gh([
              'api',
              '--paginate',
              '--slurp',
              'repos/$repo/releases?per_page=100',
            ]),
          )
          as List;
  return pages
      .expand((page) => page as List)
      .map((release) => Map<String, dynamic>.from(release))
      .toList();
}

Map<String, dynamic>? releaseForTag(String repo, String tag) {
  final matches = releases(
    repo,
  ).where((release) => release['tag_name'] == tag).toList();
  if (matches.length > 1) throw StateError('Multiple releases found for $tag');
  return matches.isEmpty ? null : Map<String, dynamic>.from(matches.single);
}

// Resolve lightweight and annotated tags without ever moving an existing ref.
String? releaseTagCommit(String repo, String tag) {
  final refs = api('repos/$repo/git/matching-refs/tags/$tag') as List;
  final matches = refs.where((ref) => ref['ref'] == 'refs/tags/$tag').toList();
  if (matches.isEmpty) return null;
  var object = matches.single['object'];
  while (object['type'] == 'tag') {
    object = api('repos/$repo/git/tags/${object['sha']}')['object'];
  }
  if (object['type'] != 'commit')
    throw StateError('$tag does not identify a commit');
  return object['sha'] as String;
}

void pinReleaseTag(String repo, String tag, String commit) {
  final existing = releaseTagCommit(repo, tag);
  if (existing != null) {
    if (existing != commit)
      throw StateError('$tag already points elsewhere; refusing to move it');
    return;
  }
  gh([
    'api',
    '--method',
    'POST',
    'repos/$repo/git/refs',
    '-f',
    'ref=refs/tags/$tag',
    '-f',
    'sha=$commit',
    '--silent',
  ]);
}

void checkVersion(String version) {
  if (!RegExp(versionPattern).hasMatch(version)) {
    throw StateError('Invalid release version: $version');
  }
}

String bumpVersion(String version, {bool minor = false}) {
  checkVersion(version);
  final parts = version.split('.').map(int.parse).toList();
  if (minor) {
    parts[1]++;
    parts[2] = 0;
  } else {
    parts[2]++;
  }
  return parts.join('.');
}

int compareVersions(String a, String b) {
  final left = a.split('.').map(int.parse).toList();
  final right = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    final difference = left[i].compareTo(right[i]);
    if (difference != 0) return difference;
  }
  return 0;
}

void summary(String message) {
  stdout.writeln(message);
  final path = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (path != null)
    File(path).writeAsStringSync('$message\n', mode: FileMode.append);
}

void runScript(void Function() action) {
  try {
    action();
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

// Called under the shared release-train concurrency group before tagging.
void refreshReleaseNotes(String repo, String version, String commit) {
  final scratch = Directory.current.createTempSync('.release-notes-');
  try {
    notesForRelease(repo, version, commit, scratch, updateDraft: true);
    summary('Updated draft notes for $version from $commit.');
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

String notesForRelease(
  String repo,
  String version,
  String source,
  Directory scratch, {
  bool updateDraft = false,
}) {
  // Compare commits, not dates: a Thursday fix must not hide Monday's master work.
  final previous =
      releases(repo).where((release) {
        final tag = release['tag_name'] as String;
        final number = tag.replaceFirst(RegExp(r'-RC$'), '');
        return release['draft'] == false &&
            RegExp(versionPattern).hasMatch(number) &&
            compareVersions(number, version) < 0;
      }).toList()..sort(
        (a, b) => compareVersions(
          (b['tag_name'] as String).replaceFirst(RegExp(r'-RC$'), ''),
          (a['tag_name'] as String).replaceFirst(RegExp(r'-RC$'), ''),
        ),
      );
  if (previous.isEmpty)
    throw StateError('No published version release to use as the notes baseline');
  final release = updateDraft ? releaseForTag(repo, version) : null;
  if (updateDraft && (release == null || release['draft'] != true)) {
    throw StateError('Expected draft notes for $version');
  }
  var config = 'file:.github/release-drafter.yml';
  if (updateDraft) {
    // Release Drafter otherwise picks the first draft, which may be another train.
    final path = '${scratch.path}/release-drafter.yml';
    File(path).writeAsStringSync(
      '${File('.github/release-drafter.yml').readAsStringSync()}\n'
      'filter-by-range: "$version"\n',
    );
    config = 'file:${File(path).uri.path.substring(Directory.current.uri.path.length)}';
  }
  final generated = jsonDecode(
    command('npx', [
      '--yes',
      'release-drafter@7.9.0',
      repo,
      '--config',
      config,
      '--from',
      previous.first['tag_name'] as String,
      '--to',
      source,
      '--release-version',
      version,
      '--tag',
      version,
      '--prerelease',
      'false',
      '--latest',
      'false',
      if (updateDraft) ...[
        '--publish',
        'false',
        '--name',
        release!['name'] as String,
      ] else
        '--dry-run',
      '--json',
    ]),
  );
  final notes = File('${scratch.path}/release-notes.md')
    ..writeAsStringSync(generated['body'] as String);
  command('ruby', ['.github/scripts/add_issues_to_release.rb', notes.path]);
  final body = notes.readAsStringSync();
  if (updateDraft) {
    if (generated['id'].toString() != release!['id'].toString() || generated['tag_name'] != version) {
      throw StateError('Release Drafter did not update the expected draft');
    }
    final payload = File('${scratch.path}/notes.json')
      ..writeAsStringSync(jsonEncode({'body': body, 'tag_name': version}));
    gh([
      'api',
      '--method',
      'PATCH',
      'repos/$repo/releases/${release['id']}',
      '--input',
      payload.path,
      '--silent',
    ]);
  }
  return body;
}
