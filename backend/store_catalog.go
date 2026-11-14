package main

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

//go:embed store-catalog.json
var storeCatalogJSON []byte

//go:embed store-catalog.png
var storeCatalogLogo []byte

func publishStoreCatalog(ctx context.Context, client *http.Client, origin, key string, data []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, origin+"/v1/catalog/spacetime", bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusNoContent {
		return fmt.Errorf("Private Store returned HTTP %d", res.StatusCode)
	}
	return nil
}

func storeCatalogPayload() ([]byte, error) {
	var catalog struct {
		SchemaVersion int                          `json:"schemaVersion"`
		Revision      int64                        `json:"revision"`
		Apps          []map[string]json.RawMessage `json:"apps"`
	}
	if err := json.Unmarshal(storeCatalogJSON, &catalog); err != nil {
		return nil, err
	}
	if catalog.SchemaVersion != 1 || catalog.Revision < 1 || len(catalog.Apps) != 1 || len(storeCatalogLogo) == 0 || len(storeCatalogLogo) > 64<<10 {
		return nil, fmt.Errorf("Spacetime catalog needs one app and a PNG of up to 64 KiB")
	}
	encodedLogo, err := json.Marshal(storeCatalogLogo)
	if err != nil {
		return nil, err
	}
	catalog.Apps[0]["logoPng"] = encodedLogo
	return json.Marshal(catalog)
}

func (a *App) runStoreCatalog(ctx context.Context) {
	key := os.Getenv("STORE_CATALOG_KEY")
	if key == "" {
		return
	}
	if a.notificationStore == "" || a.notificationHTTP == nil || len(key) < 32 {
		log.Print("Private Store catalog needs an HTTPS NOTIFICATION_STORE_URL and a valid STORE_CATALOG_KEY")
		return
	}
	data, err := storeCatalogPayload()
	if err != nil {
		log.Printf("Private Store catalog: %v", err)
		return
	}
	backoff := 5 * time.Second
	for ctx.Err() == nil {
		wait := time.Hour
		if err := publishStoreCatalog(ctx, a.notificationHTTP, a.notificationStore, key, data); err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("Private Store catalog publication: %v", err)
			wait = backoff
			backoff = min(2*backoff, 15*time.Minute)
		} else {
			backoff = 5 * time.Second
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (a *App) registerStoreCatalogAccount(ctx context.Context, binding *gravitasSession) {
	key := os.Getenv("STORE_CATALOG_KEY")
	if len(key) < 32 || binding == nil || a.gravitas == nil || a.notificationHTTP == nil || a.notificationStore == "" {
		return
	}
	proof, err := a.gravitas.openSessionProof(binding)
	if err != nil {
		return
	}
	data, err := json.Marshal(struct {
		Issuer string   `json:"issuer"`
		Proof  string   `json:"sessionProof"`
		Apps   []string `json:"apps"`
	}{binding.Issuer, string(proof), []string{"spacetime"}})
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, a.notificationStore+"/v1/catalog/spacetime/accounts", bytes.NewReader(data))
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	response, err := a.notificationHTTP.Do(req)
	if err != nil {
		log.Print("Private Store catalog account registration failed")
		return
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		log.Printf("Private Store catalog account registration returned HTTP %d", response.StatusCode)
	}
}
