package main

import (
	"strings"
	"time"

	"github.com/emersion/go-ical"
	bolt "go.etcd.io/bbolt"
	"golang.org/x/crypto/bcrypt"
)

func migrateStore(s *Store) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		events, err := eventsTx(tx)
		if err != nil {
			return err
		}
		for _, e := range events {
			cal, err := ical.NewDecoder(strings.NewReader(e.Raw)).Decode()
			if err != nil {
				return err
			}
			p, err := projectCalendar(cal)
			if err != nil {
				return err
			}
			e.UID = p.UID
			e.RRule = p.RRule
			e.Timezone = p.Timezone
			e.RDates = p.RDates
			e.ExDates = p.ExDates
			if special(e) {
				changed := e.Kind != "occasion" || e.Location != "" || len(e.Attendees) > 0
				e.Kind = "occasion"
				e.Location = ""
				e.Attendees = map[string]string{}
				for _, c := range cal.Children {
					if c.Name == ical.CompEvent {
						for _, name := range []string{"LOCATION", "ATTENDEE", "ORGANIZER"} {
							if c.Props.Get(name) != nil {
								changed = true
								c.Props.Del(name)
							}
						}
					}
				}
				if changed {
					e.Version++
					e.Updated = time.Now().UTC()
					e.Raw, err = encodeEvent(e)
					if err != nil {
						return err
					}
				}
			}
			if err := saveEvent(tx, e); err != nil {
				return err
			}
		}
		return nil
	})
}
func migrateDemoPassword(tx *bolt.Tx, hash []byte) error {
	for _, name := range []string{"alex", "jamie", "sam"} {
		u, err := userTx(tx, name)
		if err != nil {
			continue
		}
		if bcrypt.CompareHashAndPassword(u.PasswordHash, []byte("daybook-demo-2026")) == nil {
			if err := putJSON(tx, "users", name, storedUser{u.Username, u.Name, hash}); err != nil {
				return err
			}
		}
	}
	return nil
}
