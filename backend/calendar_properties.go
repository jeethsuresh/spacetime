package main

import (
	"bytes"
	"encoding/xml"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	bolt "go.etcd.io/bbolt"
)

const calendarColorNS = "http://apple.com/ns/ical/"

type davCapture struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (c *davCapture) Header() http.Header { return c.header }
func (c *davCapture) WriteHeader(status int) {
	if c.status == 0 {
		c.status = status
	}
}
func (c *davCapture) Write(b []byte) (int, error) {
	if c.status == 0 {
		c.status = 200
	}
	return c.body.Write(b)
}
func propertyNode(space, name, text string) xmlNode {
	return xmlNode{XMLName: xml.Name{Space: space, Local: name}, Text: text}
}
func privilegeNode(names ...string) xmlNode {
	n := propertyNode(davNS, "current-user-privilege-set", "")
	for _, name := range names {
		p := propertyNode(davNS, "privilege", "")
		p.Children = []xmlNode{propertyNode(davNS, name, "")}
		n.Children = append(n.Children, p)
	}
	return n
}
func cleanNamespaceAttrs(n *xmlNode) {
	attrs := []xml.Attr{}
	for _, a := range n.Attrs {
		if a.Name.Space != "xmlns" && a.Name.Local != "xmlns" {
			attrs = append(attrs, a)
		}
	}
	n.Attrs = attrs
	for i := range n.Children {
		cleanNamespaceAttrs(&n.Children[i])
	}
}

// The upstream DAV library advertises unconditional write access. Project the
// actual collection and resource ACL instead, including author-only shared
// entries. Calendar colour is a conventional Apple DAV extension.
func (b *davBackend) calendarProperties(w http.ResponseWriter, r *http.Request, next http.Handler) {
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Invalid property request", 400)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	var request xmlNode
	_ = xml.Unmarshal(raw, &request)
	all := len(raw) == 0 || request.child(davNS, "allprop") != nil
	prop := request.child(davNS, "prop")
	color := all || (prop != nil && prop.child(calendarColorNS, "calendar-color") != nil)
	privilege := all || (prop != nil && prop.child(davNS, "current-user-privilege-set") != nil)
	capture := &davCapture{header: make(http.Header)}
	next.ServeHTTP(capture, r)
	data := capture.body.Bytes()
	if capture.status == 207 {
		var result xmlNode
		if xml.Unmarshal(data, &result) == nil {
			for i := range result.Children {
				response := &result.Children[i]
				href := response.child(davNS, "href")
				if href == nil {
					continue
				}
				u, err := url.Parse(strings.TrimSpace(href.Text))
				if err != nil {
					continue
				}
				id, base, err := davCalendarID(r.Context(), u.Path)
				if err != nil {
					continue
				}
				c := accessFor(r.Context()).Calendars[id]
				collection := u.Path == base
				values := map[xml.Name]xmlNode{}
				if color && collection {
					n := propertyNode(calendarColorNS, "calendar-color", c.Color+"FF")
					values[n.XMLName] = n
				}
				if privilege {
					names := []string{"read"}
					if !c.ReadOnly {
						if collection {
							names = append(names, "bind")
							if c.Kind != "shared" {
								names = append(names, "unbind")
							}
							if c.Owner == currentUser(r.Context()) {
								names = append(names, "write-properties")
							}
						} else {
							name := strings.TrimPrefix(u.Path, base)
							var e Event
							err := b.store.db.View(func(tx *bolt.Tx) error { var err error; e, err = findCalendarResource(tx, id, name); return err })
							if err == nil && canMutateEvent(r.Context(), e) {
								names = append(names, "write-content", "write-properties")
							}
						}
					}
					n := privilegeNode(names...)
					values[n.XMLName] = n
				}
				if len(values) == 0 {
					continue
				}
				children := []xmlNode{}
				var good *xmlNode
				for _, ps := range response.Children {
					if ps.XMLName.Space != davNS || ps.XMLName.Local != "propstat" {
						children = append(children, ps)
						continue
					}
					for j := range ps.Children {
						if ps.Children[j].XMLName.Space == davNS && ps.Children[j].XMLName.Local == "prop" {
							kept := []xmlNode{}
							for _, p := range ps.Children[j].Children {
								if _, replace := values[p.XMLName]; !replace {
									kept = append(kept, p)
								}
							}
							ps.Children[j].Children = kept
						}
					}
					p := ps.child(davNS, "prop")
					status := ps.child(davNS, "status")
					if p != nil && status != nil && strings.Contains(status.Text, " 200 ") {
						copy := ps
						good = &copy
						continue
					}
					if p == nil || len(p.Children) > 0 {
						children = append(children, ps)
					}
				}
				if good == nil {
					p := propertyNode(davNS, "prop", "")
					status := propertyNode(davNS, "status", "HTTP/1.1 200 OK")
					n := propertyNode(davNS, "propstat", "")
					n.Children = []xmlNode{p, status}
					good = &n
				}
				for j := range good.Children {
					if good.Children[j].XMLName.Space == davNS && good.Children[j].XMLName.Local == "prop" {
						for _, value := range values {
							good.Children[j].Children = append(good.Children[j].Children, value)
						}
					}
				}
				response.Children = append(children, *good)
			}
			cleanNamespaceAttrs(&result)
			if encoded, err := xml.Marshal(result); err == nil {
				data = append([]byte(xml.Header), encoded...)
			}
		}
	}
	for name, values := range capture.header {
		for _, value := range values {
			w.Header().Add(name, value)
		}
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	status := capture.status
	if status == 0 {
		status = 200
	}
	w.WriteHeader(status)
	_, _ = w.Write(data)
}
