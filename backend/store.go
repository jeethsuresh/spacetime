package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/emersion/go-ical"
	"os"
	"path/filepath"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
)

type User struct {
	Username     string `json:"username"`
	Name         string `json:"name"`
	PasswordHash []byte `json:"-"`
}
type storedUser struct {
	Username, Name string
	PasswordHash   []byte
}
type Session struct {
	Username string
	Expires  time.Time
}
type Event struct {
	ID          string            `json:"id"`
	Owner       string            `json:"owner"`
	Title       string            `json:"title"`
	Description string            `json:"description"`
	Location    string            `json:"location"`
	Kind        string            `json:"kind"`
	Start       *time.Time        `json:"start,omitempty"`
	End         *time.Time        `json:"end,omitempty"`
	Due         *time.Time        `json:"due,omitempty"`
	AllDay      bool              `json:"all_day"`
	Yearly      bool              `json:"yearly"`
	LocalStart  string            `json:"start_local,omitempty"`
	LocalEnd    string            `json:"end_local,omitempty"`
	LocalDue    string            `json:"due_local,omitempty"`
	UntilDate   string            `json:"until_date,omitempty"`
	UID         string            `json:"uid"`
	RRule       string            `json:"rrule"`
	Timezone    string            `json:"timezone"`
	RDates      []string          `json:"rdates"`
	ExDates     []string          `json:"exdates"`
	Completed   bool              `json:"completed"`
	Attendees   map[string]string `json:"attendees"`
	Version     int               `json:"version"`
	Updated     time.Time         `json:"updated"`
	Imported    bool              `json:"imported"`
	Resource    string            `json:"-"`
	Raw         string            `json:"-"`
}
type record struct {
	Event         Event
	Resource, Raw string
}
type Store struct{ db *bolt.DB }

var errNotFound = errors.New("not found")

func openStore(file string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(file), 0700); err != nil {
		return nil, err
	}
	db, err := bolt.Open(file, 0600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	err = db.Update(func(tx *bolt.Tx) error {
		for _, b := range []string{"users", "sessions", "events"} {
			if _, err := tx.CreateBucketIfNotExists([]byte(b)); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db}, nil
}
func randomID() string {
	var b [24]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func getJSON(tx *bolt.Tx, bucket, key string, v any) error {
	b := tx.Bucket([]byte(bucket)).Get([]byte(key))
	if b == nil {
		return errNotFound
	}
	return json.Unmarshal(b, v)
}
func putJSON(tx *bolt.Tx, bucket, key string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return tx.Bucket([]byte(bucket)).Put([]byte(key), b)
}
func userTx(tx *bolt.Tx, name string) (User, error) {
	var u storedUser
	err := getJSON(tx, "users", name, &u)
	return User{u.Username, u.Name, u.PasswordHash}, err
}
func eventTx(tx *bolt.Tx, id string) (Event, error) {
	var r record
	err := getJSON(tx, "events", id, &r)
	r.Event.Resource, r.Event.Raw = r.Resource, r.Raw
	return r.Event, err
}
func saveEvent(tx *bolt.Tx, e Event) error {
	if e.Raw != "" {
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
		e.LocalStart = p.LocalStart
		e.LocalEnd = p.LocalEnd
		e.LocalDue = p.LocalDue
		e.UntilDate = p.UntilDate
		e.Yearly = p.Yearly
	}
	return putJSON(tx, "events", e.ID, record{e, e.Resource, e.Raw})
}
func eventsTx(tx *bolt.Tx) ([]Event, error) {
	events := []Event{}
	err := tx.Bucket([]byte("events")).ForEach(func(k, v []byte) error {
		e, err := eventTx(tx, string(k))
		if err != nil {
			return err
		}
		events = append(events, e)
		return nil
	})
	return events, err
}
func (s *Store) user(name string) (u User, err error) {
	err = s.db.View(func(tx *bolt.Tx) error { u, err = userTx(tx, name); return err })
	return
}
func visible(e Event, username string) bool {
	return e.Owner == username || e.Attendees[username] == "accepted"
}
