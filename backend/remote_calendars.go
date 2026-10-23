package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
)

const remoteLimit = 16 * 1024 * 1024

type calendarAppKey struct{}
type remoteResource struct{ Href, ETag string }
type remoteSource struct {
	ID, Owner, URL, Kind, Credentials string
	ReadOnly                          bool
	Resources                         map[string]remoteResource
}
type storedRemoteSource struct{ ID, Owner, Kind, Payload string }

func (s storedRemoteSource) aad() []byte {
	return []byte("spacetime:source-state:v1\x00" + s.ID + "\x00" + s.Owner + "\x00" + s.Kind)
}
func (a *App) saveRemoteSource(tx *bolt.Tx, s remoteSource) error {
	raw, err := json.Marshal(s)
	if err != nil {
		return err
	}
	aead, err := a.remoteCrypt()
	if err != nil {
		return err
	}
	record := storedRemoteSource{ID: s.ID, Owner: s.Owner, Kind: s.Kind}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return err
	}
	record.Payload = base64.RawURLEncoding.EncodeToString(aead.Seal(nonce, nonce, raw, record.aad()))
	return putJSON(tx, "remote_calendars", s.ID, record)
}
func (a *App) loadRemoteSource(tx *bolt.Tx, id string) (remoteSource, error) {
	var s remoteSource
	var record storedRemoteSource
	if err := getJSON(tx, "remote_calendars", id, &record); err != nil {
		return s, err
	}
	aead, err := a.remoteCrypt()
	if err != nil {
		return s, err
	}
	raw, err := base64.RawURLEncoding.DecodeString(record.Payload)
	if err != nil || len(raw) < aead.NonceSize() {
		return s, errors.New("invalid source state")
	}
	plain, err := aead.Open(nil, raw[:aead.NonceSize()], raw[aead.NonceSize():], record.aad())
	if err != nil {
		return s, err
	}
	if err = json.Unmarshal(plain, &s); err != nil {
		return s, err
	}
	if s.ID != id || s.ID != record.ID || s.Owner != record.Owner || s.Kind != record.Kind {
		return s, errors.New("source state binding mismatch")
	}
	return s, nil
}
func publicSourceURL(u *url.URL) string { return u.Scheme + "://" + u.Host }

type remoteCredentials struct{ Username, Password string }
type sourceChoice struct {
	URL      string `json:"url"`
	Name     string `json:"name"`
	Color    string `json:"color"`
	ReadOnly bool   `json:"read_only"`
}
type remoteInput struct{ ID, Name, Color, URL, Kind, Username, Password string }
type fetchedResource struct{ Href, ETag, Raw string }

func remoteAllowedHost(host string) bool {
	for _, allowed := range strings.Split(os.Getenv("CALENDAR_REMOTE_ALLOWED_HOSTS"), ",") {
		if strings.EqualFold(strings.TrimSpace(allowed), host) && host != "" {
			return true
		}
	}
	return false
}
func normalizeRemoteURL(raw string) (*url.URL, error) {
	if strings.HasPrefix(raw, "webcal://") {
		raw = "https://" + strings.TrimPrefix(raw, "webcal://")
	}
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Hostname() == "" || u.User != nil || u.Fragment != "" || u.Opaque != "" || len(raw) > 2048 {
		return nil, statusError(400, "Enter a calendar URL without embedded credentials.")
	}
	u.Scheme = strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Hostname())
	port := u.Port()
	if port == "443" && u.Scheme == "https" || port == "80" && u.Scheme == "http" {
		port = ""
	}
	if port != "" {
		u.Host = net.JoinHostPort(host, port)
	} else if strings.Contains(host, ":") {
		u.Host = "[" + host + "]"
	} else {
		u.Host = host
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && remoteAllowedHost(u.Hostname()) && (u.Hostname() == "localhost" || net.ParseIP(u.Hostname()) != nil && net.ParseIP(u.Hostname()).IsLoopback())) {
		return nil, statusError(400, "Calendar sources must use HTTPS.")
	}
	if u.Path == "" {
		u.Path = "/"
	}
	return u, nil
}
func remoteIPAllowed(ip net.IP) bool {
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	a, ok := netip.AddrFromSlice(ip)
	if !ok {
		return false
	}
	a = a.Unmap()
	if a.Is6() && !netip.MustParsePrefix("2000::/3").Contains(a) {
		return false
	}
	for _, raw := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4", "2001::/32", "2002::/16"} {
		if netip.MustParsePrefix(raw).Contains(a) {
			return false
		}
	}
	return true
}
func newRemoteHTTPClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
		if err != nil {
			return nil, err
		}
		if len(ips) == 0 {
			return nil, errors.New("source has no addresses")
		}
		for _, ip := range ips {
			if !remoteAllowedHost(host) && !remoteIPAllowed(ip) {
				return nil, errors.New("source address is private or reserved")
			}
		}
		var last error
		for _, ip := range ips {
			conn, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			if err == nil {
				return conn, nil
			}
			last = err
		}
		return nil, last
	}
	return &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func (a *App) remoteCrypt() (cipher.AEAD, error) {
	key := []byte(nil)
	if raw := os.Getenv("CALENDAR_SECRET_KEY"); raw != "" {
		var err error
		key, err = base64.StdEncoding.DecodeString(raw)
		if err != nil {
			return nil, errors.New("invalid calendar encryption key")
		}
	} else if a.gravitas != nil && len(a.gravitas.sessionKey) == 32 {
		key = a.gravitas.sessionKey
	} else {
		file := a.store.db.Path() + ".calendar-key"
		var err error
		key, err = os.ReadFile(file)
		if os.IsNotExist(err) {
			key = make([]byte, 32)
			if _, err = rand.Read(key); err != nil {
				return nil, err
			}
			f, err := os.OpenFile(file, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if os.IsExist(err) {
				key, err = os.ReadFile(file)
			} else if err == nil {
				_, err = f.Write(key)
				if err == nil {
					err = f.Sync()
				}
				closeErr := f.Close()
				if err == nil {
					err = closeErr
				}
			}
			if err != nil {
				return nil, err
			}
		} else if err != nil {
			return nil, err
		}
	}
	if len(key) != 32 {
		return nil, errors.New("calendar encryption key must contain 32 bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
func (s remoteSource) aad() []byte {
	return []byte("spacetime:source:v1\x00" + s.ID + "\x00" + s.Owner + "\x00" + s.URL + "\x00" + s.Kind)
}
func (a *App) sealSource(s remoteSource, c remoteCredentials) (string, error) {
	aead, err := a.remoteCrypt()
	if err != nil {
		return "", err
	}
	raw, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(aead.Seal(nonce, nonce, raw, s.aad())), nil
}
func (a *App) openSource(s remoteSource) (remoteCredentials, error) {
	var c remoteCredentials
	aead, err := a.remoteCrypt()
	if err != nil {
		return c, err
	}
	raw, err := base64.RawURLEncoding.DecodeString(s.Credentials)
	if err != nil || len(raw) < aead.NonceSize() {
		return c, errors.New("invalid source credential")
	}
	plain, err := aead.Open(nil, raw[:aead.NonceSize()], raw[aead.NonceSize():], s.aad())
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(plain, &c)
	return c, err
}
func sourceHref(base *url.URL, href string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(href))
	if err != nil {
		return nil, statusError(502, "Invalid source resource URL.")
	}
	u = base.ResolveReference(u)
	u, err = normalizeRemoteURL(u.String())
	if err != nil {
		return nil, statusError(502, "Invalid source resource URL.")
	}
	if u.Scheme != base.Scheme || !strings.EqualFold(u.Host, base.Host) || u.User != nil || u.Fragment != "" {
		return nil, statusError(502, "The source points to another server. Connect using that server's calendar URL.")
	}
	return u, nil
}
func sourceChild(base *url.URL, href string) (*url.URL, error) {
	u, err := sourceHref(base, href)
	if err != nil {
		return nil, err
	}
	prefix := strings.TrimSuffix(base.Path, "/") + "/"
	if !strings.HasPrefix(u.Path, prefix) || strings.Contains(strings.TrimPrefix(u.Path, prefix), "/") || strings.TrimPrefix(u.Path, prefix) == "" {
		return nil, statusError(502, "The source returned a resource outside its calendar collection.")
	}
	return u, nil
}
func (a *App) sourceRequest(ctx context.Context, s remoteSource, credentials remoteCredentials, method, target, body string, headers map[string]string) ([]byte, http.Header, int, error) {
	base, err := normalizeRemoteURL(s.URL)
	if err != nil {
		return nil, nil, 0, err
	}
	u, err := sourceHref(base, target)
	if err != nil {
		return nil, nil, 0, err
	}
	if a.gravitas != nil && u.Scheme+"://"+u.Host == a.gravitas.origin {
		return nil, nil, 0, statusError(400, "This server's calendars are already available in Spacetime.")
	}
	client := a.remoteHTTP
	if client == nil {
		client = newRemoteHTTPClient()
	}
	for redirects := 0; redirects < 4; redirects++ {
		req, err := http.NewRequestWithContext(ctx, method, u.String(), strings.NewReader(body))
		if err != nil {
			return nil, nil, 0, err
		}
		if credentials.Username != "" || credentials.Password != "" {
			req.SetBasicAuth(credentials.Username, credentials.Password)
		}
		for key, value := range headers {
			req.Header.Set(key, value)
		}
		response, err := client.Do(req)
		if err != nil {
			return nil, nil, 0, statusError(503, "Cannot reach the calendar source. Cached entries and offline changes are kept.")
		}
		raw, readErr := io.ReadAll(io.LimitReader(response.Body, remoteLimit+1))
		response.Body.Close()
		if readErr != nil || len(raw) > remoteLimit {
			return nil, nil, 0, statusError(502, "The source response is incomplete or too large.")
		}
		if response.StatusCode == 301 || response.StatusCode == 302 || response.StatusCode == 307 || response.StatusCode == 308 {
			u, err = sourceHref(u, response.Header.Get("Location"))
			if err != nil {
				return nil, nil, 0, err
			}
			continue
		}
		return raw, response.Header, response.StatusCode, nil
	}
	return nil, nil, 0, statusError(502, "The calendar source redirected too many times.")
}
func remoteStatus(code int) error {
	switch code {
	case 401, 403:
		return statusError(403, "The source denied access. Check the source credentials or calendar permissions.")
	case 409, 412:
		return statusError(409, "The source changed this entry. Sync to use the server version.")
	case 404:
		return statusError(404, "The source calendar or entry no longer exists.")
	default:
		return statusError(503, "The calendar source could not complete this request. Offline changes are kept.")
	}
}
func davResponses(raw []byte) ([]xmlNode, error) {
	var root xmlNode
	if xml.Unmarshal(raw, &root) != nil || root.XMLName.Space != davNS || root.XMLName.Local != "multistatus" {
		return nil, statusError(502, "Invalid WebDAV response.")
	}
	return root.Children, nil
}
func responseProps(response *xmlNode) (map[xml.Name]*xmlNode, bool) {
	props := map[xml.Name]*xmlNode{}
	ok := false
	for i := range response.Children {
		ps := &response.Children[i]
		if ps.XMLName.Space != davNS || ps.XMLName.Local != "propstat" {
			continue
		}
		status := ps.child(davNS, "status")
		if status == nil || !strings.Contains(status.Text, " 200 ") {
			continue
		}
		p := ps.child(davNS, "prop")
		if p == nil {
			continue
		}
		ok = true
		for j := range p.Children {
			prop := &p.Children[j]
			props[prop.XMLName] = prop
		}
	}
	return props, ok
}
func propText(props map[xml.Name]*xmlNode, space, name string) string {
	if n := props[xml.Name{Space: space, Local: name}]; n != nil {
		return strings.TrimSpace(n.Text)
	}
	return ""
}
func sourceReadOnly(props map[xml.Name]*xmlNode) bool {
	n := props[xml.Name{Space: davNS, Local: "current-user-privilege-set"}]
	if n == nil {
		return false
	}
	for _, priv := range n.Children {
		if priv.child(davNS, "all") != nil || priv.child(davNS, "write") != nil || priv.child(davNS, "write-content") != nil || priv.child(davNS, "bind") != nil {
			return false
		}
	}
	return true
}

const discoverBody = `<?xml version="1.0"?><D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:A="http://apple.com/ns/ical/"><D:prop><D:resourcetype/><D:displayname/><D:current-user-principal/><C:calendar-home-set/><D:current-user-privilege-set/><A:calendar-color/></D:prop></D:propfind>`

func (a *App) sourceDiscover(ctx context.Context, s remoteSource, c remoteCredentials) ([]sourceChoice, error) {
	u, err := normalizeRemoteURL(s.URL)
	if err != nil {
		return nil, err
	}
	if s.Kind == "ics" {
		_, _, code, err := a.sourceRequest(ctx, s, c, "GET", u.String(), "", nil)
		if err != nil {
			return nil, err
		}
		if code != 200 {
			return nil, remoteStatus(code)
		}
		_, options, status, _ := a.sourceRequest(ctx, s, c, "OPTIONS", u.String(), "", nil)
		return []sourceChoice{{URL: u.String(), Name: path.Base(u.Path), Color: "#426EB4", ReadOnly: status < 200 || status >= 300 || !strings.Contains(options.Get("Allow"), "PUT")}}, nil
	}
	visited := map[string]bool{}
	queue := []string{u.String()}
	choices := []sourceChoice{}
	seen := map[string]bool{}
	for len(queue) > 0 && len(visited) < 8 {
		target := queue[0]
		queue = queue[1:]
		if visited[target] {
			continue
		}
		visited[target] = true
		targetURL, _ := url.Parse(target)
		raw, _, code, err := a.sourceRequest(ctx, s, c, "PROPFIND", target, discoverBody, map[string]string{"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
		if err != nil {
			return nil, err
		}
		if code != 207 {
			return nil, remoteStatus(code)
		}
		responses, err := davResponses(raw)
		if err != nil {
			return nil, err
		}
		for i := range responses {
			response := &responses[i]
			href := response.child(davNS, "href")
			if href == nil {
				continue
			}
			resolved, err := sourceHref(targetURL, href.Text)
			if err != nil {
				return nil, err
			}
			props, ok := responseProps(response)
			if !ok {
				continue
			}
			resourceType := props[xml.Name{Space: davNS, Local: "resourcetype"}]
			calendar := resourceType != nil && resourceType.child(calNS, "calendar") != nil
			if calendar || (s.Kind == "webdav" && resolved.String() == target) {
				name := propText(props, davNS, "displayname")
				if name == "" {
					name = path.Base(strings.TrimSuffix(resolved.Path, "/"))
				}
				color := propText(props, "http://apple.com/ns/ical/", "calendar-color")
				if len(color) == 9 {
					color = color[:7]
				}
				if !colorPattern.MatchString(color) {
					color = "#426EB4"
				}
				if !seen[resolved.String()] {
					choices = append(choices, sourceChoice{resolved.String(), name, color, sourceReadOnly(props)})
					seen[resolved.String()] = true
				}
				continue
			}
			for _, key := range []xml.Name{{Space: davNS, Local: "current-user-principal"}, {Space: calNS, Local: "calendar-home-set"}} {
				if n := props[key]; n != nil {
					for _, child := range n.Children {
						if child.XMLName.Space == davNS && child.XMLName.Local == "href" {
							next, err := sourceHref(resolved, child.Text)
							if err != nil {
								return nil, err
							}
							if !visited[next.String()] {
								queue = append(queue, next.String())
							}
						}
					}
				}
			}
		}
		if len(choices) > 64 {
			return nil, statusError(413, "Connect at most 64 source calendars at a time.")
		}
	}
	if len(choices) == 0 {
		return nil, statusError(404, "No calendars found. Enter the source's calendar collection URL.")
	}
	return choices, nil
}
func splitSourceCalendar(raw string, allowMethod ...bool) (map[string]Event, error) {
	return parseSourceEvents(raw, len(allowMethod) > 0 && allowMethod[0])
}
func (a *App) fetchSource(ctx context.Context, s remoteSource, c remoteCredentials) ([]fetchedResource, bool, error) {
	if s.Kind == "ics" {
		raw, h, code, err := a.sourceRequest(ctx, s, c, "GET", s.URL, "", nil)
		if err != nil {
			return nil, false, err
		}
		if code != 200 {
			return nil, false, remoteStatus(code)
		}
		// An ICS URL is a subscription unless the WebDAV server explicitly
		// advertises write access. Every later write still uses If-Match.
		_, options, optionCode, _ := a.sourceRequest(ctx, s, c, "OPTIONS", s.URL, "", nil)
		writable := optionCode >= 200 && optionCode < 300 && strings.Contains(options.Get("Allow"), "PUT")
		return []fetchedResource{{s.URL, h.Get("ETag"), string(raw)}}, !writable, nil
	}
	meta, _, code, err := a.sourceRequest(ctx, s, c, "PROPFIND", s.URL, discoverBody, map[string]string{"Depth": "0", "Content-Type": "application/xml; charset=utf-8"})
	if err != nil {
		return nil, false, err
	}
	if code != 207 {
		return nil, false, remoteStatus(code)
	}
	responses, err := davResponses(meta)
	if err != nil {
		return nil, false, err
	}
	readOnly := false
	for i := range responses {
		props, ok := responseProps(&responses[i])
		if ok {
			readOnly = sourceReadOnly(props)
		}
	}
	if s.Kind == "caldav" {
		body := `<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"/></C:filter></C:calendar-query>`
		raw, _, code, err := a.sourceRequest(ctx, s, c, "REPORT", s.URL, body, map[string]string{"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
		if err != nil {
			return nil, false, err
		}
		if code != 207 {
			return nil, false, remoteStatus(code)
		}
		responses, err := davResponses(raw)
		if err != nil {
			return nil, false, err
		}
		items := []fetchedResource{}
		base, _ := normalizeRemoteURL(s.URL)
		for i := range responses {
			props, ok := responseProps(&responses[i])
			if !ok {
				return nil, false, statusError(502, "The source returned an incomplete calendar snapshot.")
			}
			href := responses[i].child(davNS, "href")
			data := props[xml.Name{Space: calNS, Local: "calendar-data"}]
			if href == nil || data == nil {
				return nil, false, statusError(502, "The source omitted calendar data.")
			}
			u, err := sourceChild(base, href.Text)
			if err != nil {
				return nil, false, err
			}
			items = append(items, fetchedResource{u.String(), propText(props, davNS, "getetag"), data.Text})
		}
		if len(items) > 2000 {
			return nil, false, statusError(413, "The source contains more than 2,000 calendar resources.")
		}
		return items, readOnly, nil
	}
	body := `<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getetag/><D:getcontenttype/></D:prop></D:propfind>`
	raw, _, code, err := a.sourceRequest(ctx, s, c, "PROPFIND", s.URL, body, map[string]string{"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
	if err != nil {
		return nil, false, err
	}
	if code != 207 {
		return nil, false, remoteStatus(code)
	}
	responses, err = davResponses(raw)
	if err != nil {
		return nil, false, err
	}
	items := []fetchedResource{}
	totalBytes := 0
	base, _ := normalizeRemoteURL(s.URL)
	for i := range responses {
		props, ok := responseProps(&responses[i])
		if !ok {
			return nil, false, statusError(502, "The source returned an incomplete WebDAV snapshot.")
		}
		kind := props[xml.Name{Space: davNS, Local: "resourcetype"}]
		if kind != nil && kind.child(davNS, "collection") != nil {
			continue
		}
		href := responses[i].child(davNS, "href")
		if href == nil {
			continue
		}
		u, err := sourceChild(base, href.Text)
		if err != nil {
			return nil, false, err
		}
		if !strings.HasSuffix(strings.ToLower(u.Path), ".ics") && !strings.HasPrefix(propText(props, davNS, "getcontenttype"), "text/calendar") {
			continue
		}
		data, h, code, err := a.sourceRequest(ctx, s, c, "GET", u.String(), "", nil)
		if err != nil {
			return nil, false, err
		}
		if code != 200 {
			return nil, false, remoteStatus(code)
		}
		totalBytes += len(data)
		if totalBytes > remoteLimit {
			return nil, false, statusError(413, "The source calendar exceeds the 16 MiB snapshot limit.")
		}
		items = append(items, fetchedResource{u.String(), h.Get("ETag"), string(data)})
		if len(items) > 2000 {
			return nil, false, statusError(413, "The source contains more than 2,000 calendar resources.")
		}
	}
	return items, readOnly, nil
}
func (a *App) pullSource(ctx context.Context, id string) error {
	var source remoteSource
	err := a.store.db.View(func(tx *bolt.Tx) error { var err error; source, err = a.loadRemoteSource(tx, id); return err })
	if err != nil {
		return err
	}
	credentials, err := a.openSource(source)
	if err != nil {
		return statusError(503, "Reconnect this source to restore its credentials.")
	}
	resources, readOnly, err := a.fetchSource(ctx, source, credentials)
	if err != nil {
		return err
	}
	return a.applySourceSnapshot(source, resources, readOnly, nil)
}
func (a *App) applySourceSnapshot(source remoteSource, resources []fetchedResource, readOnly bool, creating *Calendar) error {
	id := source.ID
	events := map[string]Event{}
	source.Resources = map[string]remoteResource{}
	totalBytes := 0
	for _, resource := range resources {
		totalBytes += len(resource.Raw)
		if totalBytes > remoteLimit {
			return statusError(413, "The source calendar exceeds the 16 MiB snapshot limit.")
		}
		parsed, err := splitSourceCalendar(resource.Raw, source.Kind != "caldav")
		if err != nil {
			return err
		}
		if source.Kind == "caldav" && len(parsed) != 1 {
			return statusError(502, "A CalDAV/WebDAV resource must contain one UID and its exceptions.")
		}
		for uid, e := range parsed {
			if _, exists := events[uid]; exists {
				return statusError(409, "The source contains duplicate UIDs in different resources.")
			}
			if len(events) >= 10000 {
				return statusError(413, "A connected calendar may contain at most 10,000 series.")
			}
			events[uid] = e
			source.Resources[uid] = remoteResource{resource.Href, resource.ETag}
		}
	}
	return a.store.db.Update(func(tx *bolt.Tx) error {
		var c Calendar
		if creating != nil {
			c = *creating
		} else {
			var err error
			c, err = calendarTx(tx, id)
			if err != nil {
				return err
			}
		}
		existing, err := eventsTx(tx)
		if err != nil {
			return err
		}
		oldByUID := map[string]Event{}
		for _, e := range existing {
			if eventCalendar(e) == id {
				oldByUID[e.UID] = e
			}
		}
		for uid, e := range events {
			old, exists := oldByUID[uid]
			if exists && old.Raw == e.Raw {
				delete(oldByUID, uid)
				continue
			}
			if exists {
				e.ID, e.Version, e.Resource = old.ID, old.Version+1, old.Resource
			} else {
				e.ID = randomID()
				e.Resource = e.ID + ".ics"
				e.Version = 1
			}
			e.Owner, e.CalendarID, e.Updated = source.Owner, id, time.Now().UTC()
			if err := saveEvent(tx, e); err != nil {
				return err
			}
			delete(oldByUID, uid)
		}
		for _, old := range oldByUID {
			if err := tx.Bucket([]byte("events")).Delete([]byte(old.ID)); err != nil {
				return err
			}
		}
		now := time.Now().UTC()
		c.LastSync = &now
		c.ReadOnly = readOnly
		c.SyncError = ""
		source.ReadOnly = readOnly
		if err := putJSON(tx, "calendars", id, c); err != nil {
			return err
		}
		return a.saveRemoteSource(tx, source)
	})
}

func (a *App) discoverRemote(w http.ResponseWriter, r *http.Request) {
	var body remoteInput
	if !decode(w, r, &body) {
		return
	}
	if len(body.Username) > 256 || len(body.Password) > 4096 {
		fail(w, 400, "Source credentials are too long.")
		return
	}
	if body.Kind != "caldav" && body.Kind != "webdav" && body.Kind != "ics" {
		fail(w, 400, "Choose CalDAV, WebDAV or a calendar URL.")
		return
	}
	choices, err := a.sourceDiscover(r.Context(), remoteSource{URL: body.URL, Kind: body.Kind}, remoteCredentials{body.Username, body.Password})
	if err != nil {
		serveError(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"calendars": choices})
}
func (a *App) connectRemote(w http.ResponseWriter, r *http.Request) {
	var body remoteInput
	if !decode(w, r, &body) {
		return
	}
	if len(body.Username) > 256 || len(body.Password) > 4096 {
		fail(w, 400, "Source credentials are too long.")
		return
	}
	if body.ID != "" {
		var old remoteSource
		err := a.store.db.View(func(tx *bolt.Tx) error { var err error; old, err = a.loadRemoteSource(tx, body.ID); return err })
		if err != nil {
			serveError(w, err)
			return
		}
		if old.Owner != currentUser(r.Context()) {
			fail(w, 403, "This source belongs to another account.")
			return
		}
		original, _ := normalizeRemoteURL(old.URL)
		if body.URL == "" || body.URL == publicSourceURL(original) {
			body.URL = old.URL
		}
		requested, err := normalizeRemoteURL(body.URL)
		if err != nil {
			serveError(w, err)
			return
		}
		if original.Scheme != requested.Scheme || original.Host != requested.Host || original.EscapedPath() != requested.EscapedPath() || old.Kind != body.Kind {
			fail(w, 400, "Add a separate calendar for a different source URL.")
			return
		}
		if requested.RawQuery == "" {
			requested.RawQuery = original.RawQuery
		}
		body.URL = requested.String()
		if body.Username == "" || body.Password == "" {
			credentials, err := a.openSource(old)
			if err != nil {
				serveError(w, err)
				return
			}
			if body.Username == "" {
				body.Username = credentials.Username
			}
			if body.Password == "" {
				body.Password = credentials.Password
			}
		}
	}
	u, err := normalizeRemoteURL(body.URL)
	if err != nil {
		serveError(w, err)
		return
	}
	if body.Kind != "caldav" && body.Kind != "webdav" && body.Kind != "ics" {
		fail(w, 400, "Choose CalDAV, WebDAV or a calendar URL.")
		return
	}
	if !colorPattern.MatchString(body.Color) {
		body.Color = "#426EB4"
	}
	if strings.TrimSpace(body.Name) == "" {
		body.Name = path.Base(strings.TrimSuffix(u.Path, "/"))
	}
	if len(body.Name) > 120 {
		fail(w, 400, "Calendar names are limited to 120 characters.")
		return
	}
	id := randomID()
	existing := false
	if body.ID != "" {
		id = body.ID
		existing = true
	}
	err = a.store.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket([]byte("calendars")).ForEach(func(_, v []byte) error {
			var c Calendar
			if err := json.Unmarshal(v, &c); err != nil {
				return err
			}
			if c.Owner == currentUser(r.Context()) && c.SourceRef == tokenKey(u.String()) && c.SourceKind == body.Kind {
				id = c.ID
				existing = true
			}
			return nil
		})
	})
	if err != nil {
		serveError(w, err)
		return
	}
	source := remoteSource{ID: id, Owner: currentUser(r.Context()), URL: u.String(), Kind: body.Kind, Resources: map[string]remoteResource{}}
	source.Credentials, err = a.sealSource(source, remoteCredentials{body.Username, body.Password})
	if err != nil {
		serveError(w, err)
		return
	}
	resources, readOnly, err := a.fetchSource(r.Context(), source, remoteCredentials{body.Username, body.Password})
	if err != nil {
		serveError(w, err)
		return
	}
	candidate := Calendar{ID: id, Owner: source.Owner, Name: body.Name, Color: strings.ToUpper(body.Color), Kind: "source", Version: 1, Updated: time.Now().UTC(), SourceURL: publicSourceURL(u), SourceKind: source.Kind, SourceRef: tokenKey(source.URL)}
	if existing {
		err = a.store.db.View(func(tx *bolt.Tx) error {
			old, e := calendarTx(tx, id)
			if e != nil {
				return e
			}
			candidate.Version = old.Version + 1
			return nil
		})
	}
	if err == nil {
		err = a.applySourceSnapshot(source, resources, readOnly, &candidate)
	}
	if err != nil {
		serveError(w, err)
		return
	}
	var c Calendar
	err = a.store.db.View(func(tx *bolt.Tx) error { var err error; c, err = calendarTx(tx, id); return err })
	if err != nil {
		serveError(w, err)
		return
	}
	c.SourceRef = ""
	writeJSON(w, 201, c)
}

func (a *App) syncSources(ctx context.Context) error {
	for id, c := range accessFor(ctx).Calendars {
		if c.Kind != "source" {
			continue
		}
		if err := a.pullSource(ctx, id); err != nil {
			_ = a.store.db.Update(func(tx *bolt.Tx) error {
				stored, e := calendarTx(tx, id)
				if e != nil {
					return e
				}
				stored.SyncError = err.Error()
				return putJSON(tx, "calendars", id, stored)
			})
		}
	}
	return nil
}
func (a *App) prepareSourceEntry(ctx context.Context, id string) error {
	var e Event
	err := a.store.db.View(func(tx *bolt.Tx) error { var err error; e, err = eventTx(tx, id); return err })
	if err != nil {
		return err
	}
	if !canMutateEvent(ctx, e) {
		return statusError(403, "Only the author can change this entry.")
	}
	if accessFor(ctx).Calendars[eventCalendar(e)].Kind == "source" {
		return a.pullSource(ctx, eventCalendar(e))
	}
	return nil
}
func strongSourceETag(etag string) bool {
	return len(etag) >= 2 && strings.HasPrefix(etag, `"`) && strings.HasSuffix(etag, `"`) && !strings.HasPrefix(etag, "W/") && !strings.ContainsAny(etag, "\r\n")
}

func (a *App) writeSource(ctx context.Context, tx *bolt.Tx, e *Event, remove bool) error {
	var source remoteSource
	var err error
	source, err = a.loadRemoteSource(tx, eventCalendar(*e))
	if err != nil {
		return err
	}
	if source.ReadOnly {
		return statusError(403, "The source calendar is read-only.")
	}
	credentials, err := a.openSource(source)
	if err != nil {
		return statusError(503, "Reconnect this source to restore its credentials.")
	}
	resource, exists := source.Resources[e.UID]
	method := "PUT"
	body := e.Raw
	headers := map[string]string{"Content-Type": "text/calendar; charset=utf-8"}
	if exists {
		if !strongSourceETag(resource.ETag) {
			return statusError(409, "The source did not provide a strong ETag. Sync before editing.")
		}
		headers["If-Match"] = resource.ETag
	} else {
		if remove {
			return nil
		}
		base, _ := normalizeRemoteURL(source.URL)
		if !strings.HasSuffix(base.Path, "/") {
			base.Path += "/"
		}
		u, err := sourceHref(base, e.ID+".ics")
		if err != nil {
			return err
		}
		resource.Href = u.String()
		headers["If-None-Match"] = "*"
	}
	bundle := source.Kind == "ics" || (source.Kind == "webdav" && exists)
	if bundle {
		target := resource.Href
		if source.Kind == "ics" {
			target = source.URL
		}
		raw, h, code, err := a.sourceRequest(ctx, source, credentials, "GET", target, "", nil)
		if err != nil {
			return err
		}
		if code != 200 {
			return remoteStatus(code)
		}
		if !strongSourceETag(h.Get("ETag")) || (exists && h.Get("ETag") != resource.ETag) {
			return statusError(409, "The source changed. Sync to use the server version.")
		}
		body, err = rewriteSourceBundle(string(raw), e, remove)
		if err != nil {
			return err
		}
		resource.Href = target
		headers["If-Match"] = h.Get("ETag")
		delete(headers, "If-None-Match")
	} else if remove {
		method = "DELETE"
		body = ""
	}
	_, _, code, err := a.sourceRequest(ctx, source, credentials, method, resource.Href, body, headers)
	if err != nil {
		return err
	}
	if code < 200 || code >= 300 {
		if remove && code == 404 {
			delete(source.Resources, e.UID)
			return a.saveRemoteSource(tx, source)
		}
		return remoteStatus(code)
	}
	if remove {
		delete(source.Resources, e.UID)
	}
	if !remove || bundle {
		raw, h, code, err := a.sourceRequest(ctx, source, credentials, "GET", resource.Href, "", nil)
		if err != nil {
			return err
		}
		if code != 200 {
			return remoteStatus(code)
		}
		canonical, err := splitSourceCalendar(string(raw), source.Kind != "caldav")
		if err != nil {
			return err
		}
		entry, ok := canonical[e.UID]
		if !remove && !ok {
			return statusError(502, "The source did not retain the entry UID.")
		}
		if !remove {
			entry.ID, entry.CalendarID, entry.Owner, entry.Version, entry.Resource, entry.Updated = e.ID, e.CalendarID, e.Owner, e.Version, e.Resource, time.Now().UTC()
			*e = entry
			source.Resources[e.UID] = remoteResource{resource.Href, h.Get("ETag")}
		}
		if bundle {
			for uid, res := range source.Resources {
				if res.Href == resource.Href {
					res.ETag = h.Get("ETag")
					source.Resources[uid] = res
				}
			}
		}
	}
	return a.saveRemoteSource(tx, source)
}
func saveCalendarEvent(ctx context.Context, tx *bolt.Tx, e *Event) error {
	if a, ok := ctx.Value(calendarAppKey{}).(*App); ok && accessFor(ctx).Calendars[eventCalendar(*e)].Kind == "source" {
		if err := a.writeSource(ctx, tx, e, false); err != nil {
			return err
		}
	}
	return saveEvent(tx, *e)
}
func deleteCalendarEvent(ctx context.Context, tx *bolt.Tx, e Event) error {
	if a, ok := ctx.Value(calendarAppKey{}).(*App); ok && accessFor(ctx).Calendars[eventCalendar(e)].Kind == "source" {
		if err := a.writeSource(ctx, tx, &e, true); err != nil {
			return err
		}
	}
	return tx.Bucket([]byte("events")).Delete([]byte(e.ID))
}
