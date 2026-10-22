package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	bolt "go.etcd.io/bbolt"
	"strings"
	"testing"
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
