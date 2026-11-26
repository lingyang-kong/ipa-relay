package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/majd/ipatool/v2/pkg/appstore"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
)

type downloadFixture struct {
	appstore.AppStore
	withLicense  bool
	licenseError error
	appIDs       []int64
}

func (f *downloadFixture) Download(input appstore.DownloadInput) (appstore.DownloadOutput, error) {
	if input.Account.PasswordToken != "store-token" ||
		input.Platform != appstore.PlatformIPhone || input.ExternalVersionID != "" {
		return appstore.DownloadOutput{}, errors.New("unexpected request for the latest licensed iOS build")
	}
	f.appIDs = append(f.appIDs, input.App.ID)
	result := appstore.DownloadOutput{DestinationPath: input.OutputPath}
	if f.withLicense {
		result.Sinfs = []appstore.Sinf{{Data: []byte("fixture")}}
	}
	return result, os.WriteFile(input.OutputPath, []byte("IPA"), 0600)
}

func (f *downloadFixture) ReplicateSinf(input appstore.ReplicateSinfInput) error {
	if !f.withLicense || len(input.Sinfs) != 1 {
		return errors.New("unexpected license operation")
	}
	if f.licenseError != nil {
		return f.licenseError
	}
	return os.WriteFile(input.PackagePath, []byte("IPA with supplied license"), 0600)
}

func TestDownloadIPA(t *testing.T) {
	session := &restoredSession{Account: appstore.Account{PasswordToken: "store-token"}}
	app := appstore.App{ID: 123}
	for _, withLicense := range []bool{true, false} {
		file := filepath.Join(t.TempDir(), "download.ipa")
		store := &downloadFixture{withLicense: withLicense}
		session.Store = store
		if err := session.downloadIPA(app, file); err != nil {
			t.Fatal(err)
		}
		if !slices.Equal(store.appIDs, []int64{123}) {
			t.Fatalf("unexpected app IDs: %v", store.appIDs)
		}
		data, err := os.ReadFile(file)
		if err != nil || strings.Contains(string(data), "with supplied license") != withLicense {
			t.Fatal("published IPA did not match the returned license data")
		}
	}
	session.Store = &downloadFixture{withLicense: true, licenseError: errors.New("private license response")}
	err := session.downloadIPA(app, filepath.Join(t.TempDir(), "download.ipa"))
	if err == nil || strings.Contains(err.Error(), "private") {
		t.Fatal("license failure was not reported safely")
	}
}

type downloadReply func([]byte) (int, error)

func (reply downloadReply) Write(data []byte) (int, error) { return reply(data) }

func TestDownloadStream(t *testing.T) {
	store := &downloadFixture{withLicense: true}
	session := &restoredSession{Store: store, Account: appstore.Account{PasswordToken: "store-token"}}
	destination := filepath.Join(t.TempDir(), "download.ipa")
	replies := 0
	ack := downloadReply(func(data []byte) (int, error) {
		ipa, err := os.ReadFile(destination)
		if err != nil || string(ipa) != "IPA with supplied license" || string(data) != "ready\n" {
			t.Fatalf("received an invalid download acknowledgement: %q, %v", data, err)
		}
		replies++
		return len(data), os.Remove(destination)
	})
	if err := session.downloadStream(strings.NewReader("123\n456\n"), ack, destination); err != nil {
		t.Fatal(err)
	}
	if replies != 2 || !slices.Equal(store.appIDs, []int64{123, 456}) {
		t.Fatalf("got %d acknowledgements for app IDs %v", replies, store.appIDs)
	}

	store.licenseError = errors.New("private license response")
	if err := session.downloadStream(strings.NewReader("789\n987\n"), ack, destination); err == nil {
		t.Fatal("stream accepted a failed license operation")
	}
	if replies != 2 || !slices.Equal(store.appIDs, []int64{123, 456, 789}) {
		t.Fatalf("stream continued after a failure: %d acknowledgements for %v", replies, store.appIDs)
	}
}

func TestStoreDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{
		{&storehttp.UnexpectedResponseError{StatusCode: 401, Snippet: "private-value"}, "HTTP 401"},
		{appstore.ErrPasswordTokenExpired, "fresh Store sign-in"},
		{appstore.ErrLicenseRequired, "reported no license"},
		{fmt.Errorf("failed to read version metadata: %w", errors.New("private-value")), "Reading Info.plist"},
		{fmt.Errorf("failed to read version metadata: %w", errors.New("expected partial content response, got status 403")), "CDN returned HTTP 403"},
		{errors.New("private-value"), "could not validate"},
	} {
		got := storeOperationError("Licensed app metadata", tc.err).Error()
		if !strings.Contains(got, tc.want) || strings.Contains(got, "private-value") {
			t.Errorf("unexpected diagnostic: %q", got)
		}
	}
}
