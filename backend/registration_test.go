package main

import (
	"net/http"
	"strings"
	"testing"
)

func TestRegistrationRequiresInviteBeforeCreatingAccount(t *testing.T) {
	for _, key := range []string{"", "incorrect", " " + testInviteKey, testInviteKey + " ", strings.ToUpper(testInviteKey)} {
		t.Run("rejected_"+key, func(t *testing.T) {
			x := setup(t)
			body := map[string]string{"username": "alice", "password": "correct horse battery"}
			if key != "" {
				body["invite_key"] = key
			}
			w := x.req("POST", "/api/register", "", body, nil)
			x.expect(w, http.StatusForbidden)
			if len(w.Result().Cookies()) != 0 || strings.Contains(w.Body.String(), testInviteKey) {
				t.Fatal("rejected registration must not create a session or reveal the key")
			}
			if _, err := x.app.store.user("alice"); err == nil {
				t.Fatal("rejected registration created an account")
			}
			// The rejected attempt must not reserve the username.
			x.register("alice")
		})
	}
}

func TestRegistrationConfigurationAndExistingAuthentication(t *testing.T) {
	x := setup(t)
	x.register("alice")
	t.Setenv("REGISTRATION_INVITE_KEY", "")
	x.app = newApp(x.app.store)
	x.handler = x.app.handler()
	x.expect(x.req("POST", "/api/register", "", map[string]string{
		"username": "bobby", "password": "correct horse battery", "invite_key": testInviteKey,
	}, nil), http.StatusServiceUnavailable)
	// Neither a disabled registration service nor an irrelevant invite value affects login.
	for _, key := range []string{"", "wrong"} {
		x.expect(x.req("POST", "/api/login", "", map[string]string{
			"username": "alice", "password": "correct horse battery", "invite_key": key,
		}, nil), http.StatusOK)
	}
	x.expect(x.req("GET", "/api/me", "alice", nil, nil), http.StatusOK)
	x.expect(x.req("PROPFIND", "/dav/alice/", "", `<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>`, map[string]string{
		"Authorization": "Basic YWxpY2U6Y29ycmVjdCBob3JzZSBiYXR0ZXJ5", "Depth": "0",
	}), http.StatusMultiStatus)
	t.Setenv("REGISTRATION_INVITE_KEY", "rotated-test-invite")
	x.app = newApp(x.app.store)
	x.handler = x.app.handler()
	body := map[string]string{"username": "bobby", "password": "correct horse battery", "invite_key": testInviteKey}
	x.expect(x.req("POST", "/api/register", "", body, nil), http.StatusForbidden)
	body["invite_key"] = "rotated-test-invite"
	x.expect(x.req("POST", "/api/register", "", body, nil), http.StatusOK)
	x.expect(x.req("POST", "/api/login", "", map[string]string{
		"username": "alice", "password": "correct horse battery",
	}, nil), http.StatusOK)
}
