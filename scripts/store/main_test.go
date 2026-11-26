package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/juju/persistent-cookiejar"
	"github.com/majd/ipatool/v2/pkg/appstore"
)

func TestAuthenticate(t *testing.T) {
	input := appstore.LoginInput{Email: "test@example.invalid", Password: "fixture"}
	t.Run("nonchallenge", func(t *testing.T) {
		failure := errors.New("HTTP 204")
		prompts := 0
		_, err := authenticate(func(appstore.LoginInput) (appstore.LoginOutput, error) {
			return appstore.LoginOutput{}, failure
		}, input, func() (string, error) {
			prompts++
			return "", nil
		})
		if !errors.Is(err, failure) || prompts != 0 {
			t.Fatalf("got %v and %d prompts", err, prompts)
		}
	})
	t.Run("challenge", func(t *testing.T) {
		calls, prompts := 0, 0
		_, err := authenticate(func(got appstore.LoginInput) (appstore.LoginOutput, error) {
			calls++
			if got.Email != input.Email || got.Password != input.Password {
				t.Fatal("credentials changed")
			}
			if calls == 1 {
				return appstore.LoginOutput{}, appstore.ErrAuthCodeRequired
			}
			if got.AuthCode != "012345" {
				t.Fatal("verification code not forwarded")
			}
			return appstore.LoginOutput{}, appstore.ErrAuthCodeRequired
		}, input, func() (string, error) {
			prompts++
			return "012345", nil
		})
		if !errors.Is(err, appstore.ErrAuthCodeRequired) || calls != 2 || prompts != 1 {
			t.Fatalf("got %v, %d calls, %d prompts", err, calls, prompts)
		}
	})
	t.Run("cancel before code submission", func(t *testing.T) {
		calls := 0
		_, err := authenticate(func(appstore.LoginInput) (appstore.LoginOutput, error) {
			calls++
			return appstore.LoginOutput{}, appstore.ErrAuthCodeRequired
		}, input, func() (string, error) { return "", nil })
		if !errors.Is(err, errCancelled) || calls != 1 {
			t.Fatalf("got %v and %d calls", err, calls)
		}
	})
}

func TestSessionRestore(t *testing.T) {
	jar, err := cookiejar.New(&cookiejar.Options{NoPersist: true})
	if err != nil {
		t.Fatal(err)
	}
	origin := &url.URL{Scheme: "https", Host: "auth.itunes.apple.com", Path: "/auth"}
	jar.SetCookies(origin, []*http.Cookie{
		{Name: "shared", Value: "fixture", Domain: ".apple.com", Path: "/", Expires: time.Now().Add(time.Hour)},
		{Name: "host", Value: "fixture", Path: "/auth", Expires: time.Now().Add(time.Hour)},
	})
	account := appstore.Account{
		DirectoryServicesID: "123",
		StoreFront:          "143465-1,29",
		Password:            "password-secret",
		Email:               "email-secret",
		Name:                "name-secret",
		PasswordToken:       "token-fixture",
		Pod:                 "12",
	}
	work := t.TempDir()
	session := restoredSession{
		Account: account,
		jar:     jar,
		state:   sessionState{provisioningKey: []byte("provisioning-fixture")},
		address: "01:02:03:04:05:06",
	}
	if err := session.save(work); err != nil {
		t.Fatal(err)
	}
	// The shell provides the SDK's native cookie file from the staged context.
	restore := func() *restoredSession {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(work, "context.json"))
		if err != nil {
			t.Fatal(err)
		}
		for _, private := range []string{"password-secret", "name-secret", "email-secret"} {
			if strings.Contains(string(data), private) {
				t.Fatal("saved a private account field")
			}
		}
		var saved storeContext
		if err := json.Unmarshal(data, &saved); err != nil {
			t.Fatal(err)
		}
		if saved.GUID != "010203040506" {
			t.Fatal("saved device changed")
		}
		if err := os.WriteFile(filepath.Join(work, "cookies.json"), saved.Cookies, 0600); err != nil {
			t.Fatal(err)
		}
		restored, err := restoreStore(work)
		if err != nil {
			t.Fatal(err)
		}
		return restored
	}
	// Older sessions can contain a derived country; restoration ignores it.
	path := filepath.Join(work, "context.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var legacy map[string]any
	if err := json.Unmarshal(data, &legacy); err != nil {
		t.Fatal(err)
	}
	legacy["country"] = "cn"
	data, err = json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	restored := restore()
	if restored.Store == nil || restored.Account.PasswordToken != "token-fixture" || restored.Account.Email != "" || restored.Account.Password != "" || restored.Account.Pod != "12" {
		t.Fatal("unexpected restored account")
	}
	if len(restored.jar.Cookies(origin)) != 2 {
		t.Fatal("scoped cookies were not restored")
	}
	other := &url.URL{Scheme: "https", Host: "other.itunes.apple.com", Path: "/"}
	if len(restored.jar.Cookies(other)) != 1 {
		t.Fatal("cookie scope changed")
	}
	restored.jar.SetCookies(origin, []*http.Cookie{{Name: "host", Value: "rotated", Path: "/auth", Expires: time.Now().Add(time.Hour)}})
	if err := restored.state.Set(provisioningKey, []byte("rotated-proof")); err != nil {
		t.Fatal(err)
	}
	if err := restored.save(work); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var rotated map[string]any
	if err := json.Unmarshal(data, &rotated); err != nil {
		t.Fatal(err)
	}
	if _, ok := rotated["country"]; ok {
		t.Fatal("rotated context retained country")
	}
	reloaded := restore()
	if string(reloaded.state[provisioningKey]) != "rotated-proof" {
		t.Fatal("provisioning did not rotate")
	}
	cookies := reloaded.jar.Cookies(origin)
	if len(cookies) != 2 || cookies[0].Value != "rotated" {
		t.Fatal("cookie did not rotate")
	}
	if len(reloaded.jar.Cookies(other)) != 1 {
		t.Fatal("host cookie escaped scope")
	}
	if err := reloaded.state.Remove(provisioningKey); err != nil {
		t.Fatal(err)
	}
	if err := reloaded.save(work); err == nil {
		t.Fatal("accepted missing provisioning")
	}
}
