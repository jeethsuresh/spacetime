Vendored from rrule 0.2.18 (https://pub.dev/packages/rrule), Apache 2.0.
Retained upstream licenses. Changes: accept all WKST values; use WKST in weekly
periods and week numbering; correct negative BYWEEKNO; remove unsafe seek for
monthly/yearly BYSETPOS; fix subdaily interval phase and seconds arithmetic; bound empty-set iteration.
The 32 independent fixtures in ../../test/fixtures/recurrence.json exercise these changes.
Timezone resolution, RFC invalid-date COUNT behavior and recurrence sets are
implemented in the application adapter, lib/local_recurrence.dart.
