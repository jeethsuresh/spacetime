part of 'models.dart';

extension CalendarCollections on CalendarState {
  bool canInviteToCalendar(CalendarCollection c) =>
      connected &&
      c.account == account &&
      c.groupId != null &&
      groups.any(
        (g) =>
            g['id'] == c.groupId &&
            g['membership'] == 'join' &&
            g['owner'] == true,
      );
  bool canLeaveCalendar(CalendarCollection c) =>
      connected &&
      c.account == account &&
      c.kind == 'shared' &&
      c.groupId != null;
  bool canManageCalendar(CalendarCollection c) =>
      c.account == null ||
      (c.account == account && c.data['owner'] == username) ||
      (!connected && c.data['_managed'] == true);
  bool isCalendarVisible(Entry e) =>
      calendarFor(e).data['_unavailable'] != true &&
      !(e.kind == 'todo' ? hiddenTodoCalendars : hiddenCalendars).contains(
        e.calendarId,
      );
  String localCalendarId(String remoteId) =>
      calendars
          .where((c) => c.remoteId == remoteId && c.account == account)
          .firstOrNull
          ?.id ??
      'device';
  Future<void> setCalendarVisible(
    String id,
    bool visible, {
    bool todos = false,
  }) async {
    final hidden = todos ? hiddenTodoCalendars : hiddenCalendars;
    if (visible) {
      hidden.remove(id);
    } else {
      hidden.add(id);
    }
    await savePreferences();
    // Persist visibility with the native calendar snapshot too, so widgets use
    // the same selections without starting Flutter or accessing the network.
    await _transaction(() {});
  }

  Future<void> selectCalendar(String id) async {
    selectedCalendarId = id;
    await savePreferences();
  }

  Future<CalendarCollection> createCalendar(String name, String color) async {
    final c = CalendarCollection({
      'id': _id(),
      'name': name.trim(),
      'color': color,
      'kind': 'personal',
      'version': 1,
      '_dirty': true,
    });
    if (c.name.isEmpty) throw ApiException('Enter a calendar name.');
    await _transaction(() => calendars = [...calendars, c], syncNeeded: true);
    await selectCalendar(c.id);
    return c;
  }

  Future<void> updateCalendar(
    CalendarCollection c,
    String name,
    String color,
  ) => _transaction(() {
    if (name.trim().isEmpty) throw ApiException('Enter a calendar name.');
    if (!canManageCalendar(c)) {
      if (name.trim() != c.name) {
        throw ApiException('Only the calendar owner can rename it.');
      }
      calendars =
          calendars
              .map(
                (v) =>
                    v.id == c.id
                        ? CalendarCollection({
                          ...v.data,
                          '_color_override': color,
                        })
                        : v,
              )
              .toList();
      return;
    }
    calendars =
        calendars
            .map(
              (v) =>
                  v.id == c.id
                      ? CalendarCollection({
                        ...v.data,
                        'name': name.trim(),
                        'color': color,
                        '_color_override': null,
                        'version': v.version + 1,
                        '_dirty': true,
                      })
                      : v,
            )
            .toList();
  }, syncNeeded: true);
  Future<void> syncCalendars({bool upload = true}) async {
    final binding = account;
    final credential = api.token;
    void ensureBinding() {
      if (binding != account || credential != api.token) {
        throw ApiException('Your account changed. Sync again.');
      }
    }

    dynamic result;
    try {
      result = await api.request('GET', '/api/calendars');
    } on ApiException catch (e) {
      if (e.status == 403) {
        await _transaction(() {
          groupsEnabled = false;
          calendars =
              calendars
                  .map(
                    (c) =>
                        c.kind == 'shared' && c.account == binding
                            ? CalendarCollection({
                              ...c.data,
                              'read_only': true,
                              '_unavailable': true,
                            })
                            : c,
                  )
                  .toList();
        });
      }
      if (e.status != 404) rethrow;
    }
    ensureBinding();
    if (result is! Map || result['calendars'] is! List) {
      // Old self-hosted servers retain their single personal collection.
      if (calendars.any((c) => c.dirty && c.id != 'device')) {
        throw ApiException(
          'Update your Spacetime server to sync multiple calendars.',
        );
      }
      return;
    }
    final remote =
        (result['calendars'] as List)
            .map((v) => Map<String, dynamic>.from(v as Map))
            .toList();
    await _transaction(() {
      final next = [...calendars];
      for (final data in remote) {
        var index = next.indexWhere(
          (c) => c.remoteId == data['id'] && c.account == binding,
        );
        if (index < 0 && data['id'] == 'default-$username') {
          index = next.indexWhere((c) => c.id == 'device' && c.account == null);
        }
        final old = index < 0 ? null : next[index];
        final c = CalendarCollection({
          ...data,
          'id': old?.id ?? _id(),
          '_account': binding,
          '_remote_id': data['id'],
          '_remote_version': data['version'],
          '_managed': data['owner'] == username,
          if (old?.data['_color_override'] != null)
            '_color_override': old!.data['_color_override'],
          if (old?.dirty == true &&
              (old!.data['_remote_version'] == null ||
                  old.data['_remote_version'] == data['version'])) ...{
            'name': old.name,
            'color': old.color,
            'version': old.version,
            '_dirty': true,
          },
        });
        if (index < 0) {
          next.add(c);
        } else {
          next[index] = c;
        }
      }
      // A removed membership never becomes a writable local calendar.
      calendars =
          next
              .map(
                (c) =>
                    c.account == binding &&
                            !remote.any((r) => r['id'] == c.remoteId) &&
                            c.remoteId != null
                        ? CalendarCollection({
                          ...c.data,
                          'read_only': true,
                          '_unavailable': true,
                        })
                        : c,
              )
              .toList();
      groupsEnabled = result['groups_enabled'] == true;
      groups =
          (result['groups'] as List? ?? [])
              .map((g) => Map<String, dynamic>.from(g as Map))
              .toList();
      final chosen =
          calendars.where((c) => c.id == selectedCalendarId).firstOrNull;
      if (chosen == null || !canCreateIn(chosen)) {
        selectedCalendarId =
            calendars
                .where((c) => c.account == binding && canCreateIn(c))
                .firstOrNull
                ?.id ??
            'device';
      }
    });
    if (!upload) return;
    for (final sent in [
      ...calendars,
    ].where((c) => c.dirty && (c.account == null || c.account == binding))) {
      ensureBinding();
      final response = Map<String, dynamic>.from(
        await api.request(
              sent.remoteId == null ? 'POST' : 'PUT',
              '/api/calendars${sent.remoteId == null ? '' : '/${sent.remoteId}'}',
              {
                'id': sent.remoteId ?? sent.id,
                'name': sent.name,
                'color': sent.color,
                'kind': sent.kind,
                'version': sent.data['_remote_version'] ?? 1,
              },
            )
            as Map,
      );
      ensureBinding();
      await _transaction(
        () =>
            calendars =
                calendars
                    .map(
                      (c) =>
                          c.id == sent.id
                              ? CalendarCollection({
                                ...c.data,
                                '_account': binding,
                                '_remote_id': response['id'],
                                '_remote_version': response['version'],
                                '_dirty': c.version != sent.version,
                              })
                              : c,
                    )
                    .toList(),
      );
    }
  }

  Future<void> refreshGroups() async {
    if (!connected) throw ApiException('Log in to use shared calendars.');
    final result = await api.request('GET', '/api/groups') as Map;
    await _transaction(() {
      groups =
          (result['groups'] as List)
              .map((v) => Map<String, dynamic>.from(v as Map))
              .toList();
      groupsEnabled = result['enabled'] == true;
    });
  }

  Future<CalendarCollection> createSharedCalendar(
    String name,
    String color, {
    String? groupId,
    required String requestId,
  }) async {
    if (!connected) throw ApiException('Log in to use shared calendars.');
    name = name.trim();
    if (name.isEmpty || name.length > 80) {
      throw ApiException('Enter a calendar name of 1–80 characters.');
    }
    final binding = account;
    final credential = api.token;
    void ensureBinding() {
      if (!connected || account != binding || api.token != credential) {
        throw ApiException('Your account changed. Try again.');
      }
    }

    if (groupId == null) {
      final g = await api.request('POST', '/api/groups', {
        'name': name,
        'txn_id': requestId,
      });
      ensureBinding();
      groupId = g['id'] as String;
      await _transaction(() {
        groups = [
          ...groups.where((v) => v['id'] != groupId),
          Map<String, dynamic>.from(g as Map),
        ];
      });
    }
    ensureBinding();
    final remote = Map<String, dynamic>.from(
      await api.request('POST', '/api/calendars', {
            'id': requestId,
            'name': name,
            'color': color,
            'kind': 'shared',
            'group_id': groupId,
          })
          as Map,
    );
    ensureBinding();
    return addServerCalendar(remote);
  }

  Future<void> inviteToSharedCalendar(
    CalendarCollection c,
    String userId,
  ) async {
    if (!canInviteToCalendar(c)) {
      throw ApiException('Only the Gravitas group owner can invite people.');
    }
    userId = userId.trim();
    if (userId.startsWith('@') && !userId.contains(':')) {
      userId = userId.substring(1);
    }
    if (userId.isEmpty || RegExp(r'\s').hasMatch(userId)) {
      throw ApiException('Enter a Gravitas username.');
    }
    await api.request(
      'POST',
      '/api/groups/${Uri.encodeComponent(c.groupId!)}/membership',
      {'action': 'invite', 'user_id': userId},
    );
  }

  Future<void> leaveSharedCalendar(CalendarCollection c) async {
    if (!canLeaveCalendar(c)) {
      throw ApiException('Sign in to this calendar’s account to leave it.');
    }
    if (loading) throw ApiException('Wait for sync to finish, then try again.');
    final binding = account;
    final credential = api.token;
    loading = true;
    try {
      await refresh();
      if (!connected || account != binding || api.token != credential) {
        throw ApiException('Your account changed. Try again.');
      }
      await api.request(
        'POST',
        '/api/groups/${Uri.encodeComponent(c.groupId!)}/membership',
        {'action': 'leave'},
      );
      // Membership is shared by every calendar attached to this group. Do not
      // upload queued writes after leaving, or delete anyone's server entries.
      await _transaction(() {
        final ids =
            calendars
                .where((v) => v.account == binding && v.groupId == c.groupId)
                .map((v) => v.id)
                .toSet();
        calendars = calendars.where((v) => !ids.contains(v.id)).toList();
        entries = entries.where((e) => !ids.contains(e.calendarId)).toList();
        tombstones =
            tombstones.where((e) => !ids.contains(e['calendar_id'])).toList();
        invitations =
            invitations.where((e) => !ids.contains(e.calendarId)).toList();
        hiddenCalendars.removeAll(ids);
        hiddenTodoCalendars.removeAll(ids);
        if (ids.contains(selectedCalendarId)) {
          selectedCalendarId =
              calendars.where(canCreateIn).firstOrNull?.id ?? 'device';
        }
        if (account == binding) {
          groups =
              groups
                  .map(
                    (g) =>
                        g['id'] == c.groupId
                            ? {...g, 'membership': 'leave'}
                            : g,
                  )
                  .toList();
        }
      });
      await savePreferences();
    } finally {
      loading = false;
      await refresh();
    }
  }

  Future<CalendarCollection> addServerCalendar(
    Map<String, dynamic> remote,
  ) async {
    final old =
        calendars
            .where((c) => c.remoteId == remote['id'] && c.account == account)
            .firstOrNull;
    final c = CalendarCollection({
      ...remote,
      'id': old?.id ?? _id(),
      '_remote_id': remote['id'],
      '_remote_version': remote['version'],
      '_account': account,
    });
    await _transaction(
      () => calendars = [...calendars.where((v) => v.id != c.id), c],
      syncNeeded: true,
    );
    await selectCalendar(c.id);
    return c;
  }

  Future<void> groupAction(
    String groupId,
    String action, {
    String? userId,
  }) async {
    await api.request('POST', '/api/groups/$groupId/membership', {
      'action': action,
      if (userId != null) 'user_id': userId,
    });
    await refreshGroups();
    await sync();
  }

  Future<void> enableSharedCalendars() async {
    if (!usesGravitas) {
      throw ApiException(
        'Connect to gravitas.cool to enable shared calendars.',
      );
    }
    _authGeneration++;
    _nativeRecoveryPending = false;
    await writePreference('spacetime.gravitas.disconnected', '0');
    browserAccount.enableGroups(username: user?['gravitas_user_id'] as String?);
  }

  String newCalendarRequestId() => _id();
  Future<List<Map<String, dynamic>>> discoverRemote(
    String url,
    String kind,
    String username,
    String password,
  ) async {
    final result = await api.request('POST', '/api/calendars/discover', {
      'url': url,
      'kind': kind,
      'username': username,
      'password': password,
    });
    return (result['calendars'] as List)
        .map((c) => Map<String, dynamic>.from(c as Map))
        .toList();
  }

  Future<CalendarCollection> connectRemote(
    String name,
    String color,
    String url,
    String kind,
    String username,
    String password, {
    String? existingId,
  }) async {
    final result = await api.request('POST', '/api/calendars/connect', {
      'name': name,
      'color': color,
      'url': url,
      'kind': kind,
      'username': username,
      'password': password,
      if (existingId != null) 'id': existingId,
    });
    return addServerCalendar(Map<String, dynamic>.from(result as Map));
  }

  Future<void> removeCalendar(CalendarCollection c) async {
    if (c.id == 'device' || c.remoteId?.startsWith('default-') == true) {
      throw ApiException('The personal calendar cannot be removed.');
    }
    if (entries.any((e) => e.calendarId == c.id) && c.kind != 'source') {
      throw ApiException('Move or remove this calendar’s entries first.');
    }
    if (c.remoteId != null) {
      if (!connected || c.account != account) {
        throw ApiException('Log in to remove this calendar from the server.');
      }
      await api.request('DELETE', '/api/calendars/${c.remoteId}', null, {
        'If-Match': '"${c.data['_remote_version'] ?? c.version}"',
      });
    }
    await _transaction(() {
      calendars = calendars.where((v) => v.id != c.id).toList();
      entries = entries.where((e) => e.calendarId != c.id).toList();
      tombstones = tombstones.where((e) => e['calendar_id'] != c.id).toList();
      hiddenCalendars.remove(c.id);
      hiddenTodoCalendars.remove(c.id);
      if (selectedCalendarId == c.id) selectedCalendarId = 'device';
    });
    await savePreferences();
  }
}
