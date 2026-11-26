package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/majd/ipatool/v2/pkg/appstore"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
)

func (session *restoredSession) check(app appstore.App) error {
	_, err := session.Store.GetVersionMetadata(appstore.GetVersionMetadataInput{
		Context:  context.Background(),
		Account:  session.Account,
		App:      app,
		Platform: appstore.PlatformIPhone,
	})
	if err != nil {
		return storeOperationError("Licensed app metadata", err)
	}
	return nil
}

func (session *restoredSession) downloadIPA(app appstore.App, destination string) error {
	result, err := session.Store.Download(appstore.DownloadInput{
		Context:    context.Background(),
		Account:    session.Account,
		App:        app,
		Platform:   appstore.PlatformIPhone,
		OutputPath: destination,
	})
	if err != nil {
		return storeOperationError("Licensed IPA download", err)
	}
	if len(result.Sinfs) > 0 {
		err := session.Store.ReplicateSinf(appstore.ReplicateSinfInput{Sinfs: result.Sinfs, PackagePath: destination})
		if err != nil {
			return errors.New("could not add the Store-supplied license to the IPA")
		}
	}
	return nil
}

// downloadStream reads one app ID per line and acknowledges each completed IPA.
// The caller processes and removes the private IPA before sending the next ID.
func (session *restoredSession) downloadStream(requests io.Reader, replies io.Writer, destination string) error {
	scanner := bufio.NewScanner(requests)
	for scanner.Scan() {
		id, err := strconv.ParseInt(scanner.Text(), 10, 64)
		if err != nil || id < 1 {
			return errors.New("invalid App Store ID")
		}
		if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
			return errors.New("the private IPA destination is unavailable")
		}
		if err := session.downloadIPA(appstore.App{ID: id}, destination); err != nil {
			return err
		}
		if _, err := fmt.Fprintln(replies, "ready"); err != nil {
			return errors.New("could not acknowledge the licensed IPA")
		}
	}
	if scanner.Err() != nil {
		return errors.New("could not read App Store download requests")
	}
	return nil
}

// SDK errors can contain credentials, signed URLs or complete Store replies.
func storeOperationError(stage string, err error) error {
	if strings.HasPrefix(err.Error(), "failed to read version metadata:") {
		stage = "Reading Info.plist from the licensed IPA"
		for cause := err; cause != nil; cause = errors.Unwrap(cause) {
			if raw, ok := strings.CutPrefix(cause.Error(), "expected partial content response, got status "); ok {
				if code, err := strconv.Atoi(raw); err == nil && code >= 100 && code <= 599 {
					return fmt.Errorf("%s: the CDN returned HTTP %d for a range request", stage, code)
				}
			}
		}
	}
	var response *storehttp.UnexpectedResponseError
	var transport *storehttp.TransportError
	switch {
	case errors.As(err, &response):
		return fmt.Errorf("%s: Apple returned HTTP %d", stage, response.StatusCode)
	case errors.Is(err, appstore.ErrPasswordTokenExpired):
		return fmt.Errorf("%s: Apple requires a fresh Store sign-in", stage)
	case errors.Is(err, appstore.ErrLicenseRequired):
		return fmt.Errorf("%s: Apple reported no license for this request", stage)
	case errors.As(err, &transport):
		return fmt.Errorf("%s: the connection to Apple failed", stage)
	case strings.Contains(err.Error(), "rate limited by Apple (HTTP 429)"):
		return fmt.Errorf("%s: Apple returned HTTP 429", stage)
	case strings.Contains(err.Error(), "generate Store AMD proof:"):
		return fmt.Errorf("%s: ipatool could not use the saved Store device registration", stage)
	case strings.HasPrefix(err.Error(), "failed to download file:"):
		return errors.New("Apple issued download metadata, but the IPA transfer failed")
	}
	return fmt.Errorf("%s: ipatool could not validate Apple's response", stage)
}
