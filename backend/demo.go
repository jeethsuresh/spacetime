package main

import (
	"time"

	bolt "go.etcd.io/bbolt"
	"golang.org/x/crypto/bcrypt"
)

func seedDemo(s *Store) error {
	hash, err := bcrypt.GenerateFromPassword([]byte("spacetime-demo-2026"), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	return s.db.Update(func(tx *bolt.Tx) error {
		// Never overwrite accounts or recreate samples on subsequent launches.
		if _, err := userTx(tx, "alex"); err == nil {
			return migrateDemoPassword(tx, hash)
		}
		for username, name := range map[string]string{"alex": "Alex Morgan", "jamie": "Jamie Park", "sam": "Sam Rivera"} {
			if _, err := userTx(tx, username); err == nil {
				continue
			}
			if err := putJSON(tx, "users", username, storedUser{username, name, hash}); err != nil {
				return err
			}
		}
		now := time.Now()
		today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		add := func(title, kind string, days, hour int, duration time.Duration, location string, attendees map[string]string) error {
			start := today.AddDate(0, 0, days).Add(time.Duration(hour) * time.Hour)
			end := start.Add(duration)
			e := Event{ID: randomID(), Owner: "alex", Title: title, Kind: kind, Start: &start, End: &end, Location: location, Attendees: attendees, Version: 1, Updated: time.Now().UTC()}
			if e.Attendees == nil {
				e.Attendees = map[string]string{}
			}
			if kind == "todo" {
				e.Due, e.Start, e.End = &start, nil, nil
			}
			if kind == "occasion" {
				e.AllDay = true
				e.Yearly = true
				e.RRule = "FREQ=YEARLY"
				e.Location = ""
				e.Attendees = map[string]string{}
			}
			e.Resource = e.ID + ".ics"
			var err error
			e.Raw, err = encodeEvent(e)
			if err != nil {
				return err
			}
			return saveEvent(tx, e)
		}
		for _, err := range []error{
			add("A little room to plan", "event", 0, 9, 45*time.Minute, "Morning ritual", nil),
			add("Coffee with Jamie", "event", 0, 11, time.Hour, "The neighbourhood café", map[string]string{"jamie": "accepted"}),
			add("Send the project proposal", "todo", 0, 17, 0, "", nil),
			add("Design catch-up", "event", 2, 14, time.Hour, "Studio", map[string]string{"sam": "pending"}),
			add("Jamie’s birthday", "occasion", 3, 0, 24*time.Hour, "", nil),
			add("Book a weekend away", "todo", 4, 17, 0, "", nil),
			add("A day for yourself", "occasion", 5, 0, 24*time.Hour, "Personal holiday", nil),
			add("Dinner with friends", "event", 6, 19, 2*time.Hour, "At home", nil),
		} {
			if err != nil {
				return err
			}
		}
		start := today.AddDate(0, 0, 1).Add(12 * time.Hour)
		end := start.Add(time.Hour)
		e := Event{ID: randomID(), Owner: "jamie", Title: "Lunch and a long walk", Kind: "event", Start: &start, End: &end, Location: "Riverside park", Attendees: map[string]string{"alex": "pending"}, Version: 1, Updated: time.Now().UTC()}
		e.Resource = e.ID + ".ics"
		e.Raw, err = encodeEvent(e)
		if err != nil {
			return err
		}
		return saveEvent(tx, e)
	})
}
