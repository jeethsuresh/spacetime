class CalendarCollection {
  final Map<String, dynamic> data;
  CalendarCollection(this.data);
  String get id => data['id'] as String;
  String get name => data['name'] as String? ?? 'Personal';
  String get color =>
      data['_color_override'] as String? ??
      data['color'] as String? ??
      '#376B51';
  String get kind => data['kind'] as String? ?? 'personal';
  String? get account => data['_account'] as String?;
  String? get remoteId => data['_remote_id'] as String?;
  String? get groupId => data['group_id'] as String?;
  bool get readOnly => data['read_only'] == true;
  bool get dirty => data['_dirty'] == true;
  int get version => data['version'] as int? ?? 1;
}

CalendarCollection deviceCalendar() => CalendarCollection({
  'id': 'device',
  'name': 'Personal',
  'color': '#376B51',
  'kind': 'personal',
});
