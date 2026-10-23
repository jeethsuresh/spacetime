package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	bolt "go.etcd.io/bbolt"
	"strings"
	"testing"
	"time"
)

func setupBroker(t *testing.T) (*testApp, *mockIAM, map[string]string) {
	x, iam := setupGravitas(t)
	x.app.gravitas.sessionChecks = true
	x.app.gravitas.sessionKey = []byte(strings.Repeat("k", 32))
	verifier := strings.Repeat("v", 43)
	sum := sha256.Sum256([]byte(verifier))
	iam.challenge = base64.RawURLEncoding.EncodeToString(sum[:])
	iam.oneUseCode = true
	return x, iam, map[string]string{"code": "one-use-code", "code_verifier": verifier, "session_id": "test-family", "sub": iam.subject}
}

func expiredBrokerSession(t *testing.T, x *testApp, iam *mockIAM, body map[string]string) string {
	t.Helper()
	response := x.req("POST", "/api/auth/gravitas/broker", "", body, nil)
	x.expect(response, 200)
	var result struct{ Token string }
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	err := x.app.store.db.Update(func(tx *bolt.Tx) error {
		var s Session
		if err := getJSON(tx, "sessions", tokenKey(result.Token), &s); err != nil {
			return err
		}
		s.Expires = time.Now().Add(-time.Second)
		return putJSON(tx, "sessions", tokenKey(result.Token), s)
	})
	if err != nil {
		t.Fatal(err)
	}
	iam.exchanges = 0
	return result.Token
}

func TestBrokerRecoveryRenewsOnlySameLinkedExpiredAccount(t *testing.T) {
	x, iam, body := setupBroker(t)
	old := expiredBrokerSession(t, x, iam, body)
	headers := map[string]string{"Authorization": "Bearer " + old}
	expired := x.req("GET", "/api/me", "", nil, headers)
	x.expect(expired, 401)
	if !strings.Contains(expired.Body.String(), `"error_code":"session_expired"`) {
		t.Fatal("local expiry is not distinguishable")
	}
	request := map[string]any{"code": body["code"], "code_verifier": body["code_verifier"], "session_id": body["session_id"], "sub": body["sub"], "recovery": true}
	renewed := x.req("POST", "/api/auth/gravitas/broker", "", request, headers)
	x.expect(renewed, 200)
	var result struct {
		Token string
		User  User
	}
	if err := json.Unmarshal(renewed.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Token == old || result.User.Username != "jeeth" {
		t.Fatal("recovery changed account or reused bearer")
	}
	x.expect(x.req("GET", "/api/me", "", nil, map[string]string{"Authorization": "Bearer " + result.Token}), 200)
	x.expect(x.req("GET", "/api/me", "", nil, headers), 401)
	iam.exchanges = 0
	x.expect(x.req("POST", "/api/auth/gravitas/broker", "", request, headers), 401)
	if iam.exchanges != 0 {
		t.Fatal("consumed expired credential allowed another recovery")
	}
}

func TestBrokerRecoveryRejectsAccountSwitchAndPreservesCredentialOnOutage(t *testing.T) {
	for _, mode := range []string{"missing-old", "wrong-subject", "wrong-family", "revoked", "outage"} {
		t.Run(mode, func(t *testing.T) {
			x, iam, body := setupBroker(t)
			old := expiredBrokerSession(t, x, iam, body)
			headers := map[string]string{"Authorization": "Bearer " + old}
			request := map[string]any{"code": body["code"], "code_verifier": body["code_verifier"], "session_id": body["session_id"], "sub": body["sub"], "recovery": true}
			want := 401
			switch mode {
			case "missing-old":
				headers = nil
			case "wrong-subject":
				request["sub"] = "other"
			case "wrong-family":
				request["session_id"] = "other"
			case "revoked":
				iam.sessionStatus = 401
			case "outage":
				iam.sessionStatus = 503
				want = 503
			}
			x.expect(x.req("POST", "/api/auth/gravitas/broker", "", request, headers), want)
			x.app.store.db.View(func(tx *bolt.Tx) error {
				var prior Session
				if err := getJSON(tx, "sessions", tokenKey(old), &prior); err != nil {
					t.Fatal("failed recovery erased old credential")
				}
				if tx.Bucket([]byte("sessions")).Stats().KeyN != 1 {
					t.Fatal("failed recovery created session")
				}
				return nil
			})
			if mode == "missing-old" || mode == "wrong-subject" || mode == "wrong-family" {
				if iam.exchanges != 0 {
					t.Fatal("unmatched prior identity reached IAM exchange")
				}
			}
		})
	}
}
func TestBrokerLoginUsesPinnedIdentityAndRevocableSession(t *testing.T) {
	x, iam, body := setupBroker(t)
	response := x.req("POST", "/api/auth/gravitas/broker", "", body, nil)
	x.expect(response, 200)
	if len(response.Result().Cookies()) != 0 {
		t.Fatal("broker response set browser cookie")
	}
	var result struct {
		Token string
		User  User
	}
	if json.Unmarshal(response.Body.Bytes(), &result) != nil || len(result.Token) != 48 || result.User.Username == "" {
		t.Fatal("invalid app session")
	}
	if strings.Contains(response.Body.String(), "private-access-token") || strings.Contains(response.Body.String(), strings.Repeat("p", 43)) {
		t.Fatal("IAM credentials exposed to child")
	}
	headers := map[string]string{"Authorization": "Bearer " + result.Token}
	x.expect(x.req("GET", "/api/me", "", nil, headers), 200)
	x.expect(x.req("POST", "/api/auth/gravitas/broker", "", body, nil), 401)
	iam.sessionStatus = 401
	x.expect(x.req("GET", "/api/events", "", nil, headers), 401)
}
func TestBrokerWrongProofIdentityAndTransientErrorsFailClosed(t *testing.T) {
	for _, mode := range []string{"wrong-verifier", "wrong-family", "wrong-subject", "revoked", "outage", "token-outage", "missing-broker"} {
		t.Run(mode, func(t *testing.T) {
			x, iam, body := setupBroker(t)
			want := 401
			switch mode {
			case "wrong-verifier":
				body["code_verifier"] = strings.Repeat("w", 43)
			case "wrong-family":
				body["session_id"] = "different-family"
			case "wrong-subject":
				body["sub"] = "different-subject"
			case "revoked":
				iam.sessionStatus = 401
			case "outage":
				iam.sessionStatus = 503
				want = 503
			case "token-outage":
				iam.tokenStatus = 503
				want = 503
			case "missing-broker":
				iam.missingBroker = true
				want = 503
			}
			x.expect(x.req("POST", "/api/auth/gravitas/broker", "", body, nil), want)
			x.app.store.db.View(func(tx *bolt.Tx) error {
				if tx.Bucket([]byte("sessions")).Stats().KeyN != 0 || tx.Bucket([]byte("gravitas_identities")).Stats().KeyN != 0 {
					t.Fatal("failed exchange created authenticated state")
				}
				return nil
			})
		})
	}
}
func TestBrokerMalformedRequestNeverReachesIAM(t *testing.T) {
	for _, field := range []string{"code", "code_verifier", "session_id", "sub"} {
		t.Run(field, func(t *testing.T) {
			x, iam, body := setupBroker(t)
			delete(body, field)
			x.expect(x.req("POST", "/api/auth/gravitas/broker", "", body, nil), 400)
			if iam.exchanges != 0 {
				t.Fatal("malformed request exchanged")
			}
		})
	}
}
