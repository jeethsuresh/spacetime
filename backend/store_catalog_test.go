package main

import (
	"bytes"
	"context"
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSpacetimePublishesBackendCatalog(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut || r.URL.Path != "/v1/catalog/spacetime" ||
			r.Header.Get("Authorization") != "Bearer test-key" || r.Header.Get("Content-Type") != "application/json" {
			t.Error("unexpected catalog publication request")
			http.Error(w, "invalid request", 400)
			return
		}
		var catalog struct {
			SchemaVersion int
			Revision      int
			Apps          []struct {
				ID, Repository, PackageName string
				LogoPNG                     []byte
			}
		}
		if err := json.NewDecoder(r.Body).Decode(&catalog); err != nil {
			t.Error(err)
			http.Error(w, "invalid JSON", 400)
			return
		}
		if catalog.SchemaVersion != 1 || catalog.Revision < 1 || len(catalog.Apps) != 1 {
			t.Error("unexpected catalog schema or app count")
		} else if app := catalog.Apps[0]; app.ID != "spacetime" || app.Repository != "jeethsuresh/spacetime" ||
			app.PackageName != "com.jeethsuresh.spacetime" || !bytes.Equal(app.LogoPNG, storeCatalogLogo) {
			t.Error("unexpected app identity or image")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	if _, err := png.Decode(bytes.NewReader(storeCatalogLogo)); err != nil {
		t.Fatal(err)
	}
	payload, err := storeCatalogPayload()
	if err != nil {
		t.Fatal(err)
	}
	if err := publishStoreCatalog(context.Background(), server.Client(), server.URL, "test-key", payload); err != nil {
		t.Fatal(err)
	}
}
