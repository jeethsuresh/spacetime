package main

import (
	"encoding/xml"
	"io"
	"net/http"
	"path"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
)

// RFC 4791 MKCALENDAR is separate from WebDAV's extended MKCOL. Initial
// properties are atomic: unsupported properties never leave a partial calendar.
func (b *davBackend) mkCalendar(w http.ResponseWriter, r *http.Request) {
	base := principal(r.Context()) + "calendars/"
	id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, base), "/")
	if !strings.HasPrefix(r.URL.Path, base) || !calendarIDPattern.MatchString(id) || id == "default" || strings.HasPrefix(id, "default-") {
		http.Error(w, "Calendar collection location is not allowed", 403)
		return
	}
	var exists bool
	_ = b.store.db.View(func(tx *bolt.Tx) error { _, err := calendarTx(tx, id); exists = err == nil; return nil })
	if exists {
		http.Error(w, "Calendar already exists", 405)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1024*1024+1))
	if err != nil || len(raw) > 1024*1024 {
		http.Error(w, "Calendar properties are too large", 413)
		return
	}
	c := Calendar{ID: id, Owner: currentUser(r.Context()), Name: path.Base(id), Color: "#376B51", Kind: "personal", Version: 1, Updated: time.Now().UTC()}
	properties := []xmlNode{}
	if len(strings.TrimSpace(string(raw))) > 0 {
		var root xmlNode
		if xml.Unmarshal(raw, &root) != nil || root.XMLName.Space != calNS || root.XMLName.Local != "mkcalendar" {
			http.Error(w, "Malformed MKCALENDAR", 400)
			return
		}
		for _, set := range root.Children {
			if set.XMLName.Space != davNS || set.XMLName.Local != "set" {
				http.Error(w, "Expected DAV:set", 400)
				return
			}
			prop := set.child(davNS, "prop")
			if prop == nil {
				http.Error(w, "Expected DAV:prop", 400)
				return
			}
			properties = append(properties, prop.Children...)
		}
	}
	failures := map[xml.Name]bool{}
	for _, p := range properties {
		switch p.XMLName {
		case xml.Name{Space: davNS, Local: "displayname"}:
			c.Name = strings.TrimSpace(p.Text)
			if c.Name == "" || len(c.Name) > 120 {
				failures[p.XMLName] = true
			}
		case xml.Name{Space: calNS, Local: "calendar-description"}:
			c.Description = p.Text
			if len(c.Description) > 10000 {
				failures[p.XMLName] = true
			}
		case xml.Name{Space: calendarColorNS, Local: "calendar-color"}:
			value := strings.ToUpper(strings.TrimSpace(p.Text))
			if len(value) == 9 && strings.HasSuffix(value, "FF") {
				value = value[:7]
			}
			if !colorPattern.MatchString(value) {
				failures[p.XMLName] = true
			} else {
				c.Color = value
			}
		case xml.Name{Space: calNS, Local: "supported-calendar-component-set"}:
			names := map[string]bool{}
			for _, child := range p.Children {
				if child.XMLName.Space != calNS || child.XMLName.Local != "comp" {
					failures[p.XMLName] = true
				}
				names[child.attr("name")] = true
			}
			if len(names) != 2 || !names["VEVENT"] || !names["VTODO"] {
				failures[p.XMLName] = true
			}
		case xml.Name{Space: calNS, Local: "calendar-timezone"}:
			// This property is not persisted yet; reject it atomically rather than
			// claiming the caller's requested floating-time interpretation was saved.
			failures[p.XMLName] = true
		default:
			failures[p.XMLName] = true
		}
	}
	if len(failures) > 0 {
		root := propertyNode(davNS, "multistatus", "")
		response := propertyNode(davNS, "response", "")
		response.Children = []xmlNode{propertyNode(davNS, "href", r.URL.Path)}
		for _, p := range properties {
			prop := propertyNode(davNS, "prop", "")
			prop.Children = []xmlNode{propertyNode(p.XMLName.Space, p.XMLName.Local, "")}
			status := "HTTP/1.1 424 Failed Dependency"
			if failures[p.XMLName] {
				status = "HTTP/1.1 403 Forbidden"
			}
			ps := propertyNode(davNS, "propstat", "")
			ps.Children = []xmlNode{prop, propertyNode(davNS, "status", status)}
			response.Children = append(response.Children, ps)
		}
		root.Children = []xmlNode{response}
		data, _ := xml.Marshal(root)
		w.Header().Set("Content-Type", "application/xml; charset=utf-8")
		w.WriteHeader(207)
		w.Write(append([]byte(xml.Header), data...))
		return
	}
	err = b.store.db.Update(func(tx *bolt.Tx) error {
		if _, err := calendarTx(tx, id); err == nil {
			return statusError(405, "Calendar already exists.")
		}
		return putJSON(tx, "calendars", id, c)
	})
	if err != nil {
		serveError(w, err)
		return
	}
	w.Header().Set("Location", r.URL.Path)
	w.WriteHeader(201)
}
