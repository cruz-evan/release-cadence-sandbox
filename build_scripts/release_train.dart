import 'dart:convert';
import 'dart:io';

import 'release_tools.dart';

// Sunday: cut -> save notes -> build Firebase + beta. Friday: rebuild beta.
void main(List<String> args) => runScript(() {
  if (args.isEmpty || args.first == '--help') {
    stdout.writeln(
      'dart build_scripts/release_train.dart '
      'cut|start|beta [Sunday YYYY-MM-DD] [release-notes-file]\n'
      'dart build_scripts/release_train.dart finish Sunday-YYYY-MM-DD approved-SHA',
    );
    return;
  }
  final action = args.first;
  if (!['cut', 'start', 'beta', 'finish'].contains(action) || args.length > 3) {
    throw ArgumentError('Choose cut, start, beta, or finish');
  }
  if (action == 'finish' &&
      (args.length != 3 || !RegExp(r'^[0-9a-f]{40}$').hasMatch(args[2]))) {
    throw ArgumentError(
      'Finish requires the full QA-approved release commit SHA',
    );
  }
  final date = trainDate(args.length > 1 ? args[1] : '');
  final notes = action == 'cut' && args.length > 2
      ? File(args[2]).absolute
      : null;
  if (notes != null && !notes.existsSync()) {
    throw ArgumentError('Release-notes file does not exist');
  }
  Directory.current = git(['rev-parse', '--show-toplevel']);
  final repo = repository();
  if (action == 'finish') {
    finishTrain(repo, date, args[2]);
    return;
  }
  // A Friday cutover has no train to refresh until the first Sunday cut.
  if (action == 'beta' &&
      Platform.environment['GITHUB_EVENT_NAME'] == 'schedule' &&
      git([
        'ls-remote',
        '--refs',
        'origin',
        'refs/tags/release-train/*',
      ]).isEmpty) {
    summary('No train has been cut yet. Friday refresh skipped until Sunday.');
    return;
  }
  if (action == 'cut') cutBranch(repo, date, notes);
  buildTrain(repo, date, firebase: action != 'beta');
});

String trainDate(String supplied) {
  // Ask the OS for Vancouver's date; no timezone package is needed.
  final today = Process.runSync(
    'date',
    ['+%F'],
    environment: {'TZ': 'America/Vancouver'},
  );
  if (today.exitCode != 0) throw StateError('Cannot read the Vancouver date');
  final parsed = DateTime.parse(
    supplied.isEmpty ? (today.stdout as String).trim() : supplied,
  );
  var date = DateTime.utc(parsed.year, parsed.month, parsed.day);
  if (supplied.isEmpty) {
    date = date.subtract(Duration(days: date.weekday % 7));
  }
  final value = date.toIso8601String().substring(0, 10);
  if (date.weekday != DateTime.sunday ||
      (supplied.isNotEmpty && supplied != value)) {
    throw ArgumentError('Train date must be a Sunday in YYYY-MM-DD format');
  }
  return value;
}

void cutBranch(String repo, String date, File? notes) {
  final marker = 'refs/tags/release-train/$date';
  final scratch = Directory.systemTemp.createTempSync('release-train-');
  final checkout = '${scratch.path}/checkout';
  try {
    Map<String, dynamic> train;
    if (git(['ls-remote', 'origin', marker]).isNotEmpty) {
      git(['fetch', '--no-tags', 'origin', '$marker:$marker']);
      train = jsonDecode(git(['for-each-ref', '--format=%(contents)', marker]));
      stdout.writeln('Resuming the release train for $date');
    } else {
      // Start at master's current head and reserve a version newer than held trains.
      git(['fetch', '--no-tags', 'origin', 'refs/heads/master']);
      final source = git(['rev-parse', 'FETCH_HEAD^{commit}']);
      final versionFile =
          jsonDecode(git(['show', '$source:VERSION.json']))
              as Map<String, dynamic>;
      final current = versionFile['version'] as String;
      checkVersion(current);
      final configuredName = Platform.environment['RELEASE_NAME'];
      final name = configuredName == null || configuredName.isEmpty
          ? versionFile['release_name'] as String
          : configuredName;
      final version = nextVersion(
        current,
        minor: name != versionFile['release_name'],
      );
      final branch = 'release/$version';

      // A temporary checkout keeps the caller's working tree untouched.
      git(['worktree', 'add', '--detach', checkout, source]);
      versionFile['version'] = version;
      versionFile['release_name'] = name;
      File('$checkout/VERSION.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(versionFile)}\n',
      );
      git(['-C', checkout, 'add', 'VERSION.json']);
      git([
        '-C',
        checkout,
        ...gitIdentity,
        'commit',
        '-m',
        'Prepare release $version',
      ]);
      final commit = git(['-C', checkout, 'rev-parse', 'HEAD']);
      train = {
        'version': version,
        'release_name': name,
        'source_commit': source,
        'notes':
            notes?.readAsStringSync() ??
            notesForRelease(repo, version, source, scratch),
      };
      final record = File('${scratch.path}/train.json')
        ..writeAsStringSync(jsonEncode(train));
      git([
        ...gitIdentity,
        'tag',
        '-a',
        'release-train/$date',
        commit,
        '-F',
        record.path,
      ]);
      // Publish both refs together, and only if neither already exists remotely.
      git([
        'push',
        '--atomic',
        '--force-with-lease=refs/heads/$branch:',
        '--force-with-lease=$marker:',
        'origin',
        '$commit:refs/heads/$branch',
        '$marker:$marker',
      ]);
    }

    // A retry repairs missing draft notes without overwriting QA's edits.
    final version = train['version'] as String;
    checkVersion(version);
    final branch = 'release/$version';
    if (git(['ls-remote', '--heads', 'origin', 'refs/heads/$branch']).isEmpty) {
      throw StateError(
        'Recorded branch $branch is missing; refusing to recreate it',
      );
    }
    final tag = version;
    if (releaseForTag(repo, tag) == null) {
      final patch = int.parse(version.split('.').last);
      final title =
          '${train['release_name']}${patch == 0 ? '' : ' SP$patch'} [$version]';
      final request = File('${scratch.path}/draft.json')
        ..writeAsStringSync(
          jsonEncode({
            'tag_name': tag,
            'target_commitish': branch,
            'name': title,
            'body': train['notes'],
            'draft': true,
            'prerelease': false,
            'make_latest': 'false',
          }),
        );
      gh([
        'api',
        '--method',
        'POST',
        'repos/$repo/releases',
        '--input',
        request.path,
        '--silent',
      ]);
    }
    summary('Release train $date: $branch, draft notes for $tag.');
  } finally {
    if (Directory(checkout).existsSync())
      git(['worktree', 'remove', '--force', checkout]);
    scratch.deleteSync(recursive: true);
  }
}

String nextVersion(String current, {required bool minor}) {
  var latest = current;
  final refs = git([
    'ls-remote',
    '--refs',
    'origin',
    'refs/heads/release/*',
    'refs/tags/*',
  ]);
  for (final line in refs.split('\n').where((line) => line.isNotEmpty)) {
    final ref = line.split(RegExp(r'\s+')).last;
    final version = ref.startsWith('refs/heads/release/')
        ? ref.substring('refs/heads/release/'.length)
        : ref.substring('refs/tags/'.length).replaceFirst(RegExp(r'-RC$'), '');
    if (RegExp(versionPattern).hasMatch(version) &&
        compareVersions(version, latest) > 0) {
      latest = version;
    }
  }
  final proposed = bumpVersion(current, minor: minor);
  return compareVersions(proposed, latest) > 0 ? proposed : bumpVersion(latest);
}

void buildTrain(String repo, String date, {required bool firebase}) {
  final marker = 'refs/tags/release-train/$date';
  git(['fetch', '--no-tags', 'origin', '$marker:$marker']);
  final version =
      jsonDecode(git(['show', '$marker:VERSION.json']))['version'] as String;
  checkVersion(version);
  final branch = 'release/$version';
  git(['fetch', '--no-tags', 'origin', 'refs/heads/$branch']);
  git(['merge-base', '--is-ancestor', marker, 'FETCH_HEAD']);
  if (releaseTagCommit(repo, version) != null) {
    throw StateError('$version is finalized; build from its tag instead');
  }
  for (final channel in [if (firebase) 'firebase', 'release_candidate']) {
    gh([
      'workflow',
      'run',
      'manual_build.yml',
      '--repo',
      repo,
      '--ref',
      branch,
      '-f',
      'distribution_channel=$channel',
      '-f',
      'platform=all',
      '-f',
      'skip_tests=false',
      '-f',
      'run_patrol=false',
      '-f',
      'use_shorebird=false',
    ]);
    summary(
      'Dispatched Manual build on $branch for $channel. Follow it in Actions / Runway.',
    );
  }
}

void finishTrain(String repo, String date, String approved) {
  final marker = 'refs/tags/release-train/$date';
  git(['fetch', '--no-tags', 'origin', '$marker:$marker']);
  final version =
      jsonDecode(git(['show', '$marker:VERSION.json']))['version'] as String;
  checkVersion(version);
  final branch = 'release/$version';
  git(['fetch', '--no-tags', 'origin', 'refs/heads/$branch']);
  final head = git(['rev-parse', 'FETCH_HEAD^{commit}']);
  final tagged = releaseTagCommit(repo, version);
  if (tagged != null && tagged != approved) {
    throw StateError('$version already points elsewhere; refusing to move it');
  }
  if (tagged == null && head != approved) {
    throw StateError(
      'The approved commit no longer matches $branch. Rebuild and approve its current head.',
    );
  }
  git(['merge-base', '--is-ancestor', marker, approved]);
  git(['merge-base', '--is-ancestor', approved, head]);
  final versionFile = jsonDecode(git(['show', '$approved:VERSION.json']));
  if (versionFile['version'] != version)
    throw StateError('$branch does not match VERSION.json');
  final release = releaseForTag(repo, version);
  if (release == null || release['draft'] != true) {
    throw StateError('Expected unfinalized draft notes for $version');
  }

  if (tagged == null) {
    refreshReleaseNotes(repo, version, approved);
    git(['fetch', '--no-tags', 'origin', 'refs/heads/$branch']);
    if (git(['rev-parse', 'FETCH_HEAD^{commit}']) != approved) {
      throw StateError('Release branch moved during finalization; rebuild and approve its current head');
    }
  }

  // Freeze QA's code before the release PR can be updated with master changes.
  pinReleaseTag(repo, version, approved);
  final prs =
      jsonDecode(
            gh([
              'pr',
              'list',
              '--repo',
              repo,
              '--head',
              branch,
              '--base',
              'master',
              '--state',
              'all',
              '--json',
              'url,state',
            ]),
          )
          as List;
  final existing = prs.where((pr) => pr['state'] != 'CLOSED').toList();
  if (existing.isNotEmpty) {
    summary(
      'Release PR: ${existing.single['url']}. $version pins approved commit $approved.',
    );
    return;
  }
  gh([
    'label',
    'create',
    'release-backfill',
    '--repo',
    repo,
    '--color',
    '8250df',
    '--description',
    'Release merge PR; excluded from release notes',
    '--force',
  ]);
  final scratch = Directory.systemTemp.createTempSync('release-pr-');
  try {
    final body = File('${scratch.path}/body.md')
      ..writeAsStringSync(
        'Merge the QA-approved `$branch` into master. `$version` already pins '
        'the approved release commit `$approved`.\n\n'
        'If required for master checks, update this PR using a merge from master '
        'and resolve integration conflicts. Build from the version tag after finalization; '
        'the updated branch can contain newer, unreleased work. '
        'Merging this reviewed PR publishes its notes; store promotion follows separately.\n\n'
        'Related to #7505.\n',
      );
    final url = gh([
      'pr',
      'create',
      '--repo',
      repo,
      '--head',
      branch,
      '--base',
      'master',
      '--title',
      'Finalize release $version',
      '--body-file',
      body.path,
      '--label',
      'release-backfill',
      '--label',
      'code cleanup :broom:',
    ]);
    summary(
      'Release PR: $url. $version pins approved commit $approved. Review and merge on Friday.',
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
