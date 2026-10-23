import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spacetime/browser_account.dart';
import 'package:spacetime/calendar_storage.dart';
import 'package:spacetime/main.dart';
import 'package:spacetime/models.dart';

class InviteBrowser extends BrowserAccount {
  int requests = 0;
  @override
  bool get enabled => true;
  @override
  bool get native => false;
  @override
  void enableGroups() {
    requests++;
  }
}

void main() {
  testWidgets(
    'A profile-only user can opt into shared invites without silent consent',
    (tester) async {
      final browser = InviteBrowser();
      final state = CalendarState(
        Api(),
        storage: MemoryCalendarStorage(),
        browserAccount: browser,
      )..user = {'username': 'alice'};
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: state,
            builder: (context, _) => HomePage(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invites').last);
      await tester.pumpAndSettle();
      expect(browser.requests, 0);
      await tester.tap(find.text('Enable shared calendar invites'));
      await tester.pumpAndSettle();
      expect(browser.requests, 1);
      state.groupsEnabled = true;
      state.groups = [
        {'id': 'group', 'name': 'Household', 'membership': 'invite'},
      ];
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Enable shared calendar invites'), findsNothing);
      expect(find.text('Household'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('No invitations'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
